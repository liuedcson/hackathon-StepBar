# StepBar · 让整个 Mac 越用越懂你

StepBar 的愿景是成为 **macOS 生态级的工作伙伴**：连接你授权的应用，理解当下的工作上下文，整理常用的工作路径，学习不同工具之间的组合，在你唤起时给出最合适的下一步。

**不只是“找到一个东西”，而是“知道你接下来要做什么”。** 

## 核心理念：从上下文，到下一步

办公不是一组孤立的搜索，而是一条跨应用的工作路径：看到消息、了解问题、查找资料、打开工具、继续处理。StepBar 希望在用户授权下连接这些上下文，逐渐学会“什么情况下，你通常会去哪、做什么”，把常用路径整理成可复用的组合。

有时，你知道想找什么，却记不起它叫什么。

浏览器开了几十个页面，标签越来越窄。你记得之前看过一篇讲强化学习（RL）的博客，解释得很好，却忘了标题、网站和打开的时间。

不必逐个翻标签，也不必猜关键词。唤起 StepBar，说一句：

“之前看的那篇讲 RL 的博客，里面解释了奖励模型。”

StepBar 要做的，不只是匹配标题，而是理解页面讲了什么、对你有什么用，让你用记忆里的描述找回它。你记住的是内容和意义，不应该被迫记住网址。

更进一步，你可能连下一步要打开什么，都不必重新寻找。

在未来的跨应用场景中，团队消息出现一条服务告警，授权应用通过 MCP 提供必要上下文。StepBar 结合过去的处理习惯，把相关指标页、日志查询和排查文档整理成建议。按 ⌘M，即可选择对应入口，继续工作。

从“帮我找到之前看过的东西”，到“帮我接上现在要做的事情”——这就是 StepBar 想走的路。

浏览器是起点，不是终点。让整个 Mac 越用越懂你，让下一步少一点寻找，多一点顺手。


## 初步实现

受 Hackathon 时间与技术条件限制，**v0.1.0 先实现 Chrome 场景**：按 **⌘M**，输入几个词或使用已配置的语音，它会结合标签页、浏览历史、页面用途、剪贴板和过去的选择，找到或生成目标网页入口。默认使用阶跃星辰 Step Plan，也支持自定义服务。

这一版验证的是愿景里的基础闭环：**获取上下文 → 理解用途 → 学习路径 → 推荐入口 → 从选择中继续学习**。目前不读取其他应用或本地文件，不截图、不读屏幕；跨应用 MCP、工作路径组合和跨应用下一步预测均属于后续规划，不是当前已交付能力。

我们希望未来的 macOS 应用能通过 **MCP（Model Context Protocol）或适配器** 与 StepBar 保持连接，按权限共享必要信息与操作能力。这个愿景不是持续监视整个 Mac：接入范围、共享信息、记忆和执行权限必须由用户控制。


## 效果演示

以下演示都是在真实 Chrome 中录制的，未修改结果内容。

### 联网获取最新信息，直达官方仓库

输入 `kimicode github`，从联网摘要中找到官方地址，直接打开 `github.com/MoonshotAI/kimi-code`，而不是一篇转载文章。

<p align="center">
  <img src="docs/assets/kimicode.gif" alt="真实演示：联网直达 Kimi Code 官方仓库" width="880">
</p>

### 点名站点，直接搜索

`小红书 国庆去哪里玩`：即使没在这个站点搜过，也能构造站内搜索地址。目标站点可能要求登录。

<p align="center">
  <img src="docs/assets/xhs.gif" alt="真实演示：直接进入小红书站内搜索" width="880">
</p>

### 一句话，把问题带到知乎

`大模型会不会让程序员失业 知乎`：去掉站名，只把问题带进知乎搜索。

<p align="center">
  <img src="docs/assets/zhihu.gif" alt="真实演示：一句话进入知乎搜索" width="880">
</p>

### 换个说法，也能找回

`阶跃 api 是啥`：标题里没有这些词，靠后台为页面写好的用途和关键词，找回看过的「基本概念」文档。

<p align="center">
  <img src="docs/assets/semantic.gif" alt="真实演示：通过页面用途找回文档" width="880">
</p>

### 记住你的选择，越用越懂你

只输入 `deeps`，上次选过的 DeepSeek GitHub 搜索页直接出现。熟悉的路径，不必每次重新寻找。

<p align="center">
  <img src="docs/assets/learned.gif" alt="真实演示：已学习的选择优先出现" width="880">
</p>

## 当前版本的工作方式

每次唤起，结果分三层逐步给出：

1. **历史匹配**（本机，约 1 ms）：按标题和网址匹配标签页与 Chrome 历史，加上以前同一输入选过的页面、学到的查询入口和站内搜索。
2. **语义匹配**（本机，约 1 ms）：后台模型事先为每个页面写好用途、中英文关键词和常见问法，换个说法也能命中。
3. **✦ Step**（停止输入 150 ms 后）：先用输入的词联网搜索一次，再把前两层的候选、联网结果、当前标签页、剪贴板和学到的网址模式一起交给 `step-3.7-flash`。模型挑出答案，必要时直接生成目标网址。

平时空闲且接通电源时，`step-5-preview` 在后台用高推理强度阅读你访问过的页面，写下页面用途，并归纳各网站的网址结构（例如 `github.com/{owner/repo}`、`zhihu.com/search?q={关键词}`）。唤起面板时，后台任务会立刻让出网络和额度。

愿景、阶段边界和演进路径见 [产品设计](docs/PRODUCT.md)；当前实现及未来 MCP 连接设计见 [技术实现](docs/ARCHITECTURE.md)。

## 安装

### v0.1.0 安装包（无需 Swift 工具链）

1. 登录 GitHub，打开 [私有 Releases](https://github.com/liuedcson/hackathon-StepBar/releases/tag/v0.1.0)，下载对应架构的 `StepBar-0.1.0-arm64.zip`（Apple Silicon）。
2. 解压，将 `StepBar.app` 移到 `~/Applications` 或有写权限的 `/Applications`，再打开。需要 macOS 13+ 和 Google Chrome。
3. 当前使用本机固定签名，**未通过 Apple 公证**。若系统拦截，在「系统设置 → 隐私与安全性」中手动允许打开；不建议关闭系统安全保护。
4. 菜单栏 → 设置，填写官方 Step Plan Key，或分别配置自定义后台/前台服务。安装包不包含任何 Key，不会自动读取源码旁的 `config.local.json`。
5. 菜单栏 → 安装 Chrome 扩展，在扩展页开启开发者模式，加载 Finder 选中的文件夹。扩展资源由应用复制到 `~/Library/Application Support/StepBar/browser-extension`，自动生成本机配对码。
6. 按 ⌘M 验证历史搜索，再测试 AI 配置与目标网页。语音按需配置，未启用的自定义语音不申请权限。

### 私有 GitHub 授权更新

设置 →「版本与授权更新」，填写自己的 fine-grained GitHub Token：仅授权本仓库，`Contents: Read-only`，存入本机钥匙串。可启用启动时和每 6 小时检查；发现新版本后确认下载、验证并安装重启，不静默安装。

GitHub Releases 保存 ZIP 和 `update-arm64.json`（版本、文件名、架构、SHA-256）。下载时 GitHub Token 仅发送到固定 GitHub API，跳转至 GitHub 签名资源地址时去掉 Token。校验包摘要、版本、Bundle ID 和与当前应用相同的签名身份，不通过则不安装。以后版本必须使用同一签名证书；Token 失效或没有权限时可登录 GitHub 手动下载。更新后 Chrome 扩展需重新加载。

### 从源码构建

额外需要 Swift 工具链（Xcode 或 Command Line Tools）。配置也可以直接在应用设置中填写；使用本机配置文件的开发者可按以下流程配置。

```sh
git clone https://github.com/liuedcson/hackathon-StepBar.git
cd hackathon-StepBar

# 1. 配置 Key：复制模板，在两处 apiKey 填入 Step Plan Key
cp config.example.json config.local.json
chmod 600 config.local.json

# 2. 可选，只需一次：创建本机固定签名，重新构建后麦克风授权不会失效
./scripts/setup-signing.sh

# 3. 构建并启动
./scripts/build.sh
open build/StepBar.app
```

`config.local.json` 已被 `.gitignore` 忽略。其中 `summary` 是后台模型（step-5-preview），`quick` 是唤起时的模型（step-3.7-flash），两者都使用 `https://api.stepfun.com/step_plan/v1`。

### 在设置中配置模型

菜单栏 →「设置」→「模型配置」：

- **官方 · StepFun Step Plan**：地址固定为官方 Step Plan；后台记忆和前台检索的 Model ID 分别填写，共用一个 Step Plan Key。
- **自定义 · OpenAI 兼容协议**：后台记忆、前台检索分别填写 Base URL、Model ID 和 API Key，可使用不同服务。Base URL 通常以 `/v1` 结尾，也可填写完整 `/chat/completions` 地址；本机服务支持 HTTP，其他地址要求 HTTPS。
- API Key 留空保留已保存值；可以单独删除。保存后立即生效，点击「测试已保存的 AI 配置」会分别测试后台和前台，不发送浏览历史。
- 官方模式的搜索和语音使用 Step Plan；**自定义模式完全不调用 Step Plan**。自定义搜索默认关闭，可选择 Bing 等搜索引擎入口（仅点击后打开，不提供模型上下文），或配置独立的搜索 JSON API（完整 URL、独立 Key，POST `{query,n}`，返回 `{results:[{title,url,snippet,time?}]}`）。
- 自定义语音默认关闭。需要时配置 OpenAI 兼容音频转写接口的完整 URL（如 `https://asr.example/v1/audio/transcriptions`）、Model ID 和独立 Key。发送 multipart WAV，返回 `{text}`。未启用或未配置完整时不录音、不请求麦克风权限；不支持此协议的服务请保持关闭。

自定义模式不发送 Step 专用推理参数；支持 JSON 输出的服务可开启「请求 JSON 输出模式」。官方和自定义配置分别保留，切换模式不会覆盖另一套 Key。

### 安装 Chrome 扩展

扩展负责上报标签页、切换和关闭标签页，并读取你停留过的页面正文（无痕窗口除外），让后台更好地理解页面。

1. 打开 `chrome://extensions`，开启右上角「开发者模式」；
2. 点「加载已解压的扩展程序」，选择仓库里的 `browser-extension` 文件夹；
3. 推荐通过菜单栏「安装 Chrome 扩展」选择应用准备好的扩展文件夹，自动配对。更新后在扩展页点「重新加载」。

不装扩展也能用，这时只搜索 Chrome 历史。

## 使用

**唤起与输入**

- **⌘M** — 唤起或关闭面板。
- **输入** — 本机结果实时出现，停顿后 ✦ Step 结果置顶。
- **按住 ⌥** — 使用已配置的语音服务说话输入；官方默认由 `stepaudio-2.5-asr` 转写。

**选择与打开**

- **↑ ↓ / ↩** — 选择并打开；已打开的页面切换到原标签页。
- **⌘1–9** — 直接打开第 N 项。
- **Tab** — 让 Step 再生成一次动作。

**退出与整理**

- **⌘⌫** — 关闭选中的标签页。
- **Esc** — 先清空输入，再按一次关闭面板。

不输入直接 ⌘M 时，显示和剪贴板相关的建议以及最近的页面。

菜单栏里的「Step 的理解与记忆」窗口可以查看后台写下的页面理解、网址模式、学到的查询入口和选择，也可以逐条删除或修改设置。

## 越用越好用

- **记住选择**：同一个输入选过的页面会置顶；选过两次以上，就不再调用模型。
- **学会站内搜索**：在某个网站搜过之后，下次「站名 + 关键词」直接在那里搜；GitHub、知乎、小红书、B 站等常见网站内置了搜索入口。
- **学会查询入口**：复制一个 ID 后两分钟内打开了含这个 ID 的网址，下次复制新 ID 唤起，就能直达从没访问过的对应页面。
- **理解页面**：后台持续为新页面写用途和关键词，语义匹配会越来越准。

## 隐私

- 所有记忆保存在本机 `~/Library/Application Support/StepBar/`，可在诊断窗口查看和删除。
- 联网搜索只发送你输入的词，不发送剪贴板、页面内容或历史。回忆类输入（「上周看的…」）、链接，以及含订单号、长 ID 或疑似密钥的输入不会联网。
- 发给模型前统一脱敏：手机号、邮箱、证件号会被替换，疑似密钥的剪贴板内容整段丢弃，带 token、session 等敏感参数的网址整条不发送。
- 不截图，不读取屏幕，不读取无痕窗口。可在设置里排除域名、关闭后台理解或联网搜索。
- 浏览器桥接只监听 `127.0.0.1:17373`，每个请求都要带配对码。

## 开发

```sh
./scripts/test.sh     # 单元测试与桥接测试
./scripts/build.sh    # 构建 build/StepBar.app

# 命令行诊断（需要 config.local.json）
.build/release/StepBar --search-check "阶跃 api 是啥"   # 逐层打印候选、联网结果、模型输出和耗时
.build/release/StepBar --model-bench "q1" "q2"          # 多个查询的端到端耗时
.build/release/StepBar --understand 1                   # 跑一轮后台页面理解与网址模式归纳
.build/release/StepBar --eval-search                    # 用本机搜索日志计算命中率
```

## 许可

本项目为 Hackathon 作品，暂未附带开源许可证。

当前限制：联网摘要可能不完整，模型生成的目标地址仍可能失效；部分站点需要登录。官方语音已通过三段合成语音的真实转写与本地搜索测试；麦克风权限、按键录音与自定义真实语音服务仍需现场验收。发布后的源码修复了中文语音省略空格时的站内搜索，现有 v0.1.0 安装包不包含此修复。
