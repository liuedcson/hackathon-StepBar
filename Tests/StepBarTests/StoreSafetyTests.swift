import AppKit
import Security

@main struct StoreSafetyTests {
    @MainActor static func main() async throws {
        guard Demo.folder != nil else { fatalError("Run only with an isolated STEPBAR_DEMO directory") }
        let folder = Settings.folder
        var settings = Settings()
        settings.aiEnabled = false; settings.browserBridge = false
        try JSONEncoder().encode(settings).write(to: folder.appendingPathComponent("settings.json"))
        let broken = Data("{broken-memory".utf8)
        let file = folder.appendingPathComponent("memory.json")
        try broken.write(to: file)
        let store = Store()
        store.paused = true
        store.save()
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("memory.json.unreadable-") }
        precondition(backups.count == 1 && (try? Data(contentsOf: backups[0])) == broken)
        store.removeNote("synthetic-deleted-page")
        precondition(store.memory.deletedNotes.contains("synthetic-deleted-page"))
        store.clear()
        precondition(store.memory.learningPaused && store.memory.notes.isEmpty)
        let historyAt = store.historyAt
        store.reloadHistory()
        precondition(store.historyAt == historyAt, "Pause must prevent history reads")
        store.paused = false
        store.prepareHistory()
        precondition(!store.memory.learningPaused)
        // The empty isolated history must not delete learned patterns.
        let pattern = Pattern(host: "synthetic.example", template: "https://synthetic.example/{value}", label: "Synthetic", param: "id", shape: "number", examples: ["1", "2"])
        store.memory.patterns = [pattern]
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(store.memory.patterns.count == 1, "Empty history must preserve memory")
        // Cached L2 snapshots rebuild on data changes, never from the clipboard.
        store.paused = true
        let page = SearchItem(id: SearchItem.urlID("https://cache.example/doc"), kind: .history, title: "English title", subtitle: "", url: "https://cache.example/doc")
        store.history = [page]
        precondition(store.localIndex.match(query: "中文别名").isEmpty)
        store.memory.notes[page.id] = PageNote(title: page.title, purpose: "中文别名", terms: ["中文别名"], schema: 2)
        precondition(store.localIndex.match(query: "中文别名").first?.id == page.id)
        let revision = store.searchIndexRevision
        store.memory.choices[page.id] = 1
        precondition(store.searchIndexRevision == revision && store.cachedLocalIndex != nil, "Click counts must not rebuild the L2 index")
        store.memory.notes = [:]
        precondition(store.localIndex.match(query: "中文别名").isEmpty)
        store.query = ""
        store.understand()
        precondition(store.aiCandidates.isEmpty && store.generate() == nil)
        store.settings.webSearch = true
        precondition(store.searchFallback("普通查询") != nil)
        precondition(store.searchFallback("昨天看的文档") == nil)
        precondition(store.searchFallback("api_key=synthetic-secret") == nil)
        store.settings.webSearch = false
        precondition(store.searchFallback("普通查询") == nil)
        // Late web results warm only the cache, never the current model snapshot.
        store.settings.aiProvider = "custom"; store.settings.customSearchMode = "api"
        store.settings.webSearch = true; store.paused = false
        let saved = store.settings, found = [WebResult(title: "Synthetic", url: "https://synthetic.example/new", snippet: "fixture")]
        store.webCacheSettings = saved
        store.aiCandidates = [page]
        store.cacheWebResults(found, key: "late query", settings: saved)
        precondition(store.webCache["late query"] == found && store.aiCandidates == [page] && !store.generating)
        let cached = store.webLookup("late query")!
        let cachedValue = await cached.value
        precondition(cachedValue == found)
        precondition(store.cachedWebResults(key: "late query", now: Date().addingTimeInterval(301)) == nil)
        precondition(store.webCache["late query"] == nil)
        // Repeating an unfinished query shares the existing task without calling
        // any real provider or loading credentials.
        let pending = Task { try? await Task.sleep(nanoseconds: 50_000_000); return found }
        store.webRequests["pending query"] = (UUID(), saved, pending)
        let reused = store.webLookup("pending query")!
        precondition(store.webRequests.count == 1)
        let reusedValue = await reused.value
        precondition(reusedValue == found)
        store.settings.customSearchURL = "https://changed.example/search"
        store.cacheWebResults(found, key: "stale query", settings: saved)
        precondition(store.webCache["stale query"] == nil)
        store.paused = true
        store.cacheWebResults(found, key: "paused query", settings: store.settings)
        precondition(store.webCache["paused query"] == nil)
        let foreground = Task<Void, Never> { try? await Task.sleep(nanoseconds: 50_000_000) }
        store.foregroundTask = foreground; store.foregroundRequestID = UUID(); store.generating = true
        store.resetAI()
        precondition(foreground.isCancelled && !store.generating && store.foregroundRequestID == nil)
        print("PASS: late web cache reuse, in-flight deduplication, unchanged candidates, settings/pause gates")
        // Exercise production read only with an unguessable synthetic service, never real credentials.
        var before = DarwinBoolean(true), after = DarwinBoolean(true)
        precondition(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
        precondition(Keychain.read("synthetic", service: "stepbar.test.\(UUID().uuidString)").isEmpty)
        precondition(SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess)
        precondition(before.boolValue == after.boolValue, "Silent read must restore the process UI policy")
        print("PASS: corrupt memory backup, delete suppression, clear stops learning, pause, empty history preservation and keychain UI-policy restoration")
    }
}
