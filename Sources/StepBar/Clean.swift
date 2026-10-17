import Foundation

// Background hygiene rules. Parameter and noise lists come from measuring 30 days of real history:
// `from`, `id`, `tab` etc. are kept because stripping them merged genuinely different pages.
enum Clean {
    static let tracking: Set<String> = ["gclid", "gclsrc", "dclid", "wbraid", "gbraid", "msclkid", "fbclid", "yclid", "twclid", "igshid", "igsh", "srsltid",
                                        "mc_cid", "mc_eid", "_ga", "_gl", "mkt_tok", "spm", "scm", "bsource", "ref", "referer", "referrer",
                                        "gs_lcrp", "oq", "sourceid", "ved", "ei", "sa", "uact", "gs_lp", "sclient", "sca_esv", "sxsrf", "biw", "bih", "authuser", "pref", "pval", "ie"]
    // Same page, one id: drop the fragment, trailing slashes and tracking parameters.
    static func canonical(_ url: String) -> String {
        var key = url
        if let hash = key.firstIndex(of: "#") { key = String(key[..<hash]) }
        if key.contains("?"), var parts = URLComponents(string: key), let items = parts.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !tracking.contains(name)
            }
            parts.queryItems = kept.isEmpty ? nil : kept
            key = parts.string ?? key
        }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }
    static let engines = ["google.", "bing.com", "baidu.com", "duckduckgo.com", "sogou.com", "so.com"]
    static func isSearch(_ url: String) -> Bool { searchTerm(url) != nil }
    // The words of a search results page (site search or a web search engine).
    static func searchTerm(_ url: String) -> String? {
        if let (_, value) = Inference.searchTemplate(url: url) { return value.replacingOccurrences(of: "+", with: " ") }
        guard let parts = URLComponents(string: url), let host = parts.host?.lowercased(), engines.contains(where: host.contains) else { return nil }
        let path = parts.path.lowercased()
        guard path.hasPrefix("/search") || path == "/s" || path.hasPrefix("/m/s") || path.hasPrefix("/web") else { return nil }
        return parts.queryItems?.first { ["q", "wd", "word", "query"].contains($0.name) }?.value.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "+", with: " ") }
    }
    // Pages nobody wants to return to: login/logout, OAuth/SSO callbacks and redirect hops.
    static func blocked(_ url: String?) -> Bool {
        guard let url, let parts = URLComponents(string: url) else { return false }
        let segments = parts.path.lowercased().split(separator: "/").map(String.init)
        let login: Set<String> = ["login", "signin", "sign-in", "log-in", "logout", "signout", "sign-out", "sso"]
        if segments.count <= 3, segments.contains(where: login.contains) { return true }
        if segments.contains(where: { $0.contains("oauth") || $0 == "oidc" || $0 == "callback" || $0 == "cas" }) { return true }
        let hops: Set<String> = ["redirect", "redir", "out", "away", "jump", "link", "go", "r"]
        if let first = segments.first, hops.contains(first), parts.queryItems?.contains(where: { ["url", "target", "u", "to"].contains($0.name.lowercased()) }) == true { return true }
        // Google's click-through hop (google.com.hk/url?q=…).
        if segments == ["url"], parts.host?.lowercased().contains("google.") == true { return true }
        return false
    }
    // Only proven tracking variants are the same page. Preserve semantic query
    // parameters, path case and SPA fragments even when the titles are identical.
    static func merge(_ items: [SearchItem]) -> [SearchItem] {
        var groups: [String: SearchItem] = [:], order: [String] = []
        for item in items {
            let key = Fusion.identity(item)
            guard var kept = groups[key] else { groups[key] = item; order.append(key); continue }
            let newest = max(kept.date ?? .distantPast, item.date ?? .distantPast)
            if item.visits > kept.visits { let total = kept.visits; kept = item; kept.visits += total } else { kept.visits += item.visits }
            kept.date = newest
            groups[key] = kept
        }
        return order.compactMap { groups[$0] }
    }
}
