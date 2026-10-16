import AVFoundation
import Foundation

// Hold-to-talk capture: 16 kHz mono PCM16, transcribed by Step Plan stepaudio-2.5-asr over SSE.
@MainActor final class VoiceInput {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let buffer = PCMBuffer()
    private(set) var recording = false
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start() async throws {
        guard !recording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AIError(message: "没有麦克风权限") }
        default: throw AIError(message: "没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风 → 打开 StepBar")
        }
        buffer.reset()
        let input = engine.inputNode, source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, let converter = AVAudioConverter(from: source, to: Self.format) else { throw AIError(message: "找不到可用的麦克风") }
        self.converter = converter
        let sink = buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { pcm, _ in
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * 16000 / source.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: VoiceInput.format, frameCapacity: capacity) else { return }
            var fed = false, error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return pcm
            }
            if error == nil, let data = out.int16ChannelData { sink.append(Data(bytes: data[0], count: Int(out.frameLength) * 2)) }
        }
        engine.prepare()
        try engine.start()
        recording = true
    }
    func stop() -> Data {
        guard recording else { return Data() }
        engine.inputNode.removeTap(onBus: 0); engine.stop(); recording = false
        return buffer.take()
    }

    nonisolated static func wav(_ pcm: Data) -> Data {
        var data = Data()
        func word(_ value: UInt32, bytes: Int = 4) { for i in 0..<bytes { data.append(UInt8((value >> (i * 8)) & 255)) } }
        data.append(Data("RIFF".utf8)); word(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8))
        word(16); word(1, bytes: 2); word(1, bytes: 2); word(16000); word(32000); word(2, bytes: 2); word(16, bytes: 2)
        data.append(Data("data".utf8)); word(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    nonisolated static func transcriptionRequest(_ pcm: Data, configuration: AIConfiguration) throws -> URLRequest {
        guard !configuration.modelID.isEmpty, !configuration.modelID.contains(where: { $0.isNewline }) else { throw AIError(message: "请配置语音 Model ID") }
        var request = URLRequest(url: try WebSearch.serviceURL(configuration.baseURL), timeoutInterval: 30)
        let boundary = "StepBar-\(UUID().uuidString)"
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty { request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization") }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(configuration.modelID)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav(pcm)); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = body
        return request
    }
    static func transcribeOpenAI(_ pcm: Data, configuration: AIConfiguration, session: URLSession? = nil) async throws -> String {
        guard pcm.count > 8000 else { throw AIError(message: "录音太短") }
        let client = session ?? AIClient(timeout: 30).session
        let (data, response) = try await client.data(for: transcriptionRequest(pcm, configuration: configuration))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 1_000_000 else { throw AIError(message: "自定义语音服务请求失败") }
        struct Transcript: Decodable { var text: String }
        return try JSONDecoder().decode(Transcript.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func transcribe(_ pcm: Data, configuration: AIConfiguration, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard pcm.count > 16000 / 2 else { throw AIError(message: "录音太短") }
        guard var parts = URLComponents(string: configuration.baseURL), parts.scheme == "https" else { throw AIError(message: "语音识别需要 HTTPS 地址") }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        parts.path += "/audio/asr/sse"
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["audio": ["data": pcm.base64EncodedString(), "input": [
            "transcription": ["model": "stepaudio-2.5-asr", "language": "zh", "enable_itn": true],
            "format": ["type": "pcm", "codec": "pcm_s16le", "rate": 16000, "bits": 16, "channel": 1]]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError(message: "语音识别返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        var text = ""
        for try await line in bytes.lines where line.hasPrefix("data:") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "transcript.text.delta": text += event["delta"] as? String ?? ""; partial(text)
            case "transcript.text.done": text = event["text"] as? String ?? text
            case "error": throw AIError(message: "语音识别失败：\((event["message"] as? String) ?? "未知错误")")
            default: break
            }
        }
        // Spoken queries end with "。"; search terms should not.
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？，, ").union(.whitespacesAndNewlines))
    }
}

final class PCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); if data.count < 16000 * 2 * 60 { data.append(chunk) }; lock.unlock() }
    func reset() { lock.lock(); data = Data(); lock.unlock() }
    func take() -> Data { lock.lock(); defer { data = Data(); lock.unlock() }; return data }
}
