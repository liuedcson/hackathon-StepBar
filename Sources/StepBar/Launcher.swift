import AppKit

// The launcher answers in three layers, all as fast as possible:
//   1. 历史匹配 — original titles and URLs; deterministic actions stay on a separate UI path.
//   2. 语义匹配 — local and instant: what the background model wrote about each page (purpose, bilingual keywords,
//      typical requests), so other words for the same page still find it.
//   3. ✦ Step — after 150 ms without typing, the typed words go to StepFun web search once; step-3.7-flash then gets
//      what layers 1 and 2 found, the fresh web results and the learned patterns, picks the answer and, when nothing
//      fits, builds a URL.
extension Store {
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    static let debounce: UInt64 = 150_000_000

    func prepareLauncher() {
        searchGeneration += 1
        resetAI(); semanticHits = []; selection = 0
        if !paused && Date().timeIntervalSince(historyAt) > 60 { reloadHistory() }
        queryChanged()
    }
    func resetAI() { stopForeground(); aiPicks = [:]; aiActions = []; aiCandidates = []; webHits = []; intent = nil }
    func reloadHistory() {
        guard !paused, !historyLoading else { return }
        historyLoading = true
        historyAt = Date()
        let learned = memory.recipes.filter { $0.shape == "search" }, settings = self.settings
        let existing = Set(allHistory.map(\.id))
        Task.detached(priority: .userInitiated) {
            let all = BrowserHistory.load().filter { !settings.excludes(url: $0.url ?? "") }
            let patterns = PatternMiner.localPatterns(all)
            let searches = BrowserHistory.searches(all, learned: learned)
            let (items, pages) = BrowserHistory.split(all)
            await MainActor.run {
                self.historyLoading = false
                guard !self.paused else { return }
                guard self.settings == settings else { self.reloadHistory(); return }
                guard !all.isEmpty else {
                    self.historyStatus = "未读取到可用历史，已保留现有记忆。请检查 Chrome 历史访问权限。"
                    return
                }
                let loaded = Set(all.map(\.id))
                let incremental = self.allHistory.filter { !existing.contains($0.id) && !loaded.contains($0.id) }
                self.allHistory = all + incremental; self.history = items; self.searchPages = pages; self.siteSearches = searches
                let known = Set(self.memory.patterns.map(\.template))
                if !self.memory.learningPaused { self.memory.patterns += patterns.filter { !known.contains($0.template) && !self.memory.deletedPatterns.contains($0.template) } }
                let alive = Set(self.allHistory.map(\.id) + self.freshTabs.map(\.id))
                self.memory.notes = Understand.prune(self.memory.notes, alive: alive)
                let hosts = Set(self.allHistory.compactMap { $0.url.flatMap(PatternMiner.host) })
                self.memory.studied = self.memory.studied.filter { hosts.contains($0.key) }
                self.memory.patterns.removeAll { !hosts.contains($0.host) }
                self.historyStatus = all.isEmpty ? "未读取到可用历史：请确认 Chrome 已使用且历史文件可访问" : "近 90 天已载入 \(all.count) 条历史，本地准备完成 · 找到 \(patterns.count) 个标识符路径"
                self.pendingSave = true; self.compose(); self.backgroundJobs()
            }
        }
    }
    func prepareHistory() {
        guard !paused else { historyStatus = "请先恢复 StepBar 再准备历史"; return }
        memory.learningPaused = false
        preparationSchedule = PreparationSchedule()
        historyStatus = "正在重新读取近 90 天历史并准备本地查询路径…"
        reloadHistory()
    }
    func queryChanged() {
        searchGeneration += 1
        resetAI(); semanticHits = []; selection = 0
        compose()
        let text = trimmedQuery, epoch = searchGeneration
        guard !text.isEmpty else { return }
        // Layer 2 right away, off the main thread; layer 3 waits for a pause in typing and for layer 2.
        let pool = searchPool, cached = cachedLocalIndex, revision = searchIndexRevision, boost = boosts(text)
        let semantic = Task.detached(priority: .userInitiated) { [weak self] in
            let store = self
            let index = cached ?? LocalIndex(pool: pool)
            let hits = index.match(query: text, boost: boost, limit: 30)
            if cached == nil {
                await MainActor.run {
                    guard let store, store.searchIndexRevision == revision else { return }
                    store.cachedLocalIndex = index
                }
            }
            return hits
        }
        Task { [weak self] in
            let hits = await semantic.value
            guard let self, epoch == self.searchGeneration else { return }
            self.semanticHits = hits; self.compose()
        }
        scheduleAI(after: semantic)
    }

    // MARK: Pools
    var freshTabs: [SearchItem] {
        Date().timeIntervalSince(browserUpdated) < 60 ? browserTabs.map(SearchItem.tab) : []
    }
    var searchPool: [SearchItem] {
        let fresh = Date().timeIntervalSince(browserUpdated) < 60
        if fresh != cachedTabsFresh { invalidateSearchIndex(); cachedTabsFresh = fresh }
        if let cachedSearchPool { return cachedSearchPool }
        let pool = Understand.enrich(freshTabs + history, notes: memory.notes)
        cachedSearchPool = pool; return pool
    }
    var localIndex: LocalIndex {
        let pool = searchPool
        if let cachedLocalIndex { return cachedLocalIndex }
        let index = LocalIndex(pool: pool); cachedLocalIndex = index; return index
    }
    var duplicateTabs: [BrowserTab] {
        guard Date().timeIntervalSince(browserUpdated) < 60 else { return [] }
        var seen = Set<String>(), extra: [BrowserTab] = []
        // Keep the active copy of each page; close the others.
        for tab in browserTabs.sorted(by: { $0.active && !$1.active }) where !seen.insert(SearchItem.urlID(tab.url)).inserted { extra.append(tab) }
        return extra
    }
    var commandItems: [SearchItem] {
        let count = duplicateTabs.count
        guard count > 0 else { return [] }
        return [SearchItem(id: "c:close-duplicates", kind: .command, title: "关闭 \(count) 个重复标签页", subtitle: "每个页面只保留一个标签页", aliases: "重复标签页 去重 整理标签 close duplicate tabs dedupe", command: "close-duplicates")]
    }
    func clipboardItems(_ text: String, pool: [SearchItem]) -> [SearchItem] {
        Inference.clipboardMatches(text, in: pool.filter { $0.url != currentPage?.url }, limit: 3)
    }
    // A chat sentence on the clipboard with nothing in it to act on is not a request: stay quiet.
    var clipboardActionable: Bool {
        guard let copied = copiedText else { return false }
        return !Inference.chatty(copied) || !Inference.values(in: copied).filter(Inference.identifier).isEmpty
    }

    // MARK: Layers
    var layers: Layers { Layers(pool: searchPool, memory: memory, entries: Layers.entries(siteSearches, patterns: memory.patterns), searchPages: searchPages) }
    func boosts(_ text: String) -> [String: Double] { layers.boosts(text) }
    func learnedActions(_ text: String?) -> [SearchItem] { layers.learnedActions(text) }
    func siteSearchActions(_ text: String, general: Int) -> (targeted: [SearchItem], general: [SearchItem]) { layers.siteSearchActions(text, general: general) }
    func queryWeights(_ text: String) -> [String: Double] { layers.queryWeights(text) }
    var searchEntries: [Recipe] { Layers.entries(siteSearches, patterns: memory.patterns) }
    func layerCandidates(_ text: String) -> [SearchItem] { layers.candidates(text, semantic: semanticHits, web: webHits) }

    // MARK: Compose
    func compose() {
        let text = trimmedQuery
        var sections: [(String, [SearchItem])] = []
        if text.isEmpty {
            var clip: [SearchItem] = []
            if let copied = copiedText { clip = learnedActions(copied) + clipboardItems(copied, pool: freshTabs + history) }
            sections.append(("剪贴板", clip))
            sections.append(("✦ Step 推荐", picked(from: clip + aiCandidates)))
            sections.append(("✦ Step 生成", aiActions))
            sections.append(("标签页", commandItems + Array(freshTabs.filter { $0.url != currentPage?.url }.prefix(4))))
            sections.append(("最近", Array(history.prefix(5))))
        } else {
            let layers = self.layers, (direct, matches) = layers.history(text)
            sections.append(("✦ Step 推荐", picked(from: aiCandidates)))
            sections.append(("✦ Step 生成", aiActions))
            sections.append(("直达", direct))
            sections.append(("命令", Ranker.rank(text, in: commandItems, limit: 2)))
            sections.append(("历史匹配", Array(matches.prefix(6))))
            sections.append(("语义匹配", Array(semanticHits.prefix(5))))
            if !Ranker.isLong(text) {
                let engine = searchFallback(text)
                sections.append(("网页", (WebSearch.allows(text) ? layers.siteSearchActions(text, general: 2).general : []) + [engine].compactMap { $0 }))
            }
        }
        var seen = Set<String>(), merged: [SearchItem] = []
        for (name, items) in sections {
            for var item in items where seen.insert(Fusion.identity(item)).inserted {
                item.section = name; merged.append(item)
            }
        }
        let trimmed = Array(merged.prefix(text.isEmpty ? 10 : 12))
        if trimmed != results { results = trimmed }
        selection = min(selection, max(0, results.count - 1))
    }
    func picked(from pool: [SearchItem]) -> [SearchItem] {
        var byID: [String: SearchItem] = [:]
        for item in pool where byID[item.id] == nil { byID[item.id] = item }
        return aiPicks.sorted { $0.value > $1.value }.compactMap { id, probability in
            guard var item = byID[id] else { return nil }
            item.note = "✦ \(Int(probability * 100))%"; return item
        }
    }

    // MARK: Layer 3
    // The answer is already obvious: the same query led to the same page at least twice, or a link was typed.
    func confident(_ text: String) -> Bool {
        if let first = layers.history(text).matches.first, (queryWeights(text)[first.id] ?? 0) >= 2 { return true }
        return Inference.safeURL(text) != nil
    }
    func searchFallback(_ text: String) -> SearchItem? {
        guard WebSearch.allows(text), settings.webSearch else { return nil }
        if let targeted = layers.siteSearchActions(text, general: 0).targeted.first { return targeted }
        if settings.isCustom {
            // Never silently send a custom-provider query to Google's search.
            return settings.customSearchMode == "engine" ? WebSearch.engineItem(text, template: settings.searchEngineTemplate) : nil
        }
        return layers.webSearch(text)
    }
    func scheduleAI(after semantic: Task<[SearchItem], Never>? = nil) {
        guard settings.aiEnabled, !paused, !trimmedQuery.isEmpty else { return }
        let epoch = searchGeneration, text = trimmedQuery, savedSettings = settings
        if confident(text) {
            scheduleTask?.cancel(); scheduleTask = nil
            let pool = layerCandidates(text)
            aiCandidates = pool
            if let first = pool.first, (queryWeights(text)[first.id] ?? 0) >= 2 { aiPicks = [first.id: 1] }
            compose(); return
        }
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Store.debounce) } catch { return }
            guard let self, epoch == self.searchGeneration, !self.paused, self.settings == savedSettings, self.settings.aiEnabled else { return }
            let web = self.webLookup(text)
            // Start the deadline with the search, not after L2 has finished.
            let timelyWeb = web.map { task in Task { await SoftDeadline.wait(for: task) } }
            defer { timelyWeb?.cancel() }
            if let semantic {
                let found = await semantic.value
                guard epoch == self.searchGeneration, !self.paused, self.settings == savedSettings else { return }
                self.semanticHits = found
            }
            if let timelyWeb {
                self.thinking = true; self.intent = "正在联网搜索「\(text.prefix(30))」…"
                let found = await timelyWeb.value
                guard epoch == self.searchGeneration, !self.paused, self.settings == savedSettings else { return }
                self.thinking = false; self.intent = nil
                self.webHits = WebSearch.items(found ?? []).map { var item = $0; item.layer = "联网结果"; return item }
                self.compose()
            }
            guard !Task.isCancelled, epoch == self.searchGeneration, !self.paused, self.settings == savedSettings, self.settings.aiEnabled else { return }
            guard !self.generating else { return }
            self.understand()
        }
    }
    // One StepFun web search per distinct query; repeats come from memory. A failed search just leaves layer 3 without it.
    func webLookup(_ text: String) -> Task<[WebResult], Never>? {
        guard settings.webSearch, WebSearch.allows(text) else { return nil }
        if settings.isCustom && settings.customSearchMode != "api" { return nil }
        let key = Semantic.normalize(text)
        if webCacheSettings != settings { clearWebCache(); webCacheSettings = settings }
        if let cached = cachedWebResults(key: key) { return Task { cached } }
        if let pending = webRequests[key], pending.settings == settings { return pending.task }
        let saved = settings
        let config = saved.isCustom ? AIConfiguration(baseURL: "", modelID: "", apiKey: "") : RuntimeChecks.stepPlanConfiguration(settings)
        if !saved.isCustom && config.apiKey.isEmpty { return nil }
        let searchKey = saved.isCustom ? RuntimeChecks.searchKey(saved) : ""
        let id = UUID()
        let task = Task<[WebResult], Never> { [weak self] in
            let result = saved.isCustom ? try? await WebSearch.customSearch(text, endpoint: saved.customSearchURL, apiKey: searchKey) : try? await WebSearch.search(text, configuration: config)
            if let self, self.webRequests[key]?.id == id { self.webRequests[key] = nil }
            guard let found = result else { return [] }
            // A late response can warm the cache, never mutate candidates or
            // trigger a second model call. Changed settings cannot seed it.
            self?.cacheWebResults(found, key: key, settings: saved)
            return found
        }
        webRequests[key] = (id, saved, task)
        return task
    }
    func cacheWebResults(_ found: [WebResult], key: String, settings saved: Settings) {
        guard !paused, settings == saved, webCacheSettings == saved, !found.isEmpty else { return }
        if webCache.count >= 100, webCache[key] == nil, let oldest = webCacheDates.min(by: { $0.value < $1.value })?.key {
            webCache[oldest] = nil; webCacheDates[oldest] = nil
        }
        webCache[key] = found; webCacheDates[key] = Date()
    }
    func cachedWebResults(key: String, now: Date = Date()) -> [WebResult]? {
        guard let date = webCacheDates[key], now.timeIntervalSince(date) < Self.webCacheTTL else {
            webCache[key] = nil; webCacheDates[key] = nil; return nil
        }
        return webCache[key]
    }
    func understand() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        let candidates = layerCandidates(text)
        aiCandidates = candidates
        generate(candidates: candidates)
    }
    @discardableResult func generate(candidates: [SearchItem]? = nil) -> Task<Void, Never>? {
        let text = trimmedQuery
        guard settings.aiEnabled, !paused, !generating, !text.isEmpty else { return nil }
        // Manual Tab generation supersedes the queued automatic request.
        scheduleTask?.cancel(); scheduleTask = nil
        let pool = Array((candidates ?? layerCandidates(text)).prefix(Fusion.limit))
        if candidates == nil { aiCandidates = pool }
        let epoch = searchGeneration, savedSettings = settings, config = RuntimeChecks.quickConfiguration(settings)
        guard !config.apiKey.isEmpty else { intent = "未配置模型，仍可选择本地结果"; return nil }
        let templates = Assistant.templates(query: text, candidates: pool, recipes: memory.recipes, searches: searchEntries, patterns: memory.patterns)
        let input = Assistant.payload(query: text, candidates: pool, recipes: memory.recipes,
                                      searches: searchEntries, patterns: memory.patterns)
        generating = true
        let requestID = UUID(); foregroundRequestID = requestID
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundRequestID == requestID {
                    self.generating = false; self.foregroundTask = nil; self.foregroundRequestID = nil
                }
            }
            do {
                let result = try await self.foregroundAI.complete(AIActions.self, configuration: config, system: Assistant.actionPrompt, payload: input)
                guard !Task.isCancelled, self.foregroundRequestID == requestID, epoch == self.searchGeneration, !self.paused, self.settings == savedSettings else { return }
                // A fresh web page or generated search cannot stand in for recalled history.
                self.aiActions = Assistant.validated(result, query: text, candidates: pool, templates: templates)
                self.aiPicks = Assistant.picks(result, from: pool, query: text)
                if !self.aiPicks.isEmpty { self.aiActions = [] }
                if self.aiActions.isEmpty && self.aiPicks.isEmpty, let fallback = self.searchFallback(text) {
                    self.aiActions = [fallback]
                }
                self.intent = result.intent.map { Privacy.text($0) }.flatMap { $0.isEmpty ? nil : String($0.prefix(20)) }
                if self.aiPicks.isEmpty && self.aiActions.isEmpty { self.intent = "未找到可靠入口，可继续选择本地结果" }
                else if self.aiPicks.isEmpty && self.aiActions.first?.note != "✦ Step 生成" { self.intent = "未找到直达答案，已提供搜索入口" }
                self.compose()
            } catch {
                guard !Task.isCancelled, self.foregroundRequestID == requestID, epoch == self.searchGeneration, !self.paused, self.settings == savedSettings else { return }
                if let fallback = self.searchFallback(text) { self.aiActions = [fallback] }
                self.intent = "模型暂不可用，仍可选择本地结果或搜索入口"
                self.compose()
            }
        }
        foregroundTask = task
        return task
    }

    // MARK: Voice
    func startVoice() {
        guard !listening, launcherOpen, !paused, settings.voiceAvailable else { return }
        if !settings.isCustom && RuntimeChecks.voiceConfiguration(settings).apiKey.isEmpty { intent = "请先配置 Step Plan Key"; return }
        listening = true; intent = "正在听…松开 ⌥M 结束"
        Task { [weak self] in
            guard let self else { return }
            do {
                guard self.listening, self.launcherOpen, !self.paused else { return }
                try await self.voice.start()
            }
            catch is CancellationError { }
            catch { self.listening = false; self.intent = error.localizedDescription }
        }
    }
    func stopVoice() {
        guard listening else { return }
        listening = false
        let pcm = voice.stop()
        guard !pcm.isEmpty else { intent = nil; return }
        intent = "正在识别…"
        let config = RuntimeChecks.voiceConfiguration(settings), custom = settings.isCustom
        let epoch = searchGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let text: String
                if custom { text = try await VoiceInput.transcribeOpenAI(pcm, configuration: config) }
                else { text = try await VoiceInput.transcribe(pcm, configuration: config) { partial in
                    if epoch == self.searchGeneration, !self.paused { self.intent = "🎙 \(partial)" }
                } }
                guard epoch == self.searchGeneration, !self.paused else { return }
                self.intent = nil
                if !text.isEmpty { self.query = text }
            } catch { if epoch == self.searchGeneration, !self.paused { self.intent = error.localizedDescription } }
        }
    }

    // MARK: Opening
    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }
    func open(_ item: SearchItem) {
        let query = trimmedQuery, rank = results.firstIndex { $0.id == item.id } ?? -1
        if item.kind == .command {
            if item.command == "close-duplicates" { closeTabs(duplicateTabs) }
            return
        }
        guard let text = item.url else { return }
        // Prefer switching to an already-open tab over opening a duplicate.
        let tab = item.tab ?? browserTabs.first { SearchItem.urlID($0.url) == item.id }?.ref
        if let tab, settings.browserBridge, Date().timeIntervalSince(browserUpdated) < 60 {
            pendingJumps[bridge.jump(tab)] = item
            status = "正在切换到标签页…"
        } else if let url = Inference.safeURL(text) {
            openWeb(url); status = "已打开：\(item.title)"
        } else { return }
        guard !paused else { return }
        memory.choices[item.id, default: 0] += 1
        learn(item, query: query, rank: rank)
        save()
    }
    func closeTabs(_ tabs: [BrowserTab]) {
        guard !tabs.isEmpty else { return }
        bridge.close(tabs.map(\.id), bundle: BrowserTab.chrome)
        let closing = Set(tabs.map(\.identity))
        browserTabs.removeAll { closing.contains($0.identity) }
        status = "已关闭 \(tabs.count) 个标签页"
        compose()
    }
    // ⌘⌫ on a tab result closes that tab.
    func closeSelected() {
        guard results.indices.contains(selection), let ref = results[selection].tab,
              let tab = browserTabs.first(where: { $0.id == ref.tabID }) else { return }
        closeTabs([tab])
    }
    // Query → choice: the next time this query (or the start of it) is typed, this answer comes first, and from the
    // second time on without asking the model. Generated pages are remembered too, so they need no model call again.
    private func learn(_ item: SearchItem, query: String, rank: Int) {
        guard !query.isEmpty else { return }
        guard Privacy.secrets(query) == query, Privacy.personal(query) == query else { return }
        let key = Semantic.normalize(query)
        if key.count <= 60 {
            memory.queryChoices[key, default: [:]][item.id, default: 0] += 1
            memory.remembered[item.id] = item.remembered
        }
        memory.searchLog.append(SearchLog(query: String(query.prefix(200)), chosen: item.id, title: item.title, rank: rank, section: item.section))
    }
}
