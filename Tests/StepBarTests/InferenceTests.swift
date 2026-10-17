import Foundation

func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Expected \(rhs), got \(lhs)", file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}

@main struct InferenceTests {
    static func main() async throws {
        let tests = InferenceTests()
        tests.testExactPathAndQueryLearning()
        tests.testDoesNotLearnHostSubstringsOrAmbiguousValues()
        try tests.testPersistenceAndMigration()
        tests.testClipboardContentPicksDestination()
        tests.testSemanticSearch()
        tests.testCleaning()
        try tests.testLauncherSearch()
        tests.testUnderstand()
        tests.testPatternMiner()
        tests.testLayers()
        tests.testAssistantPayload()
        try tests.testRetrievalPipeline()
        tests.testDifficultRetrieval()
        await tests.testSoftDeadline()
        try tests.testDecisionSafety()
        try await tests.testWebSearch()
        try tests.testEndpointAndPrivacy()
        try await tests.testOpenAICompatibleTransport()
        try await tests.testStepPlanTransport()
        print("PASS: 16 test groups (matching, learning, background understanding, URL patterns, layers, web search, transport)")
    }
    func testExactPathAndQueryLearning() {
        XCTAssertEqual(Inference.template(url: "https://work.example/orders/12345", object: "12345"), "https://work.example/orders/{value}")
        XCTAssertEqual(Inference.template(url: "https://work.example/search?id=12345&kind=order", object: "12345"), "https://work.example/search?id={value}&kind=order")
        XCTAssertEqual(Inference.instantiate("https://work.example/orders/{value}", value: "67890"), "https://work.example/orders/67890")
    }
    func testDoesNotLearnHostSubstringsOrAmbiguousValues() {
        XCTAssertNil(Inference.template(url: "https://12345.example/orders", object: "12345"))
        XCTAssertNil(Inference.template(url: "https://work.example/orders/9123456", object: "12345"))
        XCTAssertNil(Inference.template(url: "https://work.example/12345?id=12345", object: "12345"))
        XCTAssertNil(Inference.template(url: "file:///tmp/12345", object: "12345"))
        XCTAssertNil(Inference.instantiate("https://work.example/{value}", value: "../../private"))
    }
    func testPersistenceAndMigration() throws {
        var memory = Memory()
        memory.recipes = [Recipe(source: "clipboard", template: "https://work.example/{value}", label: "work", shape: "number")]
        memory.patterns = [Pattern(host: "github.com", template: "https://github.com/{value}", label: "GitHub 仓库", param: "owner/repo", shape: "text", examples: ["a/b"])]
        let restored = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored.recipes.first?.template, memory.recipes.first?.template)
        XCTAssertEqual(restored.patterns, memory.patterns)
        // Fields of older versions are ignored instead of failing the whole file.
        let old = try JSONDecoder().decode(Memory.self, from: Data("{\"unknownField\":[1],\"choices\":{\"u:a\":2}}".utf8))
        XCTAssertEqual(old.choices["u:a"], 2)
        XCTAssertEqual(old.notes.count, 0)
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{\"autoSummarize\":false,\"excludedApps\":\"com.tencent.xinWeChat bank.example\",\"hotkey\":\"commandL\"}".utf8))
        XCTAssertEqual(settings.background, false)
        XCTAssertEqual(settings.excludedSites, "bank.example")
        XCTAssertEqual(settings.hotkey, "commandM")
        XCTAssertEqual(settings.excludes(url: "https://my.bank.example/x"), true)
        XCTAssertEqual(settings.excludes(url: "https://notbank.example/x"), false)
    }
    func testClipboardContentPicksDestination() {
        let tab = BrowserTabRef(tabID: 3, windowID: 1, bundle: "com.google.Chrome")
        func page(_ title: String, _ url: String, _ tab: BrowserTabRef? = nil) -> SearchItem {
            SearchItem(id: SearchItem.urlID(url), kind: tab == nil ? .history : .tab, title: title, subtitle: "", url: url, tab: tab)
        }
        let pool = [
            page("Step 3.5 Flash - StepFun 开放平台文档中心", "https://platform.stepfun.com/docs/zh/guides/models/step-3.5-flash", tab),
            page("商品详情", "https://shop.example/product?item_id=a1b2c3d4e5f6"),
            page("Beginner RL guide", "https://learn.example/beginner-rl")
        ]
        XCTAssertEqual(Inference.clipboardMatches("https://platform.stepfun.com/docs/zh/guides/models/step-3.5-flash#top", in: pool).first?.tab, tab)
        XCTAssertEqual(Inference.clipboardMatches("a1b2c3d4e5f6", in: pool).first?.title, "商品详情")
        XCTAssertEqual(Inference.clipboardMatches("StepFun 开放平台", in: pool).first?.tab, tab)
        XCTAssertEqual(Inference.clipboardMatches("Read the beginner guide for RL training", in: pool).first?.title, "Beginner RL guide")
        XCTAssertEqual(Inference.clipboardMatches("unrelated words here please", in: pool).count, 0)
    }
    func testSemanticSearch() {
        // Site search templates: keep the search parameter, drop tracking noise, skip Google.
        let github = Inference.searchTemplate(url: "https://github.com/search?q=intent+bar&type=repositories&ref=nav")
        XCTAssertEqual(github?.template, "https://github.com/search?q={value}&type=repositories")
        XCTAssertNil(Inference.searchTemplate(url: "https://www.google.com/search?q=x"))
        XCTAssertNil(Inference.searchTemplate(url: "https://example.com/page?id=1"))
        XCTAssertEqual(Inference.instantiateSearch("https://github.com/search?q={value}", value: "强化 学习&x"), "https://github.com/search?q=%E5%BC%BA%E5%8C%96%20%E5%AD%A6%E4%B9%A0%26x")
        XCTAssertEqual(BrowserHistory.siteName("search.bilibili.com"), "bilibili")
        XCTAssertEqual(BrowserHistory.siteName("github.com"), "github")
        let history = [
            SearchItem(id: "u:1", kind: .history, title: "a", subtitle: "", url: "https://github.com/search?q=a", visits: 2),
            SearchItem(id: "u:2", kind: .history, title: "b", subtitle: "", url: "https://github.com/search?q=b", visits: 1),
            SearchItem(id: "u:3", kind: .history, title: "c", subtitle: "", url: "https://once.example/?q=c", visits: 1)
        ]
        XCTAssertEqual(BrowserHistory.searches(history, learned: []).map(\.label), ["github.com"])

        // Page notes and page text bridge languages; unrelated items stay out.
        let rl = SearchItem(id: "u:rl", kind: .history, title: "Beginner RL training", subtitle: "", url: "https://blog.example/rl", date: Date().addingTimeInterval(-86400))
        let doc = SearchItem(id: "u:https://docs.example/w", kind: .history, title: "Weekly sync", subtitle: "", url: "https://docs.example/w")
        let other = SearchItem(id: "u:x", kind: .history, title: "Pricing vendor sheet", subtitle: "", url: "https://sheet.example/p")
        let pages = ["u:https://docs.example/w": PageText(url: "https://docs.example/w", title: "Weekly sync", text: "本周讨论强化学习奖励设计")]
        let notes = ["u:rl": PageNote(title: rl.title, purpose: "多环境强化学习训练指南", terms: ["强化学习", "RL"], asks: ["强化学习那篇"])]
        let hits = Semantic.match(query: "昨天看的强化学习那篇", pool: Understand.enrich([other, doc, rl], notes: notes), pages: pages)
        XCTAssertEqual(hits.first?.id, rl.id)
        XCTAssertEqual(hits.contains { $0.id == doc.id }, false) // Raw body is not Step 5 structured data.
        XCTAssertEqual(hits.contains { $0.id == other.id }, false)
        XCTAssertEqual(Semantic.core("昨天看的强化学习那篇"), "强化学习")
        XCTAssertNil(PageIndex.sanitized(PageText(url: "https://a.example/?token=x", title: "t", text: "x")))
        XCTAssertEqual(PageIndex.sanitized(PageText(url: "https://a.example/", title: "t", text: "key  api_key=abc123\n next"))?.text, "key [已过滤] next")
    }
    func testCleaning() {
        // Tracking parameters and fragments go; content parameters stay.
        XCTAssertEqual(Clean.canonical("https://a.example/doc/?utm_source=x&id=7&spm=1.2#top"), "https://a.example/doc/?id=7")
        XCTAssertEqual(Clean.canonical("https://a.example/p?from=feed"), "https://a.example/p?from=feed")
        XCTAssertEqual(SearchItem.urlID("https://a.example/x?gclid=1"), SearchItem.urlID("https://a.example/x/"))
        XCTAssertEqual(Clean.blocked("https://id.example/login?next=/"), true)
        XCTAssertEqual(Clean.blocked("https://app.example/oauth2/callback?state=1"), true)
        XCTAssertEqual(Clean.blocked("https://link.example/redirect?url=https://b.example"), true)
        XCTAssertEqual(Clean.blocked("https://docs.example/guide/login-flow-design"), false)
        XCTAssertEqual(Clean.searchTerm("https://www.google.com/search?q=intent+bar"), "intent bar")
        XCTAssertEqual(Clean.searchTerm("https://github.com/search?q=swift"), "swift")
        XCTAssertNil(Clean.searchTerm("https://a.example/page?id=1"))
        // Personal details are masked wherever text leaves or is stored.
        XCTAssertEqual(Privacy.text("联系我 13800138000 或 test.user@example.com"), "联系我 [手机号] 或 [邮箱]")
        XCTAssertEqual(Privacy.text("+86 131-2296-9150，身份证 11010519491231002X"), "[手机号]，身份证 [身份证号]")
        XCTAssertEqual(Privacy.text("商品 a1b2c3d4e5f60718293a4b5c6d7e8f90 订单 123456789012345"), "商品 a1b2c3d4e5f60718293a4b5c6d7e8f90 订单 123456789012345")
        XCTAssertEqual(Privacy.text("座机 010-12345678"), "座机 [电话]")

        // Value shapes: a hex value, a git sha, an id and a word are different inputs.
        XCTAssertEqual(Inference.shape("a1b2c3d4e5f60718293a4b5c6d7e8f90"), "hex32")
        XCTAssertEqual(Inference.shape("a1b2c3d"), "hex7")
        XCTAssertEqual(Inference.shape("req-8f3a9z"), "id")
        XCTAssertEqual(Inference.shape("example-product"), "word")
        XCTAssertEqual(Inference.values(in: "这个商品怎么查不到"), [])
        XCTAssertEqual(Inference.chatty("这个商品怎么查不到"), true)
        XCTAssertEqual(Inference.chatty("阶跃 模型文档"), false)
        XCTAssertEqual(Inference.chatty("rlhf 博客"), false)
        XCTAssertEqual(Inference.recalling("上周看的 rust 文章"), true)
        XCTAssertEqual(Inference.recalling("deepseek r2 知乎上怎么评价"), false)
        XCTAssertEqual(Sites.named("小红书")?.label, "xiaohongshu.com")
        XCTAssertEqual(Sites.named("githu")?.label, "github.com")
        XCTAssertEqual(Sites.named("stackover")?.label, "stackoverflow.com")
        XCTAssertNil(Sites.named("rust"))
        XCTAssertEqual(Sites.mentioned(in: "step 3.5 flash 知乎").map(\.label), ["zhihu.com"])
        XCTAssertEqual(Sites.mentioned(in: "solar system").map(\.label), [])
        XCTAssertEqual(Inference.recalling("强化学习"), false)
        XCTAssertEqual(Inference.values(in: "这个商店今天下午有点不稳定"), [])
        XCTAssertEqual(Inference.values(in: "帮我看下 a1b2c3d4e5f60718293a4b5c6d7e8f90 这个商品"), ["a1b2c3d4e5f60718293a4b5c6d7e8f90"])
        XCTAssertEqual(Inference.values(in: "2026 年的计划"), [])
        XCTAssertEqual(Inference.values(in: "example-product"), ["example-product"])
        XCTAssertEqual(Inference.fits("hex32", "a1b2c3d4e5f60718293a4b5c6d7e8f90"), true)
        XCTAssertEqual(Inference.fits("hex32", "a1b2c3d"), false)
        XCTAssertEqual(Inference.fits("token", "product"), false)
        XCTAssertEqual(Inference.fits("token", "a1b2c3d"), false)
        XCTAssertEqual(Inference.fits("token", "a1b2c3d4e5f60718293a4b5c6d7e8f90"), true)
        XCTAssertEqual(Inference.learnable("https://docs.example/guides/{value}/integrations/editor", value: "example-product"), false)
        XCTAssertEqual(Inference.learnable("https://www.zhihu.com/search?q={value}", value: "rlhf"), true)
        XCTAssertEqual(Inference.learnable("https://shop.example/product/{value}", value: "a1b2c3d4e5f60718293a4b5c6d7e8f90"), true)

        // Search/login pages leave; semantic query variants are distinct even with identical titles.
        let items = [
            SearchItem(id: "u:1", kind: .history, title: "Quarterly plan", subtitle: "", url: "https://wiki.example/plan?view=1", visits: 2),
            SearchItem(id: "u:2", kind: .history, title: "Quarterly plan", subtitle: "", url: "https://wiki.example/plan?view=2", visits: 5),
            SearchItem(id: "u:3", kind: .history, title: "Quarterly plan", subtitle: "", url: "https://wiki.example/other", visits: 1),
            SearchItem(id: "u:4", kind: .history, title: "swift - Google 搜索", subtitle: "", url: "https://www.google.com/search?q=swift", visits: 3),
            SearchItem(id: "u:5", kind: .history, title: "Sign in", subtitle: "", url: "https://id.example/login", visits: 9)
        ]
        let (candidates, searches) = BrowserHistory.split(items)
        XCTAssertEqual(candidates.map(\.id).sorted(), ["u:1", "u:2", "u:3"])
        XCTAssertEqual(candidates.first { $0.id == "u:2" }?.visits, 5)
        XCTAssertEqual(searches.map(\.id), ["u:4"])
        XCTAssertEqual(BrowserHistory.matchingSearches("swift", in: searches).count, 1)
        XCTAssertEqual(BrowserHistory.matchingSearches("rust", in: searches).count, 0)

    }
    func testLauncherSearch() throws {
        let url = "https://platform.stepfun.com/docs/zh/guides/models/step-3.5-flash"
        let tab = SearchItem.tab(BrowserTab(id: 1, windowID: 1, title: "Step 3.5 Flash - StepFun 文档", url: url, active: false, focused: false, bundle: "com.google.Chrome"))
        var visited = SearchItem(id: SearchItem.urlID(url + "#intro"), kind: .history, title: "Step 3.5 Flash - StepFun 文档", subtitle: "", url: url, visits: 9)
        visited.date = Date()
        let docs = Ranker.rank("stepfun flash", in: [tab, visited])
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?.kind, .tab)
        XCTAssertEqual(Ranker.rank("stepfun missing", in: [tab]).count, 0)
        let actions = Assistant.validated(AIActions(intent: "x", actions: [
            AIAction(title: "搜索", url: "https://www.google.com/search?q=step"),
            AIAction(title: "本机", url: "http://localhost:3000/"),
            AIAction(title: "脚本", url: "javascript:alert(1)"),
            AIAction(title: "带密钥", url: "https://example.com/?token=abc")
        ]))
        XCTAssertEqual(actions.count, 0) // Speculative URLs without template/candidate evidence are rejected.
        XCTAssertEqual(SearchItem.short("https://example.com/a?b=1"), "example.com/a?b=1")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stepbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("History")
        let now = (Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        let sql = "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);" +
            "INSERT INTO urls VALUES(1,'\(url)','Step docs',4,0,\(Int64(now)),0);" +
            "INSERT INTO urls VALUES(2,'https://example.com/?session=x','secret',1,0,\(Int64(now)),0);" +
            "INSERT INTO urls VALUES(3,'https://old.example/','old',1,0,\(Int64(now - 90 * 86_400_000_000)),0);"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); process.arguments = [db.path, sql]
        try process.run(); process.waitUntilExit()
        let history = BrowserHistory.read(db, days: 30, limit: 100)
        XCTAssertEqual(history.map(\.title), ["Step docs"])
        XCTAssertEqual(history.first?.visits, 4)
        XCTAssertEqual(history.first?.id, tab.id)
    }
}
