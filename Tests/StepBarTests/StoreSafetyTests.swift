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
        // Exercise production read only with an unguessable synthetic service, never real credentials.
        var before = DarwinBoolean(true), after = DarwinBoolean(true)
        precondition(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
        precondition(Keychain.read("synthetic", service: "stepbar.test.\(UUID().uuidString)").isEmpty)
        precondition(SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess)
        precondition(before.boolValue == after.boolValue, "Silent read must restore the process UI policy")
        print("PASS: corrupt memory backup, delete suppression, clear stops learning, pause, empty history preservation and keychain UI-policy restoration")
    }
}
