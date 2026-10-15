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
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    // A short, high-recall list: query words and Chinese bigrams against titles, background notes, page text and
    // time windows. (Apple's NLEmbedding was tried and dropped: unrelated titles scored as high as related ones.)
    static func match(query: String, pool: [SearchItem], pages: [String: PageText], boost: [String: Double] = [:], now: Date = Date(), limit: Int = 12) -> [SearchItem] {
        let phrases = Ranker.tokens(core(query)).filter { $0.count >= 2 && $0.unicodeScalars.allSatisfy(\.isASCII) }
        let grams = Ranker.grams(core(query))
        let window = Ranker.window(query, now: now)
        let lowered = query.lowercased()
        var seen = Set<String>(), scored: [(SearchItem, Double)] = []
        for var item in pool where seen.insert(item.id).inserted {
            let head = (item.title + " " + item.aliases).lowercased(), address = (item.url ?? "").lowercased()
            let content = item.url.flatMap { pages[SearchItem.urlID($0)]?.text.lowercased() } ?? ""
            var score = 0.0, matched = false
            for phrase in phrases {
                if has(phrase, in: head) { score += 3; matched = true }
                else if has(phrase.replacingOccurrences(of: " ", with: "-"), in: address) || has(phrase.replacingOccurrences(of: " ", with: ""), in: address) { score += 1.5; matched = true }
                else if has(phrase, in: content) { score += 1; matched = true }
            }
            // Chinese bigrams: one stray hit ("学习") is noise, so at least half of them must appear.
            var gramHits = 0
            // A background keyword the query mentions ("阶跃" in "阶跃模型文档" for a StepFun page); counted once, below a title hit.
            let tagHits = item.keywords.filter { $0.count >= 2 && lowered.contains($0.lowercased()) }.count
            let tagText = tagHits > 0 ? "" : (item.keywords.joined(separator: " ") + " " + item.purpose).lowercased()
            for gram in grams {
                if head.contains(gram) { score += 1.5; gramHits += 1 }
                else if !tagText.isEmpty && tagText.contains(gram) { score += 1; gramHits += 1 }
                else if content.contains(gram) { score += 0.5; gramHits += 1 }
            }
            if gramHits > 0 && gramHits * 2 >= grams.count { matched = true }
            if tagHits > 0 { score += 2 * Double(min(tagHits, 2)); matched = true }
            let inWindow = window.map { w in item.date.map(w.contains) ?? false } ?? false
            if inWindow { score += 2 }
            // A bare time phrase ("昨天看的那篇") is a valid request on its own.
            guard matched || (inWindow && grams.isEmpty && phrases.isEmpty) else { continue }
            // Search result pages are rarely what someone wants to go back to.
            if let url = item.url, Inference.searchTemplate(url: url) != nil || url.contains("google.com/search") { score -= 2 }
            if item.kind == .tab { score += 0.5 }
            score += min(log2(Double(item.visits) + 1), 3) * 0.3 + (boost[item.id] ?? 0)
            if let page = item.url.flatMap({ pages[SearchItem.urlID($0)] }) { item.content = String(page.text.prefix(120)) }
            scored.append((item, score))
        }
        return distinct(scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.date ?? .distantPast) > ($1.0.date ?? .distantPast) }.map(\.0), limit: limit)
    }
    // The query and a background keyword meet: the query names the keyword, or shares a Chinese bigram with it.
    static func tagged(_ item: SearchItem, query: String) -> Bool {
        guard !item.keywords.isEmpty || !item.purpose.isEmpty else { return false }
        let lowered = query.lowercased(), text = (item.keywords.joined(separator: " ") + " " + item.purpose).lowercased()
        return item.keywords.contains { $0.count >= 2 && lowered.contains($0.lowercased()) } || Ranker.grams(core(query)).contains { text.contains($0) }
    }
    // Same id or same title (one page visited under several URLs) only takes one model slot.
    static func distinct(_ items: [SearchItem], limit: Int) -> [SearchItem] {
        var ids = Set<String>(), titles = Set<String>(), result: [SearchItem] = []
        for item in items where ids.insert(item.id).inserted && titles.insert(item.kind.rawValue + "|" + item.title.lowercased()).inserted {
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }
}
