import Foundation

struct TokenUsage: Codable, Equatable {
    var input = 0
    var output = 0
    var total = 0
    var requests = 0
    var unreported = 0
    mutating func add(_ other: TokenUsage) {
        input += other.input; output += other.output; total += other.total
        requests += other.requests; unreported += other.unreported
    }
    static let notification = Notification.Name("StepBarTokenUsage")
    static func parse(_ json: [String: Any]) -> TokenUsage {
        guard let usage = json["usage"] as? [String: Any] else { return TokenUsage(requests: 1, unreported: 1) }
        let input = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int)
        let output = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int)
        let reportedTotal = usage["total_tokens"] as? Int
        guard input != nil || output != nil || reportedTotal != nil else { return TokenUsage(requests: 1, unreported: 1) }
        let knownInput = max(0, input ?? 0), knownOutput = max(0, output ?? 0)
        let total = max(knownInput + knownOutput, max(0, reportedTotal ?? 0))
        let incomplete = input == nil || output == nil || (input ?? 0) < 0 || (output ?? 0) < 0 || (reportedTotal ?? 0) < 0
        return TokenUsage(input: knownInput, output: knownOutput, total: total, requests: 1, unreported: incomplete ? 1 : 0)
    }
    static func report(_ data: Data) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        NotificationCenter.default.post(name: notification, object: parse(json))
    }
}

struct UsageLedger: Codable {
    var day = Calendar.current.startOfDay(for: Date())
    var today = TokenUsage()
    var lifetime = TokenUsage()
    mutating func record(_ usage: TokenUsage, now: Date = Date()) {
        let current = Calendar.current.startOfDay(for: now)
        if day != current { day = current; today = TokenUsage() }
        today.add(usage); lifetime.add(usage)
    }
}
