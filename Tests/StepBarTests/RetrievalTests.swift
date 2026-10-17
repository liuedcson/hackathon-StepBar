import Foundation

extension InferenceTests {
    func testDecisionSafety() throws {
        for text in ["今天的新模型", "怎么转换时间戳", "SwiftUI 的文档", "github 上怎么评价", "昨天发布的新产品"] {
            XCTAssertEqual(Inference.recalling(text), false)
            XCTAssertEqual(WebSearch.allows(text), true)
        }
        for text in ["昨天看的文档", "之前那个项目", "刚才打开过的仓库", "上周看的文章"] {
            XCTAssertEqual(Inference.recalling(text), true)
            XCTAssertEqual(WebSearch.allows(text), false)
        }
        let template = Assistant.templates(query: "github swift", candidates: [], recipes: [], searches: [], patterns: [])
        let partiallyBad = try JSONDecoder().decode(AIActions.self, from: Data(#"{"mode":"generate","actions":[{"title":42},{"title":"搜索","template_id":"t0","value":"swift"}],"picks":[{"id":1},{"id":"c0","confidence":0.9}]}"#.utf8))
        XCTAssertEqual(partiallyBad.actions.count, 1)
        XCTAssertEqual(Assistant.validated(partiallyBad, query: "github swift", templates: template).count, 1)
        let local = SearchItem(id: "local", kind: .history, title: "Swift", subtitle: "", url: "https://fixture.example/swift")
        XCTAssertEqual(Assistant.picks(partiallyBad, from: [local]).count, 0)
        let none = try JSONDecoder().decode(AIActions.self, from: Data(#"{"mode":"none","picks":[{"id":"c0","confidence":1}],"actions":[{"title":"搜索","template_id":"t0","value":"swift"}]}"#.utf8))
        XCTAssertEqual(Assistant.picks(none, from: [local]).count, 0)
        XCTAssertEqual(Assistant.validated(none, query: "github swift", templates: template).count, 0)
        for data in [#"{"mode":"bad","actions":[]}"#, #"{"fallback":"bad","actions":[]}"#] {
            precondition((try? JSONDecoder().decode(AIActions.self, from: Data(data.utf8))) == nil)
        }
        let web = SearchItem.action(title: "Swift", url: "https://web.example/swift", note: "联网")
        let picks = AIActions(intent: nil, picks: [.init(id: "c9", confidence: 1), .init(id: "c0", confidence: 0.2), .init(id: "c1", confidence: 0.9)], actions: [])
        XCTAssertEqual(Assistant.picks(picks, from: [web, local], query: "昨天看的 Swift"), ["local": 0.9])
        let paddedActions = AIActions(intent: nil, actions: [.init(title: "坏", url: "javascript:x"), .init(title: "坏", url: "https://guess.example"), .init(title: "好", template_id: "t0", value: "swift")])
        XCTAssertEqual(Assistant.validated(paddedActions, query: "github swift", templates: template).count, 1)
        let repoQuery = "github apple/swift"
        let repoTemplates = Assistant.templates(query: repoQuery, candidates: [], recipes: [], searches: [], patterns: [])
        let repoTemplate = repoTemplates.first { $0.kind == "pattern" }!
        let repo = AIActions(intent: nil, actions: [.init(title: "Swift", template_id: repoTemplate.id, value: "apple/swift")])
        XCTAssertEqual(Assistant.validated(repo, query: repoQuery, templates: repoTemplates).first?.url, "https://github.com/apple/swift")
        let emptyLayers = Layers(pool: [], memory: Memory(), entries: [], searchPages: [])
        XCTAssertEqual(emptyLayers.history(repoQuery).direct.first?.url, "https://github.com/apple/swift")
        XCTAssertEqual(emptyLayers.history("github ../swift").direct.contains { $0.note == "明确的仓库路径" }, false)
        XCTAssertEqual(emptyLayers.history("昨天看的 github apple/swift").direct.count, 0)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(3600)
        var old = local; old.date = yesterday
        var today = local; today.id = "today"; today.url = "https://fixture.example/today"; today.date = Date()
        let history = Layers(pool: [today, old], memory: Memory(), entries: [], searchPages: [])
        XCTAssertEqual(history.history("昨天看的 Swift").matches.map(\.id), [old.id])
        XCTAssertEqual(history.history("昨天看的那篇").matches.map(\.id), [old.id])
        print("PASS: unified recall routing, partial output recovery, mode enforcement and post-validation limits")
    }
    func testSoftDeadline() async {
        let fast = Task { ["ready"] }
        XCTAssertEqual(await SoftDeadline.wait(for: fast, nanoseconds: 200_000_000), ["ready"])
        let slow = Task { try? await Task.sleep(nanoseconds: 250_000_000); return ["late"] }
        let start = Date()
        XCTAssertNil(await SoftDeadline.wait(for: slow, nanoseconds: 10_000_000))
        precondition(Date().timeIntervalSince(start) < 0.2, "Soft deadline must not join the slow task")
        XCTAssertEqual(await slow.value, ["late"])
        XCTAssertEqual(await SoftDeadline.wait(for: slow, nanoseconds: 200_000_000), ["late"])
        let pending = Task { try? await Task.sleep(nanoseconds: 200_000_000); return 42 }
        let waiter = Task { await SoftDeadline.wait(for: pending, nanoseconds: 1_000_000_000) }
        waiter.cancel()
        XCTAssertNil(await waiter.value)
        XCTAssertEqual(await pending.value, 42)
        print("PASS: fast search, soft cutoff, late result reuse and cancellation without cancelling search")
    }
    func testDifficultRetrieval() {
        func page(_ title: String, _ path: String, entity: String = "", terms: [String] = [], asks: [String] = []) -> SearchItem {
            var item = SearchItem(id: SearchItem.urlID("https://fixture.example/" + path), kind: .history, title: title, subtitle: "", url: "https://fixture.example/" + path)
            item.entity = entity; item.keywords = terms; item.asks = asks; return item
        }
        let swift = page("SwiftUI | Reference", "swiftui", entity: "SwiftUI", terms: ["苹果", "界面", "声明式"], asks: ["苹果写界面的框架"])
        let step = page("StepFun API Authentication", "step-auth", entity: "StepFun", terms: ["阶跃", "鉴权", "模型", "文档"], asks: ["stepfun模型鉴权文档"])
        let rl = page("RL reward design", "rl", entity: "强化学习", terms: ["RL", "强化学习", "奖励设计"])
        let other = page("URL routing reference", "url", terms: ["路由", "URL"])
        let sameTitles = (0..<12).map { page("工作台", "dashboard?id=\($0)", entity: "工作台", terms: ["订单\($0)"]) }
        let pool = [swift, step, rl, other] + sameTitles
        let layers = Layers(pool: pool, memory: Memory(), entries: [], searchPages: [])
        let index = LocalIndex(pool: pool)
        let cases: [(String, SearchItem)] = [("苹果写界面的框架", swift), ("SwiftUI 声明式", swift), ("苹果 界面", swift),
            ("stepfun模型鉴权文档", step), ("阶跃 鉴权", step), ("StepFun authentication", step),
            ("RL 奖励设计", rl), ("强化学习 奖励", rl)] + sameTitles.enumerated().map { ("订单\($0.offset)", $0.element) }
        var before = 0, after = 0, top1 = 0
        for (query, target) in cases {
            let l1 = layers.history(query).matches, l2 = index.match(query: query)
            if (l1 + l2).contains(where: { Fusion.identity($0) == Fusion.identity(target) }) { before += 1 }
            let fused = layers.candidates(query, semantic: l2)
            if fused.contains(where: { Fusion.identity($0) == Fusion.identity(target) }) { after += 1 }
            if fused.first.map(Fusion.identity) == Fusion.identity(target) { top1 += 1 }
            precondition(fused.contains { Fusion.identity($0) == Fusion.identity(target) }, "Missing hard query: \(query)")
        }
        XCTAssertEqual(before, cases.count); XCTAssertEqual(after, before)
        XCTAssertEqual(layers.history("rl").matches.contains { $0.id == other.id }, false)
        XCTAssertEqual(layers.candidates("毫无关系的火星天气", semantic: index.match(query: "毫无关系的火星天气")).count, 0)
        // A new project's only real answer comes from the web; duplicate reports
        // must not consume slots. No fixed web quota is needed in this fixture.
        let report = SearchItem.action(title: "新项目报道", url: "https://news.example/new", note: "联网")
        let repo = SearchItem.action(title: "新项目官方仓库", url: "https://github.com/synthetic/new-project", note: "联网")
        let web = [repo, repo, report]
        let newHits = layers.candidates("synthetic new-project github", semantic: [], web: web)
        XCTAssertEqual(newHits.first?.url, repo.url); XCTAssertEqual(newHits.count, 2)
        // Deliberate cutoff cliff: all candidates are equally plausible. Measure
        // loss instead of claiming 100% recall or manufacturing a source quota.
        let ambiguous = Fusion.merge(query: "工作台", l1: sameTitles, l2: [])
        XCTAssertEqual(ambiguous.count, 5)
        XCTAssertEqual(sameTitles.filter { item in ambiguous.contains { Fusion.identity($0) == Fusion.identity(item) } }.count, 5)
        print("SYNTHETIC hard cases: pre-cut recall \(before)/\(cases.count), Recall@5 \(after)/\(cases.count), Top1 \(top1)/\(cases.count); ambiguous same-title alternatives retained 5/12 (7 cut, intentionally unresolved)")
    }
    func testRetrievalPipeline() throws {
        func page(_ title: String, _ url: String) -> SearchItem {
            SearchItem(id: SearchItem.urlID(url), kind: .history, title: title, subtitle: "", url: url, visits: 3)
        }
        let local = page("Target", "https://docs.example/page?id=1")
        var structured = local; structured.keywords = ["目标"]; structured.asks = ["找目标"]; structured.purpose = "目标文档"
        var web = SearchItem.action(title: "Target online", url: "https://DOCS.example:443/page?id=1&utm_source=test", note: "联网")
        web.content = "联网补充"
        let merged = Fusion.merge(query: "Target", l1: [local], l2: [structured], web: [web, web])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, local.id)
        XCTAssertEqual(merged[0].visits, 3)
        XCTAssertEqual(merged[0].content, "联网补充")
        XCTAssertEqual(merged[0].asks, ["找目标"])
        XCTAssertEqual(merged[0].layer, "历史匹配+语义匹配+联网结果")
        let duplicateHistory = page("Target", "https://docs.example/page?id=1&utm_source=test")
        XCTAssertEqual(Clean.merge([local, duplicateHistory]).count, 1)
        XCTAssertEqual(Clean.merge([local, duplicateHistory])[0].visits, 6)
        XCTAssertEqual(Clean.merge([local, page("Target", "https://docs.example/page?id=2")]).count, 2)
        let variants = ["https://docs.example/page?id=2", "https://docs.example/Page?id=1",
                        "https://docs.example/page/?id=1", "http://docs.example/page?id=1",
                        "https://www.docs.example/page?id=1", "https://docs.example/page?id=1#/other"]
        for url in variants {
            XCTAssertEqual(Fusion.merge(query: "Target", l1: [local, page("Target", url)], l2: []).count, 2)
        }
        let noise = (0..<30).map { page("Noise \($0)", "https://noise.example/\($0)") }
        XCTAssertEqual(Fusion.merge(query: "Target", l1: noise + [local], l2: noise).first?.id, local.id)
        XCTAssertEqual(Fusion.merge(query: "q", l1: noise, l2: [], limit: 99).count, 5)
        XCTAssertEqual(Fusion.merge(query: "q", l1: [], l2: []).count, 0)
        XCTAssertEqual(Fusion.merge(query: "q", l1: noise, l2: [], web: [web]).contains { $0.url == web.url }, true)
        XCTAssertEqual(Fusion.merge(query: "q", l1: noise, l2: []), Fusion.merge(query: "q", l1: noise, l2: []))

        var memory = Memory(); memory.queryChoices = ["目标": [local.id: 100]]
        let layers = Layers(pool: [structured], memory: memory, entries: [], searchPages: [])
        XCTAssertEqual(layers.history("目标").matches.count, 0)
        XCTAssertEqual(layers.candidates("目标", semantic: LocalIndex(pool: [structured]).match(query: "目标")).first?.id, local.id)
        XCTAssertEqual(Ranker.grams("stepfun模型文档").contains("stepfun"), true)
        XCTAssertEqual(Ranker.grams("stepfun模型文档").contains("st"), false)
        XCTAssertEqual(LocalIndex(pool: [structured]).match(query: "毫不相关目标用户需求").count, 0)
        XCTAssertEqual(LocalIndex(pool: [local]).match(query: "Target").count, 0)
        let legacy = try JSONDecoder().decode(PageNote.self, from: Data(#"{"title":"old","purpose":"用途","terms":["词语"]}"#.utf8))
        XCTAssertEqual(legacy.schema, 1); XCTAssertEqual(legacy.asks, [])
        XCTAssertEqual(Understand.pending(pool: [page("old", "https://old.example")], notes: [SearchItem.urlID("https://old.example"): legacy], pages: [:]).count, 1)
        let batch = try JSONDecoder().decode(AINotes.self, from: Data(#"{"items":[{"i":0,"terms":["Target"],"kind":"doc","entity":"Target","confidence":0.9},{"i":"bad"},{"i":1,"terms":["Other"]}]}"#.utf8))
        XCTAssertEqual(batch.items.count, 2)
        var notes: [String: PageNote] = [:]
        XCTAssertEqual(Understand.apply(batch, to: [local, page("Other", "https://other.example")], pages: [:], into: &notes), 2)
        XCTAssertEqual(notes[local.id]?.terms, ["Target"])
        XCTAssertEqual(notes[local.id]?.schema, 2)
        _ = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(Memory()))

        let query = "github swift"
        let templates = Assistant.templates(query: query, candidates: [], recipes: [], searches: [], patterns: [])
        XCTAssertEqual(templates.count, 1)
        let output = try JSONDecoder().decode(AIActions.self, from: Data(#"{"picks":[],"actions":[{"title":"搜索 Swift","template_id":"t0","value":"swift"}],"fallback":"none"}"#.utf8))
        XCTAssertEqual(Assistant.validated(output, query: query, templates: templates).count, 1)
        let guessed = AIActions(intent: nil, actions: [.init(title: "假地址", url: "https://invented.example/path")])
        XCTAssertEqual(Assistant.validated(guessed, query: query, templates: templates).count, 0)
        let inventedValue = AIActions(intent: nil, actions: [.init(title: "搜索", template_id: "t0", value: "swift invented")])
        XCTAssertEqual(Assistant.validated(inventedValue, query: query, templates: templates).count, 0)
        let duplicate = AIActions(intent: nil, actions: [.init(title: "重复", url: local.url!, candidate_id: "c0")])
        XCTAssertEqual(Assistant.validated(duplicate, query: query, candidates: [local]).count, 0)
        XCTAssertEqual(Assistant.validated(output, query: "昨天看的 swift", templates: templates).count, 0)
        let pattern = Pattern(host: "github.com", template: "https://github.com/{value}", label: "GitHub 仓库", param: "owner/repo", shape: "text", examples: ["a/b", "c/d"])
        let repoQuery = "github apple/swift"
        let repoTemplates = Assistant.templates(query: repoQuery, candidates: [], recipes: [], searches: [], patterns: [pattern])
        let repoTemplate = repoTemplates.first { $0.kind == "pattern" }!
        let repoAction = AIActions(intent: nil, actions: [.init(title: "Swift", template_id: repoTemplate.id, value: "apple/swift")])
        XCTAssertEqual(Assistant.validated(repoAction, query: repoQuery, templates: repoTemplates).first?.url, "https://github.com/apple/swift")
        let payload = Assistant.payload(query: query, candidates: noise, recipes: [], searches: [], patterns: [])
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        XCTAssertEqual((object["candidates"] as! [Any]).count, 5)
        XCTAssertNil(object["current"]); XCTAssertNil(object["clipboard"])
        XCTAssertEqual(Set(object.keys), Set(["query", "task", "candidates", "templates"]))
        XCTAssertEqual(Assistant.picks(AIActions(intent: nil, picks: [.init(id: "c00", confidence: 1)], actions: []), from: [local]).count, 0)
        // Deterministic synthetic golden set: each layer has an independently
        // identifiable answer, alongside negatives and cross-source duplicates.
        var goldPool: [SearchItem] = [], golden: [(String, String)] = []
        for i in 0..<40 {
            var item = page("Project\(i) guide", "https://gold.example/project\(i)")
            item.entity = "Project\(i)"; item.keywords = ["专题\(i)", "Project\(i)"]
            goldPool.append(item); golden.append(("Project\(i)", item.id))
        }
        let goldLayers = Layers(pool: goldPool, memory: Memory(), entries: [], searchPages: [])
        let goldIndex = LocalIndex(pool: goldPool)
        var recalled = 0
        for (query, target) in golden {
            let fused = goldLayers.candidates(query, semantic: goldIndex.match(query: query))
            if fused.contains(where: { $0.id == target }) { recalled += 1 }
            XCTAssertEqual(fused.first?.id, target)
            XCTAssertEqual(Set(fused.map(Fusion.identity)).count, fused.count)
        }
        XCTAssertEqual(recalled, golden.count)
        XCTAssertEqual(goldLayers.candidates("absent entirely", semantic: goldIndex.match(query: "absent entirely")).count, 0)
        // Timings are observations of synthetic local data, not API/UI latency.
        for size in [2000, 20000] {
            let pool = (0..<size).map { i -> SearchItem in
                var item = page("Fixture\(i)", "https://fixture.example/\(i)")
                item.entity = "Fixture\(i)"; item.keywords = ["Fixture\(i)", "documentation"]; return item
            }
            let start = Date(), index = LocalIndex(pool: pool)
            let buildMS = Date().timeIntervalSince(start) * 1000
            var samples: [Double] = []
            for i in 0..<50 {
                let start = Date(), hits = index.match(query: "Fixture\(i)")
                XCTAssertEqual(hits.first?.entity, "Fixture\(i)")
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
            samples.sort()
            print(String(format: "SYNTHETIC L2 %d pages: index %.1f ms · query p50 %.3f ms / p95 %.3f ms", size, buildMS, samples[25], samples[47]))
        }
        print("PASS: synthetic golden Recall@5 \(recalled)/\(golden.count), conservative deduplication, evidence generation and schema migration")
    }
}
