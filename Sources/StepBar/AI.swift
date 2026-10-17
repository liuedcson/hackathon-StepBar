import Foundation

struct AIConfiguration {
    var baseURL: String
    var modelID: String
    var apiKey: String
    var jsonMode = false
    var reasoningEffort: String?
    var maxTokens: Int?
}
struct AIError: LocalizedError {
    var message: String
    var truncated = false
    var errorDescription: String? { message }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct AIClient {
    let session: URLSession
    init(session: URLSession? = nil, timeout: Double = 120) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout + 30
            self.session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }
    }
    // Step Plan speaks OpenAI Chat Completions.
    static func endpoint(_ base: String) throws -> URL {
        guard var parts = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw AIError(message: "Base URL 需要 HTTPS（本机服务允许 HTTP），且不能含凭据、查询参数或片段。")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        let suffix = "/chat/completions"
        if !parts.path.hasSuffix(suffix) { parts.path += suffix }
        guard let url = parts.url else { throw AIError(message: "Base URL 无效") }
        return url
    }
    // Connectivity only: truncated output is expected and no JSON generation is required.
    func probe(configuration: AIConfiguration) async throws {
        guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError(message: "请填写 Model ID") }
        var request = URLRequest(url: try Self.endpoint(configuration.baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty { request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": configuration.modelID, "stream": false, "max_tokens": 1, "messages": [["role": "user", "content": "Hi"]]])
        let (data, response) = try await session.data(for: request)
        TokenUsage.report(data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError(message: "AI 连通性检查失败；检查地址、模型和 API Key。")
        }
        guard data.count <= 1_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], !choices.isEmpty,
              choices[0]["message"] is [String: Any] else { throw AIError(message: "服务未返回 Chat Completions 响应") }
    }
    func complete<T: Decodable>(_ type: T.Type, configuration: AIConfiguration, system: String, payload: String) async throws -> T {
        guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError(message: "请填写 Model ID") }
        var request = URLRequest(url: try Self.endpoint(configuration.baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty { request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": configuration.modelID, "stream": false, "messages": [["role": "system", "content": system], ["role": "user", "content": payload]]]
        if configuration.jsonMode { body["response_format"] = ["type": "json_object"] }
        if let effort = configuration.reasoningEffort { body["reasoning_effort"] = effort }
        if let limit = configuration.maxTokens { body["max_tokens"] = limit }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        TokenUsage.report(data)
        guard let http = response as? HTTPURLResponse else { throw AIError(message: "服务返回无效响应") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not expose the provider body: it can contain echoed private prompts or credentials.
            throw AIError(message: "AI 服务返回 HTTP \(http.statusCode)；检查地址、模型、API Key 或 JSON 模式。")
        }
        guard data.count <= 1_000_000 else { throw AIError(message: "AI 返回内容过大") }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError(message: "AI 返回无效 JSON") }
            if let choices = json["choices"] as? [[String: Any]], choices.first?["finish_reason"] as? String == "length" {
                throw AIError(message: "AI 输出达到上限，未采纳不完整结果", truncated: true)
            }
            guard let choices = json["choices"] as? [[String: Any]], let first = choices.first,
                  first["finish_reason"] as? String != "length",
                  let message = first["message"] as? [String: Any], let content = message["content"] as? String else { throw AIError(message: "AI 响应缺少完整 choices[0].message.content") }
            let cleaned = Self.cleanJSON(content)
            if let log = ProcessInfo.processInfo.environment["STEPBAR_DEBUG"], log.hasPrefix("/") { try? Data("\(payload.prefix(1500))\n→ \(content.prefix(1500))\n\n".utf8).append(to: log) }
            do { return try JSONDecoder().decode(type, from: Data(cleaned.utf8)) }
            catch {
                if ProcessInfo.processInfo.environment["STEPBAR_DEBUG"] != nil { FileHandle.standardError.write(Data("raw: \(content.prefix(800))\n".utf8)) }
                throw AIError(message: "AI 结果不符合结构；已保留本地规则结果。")
            }
        }
    }
    static func cleanJSON(_ content: String) -> String {
        var value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), let line = value.firstIndex(of: "\n"), value.hasSuffix("```") {
            value = String(value[value.index(after: line)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A sentence before or after the object: keep the outermost {...}.
        if !value.hasPrefix("{"), let open = value.firstIndex(of: "{"), let close = value.lastIndex(of: "}"), open < close { value = String(value[open...close]) }
        return value
    }
}

extension Data {
    func append(to path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(self) }
        else { try write(to: URL(fileURLWithPath: path)) }
    }
}
