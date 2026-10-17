import Foundation

// The single model-candidate boundary, also used by CLI evaluation. Scores from
// different retrievers have different units; fuse ranks, not their raw scores.
enum Fusion {
    static let limit = 5
    // Deliberately preserve scheme, www, path case, slash, semantic parameters
    // and fragments (including SPA routes). No title/entity based deduplication.
    static func key(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if let query = parts.queryItems {
            let kept = query.filter { !Clean.tracking.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
            parts.queryItems = kept.isEmpty ? nil : kept
        }
        return parts.string ?? address
    }
    static func identity(_ item: SearchItem) -> String { item.url.map { "url:" + key($0) } ?? item.id }
    static func merge(query: String, l1: [SearchItem], l2: [SearchItem], web: [SearchItem] = [], boost: [String: Double] = [:], limit: Int = limit) -> [SearchItem] {
        guard limit > 0 else { return [] }
        struct Hit { var item: SearchItem; var score: Double; var sources: [String]; var exact: Bool }
        var hits: [String: Hit] = [:]
        let normalized = Semantic.normalize(query)
        for (source, weight, items) in [("历史匹配", 1.0, l1), ("语义匹配", 0.9, l2), ("联网结果", 0.9, web)] {
            var seen = Set<String>()
            for (rank, item) in items.enumerated() {
                let key = identity(item)
                guard seen.insert(key).inserted else { continue }
                let exact = source == "历史匹配" && !normalized.isEmpty && (Semantic.normalize(item.title) == normalized || item.url.map { Fusion.key($0) == Fusion.key(query) } == true)
                let score = weight / (20 + Double(rank + 1))
                if var hit = hits[key] {
                    // L1/L2 arrive before web: keep the local identity and tab ref.
                    if item.kind == .tab && hit.item.kind != .tab { let content = hit.item.content; hit.item = item; if hit.item.content.isEmpty { hit.item.content = content } }
                    if hit.item.purpose.isEmpty { hit.item.purpose = item.purpose }
                    if hit.item.keywords.isEmpty { hit.item.keywords = item.keywords }
                    if hit.item.asks.isEmpty { hit.item.asks = item.asks }
                    if hit.item.entity.isEmpty { hit.item.entity = item.entity }
                    if hit.item.pageKind == "other" { hit.item.pageKind = item.pageKind }
                    if !item.content.isEmpty { hit.item.content = item.content }
                    hit.score += score; hit.sources.append(source); hit.exact = hit.exact || exact
                    hits[key] = hit
                } else { hits[key] = Hit(item: item, score: score, sources: [source], exact: exact) }
            }
        }
        return hits.values.sorted { a, b in
            if a.exact != b.exact { return a.exact }
            // Preference is bounded, and only reranks already relevant matches.
            let x = a.score + min(max(boost[a.item.id] ?? 0, 0), 12) * 0.0002
            let y = b.score + min(max(boost[b.item.id] ?? 0, 0), 12) * 0.0002
            return x != y ? x > y : identity(a.item) < identity(b.item)
        }.prefix(min(limit, Self.limit)).map { hit in
            var item = hit.item; item.layer = hit.sources.joined(separator: "+"); item.score = hit.score; return item
        }
    }
}
