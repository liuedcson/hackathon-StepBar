import Foundation
import Network

struct BrowserTab: Codable, Identifiable {
    var id: Int
    var windowID: Int
    var title: String
    var url: String
    var active: Bool
    var focused: Bool
    var bundle: String
    var identity: String { "\(bundle):\(id)" }
    static let chrome = "com.google.Chrome"
    var ref: BrowserTabRef { BrowserTabRef(tabID: id, windowID: windowID, bundle: bundle) }
}
struct BrowserReport: Codable { var bundle: String?; var tabs: [BrowserTab] }
struct BrowserCommand: Codable {
    var id = UUID()
    var tabID: Int
    var windowID: Int
    var bundle: String
    var date = Date()
    // Set for close commands: tabs to remove instead of focusing tabID.
    var close: [Int]?
    var probe: Bool?
}
struct BrowserAck: Codable { var id: UUID; var success: Bool }

// Loopback-only HTTP bridge; pairing token required on every endpoint.
final class BrowserBridge {
    private let port: UInt16
    private let fallbackCount: UInt16
    init(port: UInt16 = 17373, fallbackCount: UInt16 = 20) { self.port = port; self.fallbackCount = fallbackCount }
    private let queue = DispatchQueue(label: "StepBar.browser-bridge")
    private var listener: NWListener?
    private var token = ""
    private var commands: [BrowserCommand] = []
    var onReport: ((BrowserReport) -> Void)?
    var onStatus: ((String) -> Void)?
    var onAck: ((BrowserAck) -> Void)?
    var onPage: ((PageText) -> Void)?
    var onHeartbeat: (() -> Void)?
    var onPort: ((UInt16) -> Void)?
    func start(token: String) {
        queue.async {
            self.listener?.cancel(); self.listener = nil; self.token = token; self.commands = []
            self.listen(port: self.port)
        }
    }
    private func listen(port: UInt16) {
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    if case .ready = state { self.onPort?(port); self.onStatus?("浏览器桥接就绪") }
                    if case .failed(let error) = state {
                        listener.cancel(); self.listener = nil
                        if case .posix(.EADDRINUSE) = error, UInt32(port) < min(65535, UInt32(self.port) + UInt32(self.fallbackCount)) {
                            self.listen(port: port + 1)
                        } else { self.onStatus?("Chrome 连接启动失败，请重试") }
                    }
                }
                self.listener = listener; listener.start(queue: self.queue)
            } catch { self.onStatus?("无法启动浏览器桥接") }
    }
    func stop() { queue.async { self.listener?.cancel(); self.listener = nil; self.commands = [] } }
    @discardableResult func jump(_ ref: BrowserTabRef) -> UUID {
        send(BrowserCommand(tabID: ref.tabID, windowID: ref.windowID, bundle: ref.bundle))
    }
    @discardableResult func close(_ tabIDs: [Int], bundle: String) -> UUID {
        send(BrowserCommand(tabID: tabIDs.first ?? 0, windowID: 0, bundle: bundle, close: tabIDs))
    }
    @discardableResult func testConnection() -> UUID {
        send(BrowserCommand(tabID: 0, windowID: 0, bundle: BrowserTab.chrome, probe: true))
    }
    private func send(_ command: BrowserCommand) -> UUID {
        queue.async {
            self.commands.append(command)
            self.queue.asyncAfter(deadline: .now() + 10) {
                if self.commands.contains(where: { $0.id == command.id }) {
                    self.commands.removeAll { $0.id == command.id }
                    self.onAck?(BrowserAck(id: command.id, success: false))
                }
            }
        }
        return command.id
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { connection.cancel() }
        receive(connection, buffer: Data())
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count < 1_000_000 else { self.respond(connection, status: 413, data: Data()); return }
            guard let marker = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: buffer[..<marker.lowerBound], encoding: .utf8) else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }; return
            }
            let lines = header.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 && length < 900_000 else { self.respond(connection, status: 400, data: Data()); return }
            if buffer.count - marker.upperBound < length {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }; return
            }
            let route = lines[0].split(separator: " ").map(String.init)
            guard route.count >= 2 else { self.respond(connection, status: 400, data: Data()); return }
            if route[0] == "OPTIONS" { self.respond(connection, status: 204, data: Data()); return }
            guard headers["authorization"] == "Bearer \(self.token)" else { self.respond(connection, status: 401, data: Data()); return }
            let body = Data(buffer[marker.upperBound..<(marker.upperBound + length)])
            self.handle(route[0], route[1], headers: headers, body: body, connection: connection)
        }
    }
    private func handle(_ method: String, _ path: String, headers: [String: String], body: Data, connection: NWConnection) {
        switch (method, path) {
        case ("POST", "/events"):
            guard var report = try? JSONDecoder().decode(BrowserReport.self, from: body), report.tabs.count <= 500 else { self.respond(connection, status: 400, data: Data()); return }
            report.tabs = report.tabs.filter { $0.bundle == BrowserTab.chrome }
                .compactMap { tab in
                    guard let url = Privacy.url(tab.url), Inference.safeURL(url) != nil else { return nil }
                    var tab = tab; tab.title = Privacy.text(tab.title); tab.url = url; return tab
                }
            self.onReport?(report); self.respond(connection, status: 200, data: Data("{}".utf8))
        case ("GET", "/command"):
            if headers["x-browser-bundle"] == BrowserTab.chrome { self.onHeartbeat?() }
            self.commands.removeAll { Date().timeIntervalSince($0.date) > 10 }
            // Browser-specific polling prevents another connected browser consuming the command.
            let bundle = headers["x-browser-bundle"] ?? ""
            let command = self.commands.first { $0.bundle == bundle }
            let data = command.flatMap { try? JSONEncoder().encode($0) } ?? Data("{}".utf8)
            self.respond(connection, status: 200, data: data)
        case ("POST", "/page"):
            guard let page = try? JSONDecoder().decode(PageText.self, from: body), let clean = PageIndex.sanitized(page) else { self.respond(connection, status: 400, data: Data()); return }
            self.onPage?(clean); self.respond(connection, status: 200, data: Data("{}".utf8))
        case ("POST", "/ack"):
            if let ack = try? JSONDecoder().decode(BrowserAck.self, from: body), self.commands.contains(where: { $0.id == ack.id }) {
                self.commands.removeAll { $0.id == ack.id }; self.onAck?(ack)
            }
            self.respond(connection, status: 200, data: Data("{}".utf8))
        default: self.respond(connection, status: 404, data: Data())
        }
    }
    private func respond(_ connection: NWConnection, status: Int, data: Data) {
        let header = "HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Authorization, Content-Type, X-Browser-Bundle\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
