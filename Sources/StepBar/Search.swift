import Foundation
import SQLite3

struct SearchItem: Identifiable, Equatable {
    enum Kind: String { case action, command, tab, history }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var url: String?
    var tab: BrowserTabRef?
    var aliases: String = ""
    var date: Date?
    var visits = 0
    var score = 0.0
    var section = ""
    var note: String?
    // Built-in commands (close duplicate tabs …) run instead of opening a URL.
    var command: String?
    // Page text snippet shown to the model when choosing.
    var content = ""
    // Background understanding (PageNote): keywords, typical requests and what the page is for.
    var keywords: [String] = []
    var purpose = ""
    // Which launcher layer found it (历史匹配 / 语义匹配), told to the model.
    var layer = ""

    static func == (a: SearchItem, b: SearchItem) -> Bool {
        a.id == b.id && a.section == b.section && a.note == b.note && a.score == b.score &&
        a.title == b.title && a.subtitle == b.subtitle && a.url == b.url &&
        a.kind == b.kind && a.tab == b.tab && a.command == b.command && a.content == b.content &&
        a.aliases == b.aliases && a.keywords == b.keywords && a.purpose == b.purpose && a.layer == b.layer
    }
    // Some sites embed zero-width characters in page titles.
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { !(0x200B...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value) && !(0x2060...0x2064).contains($0.value) && $0.value != 0xFEFF })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func urlID(_ url: String) -> String { "u:" + Clean.canonical(url) }
    static func tab(_ tab: BrowserTab) -> SearchItem {
        SearchItem(id: urlID(tab.url), kind: .tab, title: tab.title.isEmpty ? tab.url : clean(tab.title), subtitle: SearchItem.short(tab.url), url: tab.url, tab: tab.ref)
    }
    static func action(title: String, url: String, note: String) -> SearchItem {
        SearchItem(id: "x:\(url)", kind: .action, title: title, subtitle: short(url), url: url, note: note)
    }
    var remembered: Remembered { Remembered(kind: kind.rawValue, title: title, subtitle: subtitle, url: url, command: command) }
    static func remembered(_ id: String, _ value: Remembered) -> SearchItem? {
        guard let kind = Kind(rawValue: value.kind), kind != .tab, kind != .command else { return nil }
        return SearchItem(id: id, kind: kind, title: value.title, subtitle: value.subtitle, url: value.url)
    }
    static func short(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host else { return url }
        let rest = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        return String((host + (rest == "/" ? "" : rest)).prefix(120))
    }
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 \(time)" }
        return "\(Int(seconds / 86400)) 天前"
    }
}

enum Ranker {
    static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    static func wordStart(_ token: String, in text: String) -> Bool {
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: range) {
            if found.lowerBound == text.startIndex || " -_./|·(".contains(text[text.index(before: found.lowerBound)]) { return true }
            range = found.upperBound..<text.endIndex
        }
        return false
    }
    // Pasted paragraphs are not keyword queries; they go through loose recall instead.
    static func isLong(_ query: String) -> Bool { query.count > 60 || tokens(query).count > 6 }
    // Every token must match some field. Ordering combines match quality, kind and frecency.
    static func match(_ item: SearchItem, tokens: [String], boost: Double = 0, now: Date = Date()) -> Double? {
        guard !tokens.isEmpty else { return nil }
        let title = item.title.lowercased(), alias = item.aliases.lowercased(), detail = (item.subtitle + " " + (item.url ?? "")).lowercased()
        var score = 0.0
        for token in tokens {
            if title.hasPrefix(token) { score += 5 }
            else if wordStart(token, in: title) { score += 4 }
            else if title.contains(token) || alias.contains(token) { score += 3 }
            else if token.count >= 2, item.keywords.contains(where: { $0.lowercased().contains(token) }) { score += 2 }
            else if detail.contains(token) { score += 1.5 }
            else { return nil }
        }
        if title == tokens.joined(separator: " ") { score += 6 }
        switch item.kind {
        case .action, .command: score += 8
        case .tab: score += 2.5
        case .history: score += min(log2(Double(item.visits) + 1), 3)
        }
        if let date = item.date { score += max(0, 2 - now.timeIntervalSince(date) / 43200) }
        return score + boost
    }
    static func rank(_ query: String, in pool: [SearchItem], boost: [String: Double] = [:], limit: Int = 30) -> [SearchItem] {
        let words = tokens(query)
        var seen = Set<String>()
        var results: [SearchItem] = []
        for var item in pool where !seen.contains(item.id) {
            guard let score = match(item, tokens: words, boost: boost[item.id] ?? 0) else { continue }
            seen.insert(item.id); item.score = score; results.append(item)
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }
}

extension Ranker {
    // Loose recall for the AI: any word or Chinese bigram may match.
    static func grams(_ query: String) -> [String] {
        var result: [String] = []
        for token in tokens(query) {
            let chars = Array(token)
            if chars.contains(where: { $0.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false }) && chars.count > 2 {
                for i in 0..<(chars.count - 1) { result.append(String(chars[i...i + 1])) }
            } else if token.count >= 2 { result.append(token) }
        }
        result = Array(Set(result)).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.prefix(24).map { $0 }
        let filler: Set<String> = ["那个", "这个", "一下", "看的", "的那", "那篇", "刚才", "昨天", "今天", "前天", "上周", "最近", "打开", "找一", "找到"]
        return Array(Set(result).subtracting(filler))
    }
    static func recall(_ query: String, in pool: [SearchItem], limit: Int) -> [SearchItem] {
        let words = grams(query)
        guard !words.isEmpty else { return [] }
        var scored: [(SearchItem, Int)] = []
        for item in pool {
            let text = (item.title + " " + (item.url ?? "") + " " + item.aliases).lowercased() as NSString
            let hits = words.filter { text.range(of: $0, options: .literal).location != NSNotFound }.count
            if hits > 0 { scored.append((item, hits)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.date ?? .distantPast) > ($1.0.date ?? .distantPast) }.prefix(limit).map(\.0)
    }
    // Time phrases narrow history to a window the model can choose from.
    static func window(_ query: String, now: Date = Date()) -> DateInterval? {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        if query.contains("刚才") || query.contains("刚刚") { return DateInterval(start: now.addingTimeInterval(-7200), end: now) }
        if query.contains("前天"), let start = calendar.date(byAdding: .day, value: -2, to: today) { return DateInterval(start: start, duration: 86400) }
        if query.contains("昨天"), let start = calendar.date(byAdding: .day, value: -1, to: today) { return DateInterval(start: start, duration: 86400) }
        if query.contains("今天") { return DateInterval(start: today, end: now) }
        if query.contains("上周") || query.contains("这周") || query.contains("最近") { return DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now) }
        return nil
    }
}

// Well-known sites by the names people call them, with their search page. A search page learned from the user's own
// history wins over these; these cover a site named in the query that was never searched before ("小红书 国庆去哪里玩").
enum Sites {
    struct Site { var names: [String]; var label: String; var template: String }
    static let known: [Site] = [
        Site(names: ["github", "gh"], label: "github.com", template: "https://github.com/search?q={value}&type=repositories"),
        Site(names: ["知乎", "zhihu"], label: "zhihu.com", template: "https://www.zhihu.com/search?type=content&q={value}"),
        Site(names: ["小红书", "xhs", "xiaohongshu", "rednote"], label: "xiaohongshu.com", template: "https://www.xiaohongshu.com/search_result?keyword={value}"),
        Site(names: ["b站", "哔哩哔哩", "bilibili", "bili"], label: "bilibili.com", template: "https://search.bilibili.com/all?keyword={value}"),
        Site(names: ["抖音", "douyin"], label: "douyin.com", template: "https://www.douyin.com/search/{value}"),
        Site(names: ["微博", "weibo"], label: "weibo.com", template: "https://s.weibo.com/weibo?q={value}"),
        Site(names: ["豆瓣", "douban"], label: "douban.com", template: "https://www.douban.com/search?q={value}"),
        Site(names: ["淘宝", "taobao"], label: "taobao.com", template: "https://s.taobao.com/search?q={value}"),
        Site(names: ["京东", "jd"], label: "jd.com", template: "https://search.jd.com/Search?keyword={value}"),
        Site(names: ["掘金", "juejin"], label: "juejin.cn", template: "https://juejin.cn/search?query={value}"),
        Site(names: ["百度", "baidu"], label: "baidu.com", template: "https://www.baidu.com/s?wd={value}"),
        Site(names: ["谷歌", "google"], label: "google.com", template: "https://www.google.com/search?q={value}"),
        Site(names: ["必应", "bing"], label: "bing.com", template: "https://www.bing.com/search?q={value}"),
        Site(names: ["youtube", "油管", "yt"], label: "youtube.com", template: "https://www.youtube.com/results?search_query={value}"),
        Site(names: ["stackoverflow"], label: "stackoverflow.com", template: "https://stackoverflow.com/search?q={value}"),
        Site(names: ["huggingface", "hf", "抱抱脸"], label: "huggingface.co", template: "https://huggingface.co/search/full-text?q={value}"),
        Site(names: ["arxiv"], label: "arxiv.org", template: "https://arxiv.org/search/?query={value}&searchtype=all"),
        Site(names: ["npm"], label: "npmjs.com", template: "https://www.npmjs.com/search?q={value}"),
        Site(names: ["pypi"], label: "pypi.org", template: "https://pypi.org/search/?q={value}"),
        Site(names: ["维基", "维基百科", "wikipedia", "wiki"], label: "wikipedia.org", template: "https://zh.wikipedia.org/w/index.php?search={value}"),
    ]
    // The site a word names: exact for short or Chinese names, a prefix of at least 4 letters for the rest ("githu").
    static func named(_ word: String) -> Site? {
        let word = word.lowercased()
        return known.first { $0.names.contains(word) } ?? (word.count >= 4 ? known.first { $0.names.contains { $0.count > 3 && $0.hasPrefix(word) } } : nil)
    }
    // Sites named anywhere in the text, for the model to choose from.
    static func mentioned(in text: String) -> [Site] {
        let lower = text.lowercased()
        return known.filter { site in site.names.contains { name in name.count >= 2 && (name.unicodeScalars.first?.properties.isIdeographic == true ? lower.contains(name) : lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == name }) } }
    }
}

enum BrowserHistory {
    // Chrome only: every profile, the last 90 days. Demo mode reads the demo Chrome's profile instead.
    static func load(days: Int = 90, perProfile: Int = -1) -> [SearchItem] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = Demo.chrome ?? support.appendingPathComponent("Google/Chrome")
        var items: [SearchItem] = []
        for profile in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where profile == "Default" || profile.hasPrefix("Profile ") {
            let file = base.appendingPathComponent(profile).appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            items += read(file, days: days, limit: perProfile)
        }
        var best: [String: SearchItem] = [:]
        for item in items {
            guard var kept = best[item.id] else { best[item.id] = item; continue }
            // Tracking-parameter variants now share one id: keep the newest, add up the visits.
            let visits = kept.visits + item.visits
            if (kept.date ?? .distantPast) < (item.date ?? .distantPast) { kept = item }
            kept.visits = visits; best[item.id] = kept
        }
        return best.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    // Candidates exclude login/redirect hops and search result pages (those still feed site-search
    // learning, and come back only when the query matches what was searched).
    static func split(_ items: [SearchItem]) -> (candidates: [SearchItem], searches: [SearchItem]) {
        var candidates: [SearchItem] = [], searches: [SearchItem] = []
        for item in items {
            guard let url = item.url, !Clean.blocked(url) else { continue }
            if Clean.isSearch(url) { searches.append(item) } else { candidates.append(item) }
        }
        return (Clean.merge(candidates), searches)
    }
    static func matchingSearches(_ text: String, in searches: [SearchItem]) -> [SearchItem] {
        let key = Semantic.normalize(text)
        guard key.count >= 2 else { return [] }
        return searches.filter { item in
            guard let term = item.url.flatMap(Clean.searchTerm) else { return false }
            return Semantic.normalize(term).contains(key)
        }
    }
    // Site search templates from history (pages like github.com/search?q=…) plus ones learned in use.
    static func searches(_ items: [SearchItem], learned: [Recipe]) -> [Recipe] {
        var byTemplate: [String: Recipe] = [:]
        for recipe in learned { byTemplate[recipe.template] = recipe }
        for item in items {
            guard let url = item.url, let (template, _) = Inference.searchTemplate(url: url), let host = URL(string: url)?.host else { continue }
            let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            byTemplate[template, default: Recipe(source: "history", template: template, label: label, shape: "search", count: 0, updated: item.date ?? Date())].count += max(1, item.visits)
        }
        // One template per site, the most used one; at least two visits so one-off searches stay out.
        var bySite: [String: Recipe] = [:]
        for recipe in byTemplate.values where recipe.count >= 2 {
            if (bySite[recipe.label]?.count ?? 0) < recipe.count { bySite[recipe.label] = recipe }
        }
        return bySite.values.sorted { $0.count > $1.count }.prefix(30).map { $0 }
    }
    // "search.bilibili.com" → "bilibili", "github.com" → "github".
    static func siteName(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host.lowercased() }
        let generic: Set<String> = ["com", "net", "org", "cn", "io", "co", "edu", "gov"]
        let core = parts.dropLast().last { !generic.contains($0) } ?? parts[0]
        return core
    }
    // The live database is locked by the browser, so read a private copy.
    static func read(_ file: URL, days: Int, limit: Int) -> [SearchItem] {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("stepbar-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > ? ORDER BY last_visit_time DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let cutoff = (Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        sqlite3_bind_int64(statement, 1, Int64(cutoff)); sqlite3_bind_int(statement, 2, Int32(limit))
        var items: [SearchItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = Privacy.url(String(cString: raw)), Inference.safeURL(url) != nil else { continue }
            let title = sqlite3_column_text(statement, 1).map { SearchItem.clean(Privacy.text(String(cString: $0))) } ?? ""
            let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - 11_644_473_600)
            items.append(SearchItem(id: SearchItem.urlID(url), kind: .history, title: title.isEmpty ? SearchItem.short(url) : title, subtitle: "\(SearchItem.relative(date)) · \(SearchItem.short(url))", url: url, date: date, visits: Int(sqlite3_column_int(statement, 2))))
        }
        return items
    }
}
