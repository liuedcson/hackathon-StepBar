import AppKit
import CryptoKit
import SwiftUI

struct ReleaseManifest: Codable {
    var version: String
    var asset: String
    var sha256: String
    var architecture: String
    static func newer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let values = text.split(separator: ".", omittingEmptySubsequences: false)
            guard values.count == 3 else { return nil }
            let numbers = values.compactMap { Int($0) }
            return numbers.count == 3 && numbers.allSatisfy { $0 >= 0 } ? numbers : nil
        }
        guard let next = parts(candidate), let previous = parts(current) else { return false }
        return previous.lexicographicallyPrecedes(next)
    }
}

@MainActor final class Updater: ObservableObject {
    static let repository = "liuedcson/hackathon-StepBar"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.3" }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    struct Asset: Decodable { var id: Int; var name: String; var size: Int }
    struct Release: Decodable { var tag_name: String; var assets: [Asset]; var draft: Bool; var prerelease: Bool }
    @Published var status = "未检查更新"
    @Published var busy = false
    @Published var available: String?
    @Published var automatic: Bool
    private var ready: (ReleaseManifest, Asset)?
    private var timer: Timer?
    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession? = nil, defaults: UserDefaults = .standard, startChecks: Bool = true) {
        self.session = session ?? AIClient(timeout: 60).session
        self.defaults = defaults
        automatic = (defaults.object(forKey: "StepBarAutomaticUpdates") as? Bool) ?? true
        guard startChecks else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.automatic == true { await self?.check() } }
        }
        if automatic { Task { await check() } }
    }
    func save(automatic: Bool) {
            self.automatic = automatic
            defaults.set(automatic, forKey: "StepBarAutomaticUpdates")
            ready = nil; available = nil
            status = "更新配置已保存"
    }
    private func get(_ path: String, binary: Bool = false, limit: Int) async throws -> Data {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)")!
        var request = URLRequest(url: url)
        request.setValue(binary ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("StepBar/\(Self.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError(message: "GitHub 响应无效") }
        // GitHub normally redirects release downloads to signed object URLs. Never forward the token.
        if binary && [301, 302, 303, 307, 308].contains(http.statusCode) {
            guard let location = http.value(forHTTPHeaderField: "Location"), let redirected = URL(string: location),
                  redirected.scheme == "https", redirected.user == nil, redirected.password == nil,
                  ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(redirected.host) else { throw AIError(message: "不安全的下载重定向") }
            let (bytes, reply) = try await session.data(for: URLRequest(url: redirected))
            guard let reply = reply as? HTTPURLResponse, reply.statusCode == 200, bytes.count <= limit else { throw AIError(message: "更新资源下载失败") }
            return bytes
        }
        guard http.statusCode == 200, data.count <= limit else { throw AIError(message: "GitHub 请求失败（\(http.statusCode)），请稍后重试或手动下载") }
        return data
    }
    func check() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        ready = nil; available = nil; status = "正在检查 GitHub Release…"
        do {
            let release = try JSONDecoder().decode(Release.self, from: await get("releases/latest", limit: 1_000_000))
            guard !release.draft, !release.prerelease,
                  let metadata = release.assets.first(where: { $0.name == "update-\(Self.architecture).json" }) else { throw AIError(message: "Release 缺少适配本机的更新清单") }
            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: await get("releases/assets/\(metadata.id)", binary: true, limit: 16384))
            guard release.tag_name == "v\(manifest.version)", manifest.architecture == Self.architecture,
                  manifest.asset == "StepBar-\(manifest.version)-\(Self.architecture).zip",
                  manifest.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let asset = release.assets.first(where: { $0.name == manifest.asset }), asset.size > 0, asset.size < 100_000_000 else { throw AIError(message: "更新清单无效") }
            if ReleaseManifest.newer(manifest.version, than: Self.version) {
                ready = (manifest, asset); available = manifest.version; status = "发现 v\(manifest.version)，确认后下载并安装"
            } else { status = "当前已是最新版本 v\(Self.version)" }
        } catch { status = error.localizedDescription }
    }
    private func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AIError(message: "更新包验证或准备失败，原应用未改动") }
        return String(decoding: output, as: UTF8.self)
    }
    func install() async {
        guard !busy, let (manifest, asset) = ready else { return }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app", current.lastPathComponent == "StepBar.app",
              FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path),
              let helper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else { status = "请将 StepBar.app 放到有写权限的应用目录"; return }
        busy = true; defer { busy = false }
        var workspace: URL?
        do {
            status = "正在下载并验证 v\(manifest.version)…"
            let bytes = try await get("releases/assets/\(asset.id)", binary: true, limit: 100_000_000)
            guard bytes.count == asset.size, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw AIError(message: "更新包校验不一致，已拒绝安装") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stepbar-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); workspace = folder
            let archive = folder.appendingPathComponent("update.zip")
            try bytes.write(to: archive)
            let entries = try run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n")
            guard !entries.isEmpty, entries.allSatisfy({ $0.hasPrefix("StepBar.app/") && !$0.split(separator: "/").contains("..") && !$0.contains("\\") }) else { throw AIError(message: "更新包路径不安全") }
            let details = try run("/usr/bin/zipinfo", ["-l", archive.path])
            guard !details.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw AIError(message: "更新包包含符号链接，拒绝安装") }
            _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
            let app = folder.appendingPathComponent("StepBar.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == manifest.version else { throw AIError(message: "更新包身份或版本不符") }
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let requirement = try run("/usr/bin/codesign", ["-d", "-r-", current.path]).components(separatedBy: "designated => ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard requirement.contains("certificate leaf") || requirement.contains("anchor") else { throw AIError(message: "当前应用未使用稳定证书签名，请手动更新") }
            _ = try run("/usr/bin/codesign", ["--verify", "-R", requirement, app.path])
            let copiedHelper = folder.appendingPathComponent("install-update.sh")
            try FileManager.default.copyItem(at: helper, to: copiedHelper)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [copiedHelper.path, String(ProcessInfo.processInfo.processIdentifier), app.path, current.path, folder.path]
            try process.run()
            NotificationCenter.default.post(name: .init("StepBarInstallUpdate"), object: nil)
        } catch {
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
            status = error.localizedDescription
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: Updater
    @State private var confirm = false
    var body: some View {
        Section("版本与更新") {
            Text("StepBar v\(Updater.version) · \(Updater.architecture)")
            Text("从公开 GitHub Releases 获取更新，无需 Token。") .font(.caption)
            Toggle("启动时及每 6 小时自动检查更新", isOn: Binding(get: { updater.automatic }, set: { updater.save(automatic: $0) }))
            Button("检查更新") { Task { await updater.check() } }.disabled(updater.busy)
            if let version = updater.available { Button("下载并安装 v\(version)") { confirm = true }.disabled(updater.busy) }
            Text(updater.status).font(.caption).textSelection(.enabled)
            Text("下载后验证 SHA-256、版本与相同签名身份，确认安装时退出并重启。未公证应用首次安装可能需手动放行；更新后 Chrome 扩展需要重新加载。") .font(.caption)
        }
        .alert("安装更新并重启 StepBar？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("安装") { Task { await updater.install() } }
        } message: { Text("当前记忆与配置会保留。下载或验证失败不会替换当前应用。") }
    }
}
