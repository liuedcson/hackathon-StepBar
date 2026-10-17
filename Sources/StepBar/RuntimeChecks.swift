import AppKit

struct ConfigurationInput: Codable {
    // provider is always "openAI" (the Chat Completions protocol Step Plan speaks); kept for existing config files.
    struct Summary: Codable { var provider: String? = "openAI"; var baseURL: String; var modelID: String; var apiKey: String; var reasoningEffort: String? }
    var summary: Summary
    // Fast model for the launcher (intent and actions while the panel is open); summary is the background model.
    var quick: Summary?
    var customSummary: Summary?
    var customQuick: Summary?
    struct Service: Codable { var endpoint: String; var apiKey: String; var modelID: String? }
    var customSearch: Service?
    var customVoice: Service?
}
enum RuntimeChecks {
    static var settingsPath: URL {
        Settings.folder.appendingPathComponent("settings.json")
    }
    static func localConfig(_ settings: Settings) -> ConfigurationInput? {
        guard let path = settings.localConfigPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(ConfigurationInput.self, from: data)
    }
    static func summaryConfiguration(_ settings: Settings) -> AIConfiguration {
        let file = localConfig(settings)
        let local = settings.isCustom ? file?.customSummary ?? file?.summary : file?.summary
        let key = local?.baseURL == settings.backgroundURL ? local?.apiKey ?? "" : Keychain.read(settings.backgroundAccount)
        return AIConfiguration(baseURL: settings.backgroundURL, modelID: settings.backgroundModel, apiKey: key, jsonMode: settings.jsonMode, reasoningEffort: settings.isCustom ? nil : "high")
    }
    static func quickConfiguration(_ settings: Settings) -> AIConfiguration {
        var config = quickBase(settings)
        // For comparing models from the command line: STEPBAR_QUICK_MODEL=step-5-preview StepBar --model-bench
        let env = ProcessInfo.processInfo.environment
        if let model = env["STEPBAR_QUICK_MODEL"] { config.modelID = model }
        if let effort = env["STEPBAR_QUICK_EFFORT"] { config.reasoningEffort = effort }
        return config
    }
    static func quickBase(_ settings: Settings) -> AIConfiguration {
        let file = localConfig(settings)
        let local = settings.isCustom ? file?.customQuick ?? file?.quick : file?.quick
        let key = local?.baseURL == settings.foregroundURL ? local?.apiKey ?? "" : settings.isCustom ? Keychain.read(settings.foregroundAccount) : summaryConfiguration(settings).apiKey
        return AIConfiguration(baseURL: settings.foregroundURL, modelID: settings.foregroundModel, apiKey: key, jsonMode: settings.jsonMode, reasoningEffort: settings.isCustom ? nil : "low", maxTokens: 600)
    }
    static func stepPlanConfiguration(_ settings: Settings) -> AIConfiguration {
        let file = localConfig(settings)
        let local = [file?.quick, file?.summary].compactMap { $0 }.first { $0.baseURL == Settings.stepPlan && !$0.apiKey.isEmpty }
        return AIConfiguration(baseURL: Settings.stepPlan, modelID: "step-3.7-flash", apiKey: local?.apiKey ?? Keychain.read("openAI:\(Settings.stepPlan)"))
    }
    static func searchKey(_ settings: Settings) -> String {
        let local = localConfig(settings)?.customSearch
        return local?.endpoint == settings.customSearchURL ? local?.apiKey ?? "" : Keychain.read(settings.searchAccount)
    }
    static func voiceConfiguration(_ settings: Settings) -> AIConfiguration {
        guard settings.isCustom else { return stepPlanConfiguration(settings) }
        let local = localConfig(settings)?.customVoice
        let key = local?.endpoint == settings.customVoiceURL ? local?.apiKey ?? "" : Keychain.read(settings.voiceAccount)
        return AIConfiguration(baseURL: settings.customVoiceURL, modelID: settings.customVoiceModel, apiKey: key)
    }
    static func writeLocal(_ input: ConfigurationInput, path: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(input).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    static func exportLocal() throws {
        var settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsPath))
        let summary = summaryConfiguration(settings)
        guard !summary.apiKey.isEmpty else { throw AIError(message: "Credentials unavailable") }
        let path = FileManager.default.currentDirectoryPath + "/config.local.json"
        let quick = quickConfiguration(settings)
        var input = localConfig(settings) ?? ConfigurationInput(summary: .init(baseURL: Settings.stepPlan, modelID: settings.modelID, apiKey: stepPlanConfiguration(settings).apiKey))
        let savedSummary = ConfigurationInput.Summary(baseURL: summary.baseURL, modelID: summary.modelID, apiKey: summary.apiKey)
        let savedQuick = ConfigurationInput.Summary(baseURL: quick.baseURL, modelID: quick.modelID, apiKey: quick.apiKey)
        if settings.isCustom { input.customSummary = savedSummary; input.customQuick = savedQuick }
        else { input.summary = savedSummary; input.quick = savedQuick }
        try writeLocal(input, path: path)
        settings.localConfigPath = path
        try JSONEncoder().encode(settings).write(to: settingsPath, options: .atomic)
        print("Local config created; no credentials printed.")
    }
    static func configure() throws {
        let input = try JSONDecoder().decode(ConfigurationInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
        _ = try AIClient.endpoint(input.summary.baseURL)
        var settings = (try? Data(contentsOf: settingsPath)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        settings.baseURL = input.summary.baseURL; settings.modelID = input.summary.modelID
        settings.aiProvider = input.summary.baseURL == Settings.stepPlan ? "stepPlan" : "custom"
        settings.quickModelID = input.quick?.modelID ?? "step-3.7-flash"
        if settings.isCustom {
            settings.customBackgroundURL = input.summary.baseURL; settings.customBackgroundModel = input.summary.modelID
            settings.customForegroundURL = input.quick?.baseURL ?? input.summary.baseURL
            settings.customForegroundModel = input.quick?.modelID ?? input.summary.modelID
        }
        settings.aiEnabled = true; settings.hotkey = "commandM"
        if CommandLine.arguments.contains("--local") {
            let path = FileManager.default.currentDirectoryPath + "/config.local.json"
            try writeLocal(input, path: path)
            settings.localConfigPath = path
        } else {
            try Keychain.write(input.summary.apiKey, account: settings.backgroundAccount)
            if settings.isCustom { try Keychain.write(input.quick?.apiKey ?? input.summary.apiKey, account: settings.foregroundAccount) }
        }
        try FileManager.default.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsPath, options: .atomic)
        print("Configured AI; credentials saved locally, not printed.")
    }
    // Synthetic data only: one page to understand, one site to find patterns in, one launcher call.
    static func liveCheck() async {
        guard let data = try? Data(contentsOf: settingsPath), let settings = try? JSONDecoder().decode(Settings.self, from: data) else { print("FAIL: configuration missing"); return }
        let config = Study.configuration(settings)
        let page = SearchItem(id: SearchItem.urlID("https://www.unixtimestamp.com/"), kind: .history, title: "Unix Time Stamp - Epoch Converter", subtitle: "", url: "https://www.unixtimestamp.com/", visits: 3)
        var start = Date()
        do {
            let notes = try await Study.notes([page], pages: [:], configuration: config)
            print("Understand (\(config.modelID)): \(notes.isEmpty ? "FAIL no note" : "PASS") · \(ms(start)) ms · \(notes.values.first.map { "\($0.purpose) · \($0.terms.joined(separator: "、"))" } ?? "")")
        } catch { print("Understand: FAIL · \(error.localizedDescription)") }
        let repos = ["openai/whisper", "rust-lang/rust", "apple/swift", "torvalds/linux"].map { SearchItem(id: SearchItem.urlID("https://github.com/\($0)"), kind: .history, title: "GitHub - \($0)", subtitle: "", url: "https://github.com/\($0)") }
        start = Date()
        do {
            let found = try await Study.patterns([(host: "github.com", items: repos)], configuration: config)
            print("Patterns: \(found.isEmpty ? "FAIL none validated" : "PASS") · \(ms(start)) ms · \(found.map(\.template).joined(separator: " "))")
        } catch { print("Patterns: FAIL · \(error.localizedDescription)") }
        start = Date()
        do {
            let payload = Assistant.payload(query: "deepseek github", candidates: [], recipes: [], searches: [], patterns: [])
            let result = try await AIClient().complete(AIActions.self, configuration: quickConfiguration(settings), system: Assistant.actionPrompt, payload: payload)
            let templates = Assistant.templates(query: "deepseek github", candidates: [], recipes: [], searches: [], patterns: [])
            let actions = Assistant.validated(result, query: "deepseek github", templates: templates)
            print("Launcher (\(quickConfiguration(settings).modelID)): \(actions.isEmpty ? "FAIL no verified action" : "PASS") · \(ms(start)) ms · \(actions.compactMap(\.url).joined(separator: " "))")
        } catch { print("Launcher: FAIL · \(error.localizedDescription)") }
    }
}

extension RuntimeChecks {
    struct SearchData { var settings: Settings; var memory: Memory; var history: [SearchItem]; var searches: [SearchItem]; var pages: [String: PageText] }
    static var memoryPath: URL { Settings.folder.appendingPathComponent("memory.json") }
    static func loadSearchData() -> SearchData {
        let settings = (try? Data(contentsOf: settingsPath)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        let memory = (try? Data(contentsOf: memoryPath)).flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        let (history, searches) = BrowserHistory.split(BrowserHistory.load().filter { !settings.excludes(url: $0.url ?? "") })
        return SearchData(settings: settings, memory: memory, history: history, searches: searches, pages: PageIndex.load(Settings.folder.appendingPathComponent("pages.json")))
    }
    static func layers(_ data: SearchData) -> Layers {
        let entries = Layers.entries(BrowserHistory.searches(data.history + data.searches, learned: data.memory.recipes.filter { $0.shape == "search" }), patterns: data.memory.patterns)
        return Layers(pool: Understand.enrich(data.history, notes: data.memory.notes), memory: data.memory, entries: entries, searchPages: data.searches)
    }
    static func webItems(_ query: String, settings: Settings) async -> [SearchItem] {
        guard settings.webSearch, WebSearch.allows(query) else { return [] }
        let found: [WebResult]
        if settings.isCustom {
            guard settings.customSearchMode == "api", let result = try? await WebSearch.customSearch(query, endpoint: settings.customSearchURL, apiKey: searchKey(settings)) else { return [] }
            found = result
        } else {
            let config = stepPlanConfiguration(settings)
            guard !config.apiKey.isEmpty, let result = try? await WebSearch.search(query, configuration: config) else { return [] }
            found = result
        }
        return WebSearch.items(found).map { var item = $0; item.layer = "联网结果"; return item }
    }
    static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
    static func generate(_ query: String, candidates: [SearchItem], data: SearchData, layers: Layers) async throws -> AIActions {
        let payload = Assistant.payload(query: query, candidates: candidates, recipes: data.memory.recipes, searches: layers.entries, patterns: data.memory.patterns)
        return try await AIClient().complete(AIActions.self, configuration: quickConfiguration(data.settings), system: Assistant.actionPrompt, payload: payload)
    }
    static func validated(_ result: AIActions, query: String, candidates: [SearchItem], data: SearchData, layers: Layers) -> [SearchItem] {
        Assistant.validated(result, query: query, candidates: candidates,
                            templates: Assistant.templates(query: query, candidates: candidates, recipes: data.memory.recipes, searches: layers.entries, patterns: data.memory.patterns))
    }

    // Runs the three launcher layers on real history and memory for one query; nothing is stored.
    static func searchCheck(_ query: String) async {
        var start = Date()
        let data = loadSearchData(), layers = layers(data)
        print("index: \(data.history.count) pages · \(data.memory.notes.count) understood · \(data.memory.patterns.count) patterns · \(data.pages.count) with text · \(ms(start)) ms")
        start = Date()
        let (direct, matches) = layers.history(query)
        print("L1 历史匹配 \(ms(start)) ms:")
        for item in direct.prefix(3) { print("  → \(item.title.prefix(50)) <\((item.url ?? "").prefix(80))>") }
        for item in matches.prefix(5) { print("  [\(item.kind.rawValue)] \(item.title.prefix(60))\(item.note.map { " · \($0)" } ?? "")") }
        start = Date()
        let semantic = LocalIndex(pool: layers.pool).match(query: query, boost: layers.boosts(query), limit: 30)
        print("L2 语义匹配 \(ms(start)) ms:")
        for item in semantic.prefix(5) { print("  [\(item.kind.rawValue)] \(item.title.prefix(50)) · \(item.purpose.prefix(40))") }
        start = Date()
        let webTask = Task { await webItems(query, settings: data.settings) }
        let web = await SoftDeadline.wait(for: webTask) ?? []
        print("联网搜索 \(ms(start)) ms:\(WebSearch.allows(query) && data.settings.webSearch ? "" : " 跳过")")
        for item in web.prefix(5) { print("  \(item.title.prefix(40)) <\(SearchItem.short(item.url ?? "").prefix(60))> \(item.content.prefix(50))") }
        let candidates = layers.candidates(query, semantic: semantic, web: web)
        start = Date()
        do {
            let result = try await generate(query, candidates: candidates, data: data, layers: layers)
            print("L3 ✦ Step \(ms(start)) ms · \(result.intent ?? "-")")
            for (id, confidence) in Assistant.picks(result, from: candidates, query: query).sorted(by: { $0.value > $1.value }) {
                print("  pick \(Int(confidence * 100))% \(candidates.first { $0.id == id }.map { "[\($0.layer)] \($0.title.prefix(60))" } ?? id)")
            }
            for action in validated(result, query: query, candidates: candidates, data: data, layers: layers) { print("  生成: \(action.title) <\(action.url ?? "")>") }
        } catch { print("L3 failed: \(error.localizedDescription)") }
    }

    // Layer 3 latency over a query set, built the same way as the panel builds it.
    static func modelBench(_ queries: [String]) async {
        let data = loadSearchData(), layers = layers(data)
        print("model \(quickConfiguration(data.settings).modelID) · effort \(quickConfiguration(data.settings).reasoningEffort ?? "-")")
        var total = 0
        let index = LocalIndex(pool: layers.pool)
        for query in queries {
            let semantic = index.match(query: query, boost: layers.boosts(query), limit: 30)
            var start = Date()
            let webTask = Task { await webItems(query, settings: data.settings) }
            let web = await SoftDeadline.wait(for: webTask) ?? [], searchMS = ms(start)
            let candidates = layers.candidates(query, semantic: semantic, web: web)
            start = Date()
            do {
                let result = try await generate(query, candidates: candidates, data: data, layers: layers)
                let took = ms(start); total += took
                let picks = Assistant.picks(result, from: candidates, query: query).sorted { $0.value > $1.value }.compactMap { id, p in candidates.first { $0.id == id }.map { "\(Int(p * 100))% \($0.title.prefix(30))" } }
                let actions = validated(result, query: query, candidates: candidates, data: data, layers: layers).map { "\($0.title.prefix(24)) <\(($0.url ?? "").prefix(70))>" }
                print("\(String(format: "%5d", took)) ms (+联网 \(searchMS) ms) 「\(query)」 \(result.intent ?? "-")\n      picks: \(picks.joined(separator: " · "))\n      actions: \(actions.joined(separator: " · "))")
            } catch { print("  fail 「\(query)」 \(error.localizedDescription)") }
        }
        print("total \(total) ms · avg \(total / max(1, queries.count)) ms")
    }

    // Replays logged searches (query → what the user finally opened) and reports how often layers 1+2 had it.
    // Query-choice learning is left out so the number shows what a first-time search gets.
    static func evalSearch(ai: Bool, limit: Int) async {
        let data = loadSearchData()
        var fresh = data; fresh.memory.queryChoices = [:]; fresh.memory.choices = [:]
        let layers = layers(fresh)
        var seen = Set<String>()
        let cases = data.memory.searchLog.reversed().filter { seen.insert(Semantic.normalize($0.query) + "|" + $0.chosen).inserted }.prefix(limit)
        guard !cases.isEmpty else { print("no logged searches yet: use ⌘M for a while, then run again"); return }
        var top1 = 0, top3 = 0, recalled = 0, aiTop1 = 0, aiRuns = 0, misses: [String] = []
        let index = LocalIndex(pool: layers.pool)
        for log in cases {
            let (direct, matches) = layers.history(log.query), local = direct + matches
            let candidates = layers.candidates(log.query, semantic: index.match(query: log.query, limit: 30))
            let rank = local.firstIndex { $0.id == log.chosen }
            if rank == 0 { top1 += 1 }
            if let rank, rank < 3 { top3 += 1 }
            if candidates.contains(where: { $0.id == log.chosen }) { recalled += 1 } else { misses.append("「\(log.query)」→ \(log.title.prefix(40))") }
            if ai && rank != 0 && candidates.contains(where: { $0.id == log.chosen }) {
                aiRuns += 1
                if let result = try? await generate(log.query, candidates: candidates, data: data, layers: layers),
                   Assistant.picks(result, from: candidates, query: log.query).max(by: { $0.value < $1.value })?.key == log.chosen { aiTop1 += 1 }
            }
        }
        let n = Double(cases.count)
        print("cases \(cases.count) · L1 top1 \(Int(Double(top1) / n * 100))% · L1 top3 \(Int(Double(top3) / n * 100))% · 融合 Recall@5 \(Int(Double(recalled) / n * 100))%")
        if ai { print("L3 picked the target first in \(aiTop1)/\(aiRuns) cases where L1 top1 missed") }
        for miss in misses.prefix(10) { print("  not in candidates: \(miss)") }
    }

    // Runs the background study now (no idle or power gate) and saves it, printing what was learned.
    @MainActor static func understand(rounds: Int) async {
        var data = loadSearchData()
        let config = Study.configuration(data.settings)
        print("model \(config.modelID) · effort \(config.reasoningEffort ?? "-") · \(data.history.count) pages")
        for round in 1...max(1, rounds) {
            let sites = Array(PatternMiner.pending(history: data.history + data.searches, studied: data.memory.studied).prefix(PatternMiner.hostsPerCall))
            let notes = Array(Understand.pending(pool: data.history, notes: data.memory.notes, pages: data.pages).prefix(Understand.batch))
            if sites.isEmpty && notes.isEmpty { print("nothing left to study"); break }
            let start = Date()
            do {
                if !sites.isEmpty {
                    let found = try await Study.patterns(sites, configuration: config)
                    let hosts = Set(sites.map(\.host))
                    data.memory.patterns.removeAll { hosts.contains($0.host) }
                    data.memory.patterns += found
                    for site in sites { data.memory.studied[site.host] = Studied(pages: site.items.count) }
                    print("round \(round) · patterns of \(hosts.sorted().joined(separator: ", ")) · \(ms(start)) ms")
                    for pattern in found { print("  \(pattern.label) \(pattern.template) · \(pattern.param) · e.g. \(pattern.examples.prefix(2).joined(separator: ", "))") }
                }
                if !notes.isEmpty {
                    let start = Date()
                    let written = try await Study.notes(notes, pages: data.pages, configuration: config)
                    data.memory.notes.merge(written) { $1 }
                    print("round \(round) · \(written.count) page notes · \(ms(start)) ms")
                    for (id, note) in written.prefix(4) { print("  \(note.title.prefix(30)) → \(note.purpose) · \(note.terms.joined(separator: "、")) · \(note.asks.joined(separator: " / ")) (\(id.prefix(50)))") }
                }
            } catch { print("round \(round) failed: \(error.localizedDescription)"); break }
            try? JSONEncoder().encode(data.memory).write(to: memoryPath, options: .atomic)
        }
    }

    // Transcribes a 16 kHz mono 16-bit WAV through the same code as hold-⌥.
    @MainActor static func voiceCheck(_ path: String) async {
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: path)), let marker = wav.range(of: Data("data".utf8)) else { print("voice: cannot read \(path)"); return }
        let start = Date()
        do {
            let settings = loadSearchData().settings
            guard settings.voiceAvailable else { throw AIError(message: "语音未启用") }
            let pcm = Data(wav.suffix(from: marker.upperBound + 4))
            let config = voiceConfiguration(settings)
            let text: String
            if settings.isCustom { text = try await VoiceInput.transcribeOpenAI(pcm, configuration: config) }
            else { text = try await VoiceInput.transcribe(pcm, configuration: config) { _ in } }
            print("voice: \(text) · \(ms(start)) ms")
        } catch { print("voice: FAIL \(error.localizedDescription)") }
    }

    // Before/after counts for history cleaning on real data. Prints aggregates only.
    static func cleanCheck() {
        var start = Date()
        let all = BrowserHistory.load()
        let loadMS = ms(start); start = Date()
        let (candidates, searches) = BrowserHistory.split(all)
        let splitMS = ms(start)
        func dupTitles(_ items: [SearchItem]) -> Int { Dictionary(grouping: items, by: { $0.title.lowercased() }).values.filter { $0.count > 1 }.reduce(0) { $0 + $1.count } }
        let blocked = all.filter { Clean.blocked($0.url) }.count
        print("history: \(all.count) → candidates \(candidates.count) (search pages moved out \(searches.count), login/OAuth/redirect \(blocked), merged \(all.count - blocked - searches.count - candidates.count))")
        print("  same-title entries: \(dupTitles(all)) → \(dupTitles(candidates)) · load \(loadMS) ms · split+merge \(splitMS) ms")
        let memory = (try? Data(contentsOf: memoryPath)).flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        print("memory: notes \(memory.notes.count) · patterns \(memory.patterns.count) · recipes \(memory.recipes.count) · learned queries \(memory.queryChoices.count)")
        print("  pending: \(Understand.pending(pool: candidates, notes: memory.notes, pages: [:]).count) pages to understand · \(PatternMiner.pending(history: candidates + searches, studied: memory.studied).count) sites to study")
        print("gate: \(Gate.now().description)")
    }
}
