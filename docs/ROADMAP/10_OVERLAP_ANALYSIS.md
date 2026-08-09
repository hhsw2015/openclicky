# 重叠分析: openclicky ↔ Everywhere/OCCU

**问题 1**: openclicky 已有的能力和 Everywhere / OCCU 是否重叠?
**问题 2**: Everywhere 当初为什么没直接复用 OCCU?

---

## 一. 重叠映射表

| 能力 | openclicky 现有 | Everywhere | OCCU |
|---|---|---|---|
| **屏幕 / 窗口 / 应用枚举** | `OpenClickyNativeComputerUseController` (native swift, MIT ref: trycua/cua-driver) + `CompanionScreenCaptureUtility` (ScreenCaptureKit) | `NSScreenVisualElement.cs` / `WindowHelper.cs` / `MacAppActivator.cs` | `list_apps` / `screenshot` |
| **AX 树 walk + snapshot 渲染** | 部分 (`OpenClickyComputerUseRuntime`) | 早期 C# 手写 (63KB `AXUIElement.cs`), 后 2026-06-26 全部改走 OCCU dylib | 主实现 (`OpenComputerUseKit/Sources/`) — Snapshot / ElementIndexer / label cascade |
| **Click / type_text / press_key / scroll / drag** | native swift 部分 (`.click`, `.pressKey`, `.typeText`) + bundled `cua-driver` binary (22MB) + `BackgroundComputerUse.app` | 走 OCCU (`refactor(mac): retire C# AX automation path; route 9 tools through OCCU`) | 主实现 |
| **CGEventTap / global hotkey** | 有 (voice PTT + hotkey manager) | `CGEventListener.cs` + `CGEventShortcutListener.cs` | 部分 |
| **Cursor overlay 动画** | 有 (`OverlayWindow.swift`, 144KB) | 2026-06-25 全 port 自 OCCU (`SoftwareCursorOverlay`) | 主实现 |
| **MCP server** | `/mcp/advisor` + `/mcp/orchestrate` (HTTP :32123, SSE Streamable + 202 notifications) — 11+ tool | `/mcp` stdio + HTTP :7878 — **96 unique app-side tool** (PARITY_MATRIX 151 含 `browser_*` 走 OpenDia 转发) | 独立 MCP server + stdio (作为 codex 后端) |
| **Advisor / advisor_consult** | 8 个 `advisor_*` tool (Fable msgs 免费通道) | 无 | 无 |
| **Orchestrate** | 11+ `orchestrate_*` tool | 无 (Everywhere 是 sensor, 不是 orchestrator) | 无 |
| **Free-tier proxy** (HeyClicky) | 有 (25 credit/day, `<HEYCLICKY_PROXY_HOST>`) | 无 | 无 |
| **第三方 SaaS 集成** | Settings → **Connections tab** 有 Google Workspace (gogcli) + Composio MCP (200+ SaaS) + OpenAI docs MCP + cuaDriver MCP. Runtime 侧 `HeyClickyAgentIntegrationsClient` 走 proxy 的 Composio/Calendar/Spotify endpoint | Open-Connector V8 isolate: **831 provider** (spec 里 840, 实测 `3rd/open-connector/src/providers/` = 831) / 8300+ action, 本地 OAuth 加密, Web Console UI | 无 |
| **Chrome extension bridge** | `HeyClickyChromeBridgeServer` (:3011) + `chrome-ext/` (10KB background.js) — 用于自动化 Google account chooser | 无 (Everywhere 走 OpenDia extension, ~85 WS ops) | 无 |
| **Codex agent daemon** | bundled codex 0.132.0 + stdio JSON-RPC + lease reuse fast-path | 无 (Everywhere 是 MCP server, 不 spawn agent) | 无 |

---

## 二. openclicky ↔ Everywhere 重叠深度

### 2.1 Computer Use (强重叠)

openclicky 有 **两套并行**:
- `native_swift` (`OpenClickyNativeComputerUseController`): 参考 trycua/cua-driver, 51KB 自写 Swift, 覆盖 app/window 枚举 + 目标窗口 capture + 键盘输入 + pressKey/typeText/click
- `background_computer_use`: 22MB 二进制 `cua-driver` bundled 在 `AppResources/OpenClicky/CuaDriverRuntime/` + `BackgroundComputerUse.app`

Everywhere 的实现:
- 早期 C# 手写 AX (63KB `AXUIElement.cs`) — 2026-06 之前
- 2026-06-24 起手翻 OCCU Swift → C# (逐 commit 抄 click / snapshot / cursor / trait aggregation / label cascade)
- 2026-06-26 承认翻不完, 加 `libAxHelper.dylib` (~230 行 Swift wrapper 调 OCCU Swift Package), 一天 20+ commit 集成
- `refactor(mac): retire C# AX automation path; route 9 tools through OCCU` — 完全放弃 C# 手写

**重叠**: openclicky `native_swift` 路径大约相当于 Everywhere 试图手翻 OCCU 的成果 (但基于 trycua/cua-driver, 非 iFurySt/OCCU). 两个 Swift 实现互相独立, 但覆盖能力域重合 ~70%.

**决策**: openclicky 现有 native_swift + cua-driver 二进制 **不动**. 但 sensor 层 (`get_focused_context` / `get_app_state` / `expand_element` / `pick_element` / `screenshot` 等 Everywhere-parity MCP tool) 用什么后端要选:

**选项 A**: 走现有 `OpenClickyNativeComputerUseController` + `cua-driver` 二进制
- 优点: 无新依赖, 已通过 QA
- 缺点: 缺 OCCU 的 snapshot 渲染 (formattedLabelSegment / displayRoleText / AXLink markdown / SwiftUI auto-detect / grapheme typeText 等 wowdd1 一个月内填的坑)

**选项 B**: 加 OCCU SPM 依赖, sensor tool 走 OCCU
- 优点: 直接得到 Everywhere 一个月填坑的成果
- 缺点: 与现有 native_swift 重叠, 两套 API 并存

**选项 C (推荐)**: sensor tool 走 OCCU, `native_swift` / `cua-driver` runtime 保留服务已有 UI 场景 (visual guidance overlay / captureFrontmostWindow), 不撤. 面向 codex agent 的 MCP endpoint 全走 OCCU (确保 snapshot 与 Everywhere 一致).

### 2.2 Connector (**中重叠 — openclicky 已有类似能力**, 更正)

openclicky **实际有一个 Connections 标签页** (`OpenClickySettingsWindowManager.swift:2042 connectionsPanel`). 内容:

1. **Google Workspace** — 通过 `gogcli` (Homebrew CLI 工具) 做本地 OAuth. 有 credentials / account / storage 状态显示
2. **Composio connected apps MCP** — toggle 开启, syncCodexMCPSettings 后 codex 里挂上 `mcp_servers.composio` (GitHub 等)
3. **OpenAI developer docs MCP** — toggle 加官方 OpenAI docs 到新 agent
4. **OpenClicky computer-use MCP** — toggle 加 cuaDriver bridge
5. **Codex config sync** — 状态显示

以及 `HeyClickyAgentIntegrationsClient` 作为 **runtime 侧的 HTTP 层**, 走 proxy 的 5-6 endpoint (Composio session / Calendar / Spotify).

**这与 Everywhere connector 重叠什么**:

Everywhere 的 connector 是移植的 [`oomol-lab/open-connector`](https://github.com/oomol-lab/open-connector) — Apache-2.0, "Open-source auth gateway connecting 1000+ SaaS providers", 3k+ star. 实测 `Everywhere/3rd/open-connector/src/providers/` 有 **831 个 provider 目录**.

| 维度 | openclicky | Everywhere (open-connector) |
|---|---|---|
| 第三方 SaaS 连接入口 | Settings → Connections tab | Settings + Web Console UI |
| 认证方式 | 本地 gogcli (Google) + Composio hosted MCP (其他) | 本地 V8 跑 open-connector, 本地 OAuth + AES 加密 credential store |
| **Provider 数** | Composio ~250 apps (hosted, 2025 数据) + Google via gogcli | **831 provider / 8300 action** (upstream 实测) |
| Runtime | Composio hosted (远程) + gogcli 本地二进制 | V8 isolate in-process |
| 数据流 | openclicky → codex → Composio MCP → Composio cloud → SaaS | Everywhere → V8 → 本地 HTTP → SaaS |
| 隐私 | credential 在 Composio cloud 上 (需信任 Composio) | 全本地 (credential 加密存 disk) |
| License 差异 | Composio 商业服务 (Composio 公司维护 provider 定义) | Apache-2.0, provider 定义 in-repo, 完全 self-hosted |

**Provider 数差距是实际存在的**: 831 vs ~250, **openclicky 覆盖大约是 Everywhere 的 1/3**. 长尾 SaaS (小众 CRM / 特定领域 API / 区域性服务) Composio 未必覆盖.

**结论**: 定位相似, 实现路径不同. openclicky 走 **hosted MCP proxy** (Composio 生态), Everywhere 走 **本地 V8 gateway**. 各有权衡:
- openclicky: 零维护, 但依赖 Composio 生态
- Everywhere: 全本地隐私, 但需要嵌 V8 isolate (成本高) + 维护 provider manifest

**重叠治理决策 (重新评估)**:

Provider 数量差距是真实的. 移植 open-connector 有两个选项:

**选项 X**: 保持现状 (Composio 主), 不移植 open-connector
- 好处: 零维护成本, Composio 生态持续扩展
- 坏处: 长尾 provider 覆盖不足 (~1/3 of open-connector). 用户若问"能不能连 XYZ" 而 XYZ 是小众 SaaS, 可能答不上

**选项 Y (推荐)**: **混合方案** — 保留 Composio 作主入口, 另加 open-connector 作后备
- Settings Connections tab 分两栏:
  - "Managed (Composio)" — 现有 hosted, ~250 apps, 一键 OAuth
  - "Self-hosted (open-connector)" — 新增, 831 provider, 需要用户自 auth
- 后端 open-connector 有两个部署方式:
  - **Y-a (低成本)**: spawn Node.js subprocess 跑 open-connector CLI, 走 HTTP loopback (类似 openclicky 现有 chrome-ext 模式)
  - **Y-b (Everywhere-parity, 高成本)**: 嵌 ClearScript V8 isolate 到 App (但 macOS 上 V8 集成复杂, 且 .NET-only, Swift 无成熟方案)
- **Y-a 更适合 Swift-only 的 openclicky**: bundle Node runtime + open-connector, 首启用户装 (`npm install`) 或 bundled node_modules

**选项 Z**: 完全移植 Everywhere 方式 (V8 in-process) — Swift 侧无成熟 V8 集成, 排除

**决策: Y-a 必做**, P2 阶段立项 (紧随 Layer 3 stash + hook 之后). 关键难点:
- Node.js runtime 打包 (~50MB) 增加 App size
- provider manifest 更新策略 (git submodule vs 首启下载 vs 打包内置)
- OAuth 回调需要本地 HTTP server 接 (openclicky 现有 chrome-bridge :3011 可复用模式)
- 权限模型: Composio 是 hosted 授权, self-hosted 需用户自己搞 client_id / client_secret

**中间态 (先行动作)**:
- Settings Connections tab 里加 "Self-hosted providers" section (灰态 / Coming soon)
- 记录用户需要但 Composio 不覆盖的 provider 请求
- Roadmap 明确 P2 交付 open-connector 集成

**核心定调**: open-connector 831 provider 属于 "Everywhere 的东西", 是 Everywhere 完整能力的核心组成. openclicky "完整替代 Everywhere" 就必须**保留这项能力**. Composio ~250 只是补充, 不是替代. 3x provider 覆盖差距是**必须闭合**的 gap, 不接受"隐私差异是选择题"这种说法作为不做的理由.

### 2.3 Chrome extension (小重叠, 用途不同)

openclicky `chrome-ext/` + `HeyClickyChromeBridgeServer` (:3011):
- 唯一用途: 自动点 Google account chooser 做 quota reset
- 10KB background.js, 单 tab, 一个 selector click
- Ported from `clicky-mac ChromeBridgeServer` (port 3001 → 3011)

Everywhere OpenDia:
- 通用浏览器自动化 (~85 WS ops: click / fill / snapshot / diff_snapshot / network_har / cookies / auth_vault / react_tree / CDP overrides)
- 全 site 通用

**重叠度**: 只是"App 有 Chrome extension"这个形式, 内容完全不同. openclicky 是 quota-reset 单点自动化.

**决策**: 不重叠, 各自保留.

### 2.4 MCP endpoint (中重叠)

openclicky 现有 11+ tool: `advisor_*` (8) + `orchestrate_*` (3+) + click / screenshot / memory_save.
Everywhere 96 unique MCP tool (实测 `grep -rh 'Name = "'` 于 `Everywhere.Mcp/Tools/`). PARITY_MATRIX.md 里 151 是含 `browser_*` 走 OpenDia 转发的总量.

**重叠**: `click`, `screenshot`, `memory_save` — 名字相同.
- openclicky `click`: 参数 `(x, y)`, 走 native computer use
- Everywhere `click`: 参数 `(app, element_index? | (x,y), click_count?, mouse_button?)`, 走 OCCU
- 参数不兼容, tool 契约不同

**决策**: 移植 Everywhere 感知 tool 时**用 openclicky namespace**. `/mcp/sensor` 新 endpoint 里 tool 名照 Everywhere (`get_focused_context` 等), 参数照 Everywhere (与 OCCU 参数契约一致). 老的 `/mcp` / `/mcp/orchestrate` 里的 `click` **不动** (向后兼容). Sensor endpoint 里的 `click` 是 Everywhere-parity.

---

## 三. Everywhere 为什么当初不直接用 OCCU

时间线:

| 日期 | commit | 说明 |
|---|---|---|
| 2026-06-24 前 | — | Everywhere 用 C# 手写 AX (63KB `AXUIElement.cs`) — .NET 10 + Avalonia, 跨平台需求 |
| 2026-06-24 | `feat(mcp): port OCCU click action chain` / `feat(mac/mcp): port remaining OCCU robustness` | 意识到 OCCU 有很多 edge case, **手工翻译** Swift → C#, 一个 commit 一个 feature |
| 2026-06-24 → 2026-06-25 | 15+ commit 抄 OCCU click / snapshot / cursor / label / trait / scroll / SwiftUI-detect | 越抄越多, C# 侧 diverge 严重 |
| 2026-06-26 | `chore(3rd): vendor open-codex-computer-use as submodule (preparation for OCCU-helper bridge)` | 承认翻不完, 决定 bridge |
| 2026-06-26 | `feat(ax): add Swift dylib bridge over OpenComputerUseKit` | 加 `libAxHelper.dylib` (Swift wrapper) |
| 2026-06-26 | `feat(ax): wire OCCU helper as optional MCP backend (env-gated)` | 默认关, 环境变量开 |
| 2026-06-26 | `refactor(mac): retire C# AX automation path; route 9 tools through OCCU` | 全撤 C# 手写路径, 完全走 OCCU |
| 2026-06-26 | 20+ 修 dylib 集成的 bug: `bundle libAxHelper.dylib into MonoBundle`, `resolve IAxBridgeBackend via IServiceProvider`, `drop IsAvailable probe at startup — main-thread deadlock`, `apply RegisterMacServices to GUI ServiceLocator too` | dylib 边界成本 |

**核心原因**:

1. **语言鸿沟**: Everywhere 是 **C# / .NET 10**, OCCU 是 **纯 Swift Package**. C# 无法直接 SPM 依赖. 唯一路径是 `libAxHelper.dylib` (Swift shim exposing C ABI), 再从 C# 通过 P/Invoke 调.
2. **跨平台限制**: Everywhere 目标是 macOS + Windows + Linux (Avalonia). OCCU 只做 macOS. Everywhere 若一开始就用 OCCU, 只 macOS 有 AX, 其他平台空白. C# 手写至少给了跨平台抽象空间.
3. **发现成本**: 早期 (~ 2026-06-24 之前) 可能 wowdd1 还没深入研究 OCCU 的实现质量. 后来 side-by-side 翻译时发现 OCCU 里已经填了 SwiftUI / WebView / SoftwareCursorOverlay / grapheme-aware type / hit-test retry 一大堆坑, 才决定 bridge.
4. **Dylib bridge 成本**: 从 20+ 个 `fix(occu):` commit 看出, 桥接不是 free lunch. `main-thread deadlock`, `IServiceProvider 解析`, `MonoBundle 位置`, `RegisterMacServices` 服务定位, `cursor overlay isFlipped 上下颠倒`, `IsAvailable probe 死锁` — 每个都是 .NET ↔ Swift 边界坑.

**openclicky 的处境根本不同**:

| 维度 | Everywhere | openclicky |
|---|---|---|
| 主语言 | C# / .NET 10 | Swift |
| 目标平台 | macOS + Windows + Linux | macOS-only |
| 依赖 OCCU 方式 | libAxHelper.dylib (P/Invoke) | SPM package |
| 边界成本 | 20+ fix commit | 零 |

**结论**: Everywhere 不用 OCCU 是**跨语言 + 跨平台**的架构性约束, 不是 OCCU 有问题. openclicky 是 macOS Swift, 直接 SPM 依赖 OCCU 是最短路径.

**风险 (openclicky 需注意)**:
1. **OCCU 上游变更** — 依赖第三方 Swift Package, 版本 pin 死 (SPM `.exact("0.9.128")` 或 `.upToNextMinor`), 别 auto-update
2. **License** — OCCU MIT (兼容 openclicky 商业闭源, OK)
3. **Snapshot / AX 语义漂移** — OCCU 若改 snapshot 输出格式, openclicky 感知层要跟着更新
4. **macOS 版本敏感** — OCCU 用 ScreenCaptureKit / AXManualAccessibility, 要求 macOS 14+. openclicky 目标 macOS 版本要对齐
5. **main-thread deadlock** — Everywhere 在 `IsAvailable probe at startup` 撞过. openclicky 调 OCCU 时**必须**用 async 或 background thread, 别在 App startup 同步调
6. **CoreServices / TCC bundling** — Everywhere 花时间搞 `libAxHelper.dylib into MonoBundle`. openclicky SPM 依赖不需要 dylib bundle 但要确认 SPM build 产物在 signed .app 里正确签名

---

## 三.5 Everywhere 混合架构: 走 OCCU vs 自实现 (**关键**)

Everywhere 不是全走 OCCU. **OCCU 只覆盖 9 个 action tool**, 大量能力仍在 C# 侧手写. openclicky 移植时**必须**弄清楚哪些走 OCCU / 哪些从 Everywhere C# port.

### A. 走 OCCU 的 (仅 9 个函数)

来自 `Everywhere/src/Everywhere.Mac/AxBridge/LibAxHelper.cs` C ABI 声明:

```
ax_list_apps
ax_get_app_state(app, showFullText)
ax_click(app, elementIndex?, x, y, useXY, clickCount, mouseButton)
ax_scroll(app, direction, elementIndex, pages)
ax_drag(app, fromX, fromY, toX, toY)
ax_type_text(app, text)
ax_press_key(app, key)
ax_set_value(app, elementIndex, value)
ax_perform_secondary_action(app, elementIndex, action)
```

对应 MCP tool: `list_apps`, `get_app_state`, `click`, `scroll`, `drag`, `type_text`, `press_key`, `set_value`, `perform_secondary_action`.

**结果**: OCCU 返回 `{content:[{type:"text",text:"..."}], isError:bool}` 结构 JSON, Everywhere **verbatim 直发** 给 MCP client, 不 unmarshal. `element_index` 是 OCCU snapshot 内部句柄, 只在 OCCU cache 里活着, `click(elementIndex=N)` 直接查 OCCU 的 `snapshotsByApp`. Everywhere 不把 element 抽象成 `IVisualElement` — 避免二次遍历.

### B. Everywhere 自实现 (不走 OCCU) 的能力

以下 全在 `src/Everywhere.Mac/Interop/` 和 `src/Everywhere.Mac/Mcp/` 手写 C#:

| 能力 | file | 行数 | 为什么不走 OCCU |
|---|---|---|---|
| `get_focused_context` | `VisualElementContext.cs` | 145 | OCCU 只到 `get_app_state`, focused-context 是 Everywhere 概念 (含 pin_pending / whiteboard_pending / picked_links / annotations 组装) |
| `get_selected_text` (3-strat fallback) | `VisualElementContext.TextSelection.cs` | 416 | OCCU 只到 AX selection 一层, Everywhere 加 SelectionCache + child selection + Cmd-C fallback + clipboard 恢复 |
| `LinkRect harvest` | `VisualElementContext.LinkRect.cs` | 608 | 需要跨 pid AX walk + Uri parse + redact + dedup + XlbMultiPick sentinel, 全是 Everywhere 特有 |
| `screenshot` (element/window/region) | `VisualElementContext.Screenshot.cs` | 213 | ScreenCaptureKit + NSScreenVisualElement 集成, 与 Everywhere 权限流有耦合 |
| `pick_element` | `VisualElementContext.Picker.cs` | 38 | UI 交互 (用户点击选中元素), 走 Everywhere Overlay |
| `expand_element` | Everywhere.Mcp/Tools/ExpandElementTool.cs | — | 是 OCCU `get_app_state` 之上做的 subtree budget 压缩 |
| `get_browser_url` | `Mcp/MacBrowserUrlReader.cs` | 135 | AppleScript + per-pid AXURL walk, OCCU 无此逻辑 |
| `get_browser_tabs` | `Mcp/MacBrowserTabsReader.cs` | 147 | AppleScript, OCCU 无此逻辑 |
| `get_finder_selection` | `Mcp/MacFinderReader.cs` | 71 | AppleScript, OCCU 无 |
| `get_terminal_output` | `Everywhere.Mcp/Tools/GetTerminalOutputTool.cs` | — | AppleScript + AX 混合读 iTerm2/Terminal, OCCU 无 |
| `get_clipboard` | `Mcp/MacClipboardReader.cs` | 59 | NSPasteboard 直读 |
| `clipboard_write` | `Mcp/MacClipboardWriter.cs` | 77 | 写 + restore original |
| `get_idle_time` | `Mcp/MacIdleTimeReader.cs` | 29 | IOKit HID idle |
| **Global hotkey** | `Interop/CGEventShortcutListener.cs` | 277 | 全 Everywhere 自写 CGEventTap, OCCU 无 |
| **CGEventListener 通用** | `Interop/CGEventListener.cs` | 94 | 事件监听, OCCU 无 |
| **AppleScript runner** | `Mcp/MacAppleScriptRunner.cs` | 72 | NSAppleScript wrap, OCCU 无 |
| **AppActivator** (fire launch phrase) | `Mcp/MacAppActivator.cs` | 297 | NSWorkspace + FrontmostApp settle loop + TypeText, OCCU 无 |
| **PermissionHelper** (TCC) | `Interop/PermissionHelper.cs` | 51 | OCCU 有 AX permission check 但 Everywhere 自己再包一层 |
| **VisionOCR** | `Interop/MacVisionOcrEngine.cs` | 120 | Vision framework wrap, OCCU 无 |
| **NSScreenVisualElement** (多屏) | `Interop/NSScreenVisualElement.cs` | 206 | 多显示器几何 + Screenshot 目标 |
| **WindowHelper** (CGWindowList) | `Interop/WindowHelper.cs` | 384 | on-screen window 枚举, OCCU `list_apps` 只到 app level |
| **SkyLightInterop** (private API) | `Interop/SkyLightInterop.cs` | 106 | N/A — Everywhere has no `SLSGetActiveSpace` / `SLSCopyWindowsWithOptions` binding (only private capture APIs). openclicky uses `CGWindowList` directly in `WindowEnumerationCapture.swift`; the file explicitly disclaims the non-existent SkyLight port (see `docs/ROADMAP/.review-notes/F01-app-window-enumeration-2026-07-23.md` §"Intentional Divergences" #10). |
| **ScreenSelectionSession** (drag rect UI) | `Interop/ScreenSelectionSession.cs` | 446 | 用户拖矩形选屏 UI, LinkRect harvest 的前端 |
| **Input simulator** (per-key CGEvent) | `Mcp/MacInputSimulator.cs` | 389 | Launch phrase 触发时的 TypeText/Return, **与 OCCU `ax_type_text` 并行**. Everywhere 保留自己的原因: OCCU 需要 target app 参数, 而 launch phrase 是"注入到当前 frontmost"场景 |

**关键**: `AXUIElement.cs` (63KB) 虽然还在 repo 里, 但 `refactor(mac): retire C# AX automation path; route 9 tools through OCCU` 之后**已经不被 MCP tool 调**. 保留是给 non-MCP 场景 (chat plugin 里的 focused element 读取) 用. Everywhere 是**"tool 走 OCCU, App 内 UI 走自己"**.

### C. 混合 (依赖 OCCU 输出但加处理) 的能力

| 能力 | 处理 |
|---|---|
| `expand_element(index)` | Everywhere 拿 OCCU `get_app_state` 全树, budget-based 挑 subtree 返 |
| `get_focused_context` | 组装 = OCCU `get_app_state` (焦点 app) + Everywhere selected_text + pin_pending + picked_links + annotations |
| Snapshot 里 `[Selected]` marker | Everywhere 后处理: OCCU 输出 tree_text 后, Everywhere 从 `focused_items/selected_items` semantic field 再标一次 (SPEC.md 提到) |

### D. openclicky 移植策略 (精准区分)

**走 OCCU (SPM 直连, 免翻译)**: `list_apps`, `get_app_state`, `click`, `scroll`, `drag`, `type_text`, `press_key`, `set_value`, `perform_secondary_action`.

**从 Everywhere C# port (逐 file 翻译)**:
- Layer 0 感知层: `VisualElementContext.*.cs` (Screenshot/TextSelection/LinkRect/Picker), `MacBrowserUrlReader/TabsReader/FinderReader/ClipboardReader/Writer/IdleTimeReader`, `MacAppleScriptRunner`, `MacVisionOcrEngine`
- Layer 2 MCP tool: `Everywhere.Mcp/Tools/*.cs` (`GetFocusedContextTool`, `GetSelectedTextTool`, `GetBrowserUrl/Tabs/FinderSelection/TerminalOutput`, `ScreenshotTool`, `ExpandElementTool`, `PickElementTool`, `ReadPickTool`, `ReadWhiteboardTool` 等)
- Layer 3 Stash: `Everywhere.Mcp/Snapshot/ContextStashWriter.cs`, `StashPaths.cs`, `Everywhere.Mcp/Input/*` (annotation / pick / whiteboard stash)
- Layer 4 UX: hotkey 部分 (`CGEventShortcutListener.cs`), overlay 部分 (`ScreenSelectionSession.cs`)
- Settings: `ShortcutSettings.cs`

**openclicky 已有, 保留不动**:
- `OpenClickyNativeComputerUseController` / `OpenClickyComputerUseRuntime` — App 内 visual guidance overlay 场景, 不给 sensor MCP 用
- `cua-driver` bundled binary — 同上
- `BackgroundComputerUse.app` — 同上

**决策原则**:
> Sensor endpoint (/mcp/sensor) 里凡是能对应到 OCCU 那 9 个函数的, **必走 OCCU**. Sensor endpoint 里 OCCU 未覆盖的能力, **必从 Everywhere C# port**. openclicky 自己的 CUA 实现不再扩展新 MCP tool.

这样避免:
- 三套实现 (openclicky native + OCCU + Everywhere port) 语义漂移
- 未来跟 OCCU 上游 sync 时不用管 openclicky native
- Everywhere 已经填的坑 (SwiftUI detect / hit-test retry / snapshot label cascade) 直接享用

## 三.6 openclicky 现有 CUA vs OCCU 逐项对比

**openclicky 现有两条 CUA 路径** (Settings → "Computer Use" tab 里让用户选):

### 路径 A: Native CUA Swift (`OpenClickyNativeComputerUseController`)

来源: `/Users/jkneen/Documents/GitHub/cua/libs/cua-driver` (trycua/cua, MIT). 是 **trycua/cua-driver 的一个 Swift port** — **不是** iFurySt/OCCU.

API (从 `OpenClickyComputerUseRuntime.swift`):
```swift
setEnabled(_ enabled: Bool)
refreshFocusedTarget() -> OpenClickyComputerUseWindowInfo?
runningApps() -> [OpenClickyComputerUseAppInfo]
visibleWindows() -> [OpenClickyComputerUseWindowInfo]
allWindows() -> [OpenClickyComputerUseWindowInfo]
captureFocusedWindowAsJPEG() async throws -> OpenClickyComputerUseWindowCapture
pressKey(_ key: String, modifiers: [String] = [], toPid pid: pid_t? = nil)
typeText(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil)
click(at point: CGPoint)
```

覆盖: 应用/窗口枚举 + 目标窗口 JPEG 截图 + pid-directed 键盘输入 + click. **不含**: AX 树 walk, snapshot 渲染, element-index 系统, scroll, drag, set_value, secondary action, SwiftUI auto-detect, hit-test retry.

### 路径 B: Background Computer Use (`cua-driver` binary 22MB, `BackgroundComputerUse.app`)

来源: 同 trycua/cua-driver, 但作为**独立进程**运行. 通过 stateToken + 状态机 API 与主 App 通信.

API:
```swift
startRuntime() / stopRuntime() / ensureRuntimeReady(timeoutSeconds:)
captureFrontmostWindowAsJPEG() async throws
pressKey(key, modifiers, targetAppName, stateToken)
typeText(text, targetAppName, stateToken)
click(at point, window, targetAppName, stateToken)
resolveTargetWindow(appName) async
```

覆盖: 类似 Native 但走独立 runtime, 有状态跟踪 (`stateToken`). 好处是崩溃/权限问题隔离在子进程.

### 路径 C (推荐新增): iFurySt/OCCU (`OpenComputerUseKit`)

来源: `iFurySt/open-codex-computer-use`, MIT. Everywhere 用的就是这个.

API (通过 MCP tool 层暴露):
```
list_apps → app 列表 + bundle id + pid
get_app_state(app, showFullText) → **完整 AX 树 markdown 渲染** with element-index
click(app, elementIndex? | (x, y), useXY, clickCount, mouseButton)
scroll(app, direction, elementIndex, pages)
drag(app, fromX, fromY, toX, toY)
type_text(app, text) — grapheme-aware
press_key(app, key) — xdotool syntax
set_value(app, elementIndex, value)
perform_secondary_action(app, elementIndex, action)
```

覆盖: **AX 树 walk + snapshot 渲染 + element-index 系统** (关键差异) + 全套 action + SwiftUI/WebView 特殊处理 + SoftwareCursorOverlay + hit-test retry.

---

### 逐能力对比矩阵

| 能力 | Native CUA Swift (A) | Background CUA (B) | OCCU (C) |
|---|---|---|---|
| App / 窗口枚举 | ✅ | ✅ | ✅ `list_apps` |
| 窗口 JPEG 截图 | ✅ focused | ✅ frontmost | ✅ `get_app_state` 内嵌 (可关) |
| **AX 树完整 walk** | ❌ | ❌ | ✅ `get_app_state` |
| **Element index 系统** (element_index=N 引用) | ❌ | ❌ | ✅ 核心 |
| **Snapshot markdown 渲染** (label cascade / role display / AXLink → markdown) | ❌ | ❌ | ✅ |
| SwiftUI auto-detect + 特殊 click | ❌ | ❌ | ✅ |
| WebView / web-area 特殊处理 | ❌ | ❌ | ✅ |
| Hit-test retry (点击失败后 nearby 元素重试) | ❌ | ❌ | ✅ |
| Grapheme-aware type_text | 部分 (delay 参数) | 部分 | ✅ |
| Scroll / drag / set_value | ❌ | ❌ | ✅ |
| Perform secondary action | ❌ | ❌ | ✅ |
| SoftwareCursorOverlay 动画 | 走 `OverlayWindow.swift` (openclicky 自绘) | 同 | ✅ 内建 (Everywhere 2026-06-25 集成后关闭其内嵌 overlay 用自己的) |
| Pid-directed 键盘输入 (不激活窗口) | ✅ | ✅ | ❌ (需目标 app 参数, focus 目标) |
| 独立进程隔离 | ❌ | ✅ | ❌ (SPM 依赖, in-process) |
| MCP tool 直接暴露 | 需自己包装 | 需自己包装 | ✅ (`OpenComputerUseKit` 自身即 MCP server) |

### 关键差异 (核心 gap)

Native CUA Swift + Background CUA 都基于 **trycua/cua-driver**, 是**低层 CGEvent + AXUIElement 简单 wrapper**. 提供的是"能截图 + 能按键 + 能点坐标"这种底层能力.

OCCU 提供的是**"完整 AX 语义"** — element-index 系统让 agent 可以用 `click(element_index="42")` 精确点击"第 42 个可交互元素", 不用管坐标. Snapshot markdown 让 LLM 直接读结构化 UI 而不是像素. Everywhere 花了 20+ commit 集成的坑 (SwiftUI / hit-test / label cascade) 都在 OCCU 里.

### 三条路径的定位

| 路径 | 适合什么场景 |
|---|---|
| **Native CUA Swift (A)** — openclicky 现有 | App 内视觉引导 overlay (给用户提示 "点这里"), UI/UX 层的按键注入 (不需要 AX 树), 已有代码不动 |
| **Background CUA (B)** — openclicky 现有 | 用户显式开的 "隔离 runtime" 模式, 崩溃隔离在子进程, 高风险自动化场景 |
| **OCCU (C)** — 建议新增 | 面向 codex/Claude Code agent 的 MCP sensor endpoint (`get_app_state` / `click(element_index)` / snapshot 语义), Everywhere-parity 感知层 |

### 建议 (不冲突, 各司其职)

**保留 A 和 B**: openclicky 内部 UI 场景用 (visual guidance overlay / captureFrontmostWindow / pid keyboard 注入). Settings 里 "Computer Use" tab 现有选项不变.

**新增 C (OCCU)**: 只服务 MCP sensor endpoint. 不给 openclicky 内部 UI 用. 用户不感知. Settings 不加 OCCU 选项.

这样避免用户在 Settings 里看到三个 CUA backend 选项造成困惑. OCCU 在幕后为外部 agent 服务, 与 App 内 UI 路径互不干扰.

**若未来 OCCU 明显优于 Native/Background**: 可考虑把 Settings 里 backend 选项从 (A, B) 扩到 (A, B, C), 让用户选. 但**不在** P0 / P1 做, 避免 scope creep.

## 四. 最终建议

### 保留 (不动)

- openclicky `OpenClickyNativeComputerUseController` + `cua-driver` bundled binary — 给 App 内 UI 场景 (visual guidance overlay / captureFrontmostWindow) 用
- HeyClicky proxy integrations (`HeyClickyAgentIntegrationsClient`) — 商业逻辑核心
- 现有 Chrome extension (:3011) — quota reset 单一用途
- 现有 `/mcp/advisor` / `/mcp/orchestrate` — 已发布 API 契约

### 新加 (Everywhere-parity)

- SPM 依赖 `iFurySt/open-codex-computer-use`, pin exact version
- 新 `/mcp/sensor` endpoint, tool 契约照 Everywhere (参数与 OCCU 参数对齐)
- Sensor tool 后端全走 OCCU (`get_focused_context` / `get_app_state` / `expand_element` / `pick_element` / `screenshot` / `click` / `type_text` / `press_key` / `scroll` / `drag` / `set_value`)
- Layer 0 里 port Everywhere 的 **OCCU 未覆盖项**: FinderSelection / BrowserURL / BrowserTabs / TerminalScrollback / Clipboard 多类型 / IdleTime / OCR / URL redaction / Stash 数据模型 / Hotkey settings / UX (Whiteboard / LinkRect / PickStash / AnnotationStash)
- Layer 3 stash + `openclicky-context-hook`

### 移植范围界定

**边界**: openclicky 需要的是 Everywhere 的**感知能力** + **MCP 获取上下文的能力**. Everywhere MCP 生态的所有组件都在移植范围内, 属于"上下文获取"的必要基础设施.

### 必移植 (Everywhere MCP 生态, 全部)

- **open-connector** (831 provider, Everywhere P2-P12 主投入) — SaaS 层上下文来源
- **OpenCLI** (173 站点适配器) — 站点内部上下文来源 (12306 / bilibili / 中国区 + 无 API 站点)
- **OpenDia** (Everywhere fork `hhsw2015/opendia experiment/replace-ab` 有 85 WS ops; 上游 `aaronjmars/opendia` MIT 只 ~24) — OpenCLI + 通用浏览器自动化的执行层
- **xlb / KnownApps hint 协议** — 本地自描述 App 的 fast-path (xlinkBook 靠这个)
- **Doc readers** (pdf/docx/xlsx/pptx/epub/html/txt) — 文档内部上下文
- **Annotation / Whiteboard / LinkRect / PickStash** — 用户交互式上下文采集
- **Memory tools / batch / self-expanding tools / core-tool gate** — MCP meta 基础设施
- **所有 `Everywhere.Mcp/Tools/` 下的 tool** — 完整 sensor tool 集

**理由**: 这些都是 Everywhere MCP 生态的一部分, 都服务于"agent 获取上下文". 属于 Everywhere 的东西, openclicky 都要有.

### 不移植 (超出 MCP / 上下文获取范围)

- **Chat bus** (`chat_create/delete/list/read/send/subscribe`) — Everywhere 内部 chat 生态, 与上下文获取无关. openclicky 有自己的 chat/agent orchestration
- **Adapter authoring / self-expanding UX** (`adapter_*` scaffold/lint/regenerate) — 开发者 authoring 工具, 用户不用. 若未来 openclicky 想让用户扩 provider 再评估
- **Capture recording** (`capture_start/stop/current/export`) — 会话录制, openclicky 有 codex session persistence 覆盖

**理由**: 这些不属于"感知 + MCP 获取上下文"范畴, 是 Everywhere 生态的其他分支.

---

## 3.65 xlinkBook — Everywhere agent-skills / agent-state 协议参考实现

**位置**: `/Users/wowdd1/.xlb-env/xlinkBook` (Flask app) + `/Users/wowdd1/.xlb-env/xlinkBook-skill` (skills)

**关系**: xlinkBook 是 wowdd1 的**知识图谱本地 App**, 也是 Everywhere `agent-skills` / `agent-state` 协议的**第一 reference implementation**. Everywhere 在 `ContextStashWriter.cs:750` 硬编码了对 `xlb-perception` endpoint 的 fast-path 逻辑:

```csharp
if (discoveryUrl.EndsWith("/xlb-perception", ...))
    return discoveryUrl[..^"/xlb-perception".Length] + "/agent-state";
```

### xlinkBook 提供什么

- Flask web app at `http://localhost:5000`, 用户可 browse
- 服务端知识图谱: file → record → topic → tag → group → url 血缘链
- **事件流**: 用户浏览时 xlb 追加结构化 event 到 `~/.xlb-env/logs/events.jsonl`, 每条 event 带**完整 server-known ancestor lineage**
- **api endpoints**:
  - `/agent-skills` — discovery URL, 声明支持的 skill / 命令
  - `/agent-state?consume=1` — fast-path, 返回近期 view + interaction markdown
  - `/xlb-perception` — 感知 endpoint (Everywhere 里也有 fallback)
  - `title=?` API 走 topic index 查询

### 协议 (Everywhere ↔ xlinkBook 之间)

用户 hotkey 触发 Everywhere `SnapshotContext`:
1. Everywhere 捕获 focused window title (e.g. "xlinkBook - Vibe Coding")
2. Everywhere 在 `Settings.McpServer.KnownApps` 里查 `TitlePattern`, 命中 xlb
3. Everywhere 写 stash 时加 `[everywhere-discover] xlb-style local app self-describes at http://localhost:5000/agent-skills` + `Fast path: GET http://localhost:5000/agent-state?consume=1`
4. 下游 agent (Claude Code) 从 stash 读 hint, 一次 GET 拿到用户当前 view + 最近点击的 URL/topic/group markdown
5. 免去 Agent 猜"用户在看什么"

### skills 组件

`xlinkBook-skill/skills/`:
- `xlb-web-perception/SKILL.md` — 当 Everywhere stash hint 提到 xlb / localhost:5000 时, 走这个 skill 读 `events.jsonl` 精确定位用户操作 (省 token vs scrape HTML)
- `xlb-topic-index/SKILL.md` — 处理 `xlb >topic/` `xlb ??topic` 之类命令, 转 title= 参数 call API

### 与 openclicky 的关系

**xlinkBook 是 openclicky 的潜在客户**: 用户在 xlb 里浏览时按 openclicky hotkey → openclicky stash 应该也 emit `[openclicky-discover]` hint 指向 xlb `agent-state`.

**移植方向**:
- openclicky `context-stash.json` writer 里加 `KnownApps` 配置项 (TitlePattern → DiscoverUrl 映射), 完全照 Everywhere `Settings.McpServer.KnownApps`
- `ToStatePath` 函数照抄 (agent-skills/xlb-perception → agent-state)
- envelope 前缀改 `[openclicky-discover]`, URL 契约不变
- xlinkBook 服务端不用改 — 它期待的 fast-path 协议是通用的

**关键**: 这不是"移植 xlinkBook", 而是**保留 openclicky 对 xlinkBook (以及任何 xlb-style app) 的对接协议**. wowdd1 自用 xlinkBook, 若 openclicky 想替代 Everywhere, 必须支持这个 hint 协议.

**新增到 Layer 3 checklist**:
- [ ] `KnownApp` 数据模型 + Settings 存储 (`TitlePattern`, `DiscoverUrl`)
- [ ] `ResolveDiscoveryUrl(windowTitle)` — Regex.IsMatch 100ms timeout
- [ ] `ToStatePath(discoveryUrl)` — `/agent-skills` → `/agent-state`, `/xlb-perception` → `/agent-state`
- [ ] Stash 里加 `[openclicky-discover]` 行 (若匹配 KnownApp)
- [ ] Fallback: 无匹配则 emit 通用 `[openclicky-hint]`

## 3.7 更完整的第三方连接生态 (openclicky 覆盖 gap)

Everywhere 集成了**三套**独立的第三方连接系统, openclicky 现只覆盖其中一部分:

### 系统 A: open-connector — **SaaS API gateway** (831 provider)

- Repo: [`oomol-lab/open-connector`](https://github.com/oomol-lab/open-connector), Apache-2.0, 3k+ star
- 覆盖: 831 provider / ~8300 action, "1000+ SaaS providers" (README)
- 类型: **HTTP API 层** — provider 定义 API endpoint + auth 方式, Everywhere 本地 V8 跑
- 例子: GitHub / Notion / Slack / Airtable / Stripe / Salesforce / Shopify / Zoom / Discord / ...
- Vendor 路径: `Everywhere/3rd/open-connector/src/providers/*/` (831 目录)
- Everywhere 集成方式: ClearScript V8 isolate + HostShim bridge + `Runtime` + `Tools` pair
- MCP tool: `connector_connect`, `connector_describe`, `connector_disconnect`, `connector_list`, `connector_list_connections`, `connector_run`

### 系统 B: OpenCLI — **浏览器操纵任意网站** (173 站点适配器)

- Repo: [`jackwener/opencli`](https://github.com/jackwener/opencli), 27k star!
- Homepage: https://opencli.info/
- 覆盖: 173 站点, 中英文站都有 (12306 / bilibili / 淘宝 / 1688 / 51job / arxiv / apple-podcasts / bbc / amazon / autohome / ...)
- 类型: **浏览器 CDP 自动化** — 用**用户已登录的浏览器** driven-by-AI 操作站点. 不用 SaaS API, 直接模拟点击/表单填写
- 与 open-connector 差异: open-connector 需要 provider 提供 API (公开 REST/GraphQL), OpenCLI 只需要站点有浏览器界面. **覆盖 open-connector 覆盖不了的所有网页应用** (含无公开 API 的、需登录才可访问的、中国区特有的)
- Vendor 路径: `Everywhere/3rd/opencli/clis/*/` (173 目录) + `runtime/` + `cli-manifest.json` (1MB)
- Everywhere 集成方式 (2026-06-30 起 8 个 `feat(opencli):` commit):
  - vendor 上游 pipeline runner
  - Node builtin polyfills (fs / child_process 解锁)
  - lazy load + fuzzy list (`opencli_list`)
  - background-tab mode (cookie / intercept)
  - manifest `navigateBefore` 支持
  - `EVERYWHERE_MCP_OPENCLI=0` 环境 kill switch, 默认 ON
- MCP tool: `opencli_list`, `opencli_run`, 具体站点通过 `browser_*` 走 OpenDia extension

### 系统 C: OpenDia browser extension — **浏览器通用自动化底盘** (Everywhere fork 85 WS ops; 上游 ~24)

- **上游**: [`aaronjmars/opendia`](https://github.com/aaronjmars/opendia), MIT, 本地 `/Users/wowdd1/Dev/opendia/`
  - "The open alternative to Dia / Perplexity Comet"
  - Chrome + Firefox + Chromium 通用 extension
  - 已装 dxt (`opendia.dxt` 12MB) + `opendia-extension/` + `opendia-mcp/` (MCP server)
  - 核心卖点: **复用用户浏览器已有登录状态 / cookie / password / wallet / extension**
  - Anti-Detection 特化: Twitter/X / LinkedIn / Facebook 反爬绕过
- **Everywhere 用的 fork**: `hhsw2015/opendia experiment/replace-ab`, 85 WS operation
- 类型: WebSocket 服务, 类似 Puppeteer/Playwright 但走 extension (不启新浏览器实例)
- 涵盖: snapshot / diff_snapshot / click / fill / hover / focus / navigation / cookies / storage / mouse / keyboard / CDP overrides / React DevTools 探针 / auth vault

### openclicky 现有覆盖 vs Everywhere 三系统

| | 系统 A (SaaS API) | 系统 B (站点自动化) | 系统 C (浏览器底盘) |
|---|---|---|---|
| Everywhere | open-connector 831 provider | OpenCLI 173 站点 | OpenDia 85 ops |
| openclicky 现有 | Composio ~250 apps + gogcli (Google) | 无 (chrome-ext 仅 quota-reset) | 无 (chrome-ext 极简) |
| Gap | 覆盖 30% | 覆盖 0% | 覆盖 <5% |

### 建议 (更完整)

**系统 A (SaaS API)**: 中期可加 open-connector self-hosted (选项 Y-a, Node subprocess). 与 Composio 并存, 用户选.

**系统 B (OpenCLI 站点)**: **可能是最有价值的补齐** — Composio 覆盖不到的中国区站点 (12306 抢票 / bilibili / 1688 / 51job / autohome 等) OpenCLI 全覆盖. 用户价值巨大. 需要:
- Node runtime (与系统 A 共享)
- OpenDia-like Chrome extension (openclicky 现有 chrome-ext 大幅扩展)
- 或走 openclicky 自己的 OCCU-based 浏览器操作 (但要写 173 站点 selector, 成本极高, 不如复用 OpenCLI 的)

**系统 C (OpenDia)**: 若做系统 B, 系统 C 是必需的底盘. 二者绑定.

**决策**: **A + B + C 全部移植**. 三系统都属于 Everywhere MCP 生态 (上下文获取基础设施), 完整替代 Everywhere 要求全覆盖. 不做取舍.

### 集成成本估算 (openclicky 侧)

**关键洞察**: 三个系统都是**独立开源项目 + 独立上游**, openclicky 不需要走 Everywhere 那样的 C# port. 直接依赖上游即可:

| 系统 | 上游 | License | 集成方式 for openclicky |
|---|---|---|---|
| A. open-connector | `oomol-lab/open-connector` | Apache-2.0 | Bundle Node runtime + npm install open-connector, spawn subprocess, HTTP loopback |
| B. OpenCLI | `jackwener/opencli` (27k star!) | (check repo) | 同 A, 共享 Node runtime, 173 站点 manifest 打包 or 首启下载 |
| C. OpenDia | `aaronjmars/opendia` MIT | MIT | 装 Chrome extension (用户装) + bundle opendia-mcp Node server, 走 WS 通信 |

**共享成本**: A + B + C 都要 Node runtime → 一次投入
- Bundle Node.js macOS binary (~40MB)
- 或用户自装 Node (`brew install node`), 更小 App

**独立成本**:
- A: open-connector `npm install` + provider manifest 更新策略 + OAuth 回调 HTTP server (openclicky 现有 :3011 chrome-bridge 可扩)
- B: OpenCLI runtime + 173 站点 manifest (`cli-manifest.json` 1MB) + 兼容性维护 (站点改版会 break)
- C: opendia extension 用户装 (Chrome Web Store 或 sideload) + opendia-mcp server + WS token auth

**任务立项** (P2-P4):
- A. open-connector: Node subprocess, 831 provider self-hosted (Phase 7.5 in `09_MIGRATION_ORDER.md`)
- B. OpenCLI: 复用 A 的 Node runtime, 173 站点 manifest
- C. OpenDia: 用户装 Chrome extension (Store 或 sideload) + bundle opendia-mcp Node server, WS token 认证

三者共享 Node runtime (一次投入). 属于 Everywhere MCP 生态, openclicky 都要有.

### 重叠治理规则

1. **Sensor endpoint (/mcp/sensor) 里的 tool 优先走 OCCU**, 参数照 Everywhere. 若 OCCU 缺, port Everywhere 源码补.
2. **App 内 UI 场景保留 `OpenClickyNativeComputerUseController`**, 但不加新功能. 逐渐迁移到 OCCU 后可考虑 deprecate.
3. **不再在 openclicky 里手写 AX walker / snapshot renderer**. 都走 OCCU.
