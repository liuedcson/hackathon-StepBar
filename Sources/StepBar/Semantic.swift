import Foundation

// Visible text of pages the user dwelled on, captured by the browser extension. Stored locally only.
struct PageText: Codable, Equatable {
    var url: String
    var title: String
    var text: String
    var date = Date()
    init(url: String, title: String, text: String, date: Date = Date()) { self.url = url; self.title = title; self.text = text; self.date = date }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }
}

enum PageIndex {
    static let limit = 3000
    static func load(_ path: URL) -> [String: PageText] {
        (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode([String: PageText].self, from: $0) } ?? [:]
    }
    static func save(_ pages: [String: PageText], to path: URL) {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        try? data.write(to: path, options: [.atomic, .completeFileProtection])
    }
    static func sanitized(_ page: PageText) -> PageText? {
        guard let url = Privacy.url(page.url), Inference.safeURL(url) != nil else { return nil }
        let text = Privacy.text(page.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        return PageText(url: url, title: SearchItem.clean(Privacy.text(page.title)), text: String(text.prefix(500)))
    }
    static func insert(_ page: PageText, into pages: inout [String: PageText]) {
        pages[SearchItem.urlID(page.url)] = page
        if pages.count > limit {
            for key in pages.sorted(by: { $0.value.date < $1.value.date }).prefix(pages.count - limit).map(\.key) { pages[key] = nil }
        }
    }
}

// Layer 2 of the launcher: local and instant. It reads what the background model already wrote about each page
// (purpose, bilingual keywords, typical requests) and the page text, so "苹果那个写界面的文档" finds the SwiftUI page
// without waiting for a model.
enum Semantic {
    static let filler = ["那个", "这个", "那篇", "这篇", "那些", "一下", "帮我", "我要", "我想", "打开", "找一下", "找到", "找", "看的", "看过", "用过", "的", "了", "文章", "页面", "刚才", "刚刚", "今天", "昨天", "前天", "上周", "这周", "最近", "上午", "下午", "晚上"]
    // The meaningful part of a Chinese description, for embedding comparisons.
    static func core(_ query: String) -> String {
        var text = query
        for word in filler.sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: word, with: " ") }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    // Latin terms must match whole words ("rl" must not hit "url" or "rlz="); Chinese terms match anywhere.
    static func has(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        guard term.unicodeScalars.allSatisfy(\.isASCII) else { return text.contains(term) }
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: term, range: range) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !(before?.isLetter == true && before?.isASCII == true || before?.isNumber == true), !(after?.isLetter == true && after?.isASCII == true || after?.isNumber == true) { return true }
            range = found.upperBound..<text.endIndex
        }
        return false
    }
    static func normalize(_ query: String) -> String {
        query.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    // A short, high-recall list: query words and Chinese bigrams against titles, background notes, page text and
    // time windows. (Apple's NLEmbedding was tried and dropped: unrelated titles scored as high as related ones.)
    static func match(query: String, pool: [SearchItem], pages: [String: PageText], boost: [String: Double] = [:], now: Date = Date(), limit: Int = 12) -> [SearchItem] {
        LocalIndex(pool: pool).match(query: query, boost: boost, now: now, limit: limit)
    }
    // The query and a background keyword meet: the query names the keyword, or shares a Chinese bigram with it.
    static func tagged(_ item: SearchItem, query: String) -> Bool {
        guard !item.keywords.isEmpty || !item.purpose.isEmpty else { return false }
        let lowered = query.lowercased(), text = (item.keywords.joined(separator: " ") + " " + item.purpose).lowercased()
        return item.keywords.contains { $0.count >= 2 && lowered.contains($0.lowercased()) } || Ranker.grams(core(query)).contains { text.contains($0) }
    }
    // Same id or same title (one page visited under several URLs) only takes one model slot.
    static func distinct(_ items: [SearchItem], limit: Int) -> [SearchItem] {
        guard limit > 0 else { return [] }
        var ids = Set<String>(), result: [SearchItem] = []
        for item in items where ids.insert(Fusion.identity(item)).inserted {
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }
}

// Cached, pre-normalized structured fields. Raw body/title fallback belongs to
// L1, not L2; without Step 5 notes this index is deliberately empty.
struct LocalIndex {
    struct Row { var item: SearchItem; var fields: [(String, Double)]; var terms: Set<String> }
    var rows: [Row] = []
    var postings: [String: [Int]] = [:]
    init(pool: [SearchItem]) {
        var seen = Set<String>()
        for item in pool where seen.insert(Fusion.identity(item)).inserted {
            guard !item.keywords.isEmpty || !item.asks.isEmpty || !item.purpose.isEmpty || !item.entity.isEmpty else { continue }
            let fields = [(item.entity, 3.0), (item.keywords.joined(separator: " "), 2.5),
                          (item.asks.joined(separator: " "), 1.5), (item.purpose, 1.0)].map { (Semantic.normalize($0.0), $0.1) }
            let terms = Set(fields.flatMap { Ranker.grams($0.0) })
            let index = rows.count
            rows.append(Row(item: item, fields: fields, terms: terms))
            for term in terms { postings[term, default: []].append(index) }
        }
    }
    func match(query: String, boost: [String: Double] = [:], now: Date = Date(), limit: Int = 30) -> [SearchItem] {
        let terms = Ranker.grams(Semantic.core(query)), window = Inference.recalling(query) ? Ranker.window(query, now: now) : nil
        let normalized = Semantic.normalize(query)
        var candidates = Set(terms.flatMap { postings[$0] ?? [] })
        if terms.isEmpty && window != nil { candidates = Set(rows.indices) }
        func idf(_ term: String) -> Double { log(1 + Double(rows.count + 1) / Double((postings[term]?.count ?? 0) + 1)) }
        let total = terms.reduce(0.0) { $0 + idf($1) }
        var found: [SearchItem] = []
        for index in candidates {
            let row = rows[index]
            let inWindow = window.map { row.item.date.map($0.contains) ?? false } ?? false
            if window != nil && !inWindow { continue }
            var covered = 0.0, score = 0.0
            for term in terms {
                let weight = row.fields.filter { Semantic.has(term, in: $0.0) }.map(\.1).max() ?? 0
                if weight > 0 { covered += idf(term); score += idf(term) * weight }
            }
            let exact = !row.item.entity.isEmpty && Semantic.has(Semantic.normalize(row.item.entity), in: normalized)
            let coverage = total > 0 ? covered / total : 0
            guard coverage >= 0.5 || exact || (terms.isEmpty && inWindow) else { continue }
            var item = row.item
            let confidence = item.understandingConfidence.isFinite ? min(1, max(0.1, item.understandingConfidence)) : 0.1
            item.score = score * max(coverage, exact ? 1 : 0) * confidence + (exact ? 3 * confidence : 0)
                + min(max(boost[item.id] ?? 0, 0), 12) * 0.02 + (inWindow ? 0.2 : 0)
            found.append(item)
        }
        return Semantic.distinct(found.sorted { $0.score != $1.score ? $0.score > $1.score : Fusion.identity($0) < Fusion.identity($1) }, limit: limit)
    }
}
