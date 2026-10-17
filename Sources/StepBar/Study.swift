import Foundation

// One bounded background pass, shared by the app and `--understand`.
enum Study {
    static func configuration(_ settings: Settings) -> AIConfiguration {
        var config = RuntimeChecks.summaryConfiguration(settings)
        config.maxTokens = 4096
        if !settings.isCustom { config.reasoningEffort = ProcessInfo.processInfo.environment["STEPBAR_STUDY_EFFORT"] ?? "high" }
        return config
    }
    static let client = AIClient(timeout: 300)
    static func notes(_ items: [SearchItem], pages: [String: PageText], configuration: AIConfiguration) async throws -> [String: PageNote] {
        let result: AINotes
        do { result = try await client.complete(AINotes.self, configuration: configuration, system: Understand.prompt, payload: Understand.payload(items, pages: pages)) }
        catch let error as AIError where error.truncated && items.count > 1 {
            // One bounded retry with less work, never increase the token limit or change reasoning defaults.
            try Task.checkCancellation()
            let subset = Array(items.prefix(max(1, items.count / 2)))
            let retry = try await client.complete(AINotes.self, configuration: configuration, system: Understand.prompt, payload: Understand.payload(subset, pages: pages))
            var written: [String: PageNote] = [:]
            _ = Understand.apply(retry, to: subset, pages: pages, into: &written)
            return written
        }
        var written: [String: PageNote] = [:]
        _ = Understand.apply(result, to: items, pages: pages, into: &written)
        return written
    }
    static func patterns(_ sites: [(host: String, items: [SearchItem])], configuration: AIConfiguration) async throws -> [Pattern] {
        let result = try await client.complete(AIPatterns.self, configuration: configuration, system: PatternMiner.prompt, payload: PatternMiner.payload(sites))
        return PatternMiner.validated(result, sites: sites)
    }
}
