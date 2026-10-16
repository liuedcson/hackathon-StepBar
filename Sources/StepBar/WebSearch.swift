import Foundation

struct WebResult: Codable, Equatable {
    var title: String
    var url: String
    var snippet: String
    var time: String?
}

// Before layer 3 the typed words go to StepFun web search once, so the fast model picks and builds addresses with
// what the web says today (a project's real repository, a product launched after the model was trained).
// Only the query is sent: never the clipboard, page text or history.
enum WebSearch {
    static let count = 5
    // Validate an explicitly configured service URL without silently adding any provider-specific path.
    static func serviceURL(_ endpoint: String) throws -> URL {
        _ = try AIClient.endpoint(endpoint)
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AIError(message: "服务地址无效") }
        return url
    }
    static func engineItem(_ query: String, template: String) -> SearchItem? {
        guard allows(query), template.components(separatedBy: "{query}").count == 2,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics),
              let url = Inference.safeURL(template.replacingOccurrences(of: "{query}", with: encoded)) else { return nil }
        return SearchItem(id: SearchItem.urlID(url.absoluteString), kind: .action, title: "在 \(url.host ?? "搜索引擎") 搜索「\(query)」", subtitle: SearchItem.short(url.absoluteString), url: url.absoluteString, note: "搜索引擎")
    }
    // Configurable JSON search gateway: POST {query,n}, Bearer key, {results:[{title,url,snippet,time?}]}.
    static func customSearch(_ query: String, endpoint: String, apiKey: String, session: URLSession = WebSearch.session) async throws -> [WebResult] {
        var request = URLRequest(url: try serviceURL(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "n": count])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 1_000_000 else { throw AIError(message: "自定义搜索服务请求失败") }
        struct Envelope: Decodable { var results: [WebResult] }
        return cleaned(try JSONDecoder().decode(Envelope.self, from: data).results)
    }
    // Not worth a public search: recalling a page seen before, a typed link, or text with an id or a secret in it.
    static func allows(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 120, Inference.safeURL(text) == nil, Privacy.text(text) == text else { return false }
        guard !["上周", "昨天", "前天", "刚才", "刚刚", "之前", "上次", "那篇", "看过", "看的", "打开过"].contains(where: text.contains) else { return false }
        return !Inference.values(in: text).contains(where: privateID)
    }
    // Order numbers, long identifiers and UUIDs are not public search terms; "gpt-5" and "2026" are fine.
    static func privateID(_ value: String) -> Bool {
        switch Inference.shape(value) {
        case "number": return value.count >= 6
        case "word": return false
        case "id": return value.count >= 12
        default: return true
        }
    }
    // Same base as the chat endpoint: …/step_plan/v1 → …/step_plan/v1/search.
    static func endpoint(_ base: String) throws -> URL {
        let chat = try AIClient.endpoint(base).absoluteString
        guard let url = URL(string: String(chat.dropLast("/chat/completions".count)) + "/search") else { throw AIError(message: "Base URL 无效") }
        return url
    }
    static func search(_ query: String, configuration: AIConfiguration, session: URLSession = WebSearch.session) async throws -> [WebResult] {
        var request = URLRequest(url: try endpoint(configuration.baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty { request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "n": count])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError(message: "联网搜索返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        struct Envelope: Decodable { var results: [WebResult]? }
        return cleaned((try JSONDecoder().decode(Envelope.self, from: data)).results ?? [])
    }
    // Results are untrusted page text: masked, shortened, http(s) only, sensitive parameters dropped.
    static func cleaned(_ results: [WebResult]) -> [WebResult] {
        var seen = Set<String>()
        return results.prefix(count).compactMap { result in
            guard let url = Privacy.url(result.url), Inference.safeURL(url) != nil, seen.insert(SearchItem.urlID(url)).inserted else { return nil }
            let snippet = Privacy.text(result.snippet.replacingOccurrences(of: "\n", with: " "))
            return WebResult(title: String(Privacy.text(SearchItem.clean(result.title)).prefix(80)), url: url, snippet: String(snippet.prefix(160)), time: result.time.map { String($0.prefix(10)) })
        }
    }
    // Reports often quote the real address ("开源地址：https://github.com/org/repo"). Those links come first as their
    // own candidates, so layer 3 opens the source instead of the repost that mentions it.
    static func items(_ results: [WebResult]) -> [SearchItem] {
        var seen = Set(results.map { SearchItem.urlID($0.url) }), cited: [SearchItem] = []
        for result in results {
            for link in links(in: result.snippet) where seen.insert(SearchItem.urlID(link)).inserted {
                var item = SearchItem(id: SearchItem.urlID(link), kind: .action, title: "\(SearchItem.short(link))（\(result.title.prefix(20)) 中提到）", subtitle: SearchItem.short(link), url: link, note: "联网")
                item.content = result.snippet
                cited.append(item)
            }
        }
        let pages = results.map { result in
            var item = SearchItem(id: SearchItem.urlID(result.url), kind: .action, title: result.title.isEmpty ? SearchItem.short(result.url) : result.title, subtitle: SearchItem.short(result.url), url: result.url, note: "联网")
            item.content = result.snippet
            return item
        }
        return Array(cited.prefix(3)) + pages
    }
    // http(s) links written in snippet text, with a path (a bare home page says little), cleaned like any other URL.
    static func links(in text: String) -> [String] {
        // Require a delimiter after the address: snippets can end halfway through a URL.
        let pattern = "https?://[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/[A-Za-z0-9._~/%-]+(?=[\\s，。；、）)\\\"<>])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "./-"))
            guard let url = Privacy.url(raw), Inference.safeURL(url) != nil else { return nil }
            return url
        }
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3.5
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
}
