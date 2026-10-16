import AppKit

// The launcher answers in three layers, all as fast as possible:
//   1. 历史匹配 — local and instant: open tabs and Chrome history by title and address, what this query led to before,
//      learned query entries and URL patterns that take a value from the query, and site searches for a named site.
//   2. 语义匹配 — local and instant: what the background model wrote about each page (purpose, bilingual keywords,
//      typical requests) and the page text, so other words for the same page still find it.
//   3. ✦ Step — after 150 ms without typing, the typed words go to StepFun web search once; step-3.7-flash then gets
//      what layers 1 and 2 found, the fresh web results and the learned patterns, picks the answer and, when nothing
//      fits, builds a URL.
extension Store {
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    static let debounce: UInt64 = 150_000_000

    func prepareLauncher() {
        searchGeneration += 1
        resetAI(); semanticHits = []; selection = 0
        if Date().timeIntervalSince(historyAt) > 60 { reloadHistory() }
        compose()
        if clipboardActionable { scheduleAI() }
    }
    func resetAI() { aiPicks = [:]; aiActions = []; aiCandidates = []; webHits = []; intent = nil; thinking = false; generating = false }
    func reloadHistory() {
        historyAt = Date()
        let learned = memory.recipes.filter { $0.shape == "search" }, settings = self.settings
        Task.detached(priority: .userInitiated) {
            let all = BrowserHistory.load().filter { !settings.excludes(url: $0.url ?? "") }
            let searches = BrowserHistory.searches(all, learned: learned)
            let (items, pages) = BrowserHistory.split(all)
            await MainActor.run { self.history = items; self.searchPages = pages; self.siteSearches = searches; self.compose() }
        }
    }
    func queryChanged() {
        searchGeneration += 1
        resetAI(); semanticHits = []; selection = 0
        compose()
        let text = trimmedQuery, epoch = searchGeneration
        guard !text.isEmpty else { if clipboardActionable { scheduleAI() }; return }
        // Layer 2 right away, off the main thread; layer 3 waits for a pause in typing and for layer 2.
        let pool = searchPool, pages = self.pages, boost = boosts(text)
        let semantic = Task.detached(priority: .userInitiated) { Semantic.match(query: text, pool: pool, pages: pages, boost: boost, limit: 10) }
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
    var searchPool: [SearchItem] { Understand.enrich(freshTabs + commandItems + history, notes: memory.notes) }
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
    func layerCandidates(_ text: String) -> [SearchItem] { layers.candidates(text, semantic: semanticHits) }

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
            sections.append(("✦ Step 推荐", picked(from: direct + matches + semanticHits + webHits + aiCandidates)))
            sections.append(("✦ Step 生成", aiActions))
            sections.append(("直达", direct))
            sections.append(("历史匹配", Array(matches.prefix(6))))
            sections.append(("语义匹配", Array(semanticHits.prefix(5))))
            if !Ranker.isLong(text) { sections.append(("网页", layers.siteSearchActions(text, general: Inference.recalling(text) ? 0 : 2).general + [layers.webSearch(text)].compactMap { $0 })) }
        }
        var seen = Set<String>(), merged: [SearchItem] = []
        for (name, items) in sections {
            for var item in items where seen.insert(item.id).inserted {
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
        if let top = queryWeights(text).values.max(), top >= 2 { return true }
        return Inference.safeURL(text) != nil
    }
    func scheduleAI(after semantic: Task<[SearchItem], Never>? = nil) {
        guard settings.aiEnabled, !paused else { return }
        let epoch = searchGeneration, text = trimmedQuery
        if !text.isEmpty && confident(text) { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Store.debounce)
            guard let self, epoch == self.searchGeneration else { return }
            let web = self.webLookup(text)
            if let semantic { _ = await semantic.value }
            if let web {
                self.thinking = true; self.intent = "正在联网搜索「\(text.prefix(30))」…"
                let found = await web.value
                guard epoch == self.searchGeneration else { return }
                self.thinking = false; self.intent = nil
                self.webHits = WebSearch.items(found).map { var item = $0; item.layer = "联网结果"; return item }
                self.compose()
            }
            guard epoch == self.searchGeneration else { return }
            self.understand()
        }
    }
    // One StepFun web search per distinct query; repeats come from memory. A failed search just leaves layer 3 without it.
    func webLookup(_ text: String) -> Task<[WebResult], Never>? {
        guard settings.webSearch, WebSearch.allows(text) else { return nil }
        let key = Semantic.normalize(text)
        if let cached = webCache[key] { return Task { cached } }
        let config = RuntimeChecks.stepPlanConfiguration(settings)
        guard !config.apiKey.isEmpty else { return nil }
        return Task { [weak self] in
            guard let found = try? await WebSearch.search(text, configuration: config) else { return [] }
            if let self { if self.webCache.count > 100 { self.webCache = [:] }; self.webCache[key] = found }
            return found
        }
    }
    func understand() {
        let text = trimmedQuery
        var candidates: [SearchItem]
        if text.isEmpty {
            guard let copied = copiedText else { return }
            let pool = freshTabs + history
            var found = learnedActions(copied) + clipboardItems(copied, pool: pool)
            // A copied title or name is looked up like a typed one; a chat sentence is not.
            if !Inference.chatty(copied), Inference.safeURL(copied) == nil { found += Ranker.recall(copied, in: Understand.enrich(pool, notes: memory.notes), limit: 6) }
            candidates = Semantic.distinct(found, limit: 10)
        } else {
            candidates = layerCandidates(text) + webHits.prefix(WebSearch.count)
        }
        aiCandidates = candidates
        generate(candidates: candidates)
    }
    @discardableResult func generate(candidates: [SearchItem]? = nil) -> Task<Void, Never>? {
        let text = trimmedQuery
        guard settings.aiEnabled, !paused, !generating, !text.isEmpty || copiedText != nil else { return nil }
        let pool = candidates ?? (text.isEmpty ? aiCandidates : layerCandidates(text))
        if candidates == nil { aiCandidates = pool }
        let epoch = searchGeneration, config = RuntimeChecks.quickConfiguration(settings)
        let input = Assistant.payload(query: text, current: currentPage, clipboard: copiedText, candidates: pool, recipes: memory.recipes,
                                      searches: searchEntries, patterns: memory.patterns)
        generating = true
        return Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.ai.complete(AIActions.self, configuration: config, system: Assistant.actionPrompt, payload: input)
                guard epoch == self.searchGeneration else { return }
                // Recalling something seen ("上周看的 rust 文章"): a fresh web search is not it; the plain fallback row stays.
                let engines = ["www.google.com", "www.bing.com", "www.baidu.com", "duckduckgo.com", "www.sogou.com", "cn.bing.com"]
                self.aiActions = Assistant.validated(result).filter { action in
                    !(Inference.recalling(text) && engines.contains(action.url.flatMap { URL(string: $0)?.host } ?? ""))
                }
                self.aiPicks = Assistant.picks(result, from: pool)
                self.intent = result.intent.map { Privacy.text($0) }.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                self.compose()
            } catch {
                guard epoch == self.searchGeneration else { return }
                self.intent = "AI 生成失败：\(error.localizedDescription)"
            }
            if epoch == self.searchGeneration { self.generating = false }
        }
    }

    // MARK: Voice
    func startVoice() {
        guard !listening else { return }
        listening = true; intent = "正在听…松开 ⌥ 结束"
        Task { [weak self] in
            guard let self else { return }
            do { try await self.voice.start() }
            catch { self.listening = false; self.intent = error.localizedDescription }
        }
    }
    func stopVoice() {
        guard listening else { return }
        listening = false
        let pcm = voice.stop()
        intent = "正在识别…"
        let config = RuntimeChecks.stepPlanConfiguration(settings)
        guard !config.apiKey.isEmpty else { intent = "语音需要官方 Step Plan API Key，请先在设置中保存。"; return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await VoiceInput.transcribe(pcm, configuration: config) { partial in self.intent = "🎙 \(partial)" }
                self.intent = nil
                if !text.isEmpty { self.query = text }
            } catch { self.intent = error.localizedDescription }
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
        let key = Semantic.normalize(query)
        if key.count <= 60 {
            memory.queryChoices[key, default: [:]][item.id, default: 0] += 1
            memory.remembered[item.id] = item.remembered
        }
        memory.searchLog.append(SearchLog(query: String(query.prefix(200)), chosen: item.id, title: item.title, rank: rank, section: item.section))
    }
}
