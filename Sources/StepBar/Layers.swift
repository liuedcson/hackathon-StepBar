import Foundation

// The two local layers over one snapshot of tabs, history and memory. The app and the command-line checks share it.
struct Layers {
    var pool: [SearchItem]
    var memory: Memory
    var entries: [Recipe]
    var searchPages: [SearchItem]
    func boosts(_ text: String = "") -> [String: Double] {
        var result: [String: Double] = [:]
        for (id, count) in memory.choices { result[id] = Double(min(count, 5)) * 1.5 }
        for (id, weight) in queryWeights(text) { result[id, default: 0] += min(weight * 4, 12) }
        return result
    }
    // What the user opened after typing this query (or a longer query starting with it).
    func queryWeights(_ text: String) -> [String: Double] {
        let key = Semantic.normalize(text)
        guard !key.isEmpty else { return [:] }
        var weights: [String: Double] = [:]
        for (query, counts) in memory.queryChoices where query == key || (key.count >= 2 && query.hasPrefix(key)) {
            for (id, count) in counts { weights[id, default: 0] += Double(count) * (query == key ? 1 : 0.5) }
        }
        return weights
    }
    // Chosen before for this query: also generated pages that are in no history yet.
    func learnedChoices(_ text: String, pool: [SearchItem]) -> [SearchItem] {
        var byID: [String: SearchItem] = [:]
        for item in pool where byID[item.id] == nil { byID[item.id] = item }
        return queryWeights(text).sorted { $0.value > $1.value }.prefix(3).compactMap { id, weight in
            guard weight >= 1, var item = byID[id] ?? memory.remembered[id].flatMap({ SearchItem.remembered(id, $0) }) else { return nil }
            item.note = "常选 · \(Int(weight)) 次"; return item
        }
    }
    // Site searches from history, learned in use, and search patterns the background found.
    static func entries(_ siteSearches: [Recipe], patterns: [Pattern]) -> [Recipe] {
        var entries = siteSearches
        for pattern in patterns where pattern.shape == "search" {
            let label = pattern.host.hasPrefix("www.") ? String(pattern.host.dropFirst(4)) : pattern.host
            if !entries.contains(where: { $0.label == label }) { entries.append(Recipe(source: "pattern", template: pattern.template, label: label, shape: "search", count: pattern.examples.count)) }
        }
        return entries
    }
    // Instant actions when the text contains a value a learned entry or URL pattern takes.
    func learnedActions(_ text: String?) -> [SearchItem] {
        guard let text else { return [] }
        var items: [SearchItem] = []
        let values = Inference.values(in: text)
        for value in values {
            for recipe in memory.recipes where recipe.shape != "search" && Inference.fits(recipe.shape, value) {
                if let url = Inference.instantiate(recipe.template, value: value) { items.append(.action(title: "查询 \(value) · \(recipe.label)", url: url, note: "学到的查询入口 · \(recipe.count) 次")) }
            }
            for pattern in memory.patterns where !["search", "text", "word"].contains(pattern.shape) && Inference.fits(pattern.shape, value) {
                if let url = PatternMiner.fill(pattern, value) { items.append(.action(title: "\(pattern.label) · \(value)", url: url, note: "网址模式")) }
            }
        }
        // "owner/repo" style values go into path patterns of a site the text names ("github stepfun-ai/Step-Audio").
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) where word.contains("/") && Inference.safeURL(word) == nil {
            let named = Set(Sites.mentioned(in: text).map(\.label))
            for pattern in memory.patterns where pattern.shape == "text" && pattern.examples.contains(where: { $0.contains("/") }) && (named.isEmpty || named.contains { pattern.host.hasSuffix($0) }) {
                if let url = PatternMiner.fill(pattern, word) { items.append(.action(title: "\(pattern.label) · \(word)", url: url, note: "网址模式")) }
            }
        }
        if let url = Inference.safeURL(text), let clean = Privacy.url(text) { items.append(.action(title: "打开 \(url.host ?? "链接")", url: clean, note: "链接")) }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
    // "github foo" → search GitHub for foo, using search pages learned from history and use, then well-known sites.
    func siteSearchActions(_ text: String, general: Int) -> (targeted: [SearchItem], general: [SearchItem]) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let entries = self.entries
        var targeted: [SearchItem] = []
        if words.count >= 2 {
            for (site, rest) in [(words[0], words.dropFirst()), (words[words.count - 1], words.dropLast())] {
                let name = site.lowercased(), value = rest.joined(separator: " ")
                let known = Sites.named(name)
                if name.count >= 2, let recipe = entries.first(where: { BrowserHistory.siteName($0.label).hasPrefix(name) || $0.label == known?.label }),
                   let url = Inference.instantiateSearch(recipe.template, value: value) {
                    targeted.append(.action(title: "在 \(recipe.label) 搜索「\(value)」", url: url, note: recipe.count > 0 ? "站内搜索 · 用过 \(recipe.count) 次" : "站内搜索")); break
                }
                if let known, let url = Inference.instantiateSearch(known.template, value: value) {
                    targeted.append(.action(title: "在 \(known.names[0]) 搜索「\(value)」", url: url, note: "站内搜索")); break
                }
            }
        }
        // Chinese ASR usually omits spaces: recognize an explicit site name at either edge.
        if targeted.isEmpty {
            for site in Sites.known {
                for name in site.names where name.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value: String
                    if trimmed.hasPrefix(name) { value = String(trimmed.dropFirst(name.count)) }
                    else if trimmed.hasSuffix(name) { value = String(trimmed.dropLast(name.count)) }
                    else { continue }
                    let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty, let url = Inference.instantiateSearch(site.template, value: query) else { continue }
                    targeted.append(.action(title: "在 \(name) 搜索「\(query)」", url: url, note: "站内搜索"))
                    break
                }
                if !targeted.isEmpty { break }
            }
        }
        let others = entries.prefix(general).compactMap { recipe in
            Inference.instantiateSearch(recipe.template, value: text).map { SearchItem.action(title: "在 \(recipe.label) 搜索「\(text.prefix(40))」", url: $0, note: "站内搜索") }
        }
        return (targeted, others)
    }
    func webSearch(_ text: String) -> SearchItem? {
        var parts = URLComponents(string: "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: text)]
        return parts.string.map { .action(title: "在 Google 搜索「\(text)」", url: $0, note: "网页搜索") }
    }
    // Layer 1: everything that matches by name, address or past use.
    func history(_ text: String) -> (direct: [SearchItem], matches: [SearchItem]) {
                let direct = learnedActions(text) + siteSearchActions(text, general: 0).targeted
        let found = Ranker.isLong(text) ? Ranker.recall(text, in: pool, limit: 12) : Ranker.rank(text, in: pool, boost: boosts(text), limit: 12)
        let searches = BrowserHistory.matchingSearches(text, in: searchPages).prefix(2)
        return (direct, Semantic.distinct(learnedChoices(text, pool: pool) + found + searches, limit: 12))
    }
    // What the fast model sees: the best of layers 1 and 2, each tagged with the layer that found it.
    func candidates(_ text: String, semantic: [SearchItem]) -> [SearchItem] {
        let (direct, matches) = history(text)
        let l1 = (Array(direct.prefix(3)) + Array(matches.prefix(7))).map { var item = $0; item.layer = "历史匹配"; return item }
        let l2 = semantic.prefix(8).map { var item = $0; item.layer = "语义匹配"; return item }
        return Semantic.distinct(l1 + l2, limit: 14)
    }
}
