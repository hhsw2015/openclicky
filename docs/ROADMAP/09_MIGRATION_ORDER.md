# 实施顺序

**目标**: 每 phase 独立可 revert. Phase 1-3 完全独立不改现有代码; Phase 4 起小改现有 voice pipeline (加 [ROUTE] prompt + reply parse), 但都 gated by Settings toggle 可 rollback.

**每 file / 能力都必须走五步流程** (见 `08_QUALITY_ASSURANCE.md`): 调研 → 修文档 → 实现 → 对齐审查 → 测试. 下面每 phase 的 checklist 是**能力清单**, 不是执行顺序. 实际每项都是五步循环, 通过 Golden diff 与 Everywhere 输出对齐后才算完成.

**并行加速**: 同 Phase 内独立任务并发 (见 `08_QUALITY_ASSURANCE.md` 并行策略). 例:
- Phase 1: `FinderSelectionCapture` / `BrowserURLCapture` / `ClipboardCapture` / `IdleTimeCapture` 完全独立, 可 4 agent 并行
- Phase 5: 各 P1 capture file 全独立, 可 5-6 agent 并行
- Phase 7.7: 7 个 doc reader (pdf/docx/xlsx/pptx/epub/html/txt) 独立, 可 7 agent 并行
- **反例**: doc reconcile 单线程 (共享 doc file), open-connector + OpenCLI 若共享 Node runtime 需串行 Node 打包

预算里已经考虑并行加速, 若严格串行会更慢.

**预算说明**: 下方每 phase 的天数**已含五步流程时间**. 若单独看 code 行数会显得慢, 是因为调研 + 对齐 + 测试是绝对多数, 编码是少数. Zero-drift 值这个投入.

---

## Phase 1: Layer 0 ContextService 基础 (P0)

**独立**: 新 file, 现有代码不感知.

- [ ] 目录骨架 `cursor-buddy/ContextService/`
- [ ] `OpenClickyContextService.swift` — 主类 + protocol
- [ ] `Capture/FrontmostAppCapture.swift`
- [ ] `Capture/FocusedWindowCapture.swift`
- [ ] `Capture/FinderSelectionCapture.swift`
- [ ] `Capture/SelectedTextCapture.swift` (三级 fallback)
- [ ] `Capture/BrowserURLCapture.swift`
- [ ] `Capture/ClipboardCapture.swift`
- [ ] `Capture/WorkdirProbe.swift`
- [ ] `Capture/RecentSessionsCapture.swift`
- [ ] `Capture/ProjectRegistry.swift`
- [ ] `Types/CaptureTypes.swift`
- [ ] `AppleScript/AppleScriptRunner.swift`
- [ ] XCTest for 每 capture 纯逻辑
- [ ] Fixture 脚本 `scripts/verify-context/`

**验收**: 单元测试通过 + fixture 手动跑通 + 与 Everywhere golden diff (frontmost/finder/selected_text/browser_url)

**预算**: 3-5 天

---

## Phase 2: Layer 2 MCP /mcp/sensor 端点 (P0)

**独立**: 加 endpoint, 不改现有 endpoint. Codex 不接入.

- [ ] `OpenClickyExternalControlBridge.swift` 加 `/mcp/sensor` route + `.sensor` role
- [ ] MCP tool descriptors (前 15 项 core tool)
- [ ] Tool → ContextService 分发
- [ ] SSE Streamable HTTP + notifications 202 (复用现有)
- [ ] Test with `curl` MCP `tools/list` + `tools/call`

**验收**: 外部 (curl / Claude Code) 能调 tools/list 看到 core tools, 能 call `get_focused_context` 拿到数据

**预算**: 1-2 天

---

## Phase 3: Layer 2 Codex sensor 集成 (P0)

**独立**: openclicky codex config.toml 加 `[mcp_servers.sensor]`. 无 UI 改.

- [ ] `ClickyCodexConfigTemplate.swift` 加 sensor MCP server 声明 (仿 advisor)
- [ ] http_headers 带 token
- [ ] 测试: 手动 spawn 一个小 codex task, 让它 call `probe_workdir` 或 `get_finder_selection`
- [ ] Codex agents 实际使用 tools/list 会看到什么

**验收**: codex 内部能连上 sensor MCP + tool call 有效.

**预算**: 半天

---

## Phase 4: Layer 1 意图判定融入 dialog reply (P0)

**要改现有 voice pipeline** (小改动, 加 prompt + parse).

- [ ] `CompanionManager.swift` `onDialogReplyComplete` 加 [ROUTE] parse
- [ ] `startVoiceAgentTaskPlan` 扩参数 (`workingDirectoryHint`, `projectRef`, `slug`, `progressDriven`, `completionMarker`)
- [ ] `CodexAgentSession.swift` 加 `progressDriven` / `completionMarker` 字段
- [ ] Auto-continue observer 加 progress-driven 分支 (`turn/completed → 若 progress.md 未 DONE, fire`)
- [ ] Dialog model system prompt 增强 (给上下文 + 教 emit [ROUTE])

**验收**: 完整 e2e — 语音说 "在 openclicky 加截屏", openclicky 在 `.openclicky/tasks/screenshot-tool/` 建目录 + codex spawn.

**预算**: 2-3 天

---

## Phase 5: Layer 0 补齐 P1 项 (Everywhere 完整对等)

**独立**: 加更多 capture, 不改 Router / UI.

- [ ] `Capture/FocusedElementCapture.swift`
- [ ] `Capture/AXTreeCapture.swift` (token-budget 压缩)
- [ ] `Capture/BrowserTabsCapture.swift`
- [ ] `Capture/TerminalCapture.swift`
- [ ] `Capture/OCRCapture.swift`
- [ ] `Capture/AXQuirksInstaller.swift` (`AXManualAccessibility` / `AXEnhancedUserInterface`)
- [ ] `Capture/IdleTimeCapture.swift`
- [ ] `Capture/CursorCapture.swift` + `Capture/ElementUnderCursorCapture.swift`
- [ ] `Capture/WindowEnumerationCapture.swift`
- [ ] `Capture/PermissionPreflight.swift`
- [ ] MCP tool 扩到全部 core + long-tail

**预算**: 4-6 天

---

## Phase 6: Layer 3 Stash + Hook (P2)

**独立**: 全新功能, 不动其他.

- [ ] `Capture/ContextStashWriter.swift` (原子写)
- [ ] Payload format 照 Everywhere `FormatForHook` 输出结构, 品牌换成 `[openclicky-ctx]` / `[openclicky-ctx-link]` / `[openclicky-ctx-annotation]` / `[openclicky-hint]` / `[openclicky-discover]` / `[openclicky-ctx-json]`
- [ ] URL redaction + sanitisation (与 Everywhere 逻辑完全一致, 见 04 doc)
- [ ] Shortcut 移植: `SnapshotContext` / `ClearContextStash` / `AgentPickElement` / `Whiteboard` / `LinkRect` (默认全未绑, 与 Everywhere 一致)
- [ ] `openclicky-context-hook` Swift CLI (照 Everywhere Rust hook 协议翻译)
- [ ] Bundle 到 `Contents/Helpers/openclicky-context-hook`
- [ ] Docs: 用户配置 `~/.claude/settings.json` UserPromptSubmit 指向 openclicky hook

**验收**: 完全独立跑通. 用户从 Everywhere 切过来只需 (1) 卸载 Everywhere, (2) 改 hook 命令名 (`everywhere-context-hook` → `openclicky-context-hook`), (3) 在 openclicky Settings 里重设自己习惯的 hotkey.

**预算**: 2-3 天

---

## Phase 7: Layer 4 UX (P3)

- [ ] Settings 面板 "Context Awareness" tab
- [ ] PickStash (pin element hotkey)
- [ ] Whiteboard gestures + OCR + 手势分类
- [ ] LinkRect harvest (drag rect)
- [ ] Auto text-selection observer (默认 off)

**预算**: 5-7 天

---

## Phase 7.5: open-connector 集成 (P2, Everywhere-parity 核心)

**目的**: 移植 Everywhere 的 open-connector 能力, 覆盖 831 SaaS provider (与 openclicky 现有 Composio ~250 并存, 补长尾).

**属于 Everywhere 的能力**, 完整替代要求.

- [x] Node runtime strategy: require system `node` (brew / nvm / /opt/homebrew/…) — bundling `~40MB` universal binary rejected per impl-notes 2026-07-23; auto-discovery in `OpenClickyConnectorSubprocess.resolveNodePath` covers 5 install paths.
- [x] Vendor plan: `AppResources/OpenClicky/OpenConnectorRuntime/{boot.js, config.json, UPSTREAM_SHA, README.md}` — `open-connector/dist/connector-manifest.json` optional; POC ships seeded manifest (github + no_auth_demo) inside `boot.js`, full bundle deferred.
- [x] `cursor-buddy/OpenClickyConnectorSubprocess.swift` — Node subprocess lifecycle (start / stop / crash-restart), READY-line handshake, health probe, `request(path:method:body:)` HTTP wrapper.
- [x] HTTP loopback: random port in `[52000, 53000)`, bearer token in env `OPENCLICKY_CONNECTOR_TOKEN`.
- [x] MCP tool port (byte-for-byte with `ConnectorTools.cs`):
  - `connector_list` — service? / query? / cap=60
  - `connector_describe(service, name)` — full input/output JSON schema + requiredScopes
  - `connector_connect(service, api_key?, display_name?, connection?)` — api_key stores directly in Keychain; empty api_key kicks off OAuth flow (returns `authorization_url` + `state`)
  - `connector_list_connections()` — enumerates Keychain, values never returned
  - `connector_disconnect(service, connection?)` — idempotent Keychain delete
  - `connector_run(service, name, arguments_json, connection?)` — forwards to Node with the Keychain credential inlined
- [x] `cursor-buddy/OpenClickyConnectorOAuthCallback.swift` — loopback HTTP server on random port in `[54000, 55000)`, `/oauth/callback?code&state` route validates state against in-memory pending map (10 min TTL), forwards to Node's `POST /internal/oauth_complete`, renders success/failure HTML.
- [x] `cursor-buddy/OpenClickyConnectorCredentialStore.swift` — Keychain-backed store (kSecClassGenericPassword, `com.jkneen.openclicky.connector.<providerId>` service prefix, connectionId as account, JSON-encoded credential in value). AES-at-rest handled by macOS Keychain; supports named connections via composite primary key.
- [x] `cursor-buddy/OpenClickyConnectorSettings.swift` — UserDefaults master toggle (`openclicky.connector.enabled`, default false), Node path override, provider allow/disallow lists, published runtime status.
- [x] `cursor-buddy/OpenClickyConnectorBridgeTools.swift` — 6 MCP tool descriptors + dispatch. Wired into `OpenClickyExternalControlBridge.sensorToolNames` / `sensorToolDomains` / `sensorToolDescriptorsRaw` / `executeSensorTool`.
- [x] Autostart on app launch (`cursor_buddyApp.applicationDidFinishLaunching` → `OpenClickyConnectorSettings.autostartIfEnabled()`) and clean shutdown in `applicationWillTerminate`.
- [ ] Settings panel UI (Connections tab) — deferred; env-driven toggle only in this landing.
- [ ] Full 831-provider bundle build (`build-connector-bundle.mjs` + esbuild) — deferred.
- [ ] Composio coexistence UX — same provider surfaced under both self-hosted and hosted; requires bridge-level provider-namespace prefix decision, not in scope.

**Documented deviations** (see `.impl-notes/phase7-5-open-connector-2026-07-23.md`):
1. ClearScript V8 → Node subprocess (Swift has no first-class V8; JSC missing fetch + Node primitives).
2. JSON file store (`~/.everywhere/connector/connections.json`) → macOS Keychain (Everywhere Phase 6 target reached one release early).
3. Bundled Node binary → system Node via `brew install node`.

**验收**:
- 首个 provider (GitHub, 与 Everywhere Phase 1 一致) end-to-end OAuth + list_issues 成功
- Codex agent 调 `connector_run(github, list_repos)` 拿到用户 repo
- Settings Connections tab 显示 self-hosted 已连的 provider

**预算**: 5-8 天 (含 Node runtime 打包 + provider manifest 集成 + 3-5 个 provider 冒烟)

**参考**: `Everywhere/docs/specs/everywhere-connector.md` (31KB, 12 phase 详细规格)

---

## Phase 7.6: OpenCLI + OpenDia (P3, Everywhere MCP 生态)

**目的**: 移植 Everywhere 的浏览器自动化上下文获取能力.
- OpenCLI: 173 站点 (12306 / bilibili / 中国区 SaaS 等 open-connector 覆盖不到的)
- OpenDia: 通用浏览器自动化底盘. **Everywhere 用 `hhsw2015/opendia experiment/replace-ab` fork, 有 85 WS ops**. 上游 `aaronjmars/opendia` MIT 只 ~24 top-level tool. openclicky 若 port 需选:
  - (a) 用 Everywhere fork 的 85 ops (功能全, 但脱离 MIT 上游, 需自己 maintain)
  - (b) 用上游 24 ops (轻, 但 gap 60+ ops), 之后 upstream fork 或补 ops

**属于 Everywhere MCP 生态**, 完整替代要求.

### OpenDia (浏览器底盘) — Phase 7.6b F31 (2026-07-23 landing)

- [x] Vendor `aaronjmars/opendia` (MIT, upstream pin recorded in `AppResources/OpenClicky/OpenDiaRuntime/UPSTREAM_SHA`) 到 `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/`.
- [x] `AppResources/OpenClicky/OpenDiaRuntime/boot.js` — HTTP loopback + WS server for the extension. Auth: bearer `OPENCLICKY_OPENDIA_TOKEN`; port range `[56000, 57000)`. Routes `/health`, `/tools`, `/call`.
- [x] `cursor-buddy/OpenClickyOpenDiaSubprocess.swift` — Node subprocess (mirrors F29/F30 shape). Talks Swift ↔ Node over HTTP; Node ↔ extension over WS.
- [x] `cursor-buddy/OpenClickyOpenDiaBridgeTools.swift` — 120 `browser_*` MCP tool descriptors + prefix-based dispatch.
- [x] `cursor-buddy/OpenClickyOpenDiaSettings.swift` — master toggle `openclicky.opendia.enabled` (default false), env force `OPENCLICKY_MCP_OPENDIA=1`.
- [x] Bridge wire-up: 4 extension points in `OpenClickyExternalControlBridge.swift` (`sensorToolNames`, `sensorToolDomains`, `sensorToolDescriptorsRaw`, `executeSensorTool`). All `browser_*` tools live in `OpenClickyMetaDomain.browser` — hidden until `activate_domain name=browser`.
- [x] Autostart on `applicationDidFinishLaunching`, stop on `applicationWillTerminate` in `cursor_buddyApp.swift`.
- [x] Xcode: `OpenDiaRuntime` added to "Copy OpenClicky App Resources" ditto list.
- [ ] User installs Chrome/Firefox extension. Distribution: upstream ships pre-built zips (`releases/opendia-chrome-1.0.6.zip`, `releases/opendia-firefox-1.0.6.zip`). `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md` documents the sideload flow; runtime bundle intentionally omits the 500 MB extension source tree.

**Deviations from Everywhere** (see `docs/ROADMAP/.impl-notes/phase7-6b-opendia-2026-07-23.md`):
- .NET `System.Net.WebSockets` server (Everywhere `OpenDiaBridge.cs`) → Node `ws` server behind an HTTP shim. Same rationale as F29: no ClearScript / no in-process JS engine.
- Independent subprocess (own port range, own auth token). Does not share the F29 Node process (crash isolation, and F31 needs the `ws` npm dep which F29 does not).
- Full 120 `browser_*` tool descriptors registered; the extension itself decides which subset it implements. Missing tools return `{ok:false, code:"UNKNOWN_TOOL"}`.

### OpenCLI (站点适配器) — Phase 7.6a F30 (2026-07-23 landing)

- [x] Vendor `jackwener/opencli` (pin `9161d99d96ec107cd77f13a30315614129179a1a`, tag `v1.8.5`) 到 `AppResources/OpenClicky/OpenCLIRuntime/opencli/` — 171 unique sites, 1257 adapter registrations (`clis/*/` + `cli-manifest.json` + `runtime/`).
- [x] `AppResources/OpenClicky/OpenCLIRuntime/boot.js` — HTTP loopback + bearer token, `/list` / `/describe` / `/run` / `/health` routes.
- [x] `cursor-buddy/OpenClickyOpenCLISubprocess.swift` — Node subprocess (port `[55000, 56000)`, env `OPENCLICKY_OPENCLI_TOKEN`). Reuses F29's Node-path resolver.
- [x] `cursor-buddy/OpenClickyOpenCLIBridgeTools.swift` — 3 MCP tool descriptors + dispatch.
- [x] `cursor-buddy/OpenClickyOpenCLISettings.swift` — master toggle `openclicky.opencli.enabled` (default false), env force `OPENCLICKY_MCP_OPENCLI=1`.
- [x] Bridge wire-up: 4 extension points in `OpenClickyExternalControlBridge.swift` (`sensorToolNames`, `sensorToolDomains`, `sensorToolDescriptorsRaw`, `executeSensorTool`).
- [x] Autostart on `applicationDidFinishLaunching`, stop on `applicationWillTerminate` in `cursor_buddyApp.swift`.
- [x] Xcode: `OpenCLIRuntime` added to "Copy OpenClicky App Resources" ditto list.
- [ ] Background-tab mode (cookie / intercept) — deferred to F31 (OpenDia). `opencli_run` returns `{ok:false, code:"BROWSER_NOT_READY"}` for browser strategies per SPEC §2.1.
- [ ] Full pipeline runner execution — POC ships a minimal inline interpreter (`fetch` / `limit` / `map` / `filter` / `select` / `sort`); non-fetchable adapters return `RUNTIME_NOT_IMPLEMENTED`.

**Deviations from Everywhere** (see `docs/ROADMAP/.impl-notes/phase7-6a-opencli-2026-07-23.md`):
- ClearScript V8 → Node subprocess (same rationale as F29).
- Independent subprocess; does not share Node process with F29 (crash isolation).
- 171 sites, not 173 — upstream contains a couple of `_` prefixed private modules which are filtered out.

**验收**:
- 首个站点冒烟 (bilibili list 或 arxiv search) end-to-end
- 用户浏览器扩展装好 + openclicky ↔ extension WS 通
- Codex 调 `opencli_run(bilibili, search, {q:"..."})` 拿结果

**预算**: 4-6 天

**参考**:
- `Everywhere/docs/specs/everywhere-replace-agent-browser.md` (26KB)
- `Everywhere/docs/specs/everywhere-opencli-adapters.md` (27KB)
- `Everywhere/docs/specs/opendia-cebian-merge.md` (21KB)

---

## Phase 7.7: Doc readers (P3, Everywhere MCP 生态)

**目的**: 移植文档内容读取, agent 需读用户本地 pdf/docx/xlsx/pptx/epub/html/txt.

**照 Everywhere `Everywhere.Mcp/Tools/DocRead*.cs` 完整移植**.

- [ ] `doc_read_pdf` — PDFKit
- [ ] `doc_read_docx` — Aspose.Words 或纯 Swift 解 zip + XML
- [ ] `doc_read_xlsx` — 同上
- [ ] `doc_read_pptx` — 同上
- [ ] `doc_read_epub` — zip + HTML parse
- [ ] `doc_read_html` — WKWebView headless render 或纯解析
- [ ] `doc_read_txt` — 直读 (encoding detect)

**参考**: `Everywhere/docs/specs/everywhere-doc-readers-mcp.md` (20KB)

**预算**: 3-4 天

---

## Phase 8: 长尾 tool + 兼容 (P4)

- [ ] Doc readers (pdf/docx/xlsx/pptx/epub) via PDFKit/textutil
- [ ] Web search / web fetch (若走 msgs 通道, 免费)
- [ ] Domain gating / activate_domain
- [ ] batch multi-tool
- [ ] list_more_tools / search_tools / call_tool 反射

**预算**: 3-5 天

---

## 总预算

**核心感知 + 意图** (Phase 1-4): **6.5-10.5 天** → 意图分类, project 感知, MCP sensor 端点通

**Everywhere-parity Layer 0/3** (Phase 5-6): **6-9 天** → 全 Layer 0 采集 + 外部 hook

**UX** (Phase 7): **5-7 天**

**Everywhere MCP 生态移植** (Phase 7.5-7.7): **12-18 天** → open-connector 831 provider + OpenDia + OpenCLI + Doc readers

**长尾** (Phase 8): **3-5 天**

**共**: **32-49 天 (7-10 周)** 达到"完整替代 Everywhere 感知 + MCP 上下文获取能力"

注: 上述都是**开发时间**估算, 不含: golden diff 验证 / 用户反馈迭代 / UI 打磨 / 权限 TCC 首次触发的用户教育. 加上这些 typical 再 +30-50%.

---

## 每 phase 之间的兼容性

- Phase 1-3 完全无副作用, 现有用户完全不感知
- Phase 4 开始有 dialog model prompt 变化, 但 [ROUTE] 缺失即 fallback 到现有行为
- Phase 5-6 全新功能, 独立开关
- Phase 7-8 全 Settings 可控

**风险最低**: Phase 4 最需要小心, 因为触及 voice pipeline. 要有 rollback 开关 (Settings toggle "Use Router-based intent classification").

---

## 现在的下一步

**Phase 1 Layer 0 起头**. 具体第一 file: `Capture/FrontmostAppCapture.swift` + `Types/CaptureTypes.swift`.

看 clarify 或直接开写.
