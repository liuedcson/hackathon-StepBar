# StepBar 技术实现

StepBar 是原生 Swift（AppKit + SwiftUI）菜单栏应用，没有第三方依赖。数据来自 Chrome 历史数据库和一个本机配对的 Chrome 扩展。默认模型调用走 StepFun Step Plan；设置中也支持后台记忆、前台检索独立配置 OpenAI 兼容服务。

## 模型配置与路由

`Settings` 保存模式及两组 Base URL / Model ID，不保存 Key。凭据存于被忽略的本机配置文件或钥匙串；自定义后台和前台使用独立钥匙串账户。`RuntimeChecks.summaryConfiguration` 与 `quickConfiguration` 是统一路由入口，App、诊断和 CLI 共用。

官方模式固定 `https://api.stepfun.com/step_plan/v1`，默认后台 step-5-preview（high）、前台 step-3.7-flash（low）。自定义模式分别使用用户配置，不发送 `reasoning_effort`；JSON 模式可选。保存时校验两个端点和 Model ID，清空当前请求上下文与联网缓存，新设置立即生效。

联网搜索和语音独立使用 `stepPlanConfiguration`，仅从官方配置读取 Key，绝不使用自定义服务的凭据。缺少官方 Key 时不发联网请求，语音给出配置提示。设置中的连接测试分别测试两组服务，仅发送合成测试文本。

```
                    ┌──────────── 唤起时（前台，越快越好） ────────────┐
 ⌘M / 按住⌥ 说话 ──► 输入 + 当前标签页 + 剪贴板
                     │
                     ├─ L1 历史匹配（主线程，~1 ms）──────────────────┐
                     ├─ L2 语义匹配（后台线程，~1 ms）─────────────────┤──► 面板立刻有结果
                     │                                                 │
                     └─ 停止输入 150 ms ─► 联网搜索（≤3 s）─► L3 step-3.7-flash（L1+L2 候选 + 联网结果 + 网址模式）
                                                                       └──► 「✦ Step 推荐 / 生成」置顶

                    ┌──────────── 平时（后台，越细越好） ─────────────┐
 Chrome 历史 / 扩展上报的标签页与正文 ─► 清洗 ─► step-5-preview（reasoning high）
                                               ├─ 页面理解：用途、关键词、常见问法 → L2
                                               └─ 网址模式：{value} 模板 → L1/L3
 用户的每次选择 / 站内搜索 / 复制 ID 后访问的网址 ─► 本地学习 → L1
```

## 1. 数据来源

| 来源 | 实现 | 说明 |
|---|---|---|
| Chrome 历史 | 复制各 Profile 的 `History` SQLite 到临时目录后只读查询（数据库被 Chrome 锁定） | 近 90 天；去跟踪参数合并、登录/OAuth/跳转页和搜索结果页不进候选 |
| 标签页 | 扩展 `browser-extension/` 通过 `127.0.0.1:17373` 上报 | 每个请求带配对码；支持切换、关闭；确认后才算成功 |
| 页面正文 | 扩展在页面停留数秒后取 `meta description` + 主体 `innerText` 前 3000 字 | 无痕窗口、密码页不取；脱敏后存本机 |
| 剪贴板 | 唤起时和每秒 tick 读取 | 疑似密钥整段丢弃，个人信息替换，最长 500 字 |
| 语音 | 按住 ⌥ 录 16 kHz PCM，SSE 流式发给 `stepaudio-2.5-asr` | 只有按住时录音 |

扩展把 `bundle` 固定为 `com.google.Chrome`。产品刻意只支持 Chrome、只用浏览器信息：不截图、不读屏幕、不读其他应用和文件。

## 2. 唤起流程（`Launcher.swift`、`Layers.swift`）

`Layers` 是一个纯值类型，App 和命令行诊断（`--search-check`）共用，保证线上和测试走同一套逻辑。

### L1 历史匹配

`Layers.history(text)` 返回两组：

- **direct（直达，≤3）**：以前同一输入选过的页面（`queryChoices` 加权）、学到的查询入口（把输入或剪贴板里的值代入 `{value}` 模板）、点名站点的站内搜索（「小红书 国庆去哪里玩」→ 小红书搜索「国庆去哪里玩」）。
- **matches（≤7）**：`Search.rank` 对标签页和历史打分，综合整词、中文双字、关键词命中、访问频次和新近程度。

### L2 语义匹配

`Semantic.match` 在后台线程运行，对后台写好的页面理解（用途、中英文关键词、常见问法）和页面正文做匹配，返回 ≤8 个。它不调用模型，所以「阶跃 api 是啥」能在本机命中标题里没有这些字的「基本概念」文档。

### L3 ✦ Step

`queryChanged` 每次按键先同步 `compose()`，再调用 `scheduleAI(after:)`：

1. 睡眠 `Store.debounce`（150 ms）；期间又有按键，`searchGeneration` 变化，本次作废。连续输入只会发出一次请求。
2. 已经很确定时跳过 L3：同一输入选过同一页面两次以上，或直接输入了网址。
3. **联网搜索**（`WebSearch.swift`）：`POST /step_plan/v1/search`，只发送输入的词，超时 3 秒，按输入缓存。返回结果去重、脱敏、截断；摘要里引用的原始地址（如报道里的「开源地址：https://github.com/…」）被摘成独立候选并排在前面，让模型打开源头而不是转载页。
4. 等 L2 完成，合并 `Layers.candidates`（L1 + L2，按层标注，≤14）与联网结果，连同当前标签页、剪贴板、相关网址模式（≤12）、站内搜索和查询入口，发给 `step-3.7-flash`（`Assistant.actionPrompt`）。
5. 模型返回 `picks`（候选 id + 置信度）和 `actions`（新网址）。程序校验后，前者置顶为「✦ Step 推荐」，后者显示为「✦ Step 生成」。

**联网门控**（`WebSearch.allows`）：回忆类输入（「上周」「看过」）、网址、含个人信息的输入、≥6 位数字、≥12 位混合 ID、hex/UUID 一律不联网；`gpt-5`、`2026` 这类短词照常联网。

**程序对模型输出的校验**：

- 动作只能是 http/https，拒绝 localhost、内网地址、`.local` 和带凭据的链接；
- 域名必须是公开知名网站，或在候选、网址模式、站内搜索、联网结果里出现过；
- 模板只代入真正从输入或剪贴板中提取的值，且形状匹配（数字、UUID、hex 长度）；
- 与已有候选重复的动作被丢弃。

### 打开

标签页已打开时，通过扩展切换到原标签页；否则在 Chrome 打开网址。每次选择写入 `choices`（全局频次）和 `queryChoices`（输入 → 页面），并记入 `searchLog` 用于 `--eval-search`。

## 3. 后台理解（`Background.swift`、`Study.swift`）

后台任务全部使用 `step-5-preview`、`reasoning_effort: high`（环境变量 `STEPBAR_STUDY_EFFORT` 可改），请求超时 300 秒。后台不赶时间，更细致的结果更划算。

| 任务 | 输入 | 输出 | 用在哪 |
|---|---|---|---|
| 页面理解 `Understand` | 每批 10 个页面：标题、网址、正文前 300 字。标签页、有正文、多次访问的页面优先，只处理新页面或改了标题的页面 | `purpose`（一句话用途）、`terms`（4–8 个中英文检索词）、`asks`（2–4 个口语问法） | L2 语义匹配；L3 候选描述 |
| 网址模式 `PatternMiner` | 每次 3 个网站，每站 ≤25 个真实地址 | 含一个 `{value}` 的模板、中文名、参数说明 | L1 查询入口；L3 生成网址的依据 |

模型输出都要经过程序校验：网址模式必须至少匹配 2 个输入地址，且除 `{value}` 之外与真实地址逐字一致；页面理解只接受输入里存在的序号。

**调度**：`Store.tick` 每秒运行一次，`backgroundJobs` 优先做网址模式，没有待办时做页面理解。

- `Gate`：接通电源、非低电量模式、温度正常、用户空闲 ≥30 秒；
- `Budget`：每小时 12 万 token，失败后指数退避（1 分钟起，最长 1 小时）；
- 唤起面板时 `yieldToForeground` 立即取消正在进行的后台请求。

## 4. 本地学习（`Store.swift`）

| 记忆 | 来源 | 作用 |
|---|---|---|
| `queryChoices` | 输入 → 打开的页面 | 同一输入置顶；≥2 次直接跳过 L3 |
| `choices` | 全局打开频次 | 排序加权 |
| `recipes` · 站内搜索 | 当前标签页网址匹配搜索模板（`?q=` 等） | 「站名 + 词」直达站内搜索 |
| `recipes` · 剪贴板入口 | 复制 ID 后 120 秒内访问的网址里出现了这个 ID | 复制新 ID 后直达对应页面 |
| `notes` / `patterns` / `studied` | 后台模型 | L2 与网址模式 |
| `remembered` | 选中结果的快照 | 历史过期后仍可找回 |

学习到的入口 180 天未使用才淘汰；`choices` ≤1000、`queryChoices` ≤800、`recipes` ≤300。保存时先做值快照，再在后台串行队列写盘。

## 5. 隐私与安全

- 数据都在 `~/Library/Application Support/StepBar/`（`memory.json`、页面正文、设置）。Key 只存在于 git 忽略的 `config.local.json`（权限 600）或钥匙串。
- 发给模型和搜索之前统一脱敏（`Privacy`）：手机号、座机、邮箱、证件号替换为占位符；疑似密钥整段丢弃；带 `token`、`code`、`session` 等参数的网址整条丢弃（脱敏后的地址也打不开，不如不用）。
- 联网结果、页面正文都按不可信数据处理，提示词要求忽略其中的指令；程序只信任校验过的网址。
- 桥接只监听回环地址，需要配对码；扩展可在选项页重新配对。
- 设置中可以排除域名（同时删除相关记忆），也可以关闭 AI、后台理解或联网搜索，或暂停使用。

## 6. 模型分工与耗时

| 用途 | 模型 | 实测 |
|---|---|---|
| L3 挑选与生成 | `step-3.7-flash`（reasoning low） | 1.2–2.6 s（偶有长尾） |
| 联网搜索 | Step Plan `/search` | 1.9–2.4 s，超时 3 s |
| 后台页面理解、网址模式 | `step-5-preview`（reasoning high） | 每批数十秒，不阻塞前台 |
| 语音转写 | `stepaudio-2.5-asr`（SSE） | 保留功能；当前版本完整语音链路尚未验收 |

前台用 flash 而不是 step-5：同一组查询，flash 的挑选质量接近，延迟却只有一半左右且长尾更短。可以用 `STEPBAR_QUICK_MODEL=step-5-preview StepBar --model-bench …` 复现对比。

## 7. 代码地图

| 文件 | 内容 |
|---|---|
| `App.swift` | 菜单栏、Carbon 全局热键、面板窗口、键盘处理、命令行入口 |
| `Views.swift` | 面板、设置、「Step 的理解与记忆」窗口 |
| `Brand.swift` | 阶跃星辰标志与图标绘制 |
| `Store.swift` | 状态中心：tick、学习、后台调度、存储 |
| `Launcher.swift` | 唤起流程：compose、防抖、联网、L3、打开 |
| `Layers.swift` | L1/L2 共享逻辑 |
| `Search.swift` | 排序、Chrome 历史读取、内置站点、站内搜索模板 |
| `Semantic.swift` | 语义匹配、页面正文存储 |
| `WebSearch.swift` | 联网搜索：门控、请求、清洗、摘取引用地址 |
| `Assistant.swift` | L3 提示词、载荷与结果校验 |
| `Background.swift` / `Study.swift` | 门控、预算、页面理解、网址模式 |
| `Core.swift` | 数据结构与推断规则（ID 形状、模板、闲聊/回忆判断） |
| `Clean.swift` | 网址规范化与定期清理 |
| `Settings.swift` | 设置、钥匙串、脱敏 |
| `AI.swift` | Step Plan 客户端（JSON 输出、禁止重定向） |
| `Voice.swift` | 录音与流式语音识别 |
| `BrowserBridge.swift` + `browser-extension/` | 本机桥接与 Chrome 扩展 |
| `RuntimeChecks.swift` | 命令行诊断 |
| `Demo.swift` | 演示模式，用 `STEPBAR_DEMO=<目录>` 与真实数据隔离 |

## 8. 测试

`./scripts/test.sh` 把源码和 `Tests/StepBarTests` 编译成一个可执行文件运行（不依赖 Xcode 的 XCTest），共 16 组核心测试（匹配、学习、后台理解、网址模式、分层、联网搜索、网络传输）和桥接测试（鉴权、上下文、命令路由与确认）。网络请求用 `URLProtocol` 模拟，不调用真实接口。

真实效果用命令行诊断验证：`--search-check` 逐层打印候选、联网结果和模型输出；`--model-bench` 测端到端耗时；`--understand` 跑一轮后台任务并校验输出。
