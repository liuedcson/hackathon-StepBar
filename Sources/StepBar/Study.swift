import Foundation

// One background pass, shared by the app and `--understand`. Background work uses step-5-preview with high effort:
// it runs while the user is away, so a slower and more careful answer is the better trade.
enum Study {
    static func configuration(_ settings: Settings) -> AIConfiguration {
        var config = RuntimeChecks.summaryConfiguration(settings)
        if !settings.isCustom { config.reasoningEffort = ProcessInfo.processInfo.environment["STEPBAR_STUDY_EFFORT"] ?? "high" }
        return config
    }
    static let client = AIClient(timeout: 300)
    static func notes(_ items: [SearchItem], pages: [String: PageText], configuration: AIConfiguration) async throws -> [String: PageNote] {
        let result = try await client.complete(AINotes.self, configuration: configuration, system: Understand.prompt, payload: Understand.payload(items, pages: pages))
        var written: [String: PageNote] = [:]
        _ = Understand.apply(result, to: items, pages: pages, into: &written)
        return written
    }
    static func patterns(_ sites: [(host: String, items: [SearchItem])], configuration: AIConfiguration) async throws -> [Pattern] {
        let result = try await client.complete(AIPatterns.self, configuration: configuration, system: PatternMiner.prompt, payload: PatternMiner.payload(sites))
        return PatternMiner.validated(result, sites: sites)
    }
}
