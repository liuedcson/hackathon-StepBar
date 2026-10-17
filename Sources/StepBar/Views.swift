import SwiftUI

struct LauncherView: View {
    @ObservedObject var store: Store
    var open: (SearchItem) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    PulsingMark(size: 26, working: store.thinking || store.generating).help("StepBar · 阶跃星辰")
                    TextField("问 StepBar：输入几个词，直达 Chrome 里的页面…", text: $store.query)
                        .textFieldStyle(.plain).font(.system(size: 24, weight: .regular)).focused($focused)
                    if store.listening { Image(systemName: "mic.fill").foregroundStyle(.red).symbolEffectPulse() }
                }
                .padding(.horizontal, 20).frame(height: 62)
                .onAppear { focused = true }
                .onChange(of: store.focusRequest) { _ in focused = true }
                if let intent = store.intent {
                    Text("✦ \(intent)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
                }
                if !store.results.isEmpty || store.copiedText != nil {
                    Hairline()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                if let copied = store.copiedText, store.query.isEmpty {
                                    Label(copied.replacingOccurrences(of: "\n", with: " "), systemImage: "doc.on.clipboard")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 10).padding(.top, 6)
                                }
                                ForEach(Array(store.results.enumerated()), id: \.element.id) { index, item in
                                    if index == 0 || store.results[index - 1].section != item.section {
                                        Text(item.section).font(.caption.weight(.semibold)).foregroundStyle(item.section.hasPrefix("✦") ? Brand.blue : .secondary)
                                            .padding(.horizontal, 10).padding(.top, index == 0 ? 6 : 10).padding(.bottom, 2)
                                    }
                                    ResultRow(item: item, index: index, selected: index == store.selection)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { open(item) }
                                        .onHover { if $0 { store.selection = index } }
                                }
                            }.padding(8)
                        }
                        .frame(maxHeight: 440)
                        .onChange(of: store.selection) { value in
                            if store.results.indices.contains(value) { proxy.scrollTo(store.results[value].id) }
                        }
                    }
                    Hairline()
                    HStack {
                        Text("↩ 打开  ⌘1–9 直达  \(store.settings.voiceAvailable ? "长按⌥M 说话  " : "")Tab 让 Step 生成  ⌘⌫ 关标签页")
                        Spacer()
                        Text("阶跃星辰 \(store.launcherModel) · \(store.settings.hotkeyLabel)")
                    }.font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 7)
                }
            }
            .modifier(Glass(radius: 28))
            .padding(24)
            Spacer(minLength: 0)
        }.frame(width: 720, height: 600, alignment: .top).tint(Brand.blue)
    }
}

struct ResultRow: View {
    var item: SearchItem
    var index: Int
    var selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let note = item.note { Text(note).font(.caption2).foregroundStyle(selected ? .white.opacity(0.85) : .secondary).lineLimit(1) }
            Text(kindLabel).font(.caption2).foregroundStyle(selected ? .white.opacity(0.7) : .secondary.opacity(0.7))
            if index < 9 { Text("⌘\(index + 1)").font(.caption2.monospaced()).foregroundStyle(selected ? .white.opacity(0.7) : .secondary.opacity(0.6)) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(selected ? .white : .primary)
        .background { if selected { SelectionFill() } }
    }
    var kindLabel: String {
        switch item.kind {
        case .action: "动作"
        case .command: "命令"
        case .tab: "标签页"
        case .history: "历史"
        }
    }
    @ViewBuilder var icon: some View {
        let symbol: String = switch item.kind {
        case .action: item.note?.hasPrefix("✦") == true ? "sparkles" : "arrow.up.right.square"
        case .tab: "globe"
        case .history: "clock.arrow.circlepath"
        case .command: "wand.and.stars"
        }
        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(selected ? .white : Brand.blue)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var draft = Settings()
    @State private var key = ""
    @State private var foregroundKey = ""
    @State private var searchKey = ""
    @State private var voiceKey = ""
    @State private var keyEdited = false
    @State private var foregroundKeyEdited = false
    @State private var searchKeyEdited = false
    @State private var voiceKeyEdited = false
    @State private var loaded = false
    private func credential(_ value: Binding<String>, edited: Binding<Bool>) -> Binding<String> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; edited.wrappedValue = true })
    }
    private func loadKeys() {
        key = RuntimeChecks.summaryConfiguration(draft).apiKey
        foregroundKey = RuntimeChecks.quickBase(draft).apiKey
        searchKey = RuntimeChecks.searchKey(draft)
        voiceKey = RuntimeChecks.voiceConfiguration(draft).apiKey
        keyEdited = false; foregroundKeyEdited = false; searchKeyEdited = false; voiceKeyEdited = false
    }
    var body: some View {
        ScrollView {
            Form {
                Section("模型配置") {
                    Toggle("启用 AI 模型", isOn: $draft.aiEnabled)
                    Picker("配置模式", selection: $draft.aiProvider) {
                        Text("官方 · StepFun Step Plan").tag("stepPlan")
                        Text("自定义 · OpenAI 兼容协议").tag("custom")
                    }.onChange(of: draft.aiProvider) { _ in loadKeys() }
                    if draft.isCustom {
                        Text("后台记忆 · 页面理解与网址模式").font(.headline)
                        TextField("后台 Base URL", text: $draft.customBackgroundURL)
                        TextField("后台 Model ID", text: $draft.customBackgroundModel)
                        SecureField("后台 API Key", text: credential($key, edited: $keyEdited))
                        Text("前台检索 · 候选挑选与网址生成").font(.headline)
                        TextField("前台 Base URL", text: $draft.customForegroundURL)
                        TextField("前台 Model ID", text: $draft.customForegroundModel)
                        SecureField("前台 API Key", text: credential($foregroundKey, edited: $foregroundKeyEdited))
                        Toggle("请求 JSON 输出模式（服务支持时开启）", isOn: $draft.jsonMode)
                        Text("两个服务独立配置。填写 OpenAI Chat Completions Base URL（通常以 /v1 结尾）。自定义模式不会调用 Step Plan，包括搜索和语音。") .font(.caption)
                        Picker("联网搜索", selection: $draft.customSearchMode) {
                            Text("不启用").tag("disabled")
                            Text("搜索引擎入口（Bing 等）").tag("engine")
                            Text("自定义搜索 JSON API").tag("api")
                        }
                        if draft.customSearchMode == "engine" {
                            TextField("搜索网址模板，使用 {query}", text: $draft.searchEngineTemplate)
                            Text("默认 Bing。仅在结果列表提供入口，点击才打开；不会抓取搜索页，也不作为模型最新信息。") .font(.caption)
                        }
                        if draft.customSearchMode == "api" {
                            TextField("搜索 API 完整 URL", text: $draft.customSearchURL)
                            SecureField("搜索 API Key", text: credential($searchKey, edited: $searchKeyEdited))
                            Text("POST JSON {query,n}，Bearer 鉴权；响应 {results:[{title,url,snippet,time?}]}。需使用兼容此格式的搜索服务或网关，不是 Bing 搜索网页地址。结果会作为前台模型上下文。") .font(.caption)
                        }
                        Toggle("启用自定义语音转写（默认关闭）", isOn: $draft.customVoiceEnabled)
                        if draft.customVoiceEnabled {
                            TextField("语音完整 URL（例如 …/v1/audio/transcriptions）", text: $draft.customVoiceURL)
                            TextField("语音 Model ID", text: $draft.customVoiceModel)
                            SecureField("语音 API Key", text: credential($voiceKey, edited: $voiceKeyEdited))
                            Text("OpenAI 兼容音频转写：multipart WAV + model，返回 {text}。服务不支持此协议时请保持关闭；未配置不录音、不申请麦克风权限。") .font(.caption)
                        }
                    } else {
                        Text("官方地址：\(Settings.stepPlan)").font(.caption)
                        TextField("后台记忆 Model ID", text: $draft.modelID)
                        TextField("前台检索 Model ID", text: $draft.quickModelID)
                        SecureField("Step Plan API Key", text: credential($key, edited: $keyEdited))
                    }
                    Text("首次配置完成立即分批准备；之后新增满 10 条或每 15 分钟增量分析，不要求空闲或接电。每次最多理解 10 个页面，输出上限 4096 tokens；后台请求会消耗 Token 和电量。官方默认：后台 step-5-preview（high），前台 step-3.7-flash（low）。")
                        .font(.caption)
                    Toggle("后台自动准备历史与增量理解新页面", isOn: $draft.background)
                    Toggle("唤起搜索时先联网搜索一次输入的词，作为第三层的最新信息", isOn: $draft.webSearch)
                    Text("后台向配置的后台模型发送页面信息；前台向配置的前台模型发送输入、剪贴板、候选及联网结果。搜索只发送输入的词，不含剪贴板。回忆、链接、订单号/ID 不联网。个人信息先打码，带敏感参数的网址不发送。各服务密钥独立，仅保存在本机配置或钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("保存设置") { store.saveSettings(draft, key: keyEdited ? key : "", clearKey: keyEdited && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, foregroundKey: foregroundKeyEdited ? foregroundKey : "", clearForegroundKey: foregroundKeyEdited && foregroundKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, searchKey: searchKeyEdited ? searchKey : "", clearSearchKey: searchKeyEdited && searchKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, voiceKey: voiceKeyEdited ? voiceKey : "", clearVoiceKey: voiceKeyEdited && voiceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        Button(store.testingAI ? "测试中…" : "测试已保存的 AI 配置") { store.testAI() }.disabled(store.testingAI)
                    }
                    Text(store.aiStatus).font(.caption).textSelection(.enabled)
                    Text("当前：\(store.aiDescription)").font(.caption)
                }
                Section("快捷键和隐私") {
                    Picker("全局唤出", selection: $draft.hotkey) {
                        Text("Command + M（会覆盖窗口最小化 ⌘M）").tag("commandM")
                        Text("Ctrl + L").tag("controlL")
                        Text("Option + Space").tag("optionSpace")
                    }
                    TextField("排除的网站域名（逗号或空格分隔，含子域名）", text: $draft.excludedSites)
                    Stepper("页面正文和搜索记录保留 \(draft.retentionDays) 天", value: $draft.retentionDays, in: 1...90)
                    Text("排除的网站不会被索引、理解或发送。学到的查询入口、网址模式和「输入 → 选择」记录是越用越准的来源，180 天未使用才会清理，可在诊断窗口逐条删除。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Chrome 扩展") {
                    Label(store.bridgeReady ? "Ready · 扩展已连接" : "Not Ready · 扩展未就绪", systemImage: store.bridgeReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(store.bridgeReady ? Color.green : Color.orange)
                    Toggle("启用本机 Chrome 桥接", isOn: $draft.browserBridge)
                    Text(store.bridgeStatus).font(.caption)
                    if store.bridgeHeartbeat != .distantPast { Text("最近心跳：\(store.bridgeHeartbeat.formatted(date: .omitted, time: .standard))").font(.caption) }
                    Text("配对码：\(draft.bridgeToken)").font(.caption.monospaced()).textSelection(.enabled)
                    Button("重新生成配对码") { draft.bridgeToken = UUID().uuidString }
                    Button("安装 Chrome 扩展（打开扩展页与文件夹）") { store.installExtension() }
                    Text("扩展上报打开的标签页、读取停留页面的正文摘录，并执行切换/关闭标签页。桥接只监听本机 127.0.0.1:17373，每个请求都要配对码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Token 用量") {
                    Text("本次运行：\(store.sessionUsage.total.formatted()) tokens · \(store.sessionUsage.requests) 次模型响应")
                    Text("今日：\(Calendar.current.isDateInToday(store.usage.day) ? store.usage.today.total : 0) · 累计：\(store.usage.lifetime.total.formatted()) tokens")
                    Text("累计输入 \(store.usage.lifetime.input.formatted()) · 输出 \(store.usage.lifetime.output.formatted()) · 未返回用量 \(store.usage.lifetime.unreported) 次")
                    Text("按模型服务返回的 usage 统计，包含前台、后台与连接测试；缺失用量不当作零消耗。搜索和语音费用不在此统计内，Token 不能直接换算金额。后台按批次和单次输出上限控制，不再按小时额度阻止历史准备。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("首次使用与历史准备") {
                    Text(store.historyStatus)
                    Text(store.preparationProgress).font(.caption)
                    Text(store.backgroundStatus).font(.caption)
                    Button("重新准备 Chrome 历史") { store.prepareHistory() }
                    Text("本地扫描近 90 天所有可读取且未排除的 Chrome 历史，先生成有至少两个不同实例支持的 ID 查询路径，不调用模型。AI 立即分批理解，之后每 15 分钟或新增满 10 条处理；移除不在历史范围中的页面理解、网站模式，正文按保留天数清理。不回访历史网页，不编造不存在的入口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("运行信息") {
                    Button("查看已学习的记忆") { store.diagnosticTab = "memory" }
                    Text("本地数据：\(store.path.deletingLastPathComponent().path)").font(.caption).textSelection(.enabled)
                    if let path = store.settings.localConfigPath { Text("本地配置：\(path) · 编辑后重启生效").font(.caption).textSelection(.enabled) }
                    Text("StepBar v\(Updater.version) · AI 不可用时保留本地两层结果").font(.caption).foregroundStyle(.secondary)
                }
                UpdateSettingsView(updater: store.updater)
            }.formStyle(.grouped).scrollContentBackground(.hidden).padding()
        }.onAppear {
            if !loaded { draft = store.settings; loadKeys(); loaded = true }
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var store: Store
    @State private var search = ""
    @State private var confirmClear = false
    var notes: [(String, PageNote)] {
        store.memory.notes.sorted { $0.value.date > $1.value.date }.filter { _, note in
            search.isEmpty || "\(note.title) \(note.purpose) \(note.terms.joined(separator: " ")) \(note.asks.joined(separator: " "))".localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BrandMark(size: 22); Text("StepBar").font(.title2.bold()); Spacer()
                Button(store.paused ? "恢复" : "暂停") { store.togglePause() }
                Button("清空记忆", role: .destructive) { confirmClear = true }
            }.padding([.horizontal, .top])
            HStack {
                Text(store.aiDescription)
                Spacer(); Text("页面理解 \(store.memory.notes.count) · 网址模式 \(store.memory.patterns.count) · 查询入口 \(store.memory.recipes.count) · 学到的选择 \(store.memory.queryChoices.count)")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            TabView(selection: $store.diagnosticTab) {
                SettingsView(store: store).tabItem { Text("设置") }.tag("settings")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                    TextField("筛选标题、用途或关键词", text: $search).padding(10)
                    DisclosureGroup("记住的网页（\(notes.count)）") {
                    Text("网页用途和关键词，让你换一种说法也能找回。").font(.caption).foregroundStyle(.secondary)
                    ForEach(notes, id: \.0) { id, note in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title).font(.headline)
                                Text(note.purpose).textSelection(.enabled)
                                Text("关键词：\(note.terms.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
                                if !note.asks.isEmpty { Text("可能这样找：\(note.asks.joined(separator: " / "))").font(.caption).foregroundStyle(.secondary) }
                                Text("\(id.dropFirst(2)) · \(note.hadText ? "读过正文" : "仅标题") · \(note.date.formatted())").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(); Button("删除") { store.removeNote(id) }
                        }.padding(.vertical, 4)
                    }
                    }
                    DisclosureGroup("快捷查询（\(store.memory.patterns.count + store.memory.recipes.count)）") {
                    Text("从历史或使用习惯学到的网址入口，填入新 ID 或关键词即可直达。").font(.caption).foregroundStyle(.secondary)
                ForEach(store.memory.patterns) { pattern in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(pattern.label) · \(pattern.host)").font(.headline)
                            Text(pattern.template).font(.caption.monospaced()).textSelection(.enabled)
                            Text("可查询：\(pattern.param)").font(.caption)
                        }; Spacer(); Button("删除") { store.removePattern(pattern.id) }
                    }.padding(.vertical, 4)
                }
                ForEach(store.memory.recipes.filter { recipe in !store.memory.patterns.contains { $0.template == recipe.template } }) { recipe in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(recipe.label).font(.headline)
                            Text(recipe.template).textSelection(.enabled)
                            Text("\(recipe.source == "search" ? "站内搜索" : "使用时学到") · \(recipe.count) 次").font(.caption).foregroundStyle(.secondary)
                        }; Spacer(); Button("删除") { store.removeRecipe(recipe.id) }
                    }.padding(.vertical, 4)
                }
                    }
                    DisclosureGroup("常用选择（\(store.memory.queryChoices.count)）") {
                    Text("记住你输入后选择的页面，下次优先推荐。").font(.caption).foregroundStyle(.secondary)
                ForEach(store.memory.queryChoices.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }, id: \.key) { query, counts in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("「\(query)」").font(.headline)
                        ForEach(counts.sorted { $0.value > $1.value }, id: \.key) { id, count in
                            Text("\(count) 次 → \(store.memory.remembered[id]?.title ?? String(id.dropFirst(2)))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 3)
                }
                    }
                    }.padding()
                }.tabItem { Text("记忆") }.tag("memory")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.status)
                Text(store.backgroundStatus).foregroundStyle(.secondary)
            }.font(.caption).padding([.horizontal, .bottom])
        }.frame(minWidth: 800, minHeight: 600)
            .onAppear { if !["settings", "memory"].contains(store.diagnosticTab) { store.diagnosticTab = "settings" } }
            .alert("清空全部本地记忆？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.clear() }
            } message: { Text("删除页面理解、网址模式、查询入口、选择记录和页面正文。AI 配置保留。") }
    }
}

extension View {
    // Pulsing mic on macOS 14+, static on 13.
    @ViewBuilder func symbolEffectPulse() -> some View {
        if #available(macOS 14, *) { self.symbolEffect(.pulse) } else { self }
    }
}

// The panel is one pane of glass. macOS 26 draws it with the system's Liquid Glass; older systems get a blurred material
// with a light rim. No custom shadow: the window's own area is the panel plus a margin, and a larger shadow was cut off at it.
struct Glass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

// Selected row: a pane of tinted glass in the brand blue, with a light edge like a lit rim.
struct SelectionFill: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(Brand.blue.opacity(0.75)), in: shape)
        } else {
            shape.fill(LinearGradient(colors: [Brand.blue.opacity(0.95), Brand.blue.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 14) }
}

// The mark is always the brand blue. While Step is thinking or generating it breathes; that is the only change.
struct PulsingMark: View {
    var size: CGFloat
    var working: Bool
    @State private var dim = false
    var body: some View {
        BrandMark(size: size).foregroundStyle(Brand.blue)
            .opacity(working && dim ? 0.35 : 1)
            .animation(working ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: dim)
            .onChange(of: working) { dim = $0 }
            .onAppear { dim = working }
    }
}
