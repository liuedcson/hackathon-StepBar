import Foundation
import Security

struct Settings: Codable, Equatable {
    var localConfigPath: String?
    static let stepPlan = "https://api.stepfun.com/step_plan/v1"
    // Local settings and memory live in ~/Library/Application Support/StepBar.
    static let folder: URL = {
        if let demo = Demo.folder { try? FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true); return demo }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StepBar")
    }()
    var aiEnabled = true
    var baseURL = Settings.stepPlan
    // Background understanding model; the launcher uses step-3.7-flash (RuntimeChecks.quickConfiguration).
    var modelID = "step-5-preview"
    var aiProvider = "stepPlan"
    var quickModelID = "step-3.7-flash"
    var customBackgroundURL = ""
    var customBackgroundModel = ""
    var customForegroundURL = ""
    var customForegroundModel = ""
    var customSearchMode = "disabled"
    var customSearchURL = ""
    var searchEngineTemplate = "https://www.bing.com/search?q={query}"
    var customVoiceEnabled = false
    var customVoiceURL = ""
    var customVoiceModel = ""
    var jsonMode = false
    // Let the background model study pages and URL patterns while the Mac is idle on power.
    var background = true
    // Search the web with the typed words before layer 3 (StepFun web search, same key).
    var webSearch = true
    // Domains whose pages are never indexed, sent or studied (bank.example.com covers its subdomains too).
    var excludedSites = ""
    var retentionDays = 30
    var browserBridge = true
    var bridgeToken = UUID().uuidString
    var hotkey = "commandM"
    init() {}
    enum CodingKeys: String, CodingKey { case aiEnabled, baseURL, modelID, aiProvider, quickModelID, customBackgroundURL, customBackgroundModel, customForegroundURL, customForegroundModel, customSearchMode, customSearchURL, searchEngineTemplate, customVoiceEnabled, customVoiceURL, customVoiceModel, jsonMode, background, webSearch, excludedSites, retentionDays, browserBridge, bridgeToken, hotkey, localConfigPath }
    enum Legacy: String, CodingKey { case autoSummarize, excludedApps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), old = try decoder.container(keyedBy: Legacy.self)
        localConfigPath = try c.decodeIfPresent(String.self, forKey: .localConfigPath)
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? true
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Settings.stepPlan
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? "step-5-preview"
        aiProvider = try c.decodeIfPresent(String.self, forKey: .aiProvider) ?? (baseURL == Settings.stepPlan ? "stepPlan" : "custom")
        quickModelID = try c.decodeIfPresent(String.self, forKey: .quickModelID) ?? "step-3.7-flash"
        customBackgroundURL = try c.decodeIfPresent(String.self, forKey: .customBackgroundURL) ?? (aiProvider == "custom" ? baseURL : "")
        customBackgroundModel = try c.decodeIfPresent(String.self, forKey: .customBackgroundModel) ?? (aiProvider == "custom" ? modelID : "")
        customForegroundURL = try c.decodeIfPresent(String.self, forKey: .customForegroundURL) ?? customBackgroundURL
        customForegroundModel = try c.decodeIfPresent(String.self, forKey: .customForegroundModel) ?? customBackgroundModel
        customSearchMode = try c.decodeIfPresent(String.self, forKey: .customSearchMode) ?? "disabled"
        customSearchURL = try c.decodeIfPresent(String.self, forKey: .customSearchURL) ?? ""
        searchEngineTemplate = try c.decodeIfPresent(String.self, forKey: .searchEngineTemplate) ?? "https://www.bing.com/search?q={query}"
        customVoiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .customVoiceEnabled) ?? false
        customVoiceURL = try c.decodeIfPresent(String.self, forKey: .customVoiceURL) ?? ""
        customVoiceModel = try c.decodeIfPresent(String.self, forKey: .customVoiceModel) ?? ""
        jsonMode = try c.decodeIfPresent(Bool.self, forKey: .jsonMode) ?? false
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? old.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? true
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? true
        // Old app bundle ids in the exclusion list mean nothing for web pages and are dropped; domains carry over.
        let legacy = (try old.decodeIfPresent(String.self, forKey: .excludedApps) ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).filter { !$0.hasPrefix("com.") }.joined(separator: " ")
        excludedSites = try c.decodeIfPresent(String.self, forKey: .excludedSites) ?? legacy
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        browserBridge = try c.decodeIfPresent(Bool.self, forKey: .browserBridge) ?? true
        bridgeToken = try c.decodeIfPresent(String.self, forKey: .bridgeToken) ?? UUID().uuidString
        let savedHotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "commandM"
        hotkey = savedHotkey == "commandL" ? "commandM" : savedHotkey
    }
    // Keychain account name; the "openAI:" prefix is the Chat Completions protocol Step Plan speaks, kept so saved keys still match.
    var summaryAccount: String { "openAI:\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))" }
    var isCustom: Bool { aiProvider == "custom" }
    var backgroundURL: String { isCustom ? customBackgroundURL : Settings.stepPlan }
    var backgroundModel: String { isCustom ? customBackgroundModel : modelID }
    var foregroundURL: String { isCustom ? customForegroundURL : Settings.stepPlan }
    var foregroundModel: String { isCustom ? customForegroundModel : quickModelID }
    var backgroundAccount: String { isCustom ? "openAI:background:\(backgroundURL.trimmingCharacters(in: .whitespacesAndNewlines))" : "openAI:\(Settings.stepPlan)" }
    var foregroundAccount: String { isCustom ? "openAI:foreground:\(foregroundURL.trimmingCharacters(in: .whitespacesAndNewlines))" : backgroundAccount }
    var searchAccount: String { "openAI:search:\(customSearchURL.trimmingCharacters(in: .whitespacesAndNewlines))" }
    var voiceAccount: String { "openAI:voice:\(customVoiceURL.trimmingCharacters(in: .whitespacesAndNewlines))" }
    var voiceAvailable: Bool { !isCustom || (customVoiceEnabled && !customVoiceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !customVoiceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    func excludes(url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return excludedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    var excludedDomains: Set<String> { Set(excludedSites.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)) }
    var hotkeyLabel: String { ["controlL": "⌃ L", "optionSpace": "⌥ Space"][hotkey] ?? "⌘ M" }
}

enum Keychain {
    private static let service = "local.stepbar.ai"
    static func query(_ account: String, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(_ account: String) -> String {
        read(account, service: service)
    }
    static func read(_ account: String, service: String) -> String {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ key: String, account: String) throws {
        let q = query(account)
        if key.isEmpty {
            let result = SecItemDelete(q as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw KeyError(status: result) }
            return
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        let result = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            var insert = q
            insert[kSecValueData as String] = Data(key.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeyError(status: added) }
        } else if result != errSecSuccess { throw KeyError(status: result) }
    }
    struct KeyError: LocalizedError {
        var status: OSStatus
        var errorDescription: String? { "钥匙串保存失败（\(status)）" }
    }
}

enum Privacy {
    static func text(_ value: String) -> String { String(personal(secrets(value)).prefix(512)) }
    static func secrets(_ value: String) -> String {
        let pattern = "(?i)((?:sk|ak)-[a-z0-9_-]{12,}|bearer\\s+[a-z0-9._-]{10,}|(?:password|passwd|secret|api[_-]?key|access[_-]?token)\\s*[:=]\\s*[^\\s&]+)"
        return value.replacingOccurrences(of: pattern, with: "[已过滤]", options: .regularExpression)
    }
    // Phone numbers, e-mail addresses and ID card numbers become placeholders: the model still knows one was there.
    static let personalPatterns: [(String, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[邮箱]"),
        (#"(?<![0-9])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9A-Za-z])"#, "[身份证号]"),
        (#"(?<![0-9])(?:\+?86[ -]?)?1[3-9][0-9](?:[ -]?[0-9]{4}){2}(?![0-9])"#, "[手机号]"),
        (#"(?<![0-9])0[1-9][0-9]{1,2}-[0-9]{7,8}(?![0-9])"#, "[电话]"),
    ]
    static func personal(_ value: String) -> String {
        personalPatterns.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
    static func url(_ value: String?) -> String? {
        guard let value, var parts = URLComponents(string: value) else { return nil }
        if parts.user != nil || parts.password != nil { return nil }
        let sensitive = ["token", "password", "secret", "key", "auth", "session", "code"]
        if let items = parts.queryItems {
            // Drop sensitive query URLs entirely: a redacted URL would not be a usable destination.
            if items.contains(where: { item in sensitive.contains { item.name.lowercased().contains($0) } }) { return nil }
            parts.queryItems = items
        }
        parts.fragment = nil
        return parts.string
    }
}
