import AppKit
import SwiftUI

@MainActor final class Store: ObservableObject {
    @Published var memory = Memory()
    @Published var settings = Settings()
    @Published var paused = false
    @Published var status = "准备就绪"
    @Published var aiStatus = "AI 未启用 · 本地规则"
    @Published var bridgeStatus = "等待 Chrome 扩展连接"
    @Published var testingAI = false
    @Published var launcherModel = ""
    @Published var browserTabs: [BrowserTab] = []
    @Published var query = "" {
        didSet {
            // Large pastes: keep one line and a bounded length so typing stays responsive.
            if query.count > 400 || query.contains(where: \.isNewline) {
                query = String(query.prefix(400)).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            }
            if query != oldValue { queryChanged() }
        }
    }
    @Published var results: [SearchItem] = []
    @Published var selection = 0
    @Published var thinking = false
    @Published var generating = false
    @Published var intent: String?
    @Published var focusRequest = 0
    @Published var listening = false
    @Published var diagnosticTab = "settings"
    @Published var backgroundStatus = "后台：等待空闲"
    @Published var historyStatus = "正在读取近 90 天 Chrome 历史…"
    @Published var usage = UsageLedger()
    @Published var sessionUsage = TokenUsage()
    @Published var bridgeReady = false
    @Published var bridgeHeartbeat = Date.distantPast
    @Published var testingBridge = false
    @Published var bridgeTestStatus = ""
    private var bridgeProbe: UUID?
    private var bridgePort: UInt16 = 17373
    var preparationSchedule = PreparationSchedule()
    var historyLoading = false
    var allHistory: [SearchItem] = []
    private var usageObserver: NSObjectProtocol?
    var history: [SearchItem] = []
    var searchPages: [SearchItem] = []
    var siteSearches: [Recipe] = []
    var historyAt = Date.distantPast
    var pages: [String: PageText] = [:]
    var pagesDirty = false
    // Layer 2 results for the current query, computed off the main thread.
    var semanticHits: [SearchItem] = []
    // StepFun web search context for the current query, given to layer 3 and cached per query.
    var webHits: [SearchItem] = []
    var webCache: [String: [WebResult]] = [:]
    var aiPicks: [String: Double] = [:]
    var aiActions: [SearchItem] = []
    var aiCandidates: [SearchItem] = []
    var searchGeneration = 0
    // The Chrome tab in front when the hotkey was pressed.
    var currentPage: BrowserTab?
    var browserUpdated = Date.distantPast
    var launcherOpen = false
    var budget = Budget()
    var pendingSave = false
    let voice = VoiceInput()
    let updater = Updater()
    let bridge = BrowserBridge()
    let ai = AIClient()
    private var timer: Timer?
    private var pasteCount = NSPasteboard.general.changeCount
    @Published private var clipText: String?
    private var clipDate = Date.distantPast
    // A copied id waiting to show up in the address of the next page opened: that is a query entry to learn.
    private var copied: (value: String, date: Date)?
    private var lastActiveURL: String?
    private var savedAt = Date.distantPast
    private var jobsAt = Date().addingTimeInterval(-45)
    private var jobTask: Task<Void, Never>?
    var pendingJumps: [UUID: SearchItem] = [:]
    let path: URL
    let settingsPath: URL
    let pagesPath: URL
    private var memoryWritable = true
    private var settingsWritable = true
    private static func preserveUnreadable(_ file: URL) -> Bool {
        do {
            let backup = file.appendingPathExtension("unreadable-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            return true
        } catch { return false }
    }

    init() {
        let folder = Settings.folder
        path = folder.appendingPathComponent("memory.json")
        settingsPath = folder.appendingPathComponent("settings.json")
        pagesPath = folder.appendingPathComponent("pages.json")
        if let data = try? Data(contentsOf: folder.appendingPathComponent("usage.json")), let saved = try? JSONDecoder().decode(UsageLedger.self, from: data) { usage = saved }
        usageObserver = NotificationCenter.default.addObserver(forName: TokenUsage.notification, object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.object as? TokenUsage else { return }
            Task { @MainActor in
                guard let self else { return }
                self.sessionUsage.add(value); self.usage.record(value)
                let snapshot = self.usage, file = folder.appendingPathComponent("usage.json")
                Self.writer.async { try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic) }
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pages = PageIndex.load(pagesPath)
        if let data = try? Data(contentsOf: path) {
            do { memory = try JSONDecoder().decode(Memory.self, from: data) }
            catch { memoryWritable = Self.preserveUnreadable(path); status = memoryWritable ? "记忆文件无法读取，已保存原文件备份。" : "记忆文件无法读取，已停止写入以保留原文件。" }
        } else if FileManager.default.fileExists(atPath: path.path) {
            memoryWritable = false; status = "记忆文件无法访问，已停止写入以保留原文件。"
        }
        if let data = try? Data(contentsOf: settingsPath) {
            do { settings = try JSONDecoder().decode(Settings.self, from: data) }
            catch { settingsWritable = Self.preserveUnreadable(settingsPath); status = "设置文件无法读取，已保留原文件或备份。" }
        } else if FileManager.default.fileExists(atPath: settingsPath.path) {
            settingsWritable = false; status = "设置文件无法访问，未覆盖原文件。"
        }
        // Written back on every launch so migrated values replace old ones and retired fields drop out.
        if settingsWritable, let normalized = try? JSONEncoder().encode(settings), normalized != (try? Data(contentsOf: settingsPath)) { try? normalized.write(to: settingsPath, options: .atomic) }
        if let local = RuntimeChecks.localConfig(settings) {
            if settings.isCustom {
                let summary = local.customSummary ?? local.summary, quick = local.customQuick ?? local.quick ?? summary
                settings.customBackgroundURL = summary.baseURL; settings.customBackgroundModel = summary.modelID
                settings.customForegroundURL = quick.baseURL; settings.customForegroundModel = quick.modelID
            } else {
                if local.summary.baseURL == Settings.stepPlan { settings.modelID = local.summary.modelID }
                if local.quick?.baseURL == Settings.stepPlan { settings.quickModelID = local.quick?.modelID ?? "step-3.7-flash" }
            }
        }
        refreshModelLabels()
        bridge.onReport = { [weak self] report in Task { @MainActor in self?.receiveBrowser(report) } }
        bridge.onStatus = { [weak self] message in Task { @MainActor in self?.bridgeStatus = message } }
        bridge.onPort = { [weak self] port in Task { @MainActor in
            guard let self else { return }
            self.bridgePort = port; self.writePairing()
        } }
        bridge.onAck = { [weak self] ack in Task { @MainActor in
            guard let self else { return }
            if ack.id == self.bridgeProbe {
                self.bridgeProbe = nil; self.testingBridge = false
                self.bridgeTestStatus = ack.success ? "连接成功" : "未收到扩展响应，请确认 Chrome 已打开并加载最新扩展"
                if ack.success { self.bridgeHeartbeat = Date(); self.refreshBridgeHealth() }
            } else { self.acknowledgeJump(ack) }
        } }
        bridge.onPage = { [weak self] page in Task { @MainActor in self?.receivePage(page) } }
        bridge.onHeartbeat = { [weak self] in Task { @MainActor in
            guard let self else { return }
            self.bridgeHeartbeat = Date(); self.refreshBridgeHealth()
        } }
        if settings.browserBridge { bridge.start(token: settings.bridgeToken) }
        writePairing()
        reloadHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func refreshModelLabels() {
        aiStatus = settings.aiEnabled ? "后台 \(settings.backgroundModel)" : "AI 未启用 · 本地规则"
        launcherModel = settings.aiEnabled ? settings.foregroundModel : "未启用"
    }
    var aiDescription: String { settings.aiEnabled ? "后台理解 \(settings.backgroundModel) · 唤起 \(settings.foregroundModel)" : "模型未启用" }
    func saveSettings(_ draft: Settings, key: String, clearKey: Bool, foregroundKey: String = "", clearForegroundKey: Bool = false, searchKey: String = "", clearSearchKey: Bool = false, voiceKey: String = "", clearVoiceKey: Bool = false) {
        guard settingsWritable else { aiStatus = "设置原文件尚未安全备份，未保存修改"; return }
        do {
            if draft.aiEnabled {
                _ = try AIClient.endpoint(draft.backgroundURL)
                _ = try AIClient.endpoint(draft.foregroundURL)
            }
            if draft.aiEnabled && [draft.backgroundModel, draft.foregroundModel].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw AIError(message: "请填写后台和前台 Model ID") }
            var updated = draft
            if updated.isCustom {
                if updated.customSearchMode == "api" { _ = try WebSearch.serviceURL(updated.customSearchURL) }
                if updated.customSearchMode == "engine", WebSearch.engineItem("test", template: updated.searchEngineTemplate) == nil { throw AIError(message: "搜索引擎模板需要恰好一个 {query} 和安全网址") }
                if updated.customVoiceEnabled {
                    _ = try WebSearch.serviceURL(updated.customVoiceURL)
                    guard !updated.customVoiceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError(message: "请填写语音 Model ID") }
                }
            }
            updated.retentionDays = min(90, max(1, updated.retentionDays))
            let current = RuntimeChecks.summaryConfiguration(settings)
            let summaryKey = clearKey ? "" : !key.isEmpty ? key.trimmingCharacters(in: .whitespacesAndNewlines) : updated.backgroundAccount == settings.backgroundAccount ? current.apiKey : Keychain.read(updated.backgroundAccount)
            let foregroundCurrent = RuntimeChecks.quickConfiguration(settings)
            let quickKey = !updated.isCustom ? summaryKey : clearForegroundKey ? "" : !foregroundKey.isEmpty ? foregroundKey.trimmingCharacters(in: .whitespacesAndNewlines) : updated.foregroundAccount == settings.foregroundAccount ? foregroundCurrent.apiKey : Keychain.read(updated.foregroundAccount)
            let needsNewKey = (updated.backgroundAccount != settings.backgroundAccount && summaryKey.isEmpty) ||
                (updated.isCustom && updated.foregroundAccount != settings.foregroundAccount && quickKey.isEmpty)
            if let path = updated.localConfigPath {
                var input = RuntimeChecks.localConfig(settings) ?? ConfigurationInput(summary: .init(baseURL: Settings.stepPlan, modelID: "step-5-preview", apiKey: ""))
                let summary = ConfigurationInput.Summary(baseURL: updated.backgroundURL, modelID: updated.backgroundModel, apiKey: summaryKey)
                let quick = ConfigurationInput.Summary(baseURL: updated.foregroundURL, modelID: updated.foregroundModel, apiKey: quickKey)
                if updated.isCustom { input.customSummary = summary; input.customQuick = quick }
                else { input.summary = summary; input.quick = quick }
                if updated.isCustom {
                    let savedSearch = clearSearchKey ? "" : !searchKey.isEmpty ? searchKey : updated.searchAccount == settings.searchAccount ? RuntimeChecks.searchKey(settings) : Keychain.read(updated.searchAccount)
                    let savedVoice = clearVoiceKey ? "" : !voiceKey.isEmpty ? voiceKey : updated.voiceAccount == settings.voiceAccount ? RuntimeChecks.voiceConfiguration(settings).apiKey : Keychain.read(updated.voiceAccount)
                    input.customSearch = .init(endpoint: updated.customSearchURL, apiKey: savedSearch)
                    input.customVoice = .init(endpoint: updated.customVoiceURL, apiKey: savedVoice, modelID: updated.customVoiceModel)
                }
                try RuntimeChecks.writeLocal(input, path: path)
            } else {
                if clearKey || !key.isEmpty { try Keychain.write(summaryKey, account: updated.backgroundAccount) }
                if updated.isCustom && (clearForegroundKey || !foregroundKey.isEmpty) { try Keychain.write(quickKey, account: updated.foregroundAccount) }
                if updated.isCustom && (clearSearchKey || !searchKey.isEmpty) { try Keychain.write(clearSearchKey ? "" : searchKey, account: updated.searchAccount) }
                if updated.isCustom && (clearVoiceKey || !voiceKey.isEmpty) { try Keychain.write(clearVoiceKey ? "" : voiceKey, account: updated.voiceAccount) }
            }
            try JSONEncoder().encode(updated).write(to: settingsPath, options: .atomic)
            stopJobs()
            if listening { _ = voice.stop(); listening = false }
            searchGeneration += 1; webCache = [:]; resetAI()
            settings = updated
            browserTabs = []; browserUpdated = .distantPast
            pendingJumps = [:]
            bridgeHeartbeat = .distantPast; bridgeReady = false
            if settings.browserBridge { bridge.start(token: settings.bridgeToken) } else { bridge.stop(); bridgeStatus = "浏览器桥接已关闭" }
            writePairing()
            clipText = nil; copied = nil
            refreshModelLabels()
            status = "设置已保存"
            aiStatus = needsNewKey ? "设置已保存，新服务地址需填写 Key；旧服务的 Key 保留" : "设置已保存"
            NotificationCenter.default.post(name: .init("StepBarSettingsChanged"), object: nil)
            save()
            preparationSchedule = PreparationSchedule(); backgroundJobs()
        } catch { status = error.localizedDescription }
    }
    var extensionFolder: URL? {
        let folder = Settings.folder.appendingPathComponent("browser-extension")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) ? folder : nil
    }
    var downloadExtensionFolder: URL {
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))
            .appendingPathComponent("StepBar-browser-extension", isDirectory: true)
    }
    // Lets the unpacked extension pair itself; the file is git-ignored and only readable by the extension.
    func writePairing() {
        prepareUninstaller()
        let target = Settings.folder.appendingPathComponent("browser-extension")
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("browser-extension"), FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for file in ["manifest.json", "background.js", "options.html", "options.js", "icons"] {
                    let destination = target.appendingPathComponent(file)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: bundled.appendingPathComponent(file), to: destination)
                }
            } catch { status = "扩展资源安装失败，请重试。" }
        }
        guard let folder = extensionFolder else { return }
        let data = try? JSONEncoder().encode(["token": settings.bridgeToken, "port": String(bridgePort)])
        try? data?.write(to: folder.appendingPathComponent("pairing.json"), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("pairing.json").path)
        let exported = downloadExtensionFolder
        if FileManager.default.fileExists(atPath: exported.appendingPathComponent(".stepbar-managed").path) {
            try? data?.write(to: exported.appendingPathComponent("pairing.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exported.appendingPathComponent("pairing.json").path)
        }
    }
    func installExtension() {
        writePairing()
        guard let source = extensionFolder else {
            status = "未找到扩展资源，请检查安装包。"
            return
        }
        let folder = downloadExtensionFolder
        let manager = FileManager.default
        let marker = folder.appendingPathComponent(".stepbar-managed")
        do {
            if manager.fileExists(atPath: folder.path), !manager.fileExists(atPath: marker.path) {
                status = "下载目录中已存在非 StepBar 管理的 StepBar-browser-extension 文件夹，请先重命名它再重试。"
                return
            }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("StepBar extension export\n".utf8).write(to: marker, options: .atomic)
            for file in ["manifest.json", "background.js", "options.html", "options.js", "icons", "pairing.json"] {
                let destination = folder.appendingPathComponent(file)
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.copyItem(at: source.appendingPathComponent(file), to: destination)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("pairing.json").path)
        } catch {
            status = "无法将扩展准备到下载目录：\(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserTab.chrome), let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
        status = "扩展已准备到下载目录的 StepBar-browser-extension。Chrome → 开发者模式 → 加载已解压的扩展程序，选择该文件夹；安装后请勿删除或移动。"
        bridgeTestStatus = "在 Chrome 开启开发者模式，加载已解压的扩展程序，选择刚打开的文件夹。完成后点击测试连接。"
    }
    func testBrowserConnection() {
        guard !testingBridge else { return }
        guard settings.browserBridge, !paused else { bridgeTestStatus = "请先启用 Chrome 扩展连接并恢复 StepBar"; return }
        testingBridge = true; bridgeTestStatus = "正在测试…"
        bridgeProbe = bridge.testConnection()
        let probe = bridgeProbe
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard self.bridgeProbe == probe else { return }
            self.bridgeProbe = nil; self.testingBridge = false
            self.bridgeTestStatus = "未收到扩展响应，请确认 Chrome 已打开并加载最新扩展"
        }
    }
    private func prepareUninstaller() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let script = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else { return }
        do {
            let folder = Settings.folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("uninstall.sh")
            try Data(contentsOf: script).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            try Data(Bundle.main.bundleURL.path.utf8).write(to: folder.appendingPathComponent("app-location.txt"), options: .atomic)
        } catch { status = "卸载工具准备失败：\(error.localizedDescription)" }
    }
    func togglePause() {
        paused.toggle(); stopJobs()
        searchGeneration += 1; resetAI()
        pendingJumps = [:]
        if listening { listening = false; _ = voice.stop() }
        clipText = nil; copied = nil
        pasteCount = NSPasteboard.general.changeCount
        if paused { results = [] }
        status = paused ? "已暂停：不读取剪贴板、不学习、不调用 AI" : "已恢复"
        refreshBridgeHealth()
        if !paused { backgroundJobs() }
    }

    // MARK: Collection
    func tick() {
        refreshBridgeHealth()
        guard !paused else { return }
        let now = Date()
        if now.timeIntervalSince(historyAt) >= PreparationSchedule.interval { reloadHistory() }
        if NSPasteboard.general.changeCount != pasteCount { readClipboard(now: now) }
        if now.timeIntervalSince(jobsAt) > 5 { jobsAt = now; backgroundJobs() }
        if pendingSave && now.timeIntervalSince(savedAt) > 5 { save() }
    }
    func receiveBrowser(_ report: BrowserReport) {
        guard settings.browserBridge, !paused else { return }
        browserTabs = report.tabs.filter { !settings.excludes(url: $0.url) }
        browserUpdated = Date()
        bridgeHeartbeat = Date(); refreshBridgeHealth()
        var known = Set(allHistory.map(\.id))
        for tab in browserTabs where known.insert(SearchItem.urlID(tab.url)).inserted {
            var item = SearchItem.tab(tab); item.date = Date(); item.visits = 1
            allHistory.append(item)
        }
        backgroundJobs()
        guard let active = browserTabs.first(where: { $0.active && $0.focused }), active.url != lastActiveURL else { return }
        lastActiveURL = active.url
        learn(from: active.url)
    }
    // What the pages the user opens teach: a search results page becomes "search this site", and an address
    // containing the id copied just before becomes a query entry for that kind of id.
    func learn(from url: String) {
        if let (template, _) = Inference.searchTemplate(url: url), let host = URL(string: url)?.host {
            let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if let index = memory.recipes.firstIndex(where: { $0.shape == "search" && $0.template == template }) {
                memory.recipes[index].count += 1; memory.recipes[index].updated = Date()
            } else { memory.recipes.append(Recipe(source: "search", template: template, label: label, shape: "search")) }
            pendingSave = true
        }
        if let copied, Date().timeIntervalSince(copied.date) < 120,
           let template = Inference.template(url: url, object: copied.value), Inference.learnable(template, value: copied.value) {
            let shape = Inference.shape(copied.value)
            if let index = memory.recipes.firstIndex(where: { $0.template == template && $0.shape == shape }) {
                memory.recipes[index].count += 1; memory.recipes[index].updated = Date()
            } else { memory.recipes.append(Recipe(source: "clipboard", template: template, label: URL(string: url)?.host ?? "网页", shape: shape)) }
            self.copied = nil; pendingSave = true
            status = "已学到一个查询入口：\(template)"
        }
    }
    func receivePage(_ page: PageText) {
        guard !paused, !settings.excludes(url: page.url) else { return }
        PageIndex.insert(page, into: &pages); pagesDirty = true; pendingSave = true
        backgroundJobs()
    }
    func refreshBridgeHealth() {
        bridgeReady = BridgeHealth.ready(enabled: settings.browserBridge, paused: paused, heartbeat: bridgeHeartbeat)
        if bridgeReady { bridgeStatus = "Ready · Chrome 扩展已连接 · \(browserTabs.count) 个标签页" }
        else if !settings.browserBridge { bridgeStatus = "未启用 Chrome 桥接" }
        else if paused { bridgeStatus = "已暂停 · Chrome 数据采集暂停" }
        else if bridgeHeartbeat != .distantPast { bridgeStatus = "连接已过期 · 请确认 Chrome 和扩展正在运行" }
    }
    // Any copied text is kept briefly as context; password-manager copies and secret-looking text are skipped.
    func readClipboard(now: Date) {
        let board = NSPasteboard.general
        pasteCount = board.changeCount
        clipDate = now
        let concealed = (board.types ?? []).contains { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"].contains($0.rawValue) }
        let raw = concealed ? nil : board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A copied secret is dropped entirely; phone numbers and e-mail addresses are masked and the rest kept.
        var safe = raw.flatMap { !$0.isEmpty && Privacy.secrets($0) == $0 ? String(Privacy.personal($0).prefix(500)) : nil }
        if let text = safe, Inference.safeURL(text) != nil { safe = Privacy.url(text) }
        clipText = safe
        copied = Inference.object(safe).map { ($0, now) }
    }
    var copiedText: String? { paused || Date().timeIntervalSince(clipDate) > 300 ? nil : clipText }
    // Called on the hotkey before the panel takes focus.
    func captureInvocation() {
        guard !paused else { return }
        if NSPasteboard.general.changeCount != pasteCount { readClipboard(now: Date()) }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentPage = front == BrowserTab.chrome && Date().timeIntervalSince(browserUpdated) < 60 ? browserTabs.first { $0.active && $0.focused } : nil
    }

    // MARK: Background understanding (step-5-preview)
    // Immediate cold start, then time/count-triggered batches, independent of power and idle state.
    func backgroundJobs() {
        guard settings.aiEnabled, settings.background, !memory.learningPaused, !paused, jobTask == nil, !allHistory.isEmpty else { return }
        let config = Study.configuration(settings)
        guard !config.apiKey.isEmpty, !config.modelID.isEmpty, !config.baseURL.isEmpty else {
            backgroundStatus = "历史 AI 准备：请先保存可用的后台模型与 Key；本地查询路径不受影响"; return
        }
        guard Date() >= budget.retryAt else { return }
        let sites = Array(PatternMiner.pending(history: allHistory, studied: memory.studied).prefix(PatternMiner.hostsPerCall))
        let notes = Array(Understand.pending(pool: freshTabs + allHistory, notes: memory.notes, pages: pages).filter { !memory.deletedNotes.contains($0.id) }.prefix(Understand.batch))
        guard !sites.isEmpty || !notes.isEmpty else {
            _ = preparationSchedule.shouldRun(pending: 0)
            backgroundStatus = "后台：已理解 \(memory.notes.count) 个页面、\(memory.patterns.count) 个网址模式"; return
        }
        let pending = Understand.pending(pool: allHistory, notes: memory.notes, pages: pages).filter { !memory.deletedNotes.contains($0.id) }.count + PatternMiner.pending(history: allHistory, studied: memory.studied).count
        guard preparationSchedule.shouldRun(pending: pending) else { backgroundStatus = "后台：新增待分析 \(pending) 条 · 满 10 条或每 15 分钟处理"; return }
        let pages = self.pages, started = Date()
        let siteCounts = Dictionary(grouping: allHistory.filter { !Clean.blocked($0.url) }.compactMap { $0.url.flatMap(PatternMiner.host) }, by: { $0 }).mapValues(\.count)
        jobTask = Task { [weak self] in
            do {
                // URL patterns first: few calls, and they make whole sites reachable by parameter.
                if !sites.isEmpty {
                    self?.backgroundStatus = "后台：\(config.modelID) 正在分析 \(sites.map(\.host).joined(separator: "、")) 的网址结构"
                    let found = try await Study.patterns(sites, configuration: config)
                    guard let self, !Task.isCancelled else { return }
                    let hosts = Set(sites.map(\.host))
                    let foundTemplates = Set(found.map(\.template))
                    self.memory.patterns.removeAll { hosts.contains($0.host) && foundTemplates.contains($0.template) }
                    self.memory.patterns += found.filter { !self.memory.deletedPatterns.contains($0.template) }
                    for site in sites { self.memory.studied[site.host] = Studied(pages: siteCounts[site.host] ?? site.items.count) }
                    self.budget.spent(PatternMiner.payload(sites).count * 2 / 3 + 3000)
                    self.backgroundStatus = "后台：找到 \(found.count) 个网址模式 · \(Int(Date().timeIntervalSince(started)))s"
                } else {
                    self?.backgroundStatus = "后台：\(config.modelID) 正在理解 \(notes.count) 个页面"
                    let written = try await Study.notes(notes, pages: pages, configuration: config)
                    guard let self, !Task.isCancelled else { return }
                    guard !written.isEmpty else { throw AIError(message: "后台未返回可用页面理解，稍后重试") }
                    self.memory.notes.merge(written.filter { !self.memory.deletedNotes.contains($0.key) }) { $1 }
                    self.budget.spent(Understand.payload(notes, pages: pages).count * 2 / 3 + notes.count * 150 + 3000)
                    self.backgroundStatus = "后台：理解了 \(written.count) 个页面 · \(Int(Date().timeIntervalSince(started)))s · 共 \(self.memory.notes.count)"
                }
                self?.pendingSave = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.budget.failed()
                self.backgroundStatus = "后台：失败（\(error.localizedDescription)），\(Int(self.budget.retryAt.timeIntervalSinceNow))s 后重试"
            }
            self?.jobTask = nil
            // More to do: continue on the next tick instead of waiting a minute.
            self?.jobsAt = .distantPast
        }
    }
    var preparationProgress: String {
        let pending = Understand.pending(pool: allHistory, notes: memory.notes, pages: pages).filter { !memory.deletedNotes.contains($0.id) }.count
        let understood = allHistory.filter { memory.notes[$0.id] != nil }.count
        return "AI 页面准备 \(understood)/\(allHistory.count) · 待处理 \(pending) · 首次立即准备，新增满 10 条或每 15 分钟增量分析"
    }
    func stopJobs() { jobTask?.cancel(); jobTask = nil }
    func yieldToForeground() {
        launcherOpen = true
    }
    func testAI() {
        guard !testingAI else { return }
        testingAI = true
        let configurations = [Study.configuration(settings), RuntimeChecks.quickConfiguration(settings)]
        Task { [weak self] in
            guard let self else { return }
            defer { self.testingAI = false }
            var statuses: [String] = []
            for (index, config) in configurations.enumerated() {
                let label = index == 0 ? "后台" : "前台"
                do {
                    try await self.ai.probe(configuration: config)
                    statuses.append("\(label)：连接成功")
                } catch { statuses.append("\(label)：\(error.localizedDescription)") }
            }
            self.aiStatus = statuses.joined(separator: " · ")
        }
    }

    // MARK: Opening
    func acknowledgeJump(_ ack: BrowserAck) {
        guard let item = pendingJumps.removeValue(forKey: ack.id) else { return }
        guard !paused else { return }
        if ack.success { status = "已切换到标签页：\(item.title)"; return }
        // The tab was closed or moved meanwhile: open the page instead.
        if let text = item.url, let url = Inference.safeURL(text) { openWeb(url); status = "标签页已不在，已重新打开" }
    }
    func save() {
        guard memoryWritable else { pendingSave = false; status = "记忆原文件尚未安全备份，未覆盖"; return }
        let excluded = settings.excludes
        memory.recipes.removeAll { excluded($0.template.replacingOccurrences(of: "{value}", with: "x")) }
        memory.patterns.removeAll { excluded($0.template.replacingOccurrences(of: "{value}", with: "x")) }
        memory.notes = memory.notes.filter { !($0.key.hasPrefix("u:") && excluded(String($0.key.dropFirst(2)))) }
        let now = Date(), cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86400)
        if !allHistory.isEmpty { memory.notes = Understand.prune(memory.notes, alive: Set(allHistory.map(\.id) + freshTabs.map(\.id)), now: now) }
        // Learned entries are what makes StepBar better with use: they stay until unused for 180 days.
        let stale = now.addingTimeInterval(-180 * 86400)
        memory.recipes = Array(memory.recipes.filter { $0.updated > stale }.sorted { $0.updated < $1.updated }.suffix(300))
        if memory.choices.count > 1000 { memory.choices = Dictionary(uniqueKeysWithValues: memory.choices.sorted { $0.value > $1.value }.prefix(1000).map { ($0.key, $0.value) }) }
        if memory.queryChoices.count > 800 { memory.queryChoices = Dictionary(uniqueKeysWithValues: memory.queryChoices.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }.prefix(800).map { ($0.key, $0.value) }) }
        let wanted = Set(memory.queryChoices.values.flatMap(\.keys)).union(memory.choices.keys)
        memory.remembered = memory.remembered.filter { wanted.contains($0.key) }
        memory.searchLog = Array(memory.searchLog.filter { $0.date > cutoff }.suffix(500))
        var pageSnapshot: [String: PageText]?
        let retainedPages = pages.filter { $0.value.date > cutoff && !excluded($0.value.url) }
        if pagesDirty || retainedPages.count != pages.count { pages = retainedPages; pageSnapshot = retainedPages; pagesDirty = false }
        // Encoding happens off the main thread on a value copy. The serial queue keeps writes in order.
        let snapshot = memory, path = self.path, pagesPath = self.pagesPath
        pendingSave = false; savedAt = now
        Store.writer.async {
            if let pageSnapshot { PageIndex.save(pageSnapshot, to: pagesPath) }
            do { try JSONEncoder().encode(snapshot).write(to: path, options: .atomic) }
            catch { let message = error.localizedDescription; Task { @MainActor in self.status = "保存失败：\(message)" } }
        }
    }
    static let writer = DispatchQueue(label: "stepbar.save", qos: .utility)
    func clear() {
        let deletedNotes = memory.deletedNotes, deletedPatterns = memory.deletedPatterns
        stopJobs(); pendingJumps = [:]; memory = Memory(); results = []; pages = [:]; pagesDirty = true; clipText = nil; copied = nil
        memory.deletedNotes = deletedNotes; memory.deletedPatterns = deletedPatterns
        memory.learningPaused = true; preparationSchedule = PreparationSchedule()
        save(); status = "本地记忆已清空"
    }
    func removeRecipe(_ id: UUID) { memory.recipes.removeAll { $0.id == id }; save() }
    func removePattern(_ id: UUID) {
        if let pattern = memory.patterns.first(where: { $0.id == id }) { memory.deletedPatterns.insert(pattern.template) }
        memory.patterns.removeAll { $0.id == id }; save()
    }
    func removeNote(_ id: String) { memory.deletedNotes.insert(id); memory.notes[id] = nil; save() }
    func resetAfterWake() { stopJobs(); clipText = nil; copied = nil }
}
