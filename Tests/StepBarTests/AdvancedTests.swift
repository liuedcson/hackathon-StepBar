import Foundation

final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw AIError(message: "No mock handler") }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
extension InferenceTests {
    func testEndpointAndPrivacy() throws {
        XCTAssertEqual(try AIClient.endpoint("https://provider.example/v1/").absoluteString, "https://provider.example/v1/chat/completions")
        XCTAssertEqual(try AIClient.endpoint("http://127.0.0.1:8080/v1/chat/completions").absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        for invalid in ["http://provider.example/v1", "https://key@provider.example/v1", "https://provider.example/v1?key=abc"] {
            do { _ = try AIClient.endpoint(invalid); preconditionFailure("Unsafe endpoint accepted") } catch {}
        }
        XCTAssertNil(Privacy.url("https://work.example/orders/123?access_token=secret"))
        XCTAssertEqual(Privacy.text("password=secret-value"), "[已过滤]")
        XCTAssertEqual(Privacy.url("https://work.example/orders/123#section"), "https://work.example/orders/123")
    }
    func testOpenAICompatibleTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = AIClient(session: URLSession(configuration: config))
        let configuration = AIConfiguration(baseURL: "https://provider.example/v1", modelID: "my-model", apiKey: "test-key", jsonMode: true)
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let size = stream.read(&bytes, maxLength: bytes.count); if size <= 0 { break }; data.append(contentsOf: bytes.prefix(size)) }
                body = data
            }
            let json = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            XCTAssertEqual(json["model"] as? String, "my-model")
            XCTAssertEqual((json["response_format"] as? [String: String])?["type"], "json_object")
            let envelope: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": "```json\n{\"items\":[]}\n```"]]]]
            return (200, try JSONSerialization.data(withJSONObject: envelope))
        }
        let response = try await client.complete(AINotes.self, configuration: configuration, system: "Return JSON", payload: "Synthetic test only")
        XCTAssertEqual(response.items.count, 0)
        MockProtocol.handler = { _ in (401, Data("secret echoed prompt".utf8)) }
        do { let _: AINotes = try await client.complete(AINotes.self, configuration: configuration, system: "JSON", payload: "test"); preconditionFailure("HTTP error accepted") }
        catch { precondition(!error.localizedDescription.contains("secret")); precondition(error.localizedDescription.contains("401")) }
        MockProtocol.handler = { _ in (200, Data("{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"{}\"}}]}".utf8)) }
        do { let _: AINotes = try await client.complete(AINotes.self, configuration: configuration, system: "JSON", payload: "test"); preconditionFailure("Truncated response accepted") } catch {}
        MockProtocol.handler = nil
    }
    func testStepPlanTransport() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/step_plan/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-step-key")
            let body = try JSONSerialization.jsonObject(with: request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "step-3.7-flash")
            XCTAssertEqual(body?["reasoning_effort"] as? String, "low")
            let envelope: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": "{\"items\":[]}"]]]]
            return (200, try JSONSerialization.data(withJSONObject: envelope))
        }
        let config = AIConfiguration(baseURL: Settings.stepPlan, modelID: "step-3.7-flash", apiKey: "test-step-key", reasoningEffort: "low")
        let notes = try await AIClient(session: session).complete(AINotes.self, configuration: config, system: "Return JSON", payload: "synthetic")
        XCTAssertEqual(notes.items.count, 0)
        MockProtocol.handler = nil
        XCTAssertEqual(try AIClient.endpoint(Settings.stepPlan).absoluteString, "https://api.stepfun.com/step_plan/v1/chat/completions")
    }
    func testUnderstand() {
        let step = SearchItem(id: "u:https://platform.stepfun.com/docs", kind: .history, title: "StepFun 开放平台文档中心", subtitle: "", url: "https://platform.stepfun.com/docs", visits: 6)
        let other = SearchItem(id: "u:https://b.example", kind: .history, title: "Weekly sync notes", subtitle: "", url: "https://b.example", visits: 3)
        let once = SearchItem(id: "u:https://c.example", kind: .history, title: "Read once", subtitle: "", url: "https://c.example", visits: 1)
        let tab = SearchItem(id: "u:https://t.example", kind: .tab, title: "Open tab", subtitle: "", url: "https://t.example")
        var notes: [String: PageNote] = [:]
        // Tabs first, then pages visited more than once; a page seen once with no text waits.
        let pending = Understand.pending(pool: [other, step, once, tab], notes: notes, pages: [:])
        XCTAssertEqual(pending.map(\.id), [tab.id, step.id, other.id])
        let result = AINotes(items: [.init(i: 1, purpose: "StepFun 模型 API 文档", terms: ["阶跃星辰", "阶跃", "StepFun", "模型 API", "阶跃"], asks: ["阶跃 api 文档"]), .init(i: 9, purpose: "x", terms: ["x"], asks: nil)])
        XCTAssertEqual(Understand.apply(result, to: pending, pages: [:], into: &notes), 1)
        // Title words and repeats are dropped from terms.
        XCTAssertEqual(notes[step.id]?.terms, ["阶跃星辰", "阶跃", "模型 API"])
        XCTAssertEqual(Understand.pending(pool: [other, step, tab], notes: notes, pages: [:]).map(\.id), [tab.id, other.id])
        // Reading the page text later makes it worth a second look.
        let text = [step.id: PageText(url: step.url!, title: step.title, text: "鉴权")]
        XCTAssertEqual(Understand.pending(pool: [step], notes: notes, pages: text).map(\.id), [step.id])

        // Without a note the Chinese query misses the English title; with one it is found locally.
        let pool = [other, step]
        XCTAssertEqual(Semantic.match(query: "阶跃模型文档", pool: [other], pages: [:]).count, 0)
        let enriched = Understand.enrich(pool, notes: notes)
        XCTAssertEqual(Semantic.match(query: "阶跃 api 文档", pool: enriched, pages: [:]).first?.id, step.id)
        XCTAssertEqual(Ranker.rank("阶跃", in: enriched).first?.id, step.id)
        XCTAssertEqual(Assistant.describe(enriched[1]).contains("用途：StepFun 模型 API 文档"), true)
        // A title that says it beats a page that only has it as a keyword.
        let board = SearchItem(id: "u:https://books.example/d", kind: .history, title: "图书目录 - 阅读清单", subtitle: "", url: "https://books.example/d", visits: 1)
        var tagged = notes; tagged[other.id] = PageNote(title: other.title, purpose: "", terms: ["阅读清单"])
        let both = Understand.enrich([other, board], notes: tagged)
        XCTAssertEqual(Semantic.match(query: "阅读清单", pool: both, pages: [:]).first?.id, board.id)
        XCTAssertEqual(Ranker.rank("阅读清单", in: both).first?.id, board.id)
        XCTAssertEqual(Understand.prune(notes, alive: [], now: Date().addingTimeInterval(31 * 86400)).count, 0)
        XCTAssertEqual(Understand.prune(notes, alive: [step.id], now: Date().addingTimeInterval(31 * 86400)).count, 1)

        var budget = Budget(hourly: 1000)
        XCTAssertEqual(budget.allows(), true)
        budget.spent(1200)
        XCTAssertEqual(budget.allows(), false)
        XCTAssertEqual(budget.allows(Date().addingTimeInterval(3700)), true)
        let later = Date().addingTimeInterval(3700)
        budget.failed(later); budget.failed(later)
        XCTAssertEqual(budget.allows(later.addingTimeInterval(60)), false)
        XCTAssertEqual(budget.allows(later.addingTimeInterval(130)), true)
        XCTAssertEqual(Gate(idle: 40, onAC: true, lowPower: false, thermal: .nominal).allowsAI, true)
        XCTAssertEqual(Gate(idle: 40, onAC: false, lowPower: false, thermal: .nominal).allowsAI, false)
        XCTAssertEqual(Gate(idle: 5, onAC: true, lowPower: false, thermal: .nominal).allowsAI, false)
        XCTAssertEqual(Gate(idle: 40, onAC: true, lowPower: false, thermal: .serious).allowsAI, false)
    }
    func testPatternMiner() {
        func page(_ url: String) -> SearchItem { SearchItem(id: SearchItem.urlID(url), kind: .history, title: url, subtitle: "", url: url) }
        let github = ["https://github.com/openai/whisper", "https://github.com/rust-lang/rust#readme", "https://github.com/apple/swift?tab=readme", "https://github.com/settings/profile", "https://github.com/login"].map(page)
        let zhihu = ["https://www.zhihu.com/search?type=content&q=%E5%9B%BD%E5%BA%86", "https://www.zhihu.com/search?type=content&q=rust+async"].map(page)
        let pending = PatternMiner.pending(history: github + zhihu, studied: [:])
        // Login pages are not sent; a site needs 4 addresses.
        XCTAssertEqual(pending.map(\.host), ["github.com"])
        XCTAssertEqual(pending[0].items.count, 4)
        XCTAssertEqual(PatternMiner.pending(history: github, studied: ["github.com": Studied(pages: 4)]).count, 0)
        XCTAssertEqual(PatternMiner.pending(history: github, studied: ["github.com": Studied(pages: 1, date: Date().addingTimeInterval(-4 * 86400))]).count, 1)

        XCTAssertEqual(PatternMiner.matches("https://github.com/{value}", in: github.compactMap(\.url)), ["openai/whisper", "rust-lang/rust", "apple/swift", "settings/profile", "login"])
        XCTAssertEqual(PatternMiner.matches("https://www.zhihu.com/search?type=content&q={value}", in: zhihu.compactMap(\.url)), ["国庆", "rust async"])
        let sites = [(host: "github.com", items: github), (host: "www.zhihu.com", items: zhihu)]
        let result = AIPatterns(patterns: [
            .init(template: "https://github.com/{value}", label: "GitHub 仓库", param: "owner/repo"),
            .init(template: "https://www.zhihu.com/search?type=content&q={value}", label: "知乎搜索", param: "关键词"),
            .init(template: "https://github.com/{value}/issues", label: "Issues", param: "仓库"),
            .init(template: "https://invented.example/{value}", label: "编造", param: "x"),
            .init(template: "https://github.com/{value}/{value}", label: "两个参数", param: "x")
        ])
        let kept = PatternMiner.validated(result, sites: sites)
        XCTAssertEqual(kept.map(\.template), ["https://github.com/{value}", "https://www.zhihu.com/search?type=content&q={value}"])
        XCTAssertEqual(kept[1].shape, "search")
        XCTAssertEqual(PatternMiner.fill(kept[0], "stepfun-ai/Step-Audio"), "https://github.com/stepfun-ai/Step-Audio")
        XCTAssertNil(PatternMiner.fill(kept[0], "../etc"))
        XCTAssertNil(PatternMiner.fill(kept[0], "two words"))
        XCTAssertEqual(PatternMiner.fill(kept[1], "国庆 去哪"), "https://www.zhihu.com/search?type=content&q=%E5%9B%BD%E5%BA%86%20%E5%8E%BB%E5%93%AA")
    }
    func testLayers() {
        let repo = SearchItem(id: "u:https://github.com/openai/whisper", kind: .history, title: "openai/whisper: Robust Speech Recognition", subtitle: "", url: "https://github.com/openai/whisper", visits: 3)
        let ts = SearchItem(id: "u:https://www.unixtimestamp.com/", kind: .history, title: "Unix Time Stamp - Epoch Converter", subtitle: "", url: "https://www.unixtimestamp.com/", visits: 2)
        var memory = Memory()
        memory.recipes = [Recipe(source: "clipboard", template: "https://work.example/orders/{value}", label: "work.example", shape: "number")]
        memory.patterns = [Pattern(host: "github.com", template: "https://github.com/{value}", label: "GitHub 仓库", param: "owner/repo", shape: "text", examples: ["openai/whisper", "apple/swift"])]
        memory.queryChoices = ["时间戳": [ts.id: 2]]
        let search = Recipe(source: "search", template: "https://github.com/search?q={value}", label: "github.com", shape: "search")
        let layers = Layers(pool: [repo, ts], memory: memory, entries: Layers.entries([search], patterns: memory.patterns), searchPages: [])
        // Site name + words → that site's search; owner/repo → the repository; an id → the learned entry.
        XCTAssertEqual(layers.history("deepseek github").direct.first?.url, "https://github.com/search?q=deepseek")
        XCTAssertEqual(layers.history("github stepfun-ai/Step-Audio").direct.contains { $0.url == "https://github.com/stepfun-ai/Step-Audio" }, true)
        XCTAssertEqual(layers.history("订单 1792069018").direct.first?.url, "https://work.example/orders/1792069018")
        // What this query led to before comes first, also for the start of the query.
        XCTAssertEqual(layers.history("时间戳").matches.first?.id, ts.id)
        XCTAssertEqual(layers.queryWeights("时间")[ts.id], 1)
        XCTAssertEqual(layers.history("whisper").matches.first?.id, repo.id)
        let candidates = layers.candidates("whisper", semantic: [ts])
        XCTAssertEqual(candidates.map(\.layer), ["历史匹配", "历史匹配", "语义匹配"].suffix(candidates.count).map { $0 })
    }
    func testAssistantPayload() {
        let pattern = Pattern(host: "github.com", template: "https://github.com/{value}", label: "GitHub 仓库", param: "owner/repo", shape: "text", examples: ["a/b"])
        let other = Pattern(host: "docs.example", template: "https://docs.example/{value}", label: "文档", param: "slug", shape: "text", examples: ["x", "y", "z"])
        XCTAssertEqual(Assistant.relevant([other, pattern], text: "github whisper", candidates: []).first?.host, "github.com")
        let recipe = Recipe(source: "clipboard", template: "https://work.example/orders/{value}", label: "订单", shape: "number")
        var item = SearchItem(id: "u:a", kind: .history, title: "A", subtitle: "", url: "https://a.example/")
        item.layer = "语义匹配"; item.purpose = "测试用途"
        let payload = Assistant.payload(query: "转日期", current: nil, clipboard: "1792069018", candidates: [item], recipes: [recipe], searches: [], patterns: [pattern])
        XCTAssertEqual(payload.contains("1792069018"), true)
        XCTAssertEqual(payload.contains("[语义匹配·浏览历史]"), true)
        XCTAssertEqual(payload.contains("work.example"), true)
        // An entry that takes ids is not offered without an id in front of the model.
        XCTAssertEqual(Assistant.payload(query: "随便", current: nil, clipboard: nil, candidates: [], recipes: [recipe], searches: [], patterns: []).contains("work.example"), false)
        let picks = Assistant.picks(AIActions(intent: "x", picks: [AIPick(id: "c0", confidence: 0.9), AIPick(id: "c7", confidence: 0.9), AIPick(id: "c0x", confidence: 1), AIPick(id: "c0", confidence: 0.1)], actions: []), from: [item])
        XCTAssertEqual(picks[item.id], 0.9)
        XCTAssertEqual(picks.count, 1)
    }
    func testWebSearch() async throws {
        var settings = Settings()
        settings.aiProvider = "custom"
        XCTAssertEqual(settings.customSearchMode, "disabled")
        XCTAssertEqual(settings.voiceAvailable, false)
        settings.customVoiceEnabled = true
        XCTAssertEqual(settings.voiceAvailable, false)
        settings.aiProvider = "stepPlan"
        XCTAssertEqual(settings.backgroundURL, Settings.stepPlan)
        XCTAssertEqual(settings.foregroundModel, "step-3.7-flash")
        settings.aiProvider = "custom"
        settings.customBackgroundURL = "https://background.example/v1"
        settings.customBackgroundModel = "memory-model"
        settings.customForegroundURL = "https://foreground.example/v1"
        settings.customForegroundModel = "search-model"
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.backgroundURL, "https://background.example/v1")
        XCTAssertEqual(restored.foregroundURL, "https://foreground.example/v1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.localConfigPath = directory.appendingPathComponent("config.local.json").path
        let input = ConfigurationInput(
            summary: .init(baseURL: Settings.stepPlan, modelID: "step-5-preview", apiKey: "test-official-key"),
            quick: .init(baseURL: Settings.stepPlan, modelID: "step-3.7-flash", apiKey: "test-official-key"),
            customSummary: .init(baseURL: settings.backgroundURL, modelID: settings.backgroundModel, apiKey: "test-background-key"),
            customQuick: .init(baseURL: settings.foregroundURL, modelID: settings.foregroundModel, apiKey: "test-foreground-key"))
        try RuntimeChecks.writeLocal(input, path: settings.localConfigPath!)
        let background = Study.configuration(settings), foreground = RuntimeChecks.quickConfiguration(settings)
        XCTAssertEqual(background.modelID, "memory-model")
        XCTAssertEqual(background.apiKey, "test-background-key")
        XCTAssertNil(background.reasoningEffort)
        XCTAssertEqual(foreground.modelID, "search-model")
        XCTAssertEqual(foreground.apiKey, "test-foreground-key")
        XCTAssertNil(foreground.reasoningEffort)
        XCTAssertEqual(RuntimeChecks.stepPlanConfiguration(settings).apiKey, "test-official-key")
        settings.aiProvider = "stepPlan"
        XCTAssertEqual(RuntimeChecks.quickConfiguration(settings).baseURL, Settings.stepPlan)
        XCTAssertEqual(Study.configuration(settings).reasoningEffort, "high")
        // Only plain words go to the web: no recall, links, order numbers, long identifiers or secrets.
        XCTAssertEqual(WebSearch.allows("kimicode github"), true)
        XCTAssertEqual(WebSearch.allows("gpt-5 发布了吗"), true)
        XCTAssertEqual(WebSearch.allows("2026 国庆 小红书"), true)
        XCTAssertEqual(WebSearch.allows("上周看的 rust 文章"), false)
        XCTAssertEqual(WebSearch.allows("https://github.com/x"), false)
        XCTAssertEqual(WebSearch.allows("订单 1792069018"), false)
        XCTAssertEqual(WebSearch.allows("a1b2c3d4e5f60718293a4b5c6d7e8f90"), false)
        XCTAssertEqual(WebSearch.allows("password=hunter2"), false)
        XCTAssertEqual(WebSearch.allows("a"), false)
        XCTAssertEqual(try WebSearch.endpoint(Settings.stepPlan).absoluteString, "https://api.stepfun.com/step_plan/v1/search")
        let cleaned = WebSearch.cleaned([
            WebResult(title: "Kimi Code\u{200B}", url: "https://github.com/MoonshotAI/kimi-code#readme", snippet: "开源\n联系 13812345678", time: "2026-09-21T10:00"),
            WebResult(title: "dup", url: "https://github.com/MoonshotAI/kimi-code", snippet: "", time: nil),
            WebResult(title: "token", url: "https://a.example/?access_token=x", snippet: "", time: nil),
            WebResult(title: "js", url: "javascript:alert(1)", snippet: "", time: nil)
        ])
        XCTAssertEqual(cleaned.map(\.url), ["https://github.com/MoonshotAI/kimi-code"])
        XCTAssertEqual(cleaned[0].title, "Kimi Code")
        XCTAssertEqual(cleaned[0].snippet.contains("13812345678"), false)
        XCTAssertEqual(cleaned[0].time, "2026-09-21")
        XCTAssertEqual(WebSearch.items(cleaned).first?.content.hasPrefix("开源"), true)
        let report = WebResult(title: "月之暗面开源Kimi Code", url: "https://m.sohu.com/a/1", snippet: "开源地址：https://github.com/MoonshotAI/kimi-code 咱们接着聊，见 https://example.com 和 https://a.example/x?token=1。", time: nil)
        XCTAssertEqual(WebSearch.links(in: report.snippet), ["https://github.com/MoonshotAI/kimi-code"])
        let quoted = WebSearch.items([report])
        XCTAssertEqual(quoted.map { $0.url ?? "" }, ["https://github.com/MoonshotAI/kimi-code", "https://m.sohu.com/a/1"])
        XCTAssertEqual(quoted[0].title.contains("中提到"), true)
        XCTAssertEqual(WebSearch.links(in: "地址 https://github.com/example/truncated"), [])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/step_plan/v1/search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-step-key")
            let body = ["results": [["title": "Kimi Code", "url": "https://github.com/MoonshotAI/kimi-code", "snippet": "开源地址", "position": 1]]]
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
        let found = try await WebSearch.search("kimicode github", configuration: AIConfiguration(baseURL: Settings.stepPlan, modelID: "step-3.7-flash", apiKey: "test-step-key"), session: URLSession(configuration: config))
        XCTAssertEqual(found.map(\.url), ["https://github.com/MoonshotAI/kimi-code"])
        MockProtocol.handler = { _ in (500, Data()) }
        do { _ = try await WebSearch.search("x y", configuration: AIConfiguration(baseURL: Settings.stepPlan, modelID: "m", apiKey: "k"), session: URLSession(configuration: config)); preconditionFailure("HTTP error accepted") } catch {}
        MockProtocol.handler = nil
        let pcm = Data(repeating: 0, count: 16000)
        let voiceConfig = AIConfiguration(baseURL: "https://voice.example/v1/audio/transcriptions", modelID: "asr-model", apiKey: "test-voice-only-key")
        let voiceRequest = try VoiceInput.transcriptionRequest(pcm, configuration: voiceConfig)
        XCTAssertEqual(voiceRequest.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(voiceRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-voice-only-key")
        XCTAssertEqual(String(decoding: VoiceInput.wav(pcm).prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(VoiceInput.wav(pcm).count, pcm.count + 44)
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/custom/search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-search-only-key")
            return (200, Data("{\"results\":[{\"title\":\"Result\",\"url\":\"https://example.com/page\",\"snippet\":\"Public result\"}]}".utf8))
        }
        let customResults = try await WebSearch.customSearch("public query", endpoint: "https://search.example/custom/search", apiKey: "test-search-only-key", session: URLSession(configuration: config))
        XCTAssertEqual(customResults.first?.title, "Result")
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-voice-only-key")
            return (200, Data("{\"text\":\"hello\"}".utf8))
        }
        let transcript = try await VoiceInput.transcribeOpenAI(pcm, configuration: voiceConfig, session: URLSession(configuration: config))
        XCTAssertEqual(transcript, "hello")
        MockProtocol.handler = nil
        let bing = WebSearch.engineItem("swift & rust", template: Settings().searchEngineTemplate)
        XCTAssertEqual(URLComponents(string: bing!.url!)?.queryItems?.first?.value, "swift & rust")
        XCTAssertNil(WebSearch.engineItem("hello", template: "https://example.com/{query}/{query}"))
        var web = WebSearch.items(cleaned)[0]; web.layer = "联网结果"
        XCTAssertEqual(Assistant.describe(web).hasPrefix("[联网结果·网页]"), true)
        XCTAssertEqual(Assistant.describe(web).contains("摘要：开源"), true)
    }
}
