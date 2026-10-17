import Foundation

@main struct BridgeTests {
    static func main() async throws {
        let bridge = BrowserBridge(port: 18776)
        let token = "synthetic-pairing-only"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.onStatus = { status in
                if status.contains("就绪") { continuation.resume() }
                else { continuation.resume(throwing: AIError(message: status)) }
            }
            bridge.start(token: token)
        }
        defer { bridge.stop() }
        let session = URLSession(configuration: .ephemeral)
        func send(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, bundle: String = "com.google.Chrome") async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18776\(path)")!)
            request.timeoutInterval = 3; request.httpMethod = method; request.httpBody = body
            if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.setValue(bundle, forHTTPHeaderField: "X-Browser-Bundle")
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        let (_, unauthorized) = try await send("/events", method: "POST", body: Data("{}".utf8), authenticated: false)
        precondition(unauthorized == 401)
        bridge.onReport = { report in
            precondition(report.tabs.count == 1)
            precondition(report.tabs[0].url == "https://work.example/orders/12345")
            precondition(report.bundle == "com.google.Chrome")
        }
        let tab = BrowserTab(id: 7, windowID: 9, title: "Order", url: "https://work.example/orders/12345", active: true, focused: true, bundle: "com.google.Chrome")
        var secret = tab; secret.id = 8; secret.url = "https://work.example/?access_token=secret"
        let report = BrowserReport(bundle: "com.google.Chrome", tabs: [tab, secret])
        let (_, reported) = try await send("/events", method: "POST", body: JSONEncoder().encode(report))
        precondition(reported == 200)
        bridge.jump(tab.ref)
        let (empty, _) = try await send("/command", bundle: "com.microsoft.edgemac")
        precondition(String(data: empty, encoding: .utf8) == "{}")
        let (data, status) = try await send("/command")
        precondition(status == 200)
        let command = try JSONDecoder().decode(BrowserCommand.self, from: data)
        precondition(command.tabID == 7 && command.windowID == 9)
        bridge.onAck = { ack in precondition(ack.id == command.id && ack.success) }
        let (_, acknowledged) = try await send("/ack", method: "POST", body: JSONEncoder().encode(BrowserAck(id: command.id, success: true)))
        precondition(acknowledged == 200)
        let (afterAck, _) = try await send("/command")
        precondition(String(data: afterAck, encoding: .utf8) == "{}")
        bridge.onAck = { ack in precondition(ack.success, "Enqueuing a second command must not fail the first") }
        let first = bridge.jump(tab.ref)
        let second = bridge.close([7], bundle: tab.bundle)
        let (queued, _) = try await send("/command")
        let queuedCommand = try JSONDecoder().decode(BrowserCommand.self, from: queued)
        precondition(queuedCommand.id == first)
        _ = try await send("/ack", method: "POST", body: JSONEncoder().encode(BrowserAck(id: first, success: true)))
        let (next, _) = try await send("/command")
        let nextCommand = try JSONDecoder().decode(BrowserCommand.self, from: next)
        precondition(nextCommand.id == second)
        _ = try await send("/ack", method: "POST", body: JSONEncoder().encode(BrowserAck(id: second, success: true)))
        print("PASS: loopback bridge auth, context, command routing and acknowledgement")
    }
}
