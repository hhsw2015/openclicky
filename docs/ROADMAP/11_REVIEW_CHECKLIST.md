# Everywhere Port Review Checklist (功能维度)

## 🔴 Review 硬性标准 (3 条)

### 标准 1: **Everywhere 代码 = 唯一事实源**

- Review 中每一个断言, 必须从 Everywhere 源 `.cs` / `.rs` file 找到出处
- **不信** Everywhere `docs/` (SPEC / PARITY_MATRIX / HANDOFF / specs/*.md) — doc 可能 stale
- **不信** openclicky roadmap doc (00-11, 包括本 checklist 自身)
- **不信** openclicky `.impl-notes/` (agent 自报可能过 rosy)
- **不信** test coverage 数字 (test 可能测的是错误行为)
- **不信** memory / "我记得" — 一律 grep + Read verify
- 冲突时: 代码 > doc > impl-notes > memory
- 每个 Alignment Table 里的 "Everywhere" 列必须能引用到 `<file>:<line>` — 无引用 = 不作数

### 标准 2: **openclicky Swift port 与 Everywhere 逻辑对齐**

对齐维度 (逐项 verify):

- **Method 签名**: 参数顺序 / 类型 / 默认值 / async-vs-sync 匹配
- **Magic constants**: 每个数字 byte-match (MaxLinks=200, MaxUrlLen=2048, RepeatSuppressionMs=1500, MacosModifierReleaseDelayMs=180, SelectionCache.Ttl=2min, PickStash.DefaultTtl=5min, WhiteboardStash.DefaultTtl=5min, AnnotationStash.DefaultTtl=10min, MaxPortFallbacks=10, port 7878, sweep stale >10min, WalkBudget=50000, MaxDepth=60, 3s subprocess timeout, 150ms activation tick × 16 iterations = 2.4s cap, ...)
- **Sanitisation 边界**: app=64/title=80/url=256/selection=200/link.url=512/link.title=120/source=32/anchor=200/ref=96/body=800 逐项
- **URL redaction denylist**: 17 param 完整匹配 (token / access_token / id_token / refresh_token / api_key / apikey / key / secret / client_secret / auth / authentication / password / pwd / sig / signature / session / sessionid)
- **Error path**: return null vs throw / log level / retry / fallback / partial failure degrade
- **Lock 语义**: SemaphoreSlim(1,1) WaitAsync(0) 立即返回 vs NSLock.try() 非阻塞 vs .lock() 阻塞
- **JSON 字段名**: snake_case wire shape 精确匹配 (schema_version / captured_at_utc / app / process_id / window_title / url / selected_text / selected_app / pin_pending / whiteboard_pending / whiteboard_region_count / picked_links / annotations)
- **`WhenWritingNull` 语义**: 空字段丢弃 (Swift `encodeIfPresent` 每字段)
- **Grapheme-safe truncate**: `Character` iteration 或 `enumerateSubstrings(byComposedCharacterSequences)`, **禁用** `unicodeScalars` (会切开 emoji ZWJ)
- **IPv6 bracket strip**: `SanitiseTokenValue` 会 strip `[` `]` — Everywhere 上游行为, **保留** (openclicky 不修)
- **AppleScript byte-identity**: `test_appleScriptSource_matchesEverywhereVerbatim` 验证源字符串 byte-exact
- **C# CRLF quirk**: `TrimEnd('\r').TrimEnd('\n')` on `"\r\n"` 留 stray `\r` — Swift `unicodeScalars` 迭代复现
- **Cocoa→Quartz Y-flip**: `quartz.y = primary.height - (cocoa.y + cocoa.height)`
- **Event tap**: `.cghidEventTap` (`kCGHIDEventTap`, raw 0, 非 sessionEventTap)
- **Env vars 命名**: `OPENCLICKY_MCP_*` (rewrite from `EVERYWHERE_MCP_*`)
- **注释里 Everywhere warning 保留**: 每个 `///` 里的 WARNING / TODO / hack 说明必须在 Swift port 里 (可翻中英双语)

对齐允许**intentional deviation** (但必须 file header + review 明确列出):
- Password field 保护 (openclicky 加, Everywhere 无)
- Full NSPasteboardItem restore (openclicky 加, Everywhere 只 restore string)
- ElementUnderCursor multi-display bug 修正 (openclicky 修, Everywhere 有 bug)
- 3 openclicky-unique capture (WorkdirProbe / RecentSessions / ProjectRegistry / GitAwareness) — 没 Everywhere 对比

Unintentional deviation = BROKEN = must-fix.

### 标准 3: **文档正确 + 功能完整 + 无 bug**

**文档正确**:
- doc/ROADMAP/00-11 每条声明可从**代码 verify**
- 每 doc 里的 file path / method name / magic constant 都要能 grep 到
- Stale 声明 → 立即修 doc (回代码为源)
- `.impl-notes/` 里的 review report 里断言必须**可复核** (给 file:line 引用)

**功能完整**:
- 25 独立功能单元 (F01-F25) **每个都在**文档里列了 owner file
- 每功能有对应的 `.review-notes/<Fxx>-*.md`
- 遗漏功能 → 加 F26+, 不隐藏
- **不允许** openclicky Layer 0-4 里存在没在 doc 11 列出的 file (孤儿 file = review gap)

**无 bug**:
- SPM test 全 pass (0 fail)
- `sign-and-install.sh` BUILD SUCCEEDED
- Sensor curl smoke 全 pass (43 tool)
- Hook binary integration 6/6 pass
- Golden diff (若已建 fixture) 无 structural difference
- Review verdict 不允许 BROKEN 留 main branch

**Review pass 条件 (all must hold)**:
1. ✅ 每功能有 review report
2. ✅ Every "Everywhere" 列引用 file:line
3. ✅ Every unintentional divergence 已修
4. ✅ Every intentional divergence 有 file header + review 声明
5. ✅ 全部 test 绿
6. ✅ Everywhere 里存在但 openclicky 未 port 的功能 → 补做 or 明确列 "wont-port" 并有理由
7. ✅ openclicky 里存在但没 review 覆盖的 file → 补 review 或删 file

---

**目的**: 开发完成后, 按**独立功能单元**逐一 review — 每功能可能涉及多文件, 但功能间相互独立可并行.

**Everywhere pin**: `30e03e9dcfdd4247fd679828ed86e9042f32d809`

**方法**: 每功能一个 review agent, 走五步:
1. 读 Everywhere 源 (功能涉及的所有 `.cs` file)
2. 读 openclicky 对应 Swift file(s)
3. Side-by-side diff 每 method / constant / field / semantic
4. 找 divergence (intentional vs unintentional)
5. 报告到 `.review-notes/<Fxx>-*.md`, 遵守 review 输出规范 (末尾)

---

## Status Summary (2026-07-23)

Status values:
- `RESOLVED` — review found issues, fix landed, report linked.
- `PASS` — review passed as SEMANTIC_MATCH / BYTE_MATCH; no fix needed.
- `PARITY_OK` — openclicky-native (no Everywhere byte parity applicable); design verified.
- `LANDED` — feature previously NOT IMPLEMENTED, now shipped; report linked.
- `CONTRACT-ONLY` — MCP contract pinned in openclicky; waiting on upstream Everywhere port.

| Feature | Verdict / Status | Report |
|---|---|---|
| F01 — App and window enumeration | PASS | `.review-notes/F01-app-window-enumeration-2026-07-23.md` |
| F02 — Element awareness (focused / at-point / semantic) | RESOLVED | `.impl-notes/f02-fix-report-2026-07-23.md` |
| F03 — Selected text capture | PASS | `.review-notes/F03-selected-text-2026-07-23.md` |
| F04 — Browser URL + Tabs | PASS | `.review-notes/F04-browser-url-tabs-2026-07-23.md` |
| F05 — Finder selection | PASS | `.review-notes/F05-finder-selection-2026-07-23.md` |
| F06 — Terminal scrollback | PASS | `.review-notes/F06-terminal-2026-07-23.md` |
| F07 — Clipboard read/write | PASS | `.review-notes/F07-clipboard-2026-07-23.md` |
| F08 — Screenshot | PASS | `.review-notes/F08-screenshot-2026-07-23.md` |
| F09 — OCR | PASS | `.review-notes/F09-ocr-2026-07-23.md` |
| F10 — IdleTime | PASS | `.review-notes/F10-idle-time-2026-07-23.md` |
| F11 — Permission preflight | PASS | `.review-notes/F11-permission-2026-07-23.md` |
| F12 — AXQuirksInstaller | PASS | `.review-notes/F12-ax-quirks-2026-07-23.md` |
| F13 — Input simulator (native, for LaunchPhrase) | RESOLVED | `.impl-notes/f13-f17-fix-report-2026-07-23.md` |
| F14 — In-memory stashes (Pick / Annotation / Whiteboard) | RESOLVED | `.impl-notes/f14-f16-fix-report-2026-07-23.md` |
| F15 — MCP tool layer (bridge + 43 sensor tools) | RESOLVED | `.impl-notes/f15-f19-f20-fix-report-2026-07-23.md` |
| F16 — Memory store + tools | RESOLVED | `.impl-notes/f14-f16-fix-report-2026-07-23.md` |
| F17 — Self-expanding + gate (meta tools + BM25) | RESOLVED | `.impl-notes/f13-f17-fix-report-2026-07-23.md` |
| F18 — Doc readers (7 formats) | PASS | `.review-notes/F18-doc-readers-2026-07-23.md` |
| F19 — Stash writer + hook binary + URL redaction | RESOLVED | `.impl-notes/f15-f19-f20-fix-report-2026-07-23.md` |
| F20 — App activator + LaunchPhrase | RESOLVED | `.impl-notes/f15-f19-f20-fix-report-2026-07-23.md` |
| F21 — KnownApps discovery (xlb hint) | RESOLVED | `.impl-notes/f21-f23-fix-report-2026-07-23.md` |
| F22 — Hotkey + Settings tab + Everywhere-parity defaults | RESOLVED | `.impl-notes/f22-f25-fix-report-2026-07-23.md` |
| F23 — Whiteboard drawing UX | RESOLVED | `.impl-notes/f21-f23-fix-report-2026-07-23.md` |
| F24 — LinkRect harvest UX | PASS | `.review-notes/F24-linkrect-ux-2026-07-23.md` |
| F25 — PickElement + Annotation ➕ badge + delta-follow | RESOLVED / PARITY_OK (openclicky-native) | `.impl-notes/f22-f25-fix-report-2026-07-23.md` |
| F26 — Codex agent config + ROUTE | RESOLVED / PARITY_OK (openclicky-native) | `.impl-notes/f26-fix-report-2026-07-23.md` |
| F27 — Dialog model preflight + ROUTE | RESOLVED / PARITY_OK (openclicky-native) | `.impl-notes/f27-fix-report-2026-07-23.md` |
| F28 — Auto-continue observer (progress-driven) | LANDED / PARITY_OK (openclicky-native) | `.impl-notes/f28-landing-report-2026-07-23.md` |
| F29 — open-connector integration (831 providers) | LANDED | `.impl-notes/phase7-5-open-connector-report-2026-07-23.md` |
| F30 — OpenCLI (171 sites) | LANDED | `.impl-notes/phase7-6a-opencli-report-2026-07-23.md` |
| F31 — OpenDia (120 browser_* tools) | LANDED | `.impl-notes/phase7-6b-opendia-report-2026-07-23.md` |
| F32 — chat_bus (6 chat_* tools + long-poll) | LANDED | `.impl-notes/f32-f34-landing-report-2026-07-23.md` |
| F33 — adapter_* (8 tools) | CONTRACT-ONLY (awaits Everywhere `CaptureSessionStore` port) | `.impl-notes/f33-f35-f36-landing-report-2026-07-23.md` |
| F34 — web_* (10 tools, `web_search` provider-not-configured stub) | LANDED | `.impl-notes/f32-f34-landing-report-2026-07-23.md` |
| F35 — page_* (2 upstream + 4 openclicky-native thin OpenDia wrappers) | LANDED | `.impl-notes/f33-f35-f36-landing-report-2026-07-23.md` |
| F36 — capture_* (4 upstream stubs + 5 openclicky-native template store) | LANDED | `.impl-notes/f33-f35-f36-landing-report-2026-07-23.md` |

---

## 功能单元清单 (24 项)

### 🟢 完全独立, 可并行

#### F01 — 应用与窗口枚举
**功能**: 列前台 app / 所有 running apps / focused window / 所有 windows.
**openclicky files**:
- `Capture/FrontmostAppCapture.swift` + `RunningAppsCapture.swift` + `FocusedWindowCapture.swift` + `WindowEnumerationCapture.swift` + `ScreenListCapture.swift`
**Everywhere files**:
- `Mac/Interop/VisualElementContext.cs` (TryFastListApps + focused walk)
- `Mac/Interop/AXUIElement.cs` (FreshFocusedWindowOf, walk to top-level)
- `Mac/Interop/WindowHelper.cs` (CGWindowListCopyWindowInfo)
- `Mac/Interop/NSScreenVisualElement.cs` (screen enumeration + Cocoa→Quartz flip)
- `Snapshot/AppKey.cs` (FromProcessId)

#### F02 — Element 感知 (focused / at-point / semantic path)
**功能**: 焦点 element 完整属性 + 光标下 element + 从叶子到根的 semantic breadcrumb.
**openclicky files**:
- `Capture/FocusedElementCapture.swift` + `CursorCapture.swift` + `ElementUnderCursorCapture.swift` + `SemanticExtractor.swift`
**Everywhere files**:
- `Snapshot/SnapshotRenderer.cs` (attribute cascade)
- `Snapshot/SemanticExtractor.cs` (BuildFocusedPath / ExtractFocused / ExtractSelected)
- `Mac/Interop/VisualElementContext.cs` (ElementFromPoint*)
- `Mac/Interop/AXUIElement.cs` (Name cascade, States, SuggestActions, secure text detection)

#### F03 — 选中文本捕获
**功能**: 三级 fallback (AX / 子 walk / Cmd-C fallback) + SelectionCache 2min TTL + password field 保护 + clipboard 恢复.
**openclicky files**:
- `Capture/SelectedTextCapture.swift` + `SelectionCache.swift`
**Everywhere files**:
- `Mac/Interop/VisualElementContext.TextSelection.cs` (416 lines)
- `Snapshot/SelectionCache.cs`

#### F04 — 浏览器 URL + Tabs
**功能**: 前台浏览器的 URL (AX AXURL 16-hop 遍历) + 全 tabs 列表 (AppleScript per-browser).
**openclicky files**:
- `Capture/BrowserURLCapture.swift` + `BrowserTabsCapture.swift`
**Everywhere files**:
- `Mac/Mcp/MacBrowserUrlReader.cs`
- `Mac/Mcp/MacBrowserTabsReader.cs` (Safari/Arc/Chromium AppleScript byte-identity)

#### F05 — Finder 选中
**功能**: 前台是 Finder 时获取当前文件夹 POSIX + 选中文件 (含 kindHint), CRLF quirk 保留.
**openclicky files**:
- `Capture/FinderSelectionCapture.swift` + `AppleScriptRunner.swift`
**Everywhere files**:
- `Mac/Mcp/MacFinderReader.cs` (AppleScript + `TrimEnd('\r').TrimEnd('\n')` C# quirk)
- `Mac/Mcp/MacAppleScriptRunner.cs`

#### F06 — Terminal scrollback
**功能**: 前台 Terminal / iTerm2 时获取 AXValue-based scrollback (executable-name 检测).
**openclicky files**:
- `Capture/TerminalCapture.swift`
**Everywhere files**:
- `Mcp/Tools/GetTerminalOutputTool.cs` (AXValue, 8-substring heuristic, Warp false-neg preserved)

#### F07 — Clipboard 读写
**功能**: NSPasteboard 文本读 (public.utf8-plain-text) + 写 + Cmd-V/Cmd-C 模拟 (CGEvent).
**openclicky files**:
- `Capture/ClipboardCapture.swift` + `ClipboardWriter.swift`
**Everywhere files**:
- `Mac/Mcp/MacClipboardReader.cs`
- `Mac/Mcp/MacClipboardWriter.cs`

#### F08 — Screenshot
**功能**: 全屏 / 窗口 / 区域截图 (SCScreenshotManager macOS 14+ + `screencapture` CLI 3s fallback + JPEG q=70 / max 1920×1080 / floor 2px / force-even dims).
**openclicky files**:
- `Capture/ScreenshotCaptureEverywhere.swift`
**Everywhere files**:
- `Mac/Interop/VisualElementContext.Screenshot.cs` (213 lines)
- `Mac/Interop/NSScreenVisualElement.cs` (CLI fallback + Y-flip)

#### F09 — OCR
**功能**: Vision `VNRecognizeTextRequest` fast branch, 无 language correction, 每行 bbox + text + confidence.
**openclicky files**:
- `Capture/OCRCapture.swift`
**Everywhere files**:
- `Mac/Interop/MacVisionOcrEngine.cs`

#### F10 — IdleTime
**功能**: 用户 idle 秒数 (CGEventSource, 不是 IOKit HID).
**openclicky files**:
- `Capture/IdleTimeCapture.swift`
**Everywhere files**:
- `Mac/Mcp/MacIdleTimeReader.cs`

#### F11 — Permission preflight
**功能**: TCC 检查 (accessibility / screenRecording / inputMonitoring / microphone / automation), 不触发 prompt.
**openclicky files**:
- `Capture/PermissionPreflight.swift`
**Everywhere files**:
- `Mac/Interop/PermissionHelper.cs`

#### F12 — AXQuirksInstaller
**功能**: 全局副作用 flip `AXManualAccessibility` + `AXEnhancedUserInterface` per-pid, idempotent + NSLock guarded.
**openclicky files**:
- `Capture/AXQuirksInstaller.swift`
**Everywhere files**:
- `Mac/Interop/AXUIElement.cs` (SetAppBoolAttribute + AppResolver.EnsureA11yEnabledOnce)

#### F13 — Input simulator (native, for LaunchPhrase)
**功能**: typeText / pressKey / click / scroll / drag (native CGEvent, `.cghidEventTap`, grapheme-aware, xdotool-syntax keys).
**openclicky files**:
- `Capture/InputSimulator.swift`
**Everywhere files**:
- `Mac/Mcp/MacInputSimulator.cs` (389 lines)
- `Mac/Mcp/MacKeyCodes.cs`
- `Mac/Interop/KeyMapping.cs`

#### F14 — In-memory stashes (Pick / Annotation / Whiteboard)
**功能**: 三个 stash + TTL (5min pin, 10min annotation, 5min whiteboard) + didChange notifications + WhiteboardStash `_imageBytesById` side-table.
**openclicky files**:
- `Capture/PickStash.swift` + `AnnotationStash.swift` + `WhiteboardStash.swift`
**Everywhere files**:
- `Everywhere.Core/Interop/PickStash.cs`
- `Everywhere.Core/Interop/AnnotationStash.cs`
- `Everywhere.Core/Interop/Whiteboard/WhiteboardStash.cs`

#### F15 — MCP tool 层 (bridge + 43 sensor tool)
**功能**: `/mcp/sensor` HTTP SSE Streamable endpoint + 22 core sensor tool + 8 memory + 7 doc + 6 meta = 43 total. 22 default visible, 15 hidden till activate_domain. Auth via `x-openclicky-token`.
**openclicky files**:
- `OpenClickyExternalControlBridge.swift` (sensorToolNames + sensorToolDescriptors + sensorToolDomains + executeSensorTool + SensorMetaDispatchDelegate)
**Everywhere files**:
- `Everywhere.Mcp/Tools/*.cs` (每 tool 一 file)
- `Everywhere.Mcp/Transport/EverywhereMcpHttpHost.cs`
- `Everywhere.Mcp/Server/EverywhereMcpServer.cs`

#### F16 — Memory store + tools
**功能**: 持久 memory (endpoints + notes + field-map + freshness + snapshot + verify-fixture), 8 MCP tool + atomic Darwin.rename 写.
**openclicky files**:
- `Memory/MemoryStore.swift` + `Memory/OpenClickyMemoryTools.swift`
**Everywhere files**:
- `Everywhere.Mcp/Tools/MemoryTools.cs`

#### F17 — Self-expanding + gate (meta tools + BM25)
**功能**: list_more_tools / search_tools (BM25 k1=1.5 b=0.75) / activate_domain / list_domains / call_tool / batch + core-tool gate + env var kill switch.
**openclicky files**:
- `Meta/OpenClickyMetaTools.swift` (BM25Index + Registry + Gate + StrategyNote)
- `Meta/OpenClickyStashTools.swift` (readPick / annotations / whiteboard)
**Everywhere files**:
- `Everywhere.Mcp/Tools/MetaTools.cs`
- `Everywhere.Mcp/Meta/Bm25Index.cs`
- `Everywhere.Mcp/CoreToolGate.cs`
- `Everywhere.Mcp/OpenCli/Observation/SelfExpandGate.cs`
- `Everywhere.Mcp/Tools/GateTools.cs`
- `Everywhere.Mcp/Tools/BatchTool.cs`
- `Everywhere.Mcp/Tools/ReadPickTool.cs` + `AddAnnotationTool.cs` + `ReadAnnotationsTool.cs` + `ClearAnnotationsTool.cs` + `ReadWhiteboardTool.cs` + `ReadWhiteboardImageTool.cs`

#### F18 — Doc readers (7 类)
**功能**: PDF / DOCX / XLSX / PPTX / EPUB / HTML / TXT 读取, 统一 `DocReaderResult` 结构 (text + warnings + metadata).
**openclicky files**:
- `DocReaders/DocReaderResult.swift` + `DocReadPdf.swift` + `DocReadDocx.swift` + `DocReadXlsx.swift` + `DocReadPptx.swift` + `DocReadEpub.swift` + `DocReadHtml.swift` + `DocReadTxt.swift`
**Everywhere files**:
- `Everywhere.Mcp/Tools/DocRead{Pdf,Docx,Xlsx,Pptx,Epub,Html,Txt}Tool.cs` + `DocReaderResult.cs`

#### F19 — Stash writer + hook binary + URL redaction
**功能**: `~/Library/Application Support/OpenClicky/context-stash.json` 原子写 (`Darwin.rename`), 品牌 rewrite `[openclicky-*]`, 17-param URL redaction, grapheme-safe truncate, 5-branch hint 优先级, single-flight `NSLock`; hook binary Swift CLI (Rust hook 协议, rename-claim + read+unlink + validate + stdout JSON).
**openclicky files**:
- `OpenClickyContextStashWriter.swift` (main app)
- `SPM Stash/OpenClickyContextSnapshotPayload.swift` + `OpenClickySanitiser.swift` + `StashPaths.swift`
- `SPM openclicky-context-hook/main.swift`
**Everywhere files**:
- `Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (1001 lines full)
- `Everywhere.Mcp/Snapshot/StashPaths.cs`
- `tools/everywhere-context-hook/src/main.rs`

#### F20 — App activator + LaunchPhrase
**功能**: 激活 target app (cmux) + 2.4s frontmost-settled loop (16 × 150ms, 2 consecutive) + focus-steal guard + `_phraseInFlight` interlock + type phrase + press Return.
**openclicky files**:
- `OpenClickyAppActivator.swift`
- `OpenClickyContextStashWriter.activateAgentAndFirePhrase()`
**Everywhere files**:
- `Mac/Mcp/MacAppActivator.cs` (297 lines)
- `Snapshot/ContextStashWriter.cs` (TryFireLaunchPhrase)

#### F21 — KnownApps discovery (xlb hint)
**功能**: Settings 里 titlePattern → discoverUrl 映射, 100ms regex timeout, ResolveDiscoveryUrl + ToStatePath (`/agent-skills` → `/agent-state`, `/xlb-perception` → `/agent-state`), stash 里 `[openclicky-discover]` line 5-branch hint 优先级.
**openclicky files**:
- `OpenClickyContextAwarenessSettings.knownApps`
- `SPM Stash/OpenClickyContextSnapshotPayload.formatForHook`
**Everywhere files**:
- `Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (ResolveDiscoveryUrl + ToStatePath + FormatForHook hint branches)

#### F22 — Hotkey + Settings tab + Everywhere-parity defaults
**功能**: 5 hotkey (SnapshotContext / ClearContextStash / AgentPickElement / Whiteboard / LinkRect) 默认 = Everywhere 用户实际值; Master toggle default on; `RepeatSuppressionMs=1500` + `MacosModifierReleaseDelayMs=180`; Settings "Context Awareness" tab; one-shot sentinel key 保证首启 seed + 之后 respect 用户 override.
**openclicky files**:
- `OpenClickyContextHotkeys.swift`
- `OpenClickyContextAwarenessSettings.swift`
- `OpenClickyContextAwarenessPanel.swift`
- `OpenClickySettingsWindowManager.swift` (`.contextAwareness` case)
- `CompanionManager.swift` (wire hotkeys singleton)
**Everywhere files**:
- `Everywhere.Core/Configuration/Settings/ShortcutSettings.cs`
- `Everywhere.Core/Configuration/Settings/McpServerSettings.cs`
- `Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs` (RepeatSuppressionMs / MacosModifierReleaseDelayMs)
- User 实际 `~/Library/Application Support/Everywhere/settings.json`

#### F23 — Whiteboard drawing UX
**功能**: press-hold hotkey → 全屏 overlay (透明, 15% 黑, 3px 黄笔画) → multi-stroke → 手势分类 (circle / underline / arrow / x / unknown, heuristic 圆度/aspect/终点距离) → 每 stroke bbox 截图 + OCR → `WhiteboardStash.set(regions, imageBytesById)`. Multi-monitor 每 screen 一 NSPanel, Cocoa→Quartz 转换.
**openclicky files**:
- `OpenClickyWhiteboardOverlayWindow.swift` (~20KB)
- `OpenClickyWhiteboardStrokeClassifier.swift` (~14KB, 纯 heuristic)
- `OpenClickyContextHotkeys.swift` (Whiteboard case)
**Everywhere files**:
- `Everywhere.Mcp/WhiteboardHotkeyInitializer.cs`
- `Everywhere.Mcp/Whiteboard/WhiteboardParser.cs` (closure / straight / axis / crossing-chord heuristics)
- `Snapshot/SemanticEnricher.cs`

#### F24 — LinkRect harvest UX
**功能**: press-drag → 单矩形 overlay (透明, 15%, 2px 绿边) → mouseUp 触发 → 遍历前屏 pid → AX walk (`MaxDepth=60`, `WalkBudget=50000`) → 找 `AXLink` role → majority-overlap → 抓 URL + AXTitle/AXDescription → 17-param redact → dedup + cap 200/2048/200 → 立即写 stash `picked_links[]` via `captureLinks()`.
**openclicky files**:
- `OpenClickyLinkRectOverlayWindow.swift` (~11KB)
- `OpenClickyLinkRectHarvester.swift` (~15KB)
- `OpenClickyContextHotkeys.swift` (LinkRect case)
- `OpenClickyContextStashWriter.captureLinks()`
**Everywhere files**:
- `Mac/Interop/VisualElementContext.LinkRect.cs` (608 lines)
- `Mac/Interop/ScreenSelectionSession.cs` (446 lines drag rect UI)
- `Snapshot/ContextStashWriter.CaptureLinksAsync`

#### F25 — PickElement + Annotation ➕ badge + delta-follow
**功能**: AgentPickElement hotkey → 全屏 crosshair overlay → 用户点 element → `ElementUnderCursorCapture` snapshot → `PickStash.set()` (5min TTL); 同时 AnnotationBadgeOverlay 订阅 3 个 stash didChange → 每 pin/region/link 显示红 badge (➕ 或 ✓ N) → 点击 badge 展开 SwiftUI textarea → 提交写 AnnotationStash; AXObserver `AXValueChanged`/`AXMoved` → badge delta-follow.
**openclicky files**:
- `OpenClickyPickElementOverlay.swift` (~14KB)
- `OpenClickyAnnotationBadgeOverlay.swift` (~26KB)
- `OpenClickyAXFollower.swift`
- `OpenClickyContextHotkeys.swift` (AgentPickElement case)
- `CompanionManager.swift` (wire AnnotationBadgeOverlay)
**Everywhere files**:
- `Mac/Interop/VisualElementContext.Picker.cs` (38 lines)
- 9 wowdd1 `feat(annotation)` commits (badge / textarea / ✓ persistence / multi-pin / follow-on-scroll / extend to whiteboard+linkrect / delta-follow-model)

### 🟡 依赖上游功能, 需晚 review

#### F26 — Codex agent 集成 (config + spawn)
**功能**: Codex `config.toml` 里 `[mcp_servers.sensor]` block 挂载 + `RouteDispatcher` spawn codex 时的 workdir precedence (route.workdir → preflight.selectedFolder → ephemeral).
**openclicky files**:
- `ClickyCodexConfigTemplate.swift`
- `CodexHomeManager.swift`
- `OpenClickyRouteDispatcher.swift`
- `CompanionManager.startVoiceAgentTaskPlan()`
**Everywhere files**: 无 1:1 (openclicky-specific, verify sensor endpoint URL + token 正确)
**依赖**: F15 (sensor endpoint) 完成

#### F27 — Dialog model preflight + ROUTE emit/parse
**功能**: Fable (via `/chat-tool-call`) preflight prepend 5 项 minimal context + system prompt 教 `[ROUTE]` JSON emit + reply parse + Fable text-only (无 tool loop 假设).
**openclicky files**:
- `HeyClickyChatToolCallClient.swift` (`buildPreflightContext` + `formatPreflightBlock` + `contextAwarenessDirectiveBlock` + `parseRouteJSON` + `RouteParseResult`)
**Everywhere files**: 无 (openclicky-specific)
**依赖**: F01/F02/F03/F04/F05 完成 (preflight 用 capture)

#### F28 — 端到端集成 (hotkey → stash → hook → Claude Code)
**功能**: 用户按 SnapshotContext → openclicky 采 → 写 `context-stash.json` → 激活 cmux → LaunchPhrase → cmux 里 Claude Code 触发 hook → hook 读 stash → injection `additionalContext`.
**依赖**: F19 (writer + hook) + F20 (activator) + F22 (hotkey binding) 全完
**openclicky files**: 无新 file, 只是 flow 集成验证
**Everywhere files**: 同 F19/F20 上游

---

## Everywhere 生态 (必移植, 非可选)

Everywhere 3rd/ 里 vendor 的 3 个上游, openclicky 也要有:

#### F29 — open-connector 集成 (`oomol-lab/open-connector`, 831 provider)
**功能**: SaaS API gateway. Node subprocess 跑 open-connector CLI + 本地 HTTP loopback + OAuth 回调 HTTP server (openclicky 复用 `HeyClickyChromeBridgeServer` 端口模式) + 本地加密 credential store (AES + Keychain).
**openclicky files (已建, 2026-07-23 — Phase 7.5 F29 landing)**:
- `cursor-buddy/OpenClickyConnectorSubprocess.swift` — Node subprocess lifecycle (start / stop / crash-restart / READY-line handshake / bearer-token HTTP wrapper).
- `cursor-buddy/OpenClickyConnectorOAuthCallback.swift` — loopback HTTP OAuth callback on random port `[54000, 55000)`; validates `state` against in-memory pending map (10 min TTL).
- `cursor-buddy/OpenClickyConnectorCredentialStore.swift` — macOS Keychain (`kSecClassGenericPassword`, service `com.jkneen.openclicky.connector.<providerId>`, account `<connectionId>`, JSON-encoded value).
- `cursor-buddy/OpenClickyConnectorSettings.swift` — UserDefaults master toggle `openclicky.connector.enabled` + Node-path override + provider allow/disallow lists.
- `cursor-buddy/OpenClickyConnectorBridgeTools.swift` — 6 MCP tool implementations + descriptors matching `ConnectorTools.cs` byte-for-byte.
- `AppResources/OpenClicky/OpenConnectorRuntime/{boot.js, config.json, UPSTREAM_SHA, README.md}` — Node entry + seeded manifest (github + no_auth_demo). Full 831-provider bundle deferred.
- `cursor-buddy/OpenClickyExternalControlBridge.swift` — patched: 6 tool names registered in `sensorToolNames`, domain-mapped in `sensorToolDomains`, descriptor blobs appended to `sensorToolDescriptorsRaw`, dispatched in `executeSensorTool`.
- `cursor-buddy/cursor_buddyApp.swift` — `applicationDidFinishLaunching` autostart + `applicationWillTerminate` cleanup.
- `cursor-buddyTests/OpenClickyConnectorCredentialStoreTests.swift` — Keychain round-trip / normalization / named-connection isolation tests.

**Everywhere files**:
- `Everywhere/3rd/open-connector/` (upstream pin `847efc10cdff5d6c50b9905ac05c663246f70684`, recorded in `AppResources/OpenClicky/OpenConnectorRuntime/UPSTREAM_SHA`)
- `Everywhere/src/Everywhere.Mcp/Tools/ConnectorTools.cs` (6 tool signatures — mirrored in `OpenClickyConnectorBridgeTools.descriptorsRaw`)
- `Everywhere/src/Everywhere.Mcp/Connector/` (ClearScript V8 wrapper — replaced with Node subprocess)
- `Everywhere/docs/specs/everywhere-connector.md` (12-phase reference)

**Documented deviations**:
1. ClearScript V8 → Node subprocess (Swift lacks first-class V8; JSC missing `fetch` + Node primitives).
2. JSON credential file → macOS Keychain (Everywhere Phase 6 target reached one release early).
3. Bundled Node binary (~40MB) → system Node via `brew install node` + 5-path auto-discovery.
4. Full 831-provider bundle deferred; POC ships seeded manifest (github + no_auth_demo) so all 6 MCP tools are exercisable end-to-end (matches Everywhere Phase 1 POC intent).

#### F30 — OpenCLI 站点适配器 (`jackwener/opencli`, 171 站点 / 1257 adapters)
**功能**: 浏览器操纵任意登录网站 (12306 / bilibili / 淘宝 / 51job 等中国区 + 无公开 API 站点). Node subprocess + pipeline interpreter + fuzzy site list. Browser-strategy adapters gated on OpenDia (F31).
**openclicky files (已建, 2026-07-23 — Phase 7.6a F30 landing)**:
- `cursor-buddy/OpenClickyOpenCLISubprocess.swift` — Node subprocess lifecycle (port `[55000, 56000)`, env `OPENCLICKY_OPENCLI_TOKEN`, `READY <port>` handshake). Reuses F29's `resolveNodePath()` static.
- `cursor-buddy/OpenClickyOpenCLIBridgeTools.swift` — 3 MCP tool descriptors (`opencli_list` / `opencli_describe` / `opencli_run`) + dispatch, byte-for-byte with `OpenCliTools.cs` envelopes.
- `cursor-buddy/OpenClickyOpenCLISettings.swift` — master toggle `openclicky.opencli.enabled` (default false), env force `OPENCLICKY_MCP_OPENCLI=1`.
- `AppResources/OpenClicky/OpenCLIRuntime/boot.js` — HTTP loopback + bearer token; routes `/list`, `/describe`, `/run`, `/health`; inline pipeline interpreter (fetch/limit/map/filter/select/sort).
- `AppResources/OpenClicky/OpenCLIRuntime/opencli/` — vendored `clis/` + `runtime/` + `cli-manifest.json` (9.3MB).
- `AppResources/OpenClicky/OpenCLIRuntime/UPSTREAM_SHA` — pinned OpenCLI SHA (`9161d99d96ec107cd77f13a30315614129179a1a`, tag `v1.8.5`).
- `AppResources/OpenClicky/OpenCLIRuntime/README.md` — runtime contract + install notes.
- Bridge wire-up (4-point pattern, mirror F29): `sensorToolNames` (3 names), `sensorToolDomains` (all → `core`), `sensorToolDescriptorsRaw` (`+ OpenClickyOpenCLIBridgeTools.descriptorsRaw`), `executeSensorTool` switch case.
- Autostart in `cursor_buddyApp.applicationDidFinishLaunching`; stop in `applicationWillTerminate`.
- Xcode: `OpenCLIRuntime` added to "Copy OpenClicky App Resources" ditto list.

**Deviations from Everywhere** (documented in `docs/ROADMAP/.impl-notes/phase7-6a-opencli-2026-07-23.md`):
- ClearScript V8 isolate → Node subprocess (matches F29 rationale).
- 171 sites (not 173) — upstream includes `_atlassian` / `_shared` private modules which the manifest loader filters out.
- Independent subprocess from F29 — separate binary, port range, auth token, no shared state (crash isolation).
- Full pipeline runner (`opencli/runtime/`) not executed by `boot.js` in this POC — minimal inline interpreter for `public`-strategy `fetch`-based adapters; browser-strategy adapters return `BROWSER_NOT_READY` until F31 lands.

**Everywhere files (source of truth)**:
- `Everywhere/3rd/opencli/` @ pin `9161d99d96ec107cd77f13a30315614129179a1a` (v1.8.5)
- `Everywhere/src/Everywhere.Mcp/OpenCli/` (runtime + observation)
- `Everywhere/src/Everywhere.Mcp/Tools/OpenCliTools.cs`
- `Everywhere/src/Everywhere.Mcp/Tools/{Search,Analysis,Generator}Tools.cs` (adapter tools)
- `Everywhere/docs/specs/everywhere-opencli-adapters.md` (27KB)

#### F31 — OpenDia 浏览器底盘 (`aaronjmars/opendia` MIT, 120 `browser_*` MCP tools)
**功能**: Chrome / Firefox extension + Node HTTP shim + WebSocket bridge to extension. 120 `browser_*` MCP tools (see `Everywhere/docs/specs/PARITY_MATRIX.md`, ownership=`opendia` OR `universal`). Task brief mentioned "85" — that's the opendia-only subset; the extra 15 `universal` tools are still routed through the extension.
**openclicky files (已建, 2026-07-23 — Phase 7.6b F31 landing)**:
- `cursor-buddy/OpenClickyOpenDiaSubprocess.swift` — Node subprocess manager (mirrors F29/F30 shape). HTTP loopback for Swift; the Node process fans requests out to the extension over WS.
- `cursor-buddy/OpenClickyOpenDiaBridgeTools.swift` — 120 `browser_*` MCP tool descriptors + prefix-based dispatch (single generic executor, one dispatch case per tool would be ~4000 lines).
- `cursor-buddy/OpenClickyOpenDiaSettings.swift` — master toggle `openclicky.opendia.enabled` (default false), env force `OPENCLICKY_MCP_OPENDIA=1`, runtime status.
- `AppResources/OpenClicky/OpenDiaRuntime/boot.js` — HTTP + WS boot entry; bearer auth via `OPENCLICKY_OPENDIA_TOKEN`; port range `[56000, 57000)`.
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/` — vendored MIT upstream server (`server.js` + `package.json` + `LICENSE`).
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md` — sideload install pointer to upstream releases zips (extension source itself is not bundled — it ships as an 11 MB pre-built zip upstream; users install it once).
- `AppResources/OpenClicky/OpenDiaRuntime/UPSTREAM_SHA` — pinned upstream commit.
- `AppResources/OpenClicky/OpenDiaRuntime/README.md` — architecture + install steps.
- Bridge extend (4 points in `OpenClickyExternalControlBridge.swift`): 120 names in `sensorToolNames`; 120 rows in `sensorToolDomains` -> `OpenClickyMetaDomain.browser`; 120 descriptor rows via `OpenClickyOpenDiaBridgeTools.descriptorsRaw`; `executeSensorTool` prefix-match dispatch.
- Autostart wire in `cursor_buddyApp.swift` (add `OpenClickyOpenDiaSettings.autostartIfEnabled()` and stop in `applicationWillTerminate`).
- Xcode: `OpenDiaRuntime` added to the "Copy OpenClicky App Resources" ditto script.

**Deviations from Everywhere**:
- .NET `System.Net.WebSockets` server (Everywhere `OpenDiaBridge.cs`, port 5555) → Node `ws` module fronted by Node HTTP shim, so Swift can keep the same HTTP-plus-bearer pattern as F29/F30. Same rationale as F29 (no ClearScript / no in-process JS engine).
- Independent Node process (different port range, different auth token, different binary). F31 needs the `ws` npm dependency; F29 doesn't; F30 doesn't. Sharing one process would either bloat F29/F30's dependency graph or force us to bind three separate stacks in one boot.js — not worth the coupling.
- All 120 tools are pre-registered on `tools/list`. Tools not implemented by the connected extension version return `{ok:false, code:"UNKNOWN_TOOL", ...}` — matches Everywhere's `OpenDiaBridge` behavior when the extension registers a smaller `AvailableTools` set.
- `opendia_smoke_check` (an Everywhere-side sanity ping) is exposed as `browser_health` on the Node HTTP shim rather than registered as an MCP tool; the existing `sensor_health` tool covers that role for MCP clients.
**Everywhere files**:
- Everywhere 用 `hhsw2015/opendia experiment/replace-ab` fork (WS layer)
- `Everywhere/src/Everywhere.Mcp/OpenDia/` (OpenDiaTool.cs + OpenDiaToolSync.cs + OpenDiaToolListBuilder)
- Local upstream at `/Users/wowdd1/Dev/opendia/` (aaronjmars MIT 参考)
- `Everywhere/docs/specs/everywhere-replace-agent-browser.md` (26KB)
- `Everywhere/docs/specs/opendia-cebian-merge.md` (21KB)
- `Everywhere/docs/specs/PARITY_MATRIX.md` (85 WS ops 完整表)

## 长尾 MCP tool (必移植, 非可选)

#### F32 — Chat bus (`chat_create/delete/list/read/send/subscribe`)
**功能**: 6 chat_* MCP tool + long-poll HTTP endpoint (daemon-side chat 消息队列)
**Everywhere files**:
- `Everywhere.Mcp/Tools/ChatBusTools.cs`
- `feat(mcp): phase 4 daemon-side chat bus — 6 chat_* MCP tools + long-poll` commit

#### F33 — Adapter authoring (`adapter_scaffold/lint/verify/save/regenerate/delete_local/list_local/drift_check`)
**功能**: 8 adapter_* MCP tool — 让 agent 扩展 OpenCLI 适配器 (self-expanding)
**Everywhere files**:
- `Everywhere.Mcp/Tools/GeneratorTools.cs` (adapter_scaffold / regenerate)
- `Everywhere.Mcp/Tools/AnalysisTools.cs` (adapter_lint / verify / drift_check)
- `Everywhere.Mcp/Tools/GateTools.cs` (adapter_save / delete_local / list_local)
- `Everywhere.Mcp/OpenCli/Adapter/` (存储 + drift)

#### F34 — Web tools (`web_search/fetch_url/js_search/js_fetch_same_origin/crypto_scan/signature_scheme/sourcemap_list_candidates/sourcemap_resolve/techstack/verdict_score`)
**功能**: 10 web_* MCP tool — web scraping / research 辅助
**Everywhere files**:
- `Everywhere.Mcp/Tools/WebSearchTool.cs`
- `Everywhere.Mcp/Tools/{ConnectorTools,SearchTools,AnalysisTools}.cs` 里的 web_* 分支

#### F35 — Page rules (`page_extract_by_rule/save_extraction_rule`)
**功能**: 用户教 agent 抽取规则 + 复用
**Everywhere files**:
- `Everywhere.Mcp/Tools/AnalysisTools.cs`

#### F36 — Capture recording (`capture_start/stop/current/export`)
**功能**: 会话录制 + 回放 + 导出
**Everywhere files**:
- `Everywhere.Mcp/Tools/CaptureTools.cs` (18.6KB)

## Review 波次扩展

**Wave R5 (5 agent)**: F29-F31 生态 + F32-F36 长尾 tool
**Wave R6 (原 R4 后置)**: F26-F28 集成层

---

## 并行 review 波次

**Wave R1 (13 agent 并行, 完全独立)**:
- F01 应用/窗口枚举
- F02 Element 感知
- F03 SelectedText
- F04 Browser URL/Tabs
- F05 Finder
- F06 Terminal
- F07 Clipboard
- F08 Screenshot
- F09 OCR
- F10 IdleTime
- F11 Permission
- F12 AXQuirks
- F13 InputSimulator

**Wave R2 (7 agent 并行)**:
- F14 Stashes (Pick / Annotation / Whiteboard)
- F15 MCP bridge + 43 tool
- F16 Memory
- F17 Meta + Self-expanding + BM25
- F18 Doc readers
- F19 Stash writer + Hook + Redaction
- F20 AppActivator + LaunchPhrase

**Wave R3 (5 agent 并行)**:
- F21 KnownApps discovery
- F22 Hotkey + Settings + Everywhere defaults
- F23 Whiteboard drawing UX
- F24 LinkRect harvest UX
- F25 PickElement + Annotation ➕ + delta-follow

**Wave R4 (3 agent, 依赖上面 done)**:
- F26 Codex agent 集成
- F27 Dialog model preflight + ROUTE
- F28 端到端集成 (最后)

**总 28 review agent, 分 4 wave**.

---

## Review 输出规范

每功能产出 `.review-notes/<Fxx>-<feature-name>-2026-XX-XX.md`:

```markdown
# Review F<xx>: <feature name>

**Everywhere pin**: 30e03e9d
**openclicky files**: <list>
**Everywhere files**: <list>
**Reviewer**: agent <id>
**Date**: 2026-XX-XX

## Alignment Table

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Function X | ... | ... | ✅ | |
| Constant Y | 200 | 200 | ✅ | |
| Behaviour Z | ... | ... | ⚠️ | intentional deviation |
| Semantic W | ... | ... | ❌ | REAL BUG |

## Issues Found

- **CRITICAL/HIGH/MEDIUM/LOW**: <description> → <recommended fix>

## Verdict

- [ ] BYTE_MATCH — Swift port is byte-equivalent modulo language syntax
- [ ] SEMANTIC_MATCH — logic identical, some Swift idiomatic reshaping OK
- [ ] DIVERGENT — has intentional deviations documented in file header
- [ ] BROKEN — real bug, needs fix before ship

## Recommendations

<if BROKEN or CRITICAL/HIGH issues: prioritized fix list>
```

## Review 严禁

- 信 doc 里的声明 (可能 stale)
- 信 test coverage 数字 (可能测的是错误行为)
- 信 impl-notes 里的宣称 (agent 自报可能过 rosy)

**只信 code**: Everywhere `.cs` 源 vs openclicky `.swift` 源 side-by-side.
