import Foundation

// A query entry learned from use: an id was copied, then a page whose address contains it was opened.
struct Recipe: Codable, Identifiable {
    var id = UUID()
    var source: String
    var template: String
    var label: String
    var shape: String
    var count: Int = 1
    var updated = Date()
}
struct BrowserTabRef: Codable, Equatable {
    var tabID: Int
    var windowID: Int
    var bundle: String
}
// What the background model understood about one page: what it is for, what it is called in both languages,
// and what someone would type when they want it again.
struct PageNote: Codable, Equatable {
    var title: String
    var purpose: String
    var terms: [String]
    var asks: [String] = []
    var hadText = false
    var date = Date()
}
// A URL shape the background model found in one site's history ("github.com/{value}" = a repository),
// checked against real addresses before it is kept.
struct Pattern: Codable, Identifiable, Equatable {
    var id = UUID()
    var host: String
    var template: String
    var label: String
    var param: String
    var shape: String
    var examples: [String]
    var date = Date()
}
struct Memory: Codable {
    var recipes: [Recipe] = []
    var choices: [String: Int] = [:]
    // Launcher learning: query → chosen item counts, snapshots of chosen items and the search log.
    var queryChoices: [String: [String: Int]] = [:]
    var remembered: [String: Remembered] = [:]
    var searchLog: [SearchLog] = []
    // Background understanding (step-5-preview): page notes by page id, URL patterns, and when each site was last studied.
    var notes: [String: PageNote] = [:]
    var patterns: [Pattern] = []
    var studied: [String: Studied] = [:]
    var learningPaused = false
    var deletedNotes: Set<String> = []
    var deletedPatterns: Set<String> = []
    init() {}
    enum CodingKeys: String, CodingKey { case recipes, choices, queryChoices, remembered, searchLog, notes, patterns, studied, learningPaused, deletedNotes, deletedPatterns }
    // Unknown fields of older versions are dropped on the next save.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try c.decodeIfPresent([Recipe].self, forKey: .recipes) ?? []
        choices = try c.decodeIfPresent([String: Int].self, forKey: .choices) ?? [:]
        queryChoices = try c.decodeIfPresent([String: [String: Int]].self, forKey: .queryChoices) ?? [:]
        remembered = try c.decodeIfPresent([String: Remembered].self, forKey: .remembered) ?? [:]
        searchLog = try c.decodeIfPresent([SearchLog].self, forKey: .searchLog) ?? []
        notes = try c.decodeIfPresent([String: PageNote].self, forKey: .notes) ?? [:]
        patterns = try c.decodeIfPresent([Pattern].self, forKey: .patterns) ?? []
        studied = try c.decodeIfPresent([String: Studied].self, forKey: .studied) ?? [:]
        learningPaused = try c.decodeIfPresent(Bool.self, forKey: .learningPaused) ?? false
        deletedNotes = try c.decodeIfPresent(Set<String>.self, forKey: .deletedNotes) ?? []
        deletedPatterns = try c.decodeIfPresent(Set<String>.self, forKey: .deletedPatterns) ?? []
    }
}
struct Studied: Codable, Equatable {
    var pages: Int
    var date = Date()
}
struct Remembered: Codable, Equatable {
    var kind: String
    var title: String
    var subtitle: String
    var url: String?
    var command: String?
}
struct SearchLog: Codable, Equatable {
    var date = Date()
    var query: String
    var chosen: String
    var title: String
    var rank: Int
    var section: String
}

enum Inference {
    static func object(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= 128,
              text.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return text
    }
    // What kind of value a learned entry takes. A hex value (32 digits), a git sha (7 or 40 hex), an order number and
    // a plain word are different things: an entry learned from one must not be offered for another.
    static func shape(_ text: String) -> String {
        if text.allSatisfy(\.isNumber) { return "number" }
        if UUID(uuidString: text) != nil { return "uuid" }
        let letters = text.contains(where: \.isLetter), digits = text.contains(where: \.isNumber)
        if letters && digits && text.allSatisfy(\.isHexDigit) { return "hex\(text.count)" }
        if letters && digits { return "id" }
        return "word"
    }
    // Written to a person rather than typed into a search box: sentence punctuation, question and chat particles, masked details.
    static func chatty(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "，。！？；,!?;")) != nil || text.contains("[手机号]") || text.contains("[邮箱]") { return true }
        return ["怎么", "为啥", "为什么", "是不是", "能不能", "有没有", "帮我", "我们", "你们", "大家", "一下", "看下", "吗", "呢", "吧", "啊", "哈"].contains { text.contains($0) }
    }
    // Describes something already seen ("上周看的 rust 文章") rather than words to search a site for.
    static func recalling(_ text: String) -> Bool {
        // "deepseek r2 知乎上怎么评价" names where to look: a question, not a memory.
        (chatty(text) && Sites.mentioned(in: text).isEmpty) || ["上周", "昨天", "前天", "今天", "刚才", "刚刚", "之前", "上次", "那个", "那篇", "这个", "这篇", "的"].contains { text.contains($0) }
    }
    // Looks like an identifier rather than a word: safe to pick out of a sentence.
    static func identifier(_ value: String) -> Bool {
        switch shape(value) {
        case "number": return value.count >= 5
        case "word": return false
        default: return true
        }
    }
    // Entries learned before shapes were split were all "token"; most came from ids, so they only take long ids now.
    static func fits(_ learned: String?, _ value: String) -> Bool {
        let actual = shape(value)
        if learned == "token" { return actual == "uuid" || actual == "id" && value.count >= 8 || actual.hasPrefix("hex") && value.count >= 16 }
        return learned == actual
    }
    // Values a learned entry could be applied to: the whole text when it is one value, otherwise only identifiers inside it.
    static func values(in text: String) -> [String] {
        if let whole = object(text) { return [whole] }
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").inverted)
            .compactMap(object).filter { identifier($0) && seen.insert($0).inserted }
    }
    static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    // Only replace an exact path component or query value; never a hostname or substring.
    static func template(url: String, object: String) -> String? {
        guard safeURL(url) != nil, var parts = URLComponents(string: url) else { return nil }
        var matches = 0
        let path = parts.percentEncodedPath.components(separatedBy: "/").map { component -> String in
            if component.removingPercentEncoding == object { matches += 1; return "STEPBARVALUE" }
            return component
        }.joined(separator: "/")
        parts.percentEncodedPath = path
        if let items = parts.queryItems {
            parts.queryItems = items.map { item in
                if item.value == object { matches += 1; return URLQueryItem(name: item.name, value: "STEPBARVALUE") }
                return item
            }
        }
        guard matches == 1, let result = parts.string, !url.contains("STEPBARVALUE") else { return nil }
        return result.replacingOccurrences(of: "STEPBARVALUE", with: "{value}")
    }
    // A word sitting in a path is the page's name (docs/guides/example-product/…), not a parameter: only ids are learned there.
    static func learnable(_ template: String, value: String) -> Bool {
        identifier(value) || !(template.split(separator: "?", maxSplits: 1).first ?? "").contains("{value}")
    }
    // Site search pages (github.com/search?q=…): keep only the search parameter and a few stable ones.
    static let searchKeys = ["q", "query", "keyword", "keywords", "search", "search_query", "wd", "word", "kw", "k", "text", "term"]
    static func searchTemplate(url: String) -> (template: String, value: String)? {
        guard let parsed = safeURL(url), var parts = URLComponents(string: url), let host = parsed.host?.lowercased(),
              !host.contains("google."), let items = parts.queryItems,
              let found = items.first(where: { searchKeys.contains($0.name.lowercased()) && !($0.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }),
              let value = found.value, value.count <= 100 else { return nil }
        let stable: Set<String> = ["type", "t", "tab", "scope", "ie", "src"]
        parts.queryItems = items.filter { $0.name == found.name || stable.contains($0.name.lowercased()) }.map { $0.name == found.name ? URLQueryItem(name: $0.name, value: "STEPBARVALUE") : $0 }
        parts.fragment = nil
        guard let result = parts.string, !value.contains("STEPBARVALUE") else { return nil }
        return (result.replacingOccurrences(of: "STEPBARVALUE", with: "{value}"), value)
    }
    static func instantiateSearch(_ template: String, value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=#?/")
        guard let encoded = value.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        let result = template.replacingOccurrences(of: "{value}", with: encoded)
        return safeURL(result) == nil ? nil : result
    }
    static func instantiate(_ template: String, value: String) -> String? {
        guard object(value) != nil else { return nil }
        let result = template.replacingOccurrences(of: "{value}", with: value)
        return safeURL(result) == nil ? nil : result
    }
    // Pages related to copied content: same URL, contains the copied ID, or title overlaps the copied text.
    static func clipboardMatches(_ raw: String, in items: [SearchItem], limit: Int = 3) -> [SearchItem] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        let lower = text.lowercased()
        let stop: Set<String> = ["the", "and", "for", "with", "this", "that", "from", "you", "are", "was", "have", "not", "but", "can", "http", "https", "www", "com"]
        var words: [String] = []
        for word in lower.components(separatedBy: CharacterSet.alphanumerics.inverted) where word.count >= 3 && Int(word) == nil && !stop.contains(word) && !words.contains(word) {
            words.append(word); if words.count == 16 { break }
        }
        // In a mostly Chinese sentence the few English words are not what it is about ("Step Plan 网关今天不稳定").
        let han = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let mostlyHan = Double(han) > Double(text.count) * 0.3
        var seen = Set<String>()
        var scored: [(SearchItem, Double, Int)] = []
        for (order, item) in items.enumerated() where item.url != nil {
            let title = item.title.lowercased(), url = (item.url ?? "").lowercased()
            var hit: (String, Double)?
            if let copied = safeURL(text), let target = item.url.flatMap(safeURL), copied.host == target.host, copied.path == target.path, copied.query == target.query {
                hit = ("剪贴板里的链接已经打开", 10)
            } else if object(text) != nil, url.contains(lower) || title.contains(lower) {
                hit = ("包含剪贴板里的 \(text)", 8)
            } else if safeURL(text) == nil, text.count <= 120, title.contains(lower) {
                hit = ("标题包含剪贴板内容", 7)
            } else if safeURL(text) == nil, title.count >= 8, lower.contains(title.replacingOccurrences(of: " - google chrome", with: "")) {
                hit = ("剪贴板内容提到这个页面", 6)
            } else if words.count >= 2 {
                let shared = words.filter { title.contains($0) || url.contains($0) }.count
                if shared >= 3 || (shared >= 2 && !mostlyHan && Double(shared) >= Double(words.count) * 0.5) { hit = ("与剪贴板内容有 \(shared) 个相同关键词", 3 + Double(shared) / Double(words.count)) }
            }
            guard let (reason, score) = hit, seen.insert(item.id).inserted else { continue }
            var found = item; found.note = reason
            scored.append((found, score, order))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.prefix(limit).map(\.0)
    }
}
