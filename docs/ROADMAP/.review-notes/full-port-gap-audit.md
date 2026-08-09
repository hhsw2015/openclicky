# OpenClicky vs Everywhere: Full Port Gap Audit
Everywhere ref @ 30e03e9dcfdd4247fd679828ed86e9042f32d809
Scope (per coordinator update): context-sensing + MCP surface only.

## 1. Whiteboard subsystem

Everywhere source: `Everywhere.Mcp/Whiteboard/AnnotationSnapper.cs` (881), `Whiteboard/WhiteboardParser.cs` (367), `Whiteboard/HybridSlicer.cs` (214), `Everywhere.Mcp/WhiteboardHotkeyInitializer.cs` (1410), `Everywhere.Core/Interop/Whiteboard/*` (SnapResult/Stroke/WhiteboardRegion/WhiteboardStash, 676).

OpenClicky counterpart: `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift` (784), `cursor-buddy/OpenClickyWhiteboardStrokeClassifier.swift` (366), `Packages/OpenClickyContextService/.../Capture/WhiteboardStash.swift` (257).

Coverage: about 30 percent. Overlay draw and OCR-plus-nearest-line are ported; the actual AX-leaf snapping engine is not.

MISSING items:
- `AnnotationSnapper` type in full: `Snap`, `SnapArrow`, `SnapUnderline`, `SnapCircleOrX`, `LeafAtPoint`, `NearestLeaf`, `TightenLeafToTip`, `DescendantsInRect`, `LeafTextRoles` / `LeafTextOrImageRoles`, `IdentifyArrowTip`, `StrokeEndpoints`, `PrewarmedTree.Build/QueryRect`.
- `HybridSlicer.Slice` (multi-line a11y leaf slicing with OCR y-anchors; `OcrReliabilityRatio`, `LogicalLineMergeThreshold`).
- `WhiteboardParser.ParseGrouped` output contract (annotations + strokeGroups 1:1) — the Swift classifier returns gestures but not stroke groups tied to each annotation.
- `WhiteboardHotkeyInitializer` prewarm task (`AnnotationSnapper.PrewarmedTree.Build` on overlay-show, 8s safety bound await on commit), `_sessionFocusedRoot` cache across Continue presses.
- `CollectImageLeaves` (session-wide `sessionImageCount` / `sessionImageBytes` caps for Circle/X over image leaves).
- `TryFallbackRegionImage` (region-crop fallback when snap yields no leaves).
- `RunOcrForRegion` (OCR restricted to region rect, used to feed HybridSlicer).
- Snap diagnostics / `snapTrace` List<(Annotation,SnapResult)>.
- `WhiteboardElementExtensions` (Root(), enumerate descendants with rect intersect).

Impact: every whiteboard commit skips a11y entirely and returns only nearest-OCR-line text, so `read_whiteboard` cannot deliver the leaves/images/text triple the LLM expects.

## 2. LinkRect subsystem

Everywhere source: `Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs` (608), `Everywhere.Mcp/LinkRectHotkeyInitializer.cs` (178).

OpenClicky counterpart: `cursor-buddy/OpenClickyLinkRectHarvester.swift` (406), `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` (658), harvest wired into `OpenClickyContextHotkeys` and `OpenClickyContextStashWriter.captureLinks`.

Coverage: about 75 percent.

MISSING items:
- `EnumerateRescueCandidates` and `TryExtractHttpUrl` (javascript: rescue path, `_httpUrlRegex`, `_githubAtRegex` github @mention -> profile URL rescue).
- `AncestorRowText` (ancestor row aggregation for anchor titles in table-of-links).
- `ExtractAllHttpUrls` (multi-URL split from a single AX text node).
- `DumpEnabled` / `_walkDump` diagnostic stream (nonessential but Everywhere ships it).
- `HighlightCapturedLinks` is present in overlay but ties into `LinkRectSession`; verify aqua-flash rectangles fire per Everywhere `ScreenSelectionWindow.cs:124-127`.

## 3. PickElement / VisualElementContext

Everywhere source: `Everywhere.Mac/Interop/VisualElementContext.Picker.cs` (38), `VisualElementContext.cs` (145), `VisualElementContext.TextSelection.cs` (416), `Everywhere.Mac/Interop/ScreenSelectionSession.cs` (446), `Everywhere.Mcp/Tools/PickElementTool.cs` (85).

OpenClicky counterpart: `cursor-buddy/OpenClickyPickElementOverlay.swift` (506), `Capture/ElementUnderCursorCapture.swift` (258).

Coverage: about 45 percent.

MISSING items:
- Screen/Window/Element mode switch (Everywhere `ScreenSelectionMode.Screen|Window|Element` cycled with Tab; OpenClicky is Element-only).
- `pick_element` MCP tool (`PickElementTool.cs`) never registered on `OpenClickyExternalControlBridge.swift` tools/list or dispatch — an agent cannot request pick over MCP; only the local hotkey pick works.
- Full name cascade at pick time: overlay reads only `kAXRole/Title/Value/Position/Size` (`OpenClickyPickElementOverlay.swift:322-436`). Missing AXDescription / AXHelp / AXTitleUIElement / AXStaticText-child / AXIdentifier fallback that `AXUIElement.Name` executes at Everywhere `AXUIElement.cs:257-315`.
- Subrole and secure-field guard on the picked element (present in FocusedElementCapture but not in PickElement capture).
- Badge overlay wiring on pick success (present in `OpenClickyAnnotationBadgeOverlay.swift` but pick side only fires `PickStash.set`, no explicit anchor-badge fanout).

## 4. Annotation stash + Pin manager

Everywhere source: `Everywhere.Core/Interop/AnnotationStash.cs` (266), `Everywhere.Core/Interop/Whiteboard/Annotation.cs` + `AnnotationKind.cs`, `Everywhere.Core/Views/Annotation/AnnotationOutlineWindow.cs`, `AnnotationOverlayWindow.cs`, `Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs` (12.5K).

OpenClicky counterpart: `Packages/OpenClickyContextService/.../Capture/AnnotationStash.swift` (315), `cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift` (901).

Coverage: about 80 percent for the queued-note surface, but the stash-to-writer bridge is stubbed.

MISSING items:
- `OpenClickyContextStashWriter.captureCoreAsync` leaves `annotations` at `nil` and skips `AnnotationStash.peek`/`consume` on manual capture (lines 206-208, 269-271 explicitly TODO). So `annotations[]` never lands in the ctx envelope even when items are queued.
- Same file leaves `pinPending`/`whiteboardPending`/`whiteboardRegionCount` at `nil` (lines 182-184) — `PickStash.peek` and `WhiteboardStash.peek` are not consulted at stash-write time. Auto-capture from whiteboard commit calls `captureAsync()` but the writer does not read those stashes.
- Nothing wires `PickStash.Pinned` event into the writer — no analogue of `AutoCaptureService.TryCapture(IVisualElement)` (Everywhere `AutoCaptureService.cs`). Whiteboard commit does fire a manual capture; pin does not.

Impact: pins and whiteboard regions produce hint text but not the structured `pin_pending`/`whiteboard_pending`/`annotations` fields. Downstream MCP clients that read the JSON envelope get partial data.

## 5. AX walker

Everywhere source: `Everywhere.Mac/Interop/AXUIElement.cs` (1434) — full `IVisualElement` tree with role, subrole, name cascade, bounds, states, actions, `Children`/`Rows`/`VisibleChildren` fanout, `Root()`.

OpenClicky counterpart: `Capture/SemanticExtractor.swift` (653), `Capture/FocusedElementCapture.swift` (482), `Capture/FocusedWindowCapture.swift` (287), `Capture/ElementUnderCursorCapture.swift` (258).

Coverage: about 35 percent of the walker surface.

MISSING items:
- No general recursive descendant walker (no `func walk`, no `DescendantsInRect`, no `IndexedNode`). Everywhere's `ElementIndexer.Walk` produces a flat indexed array consumed by SnapshotRenderer, SnapshotElideRules, SnapshotMergeRules, SnapshotActionFilter, TreeJsonBuilder — none of which exist on our side.
- No `PrewarmedTree` cache; every AX access is live (SemanticExtractor documents the trade-off but the consequence is that whiteboard/pick paths cannot amortise walks).
- No `AXRows`/`AXVisibleChildren` fan-out for table-like roles (`AXUIElement.cs:32-100`). OpenClicky reads only `AXChildren`, so pins landing on `AXOutline`/`AXList`/`AXTable`/`AXBrowser` skip row content.
- No node-budget / depth-timeout enforcement on any walker other than the LinkRect harvester's 50k / 60-depth budget.
- No `Root()` traversal (parent chain to `AXApplication`), used by Whiteboard `focusedRoot ??= FocusedElement.Root()`.

## 6. ContextStashWriter

Everywhere source: `Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (1178), plus `Snapshot/AutoCaptureService.cs` (107), `Snapshot/SelectionCache.cs`, `Snapshot/AppKey.cs`.

OpenClicky counterpart: `cursor-buddy/OpenClickyContextStashWriter.swift` (676), `Packages/OpenClickyContextService/.../Stash/OpenClickyContextSnapshotPayload.swift` (464), `Stash/OpenClickySanitiser.swift` (153).

Coverage: about 60 percent.

MISSING items:
- Stash-side reads gated to TODO (see item 4): `PickStash`, `WhiteboardStash`, `AnnotationStash` never consulted at write time. Everywhere reads all three in `CaptureCoreAsync`.
- No `AutoCaptureService` analogue — no `PickStash.Pinned` event -> writer.captureAsync(seed) subscription; auto-capture on pin is not implemented (auto-capture on whiteboard commit *is*, from the overlay directly).
- `CaptureAsync(IVisualElement seed)` overload (`ContextStashWriter.cs:115`) is absent — the Swift port only has `captureAsync()` and `captureLinks([...])`.
- Launch phrase / agent activator: present on Swift side (`activateAgentAndFirePhrase`) but `AppActivator` is a much thinner port than Everywhere's `MacAppActivator.cs`.

## 7. Screenshot subsystem

Everywhere source: `Everywhere.Mac/Interop/VisualElementContext.Screenshot.cs` (213), `Everywhere.Mcp/Snapshot/ScreenshotEncoder.cs` (125).

OpenClicky counterpart: `Packages/OpenClickyContextService/.../Capture/ScreenshotCaptureEverywhere.swift` (381).

Coverage: about 90 percent. Reviewed at F08.

MISSING items:
- Everywhere's shared bitmap (`CaptureAsync` returns a bitmap reused for whiteboard OCR + snapshot) is fused into a single call site; the OpenClicky whiteboard overlay re-captures via `ScreenshotCaptureEverywhere.captureRegion` per gesture (`OpenClickyWhiteboardOverlayWindow.swift:686`). Duplicate captures cost latency but do not break output.

## 8. OCR engine

Everywhere source: `Everywhere.Mac/Interop/MacVisionOcrEngine.cs` (120).

OpenClicky counterpart: `Packages/OpenClickyContextService/.../Capture/OCRCapture.swift` (159).

Coverage: about 85 percent.

MISSING items:
- Everywhere exposes `IOcrEngine` with a quality selector (Fast vs Accurate). Swift port pins Fast only.
- No `RunOcrForRegion` helper that pipes an already-captured shared bitmap plus a region rect into Vision. The whiteboard overlay captures fresh every gesture (see item 7).

## 9. Snapshot pipeline

Everywhere source: `Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs` (160), `Snapshot/SnapshotRenderer.cs` (12.2K), `Snapshot/TreeJsonBuilder.cs`, `Snapshot/SnapshotElideRules.cs`, `Snapshot/SnapshotMergeRules.cs`, `Snapshot/SnapshotActionFilter.cs`, `Snapshot/StashPaths.cs`.

OpenClicky counterpart: `cursor-buddy/OpenClickyContextHotkeys.swift` (533), `cursor-buddy/OpenClickyContextStashWriter.swift`, `Stash/OpenClickyContextSnapshotPayload.swift`.

Coverage: envelope 70 percent, tree-render 5 percent.

MISSING items:
- No `SnapshotRenderer` port — Everywhere renders the walked IndexedNode array into agent-facing markdown with elide/merge rules. Not just a formatter: it drives the `element` field in `read_pick` and other tools.
- No `TreeJsonBuilder` port. `include_tree_json` in `read_pick` returns a single-node encoded PickedElement instead of the walked-tree JSON that Everywhere returns (documented divergence in `F17-meta-tools-2026-07-23.md`).
- No `SnapshotElideRules` / `SnapshotMergeRules` — noise stays in the payload.
- No `SnapshotActionFilter.Filter`; `FocusedElementCapture` reimplements a subset inline.
- `SnapshotContextHotkeyInitializer` glue: OpenClicky's `OpenClickyContextHotkeys` handles all five hotkeys uniformly; parity check needed for the 1500ms repeat-suppression, 180ms modifier-release delay (both present per file headers).

## 10. MCP server surface

Everywhere source: 53 `*Tool.cs` files under `Everywhere.Mcp/Tools/` (6277 lines total).

OpenClicky counterpart: `cursor-buddy/OpenClickyExternalControlBridge.swift` (181K, tools/list + tools/call dispatch), plus per-domain bridge tool files.

Coverage: about 55 percent of the tool count, but the missing ones include the whole stash/annotation/input surface.

MISSING (no case in the bridge's tools/list nor tools/call switch):
- `read_pick` (`ReadPickTool.cs`) — the *primary* deictic-reference tool. `OpenClickyStashTools.readPick` exists in the service package but is not wired into `OpenClickyExternalControlBridge.mcpJSONRPCResponse` dispatch (confirmed by grep of the bridge file). MCP clients cannot invoke it.
- `read_whiteboard` (`ReadWhiteboardTool.cs`) — same story: implementation in `OpenClickyStashTools.readWhiteboard`, no bridge case.
- `read_whiteboard_image` — same.
- `add_annotation`, `read_annotations`, `clear_annotations` — implementations exist in `OpenClickyStashTools`, no bridge case.
- `pick_element` (`PickElementTool.cs`) — no impl, no bridge case.
- `type_text`, `press_key`, `scroll`, `click`, `drag`, `set_value`, `perform_secondary_action`, `expand_element` — Everywhere exposes these as MCP tools backed by `MacInputSimulator`. OpenClicky's `InputSimulator.swift` is the port of the mac impl (679 lines), but the MCP tools that wrap it are not registered in the bridge. Voice/agent input goes through `OpenClickyComputerUseRuntime`; MCP clients have no input surface.
- `get_app_context` (`GetAppContextTool.cs`) — bridge has `get_focused_context` but not the multi-app variant.
- `get_app_state` — missing.
- `analysis_*` tools (`AnalysisTools.cs`, 323 lines: web-analysis workflow) — no port.
- `search_*` tools (`SearchTools.cs`) — no port (bridge exposes `search_tools` for meta only).
- `native_tool_dispatcher` (`NativeToolDispatcher.cs`, 292) — no port.
- `app_resolver` / `element_resolver` — no port.
- `ScreenshotTool.cs` — bridge exposes `screenshot`, coverage is OK.

## 11. Hotkey initializer glue

Everywhere: `SnapshotContextHotkeyInitializer.cs`, `LinkRectHotkeyInitializer.cs`, `WhiteboardHotkeyInitializer.cs`, `ClearContextStashHotkeyInitializer.cs` — one initializer per hotkey.

OpenClicky counterpart: `OpenClickyContextHotkeys.swift` (533) — one CGEvent tap dispatches all five.

Coverage: 90 percent. Bindings, repeat-suppression, modifier-release delay all match. LinkRect and Whiteboard drag lifecycle is handled by the overlay windows themselves. Alt+S / Alt+D / Alt+L / Alt+C / Shift+Space are all seeded.

MISSING items:
- Whiteboard hotkey's Continue-session model (`WhiteboardHotkeyInitializer.cs:378`, "ContinueSession" from CommitKeyModifiers) — OpenClicky's overlay comment mentions second-press-commits but the session focused-root cache is absent (item 5).

## 12. KnownApps / DiscoverURL

Everywhere: `Everywhere.Core/Configuration/Settings/McpServerSettings.cs` `KnownApps` list; consumed in `ContextStashWriter.cs:682, 759`.

OpenClicky counterpart: `Packages/OpenClickyContextService/.../Stash/OpenClickyContextSnapshotPayload.swift` (`OpenClickyKnownAppRule`, `resolveDiscoveryUrl`, `toStatePath`).

Coverage: 100 percent for lookup + state-path derivation. Settings surface is present in `OpenClickyContextAwarenessSettings.swift` with default seed. Fully ported.

---

## Severity ranking

### CRITICAL
1. **Whiteboard AX-leaf snap engine (item 1).** `AnnotationSnapper`, `HybridSlicer`, `PrewarmedTree`, `CollectImageLeaves`, `TryFallbackRegionImage` all absent. Whiteboard is currently OCR-only; the whole "a11y leaves + image leaves + slice" pipeline that makes `read_whiteboard` useful is not ported.
2. **MCP bridge does not expose stash tools (item 10).** `read_pick`, `read_whiteboard`, `read_whiteboard_image`, `add_annotation`, `read_annotations`, `clear_annotations`, `pick_element` are implemented in `OpenClickyStashTools` but the JSON-RPC dispatch in `OpenClickyExternalControlBridge` has zero cases for them. MCP agents cannot reach the stash.
3. **ContextStashWriter never reads PickStash / WhiteboardStash / AnnotationStash (items 4 and 6).** The `pin_pending`, `whiteboard_pending`, `whiteboard_region_count`, and `annotations` envelope fields stay `nil` in production. Pinning + writing produces a hint but no structured payload.

### HIGH
4. **No `AutoCaptureService` / `PickStash.Pinned` event (item 6).** Pin action does not trigger an auto-capture in the way Everywhere does; only whiteboard commit does.
5. **Input-simulator MCP tools not registered (item 10).** `type_text`, `press_key`, `click`, `scroll`, `drag`, `set_value`, `expand_element`, `perform_secondary_action` are absent from the bridge. Full input surface exists internally but is not addressable over MCP.
6. **No general AX walker / `IndexedNode` array (item 5).** Blocks any full-tree tool: `SnapshotRenderer`, `TreeJsonBuilder`, node-level analysis in `read_pick`.

### MEDIUM
7. **PickElement name cascade truncated (item 3).** Only role/title/value/position/size captured; Everywhere reads six more attributes and children.
8. **`AXRows`/`AXVisibleChildren` fanout missing (item 5).** Pin on Outline/List/Table/Browser roles yields incomplete children.
9. **LinkRect `javascript:` + github @mention rescue paths (item 2).**
10. **No SnapshotRenderer/TreeJsonBuilder (item 9).** `include_tree_json` in `read_pick` diverges from Everywhere.
11. **PickElement mode switch (Screen/Window/Element) absent.**

### LOW
12. **Screenshot capture is per-gesture, not shared-bitmap (item 7).**
13. **OCR quality selector fixed to Fast (item 8).**
14. **LinkRect walk-dump diagnostic absent (item 2).**
15. **`get_app_context` and `get_app_state` MCP tools not in bridge (item 10).**

## Second-pass additional gaps

Complement to the sections above. Coordinator patch is landing the 5 CRITICAL/HIGH items already found. Everything below is NEW and was not surfaced in the first pass.

### 13. Input-simulator MCP tools — full list is longer than first-pass report

Severity: **HIGH** (extends first-pass item 5)

The first pass named `type_text / press_key / click / scroll / drag / set_value / expand_element / perform_secondary_action` but only cross-referenced against a couple of dispatch chains. A machine diff of Everywhere's `[McpServerTool(Name="…")]` set (`Everywhere.Mcp/Tools/*.cs`) against every quoted literal in `OpenClickyExternalControlBridge.swift` confirms ALL EIGHT are absent as MCP tool names — no descriptor, no dispatch case:

Missing: `type_text`, `press_key`, `click` (as MCP tool — the string appears at bridge:1078 as a `/cursor` HTTP alias, not as an MCP `tools/call` case), `drag`, `scroll`, `set_value`, `expand_element`, `perform_secondary_action`.

Backing implementations exist: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/InputSimulator.swift` (26 KB, full port). Fix: add descriptors to `Self.mcpToolDescriptors` and wire eight cases in `executeSensorTool` — 15 minutes if you follow the existing `screenshot` pattern.

### 14. Clipboard write/read MCP tools missing

Severity: **HIGH**

`Everywhere.Mcp/Tools/ClipboardTools.cs:35-54` exports four: `clipboard_read`, `clipboard_paste`, `clipboard_write`, `clipboard_copy`. OpenClicky exports zero (`clipboard_copy` appears only as a `capabilities: […]` string label at `OpenClickyExternalControlBridge.swift:1528-1602`, never as a tool). Impl exists — `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ClipboardCapture.swift` (read) and `ClipboardWriter.swift` (write, 8.7 KB, byte-parity with `MacClipboardWriter.SetText`). No bridge case, no descriptor. Fix: same as item 13.

### 15. `get_app_context` / `get_app_state` missing

Severity: **MEDIUM** (first pass mentioned this in item 10 as a bullet but did not tag the actual tool file references)

`Everywhere.Mcp/Tools/GetAppContextTool.cs` (multi-app enumeration variant of get_focused_context) and `GetAppStateTool.cs` (agent-state URL fetcher for KnownApps) are unported. `KnownAppRule` resolver + `toStatePath` already ship in `OpenClickyContextSnapshotPayload.swift:253-315` so most of the mechanics are in place — but the MCP surface that turns them into an on-demand tool call is missing.

### 16. Web analysis tools (Everywhere `AnalysisTools.cs`) — 8 tools missing

Severity: **MEDIUM**

`Everywhere.Mcp/Tools/AnalysisTools.cs` (11 KB) registers eight `web_*` tools: `web_verdict_score`, `web_signature_scheme`, `web_techstack`, `web_js_search`, `web_crypto_scan`, `web_sourcemap_list_candidates`, `web_sourcemap_resolve`, `web_js_fetch_same_origin`. OpenClicky's `OpenClickyWebBridgeTools` covers only `web_search + web_fetch_url` (`OpenClickyExternalControlBridge.swift:3308-3310`). The eight adversarial-web-analysis tools that give Everywhere its "reverse-engineer the frontend" surface are entirely absent from the port.

### 17. Chat bus tools — 4 of 6 missing

Severity: **MEDIUM**

`Everywhere.Mcp/Tools/ChatBusTools.cs` registers six: `chat_send`, `chat_subscribe`, `chat_list`, `chat_read`, `chat_create`, `chat_delete`. `OpenClickyChatBusTools.swift:28-31` only exposes `chat_send` + `chat_subscribe` — the four channel-management tools (`chat_list / chat_read / chat_create / chat_delete`) are missing entirely, no impl and no bridge case. `OpenClickyChatBus.swift:71-126` only has `send` + `subscribe`, so this is a real impl gap not just an unwired surface.

### 18. `opendia_smoke_check` missing

Severity: **MEDIUM**

`Everywhere.Mcp/Tools/GeneratorTools.cs:390` registers `opendia_smoke_check` (verifies the OpenDia extension exposes every required browser tool the adapter authoring flow depends on). No `opendia_smoke_check` case anywhere in OpenClicky. This blocks the adapter-authoring loop from surfacing "your OpenDia install is missing tools X, Y, Z" cleanly.

### 19. `search_adapters`, `strategy_note_get`, `strategy_note_write`, `browser_captcha_present` missing

Severity: **LOW-MEDIUM**

- `SearchTools.cs:114` — `search_adapters` (BM25 over the OpenCLI adapter catalog). No swift port.
- `GeneratorTools.cs` — `strategy_note_get` / `strategy_note_write` (prewrite-a-plan-before-scaffolding gate). Referenced by adapter authoring flow docs but not implemented in swift.
- `CaptureTools.cs:274` — `browser_captcha_present` (OpenDia-forwarded check). No swift port.

### 20. Full envelope / hook binary — byte-parity CONFIRMED

Severity: **N/A** (report as verified, not a gap)

Cross-checked `Everywhere.Mcp/Snapshot/ContextStashWriter.cs:618-735` (FormatForHook) against `OpenClickyContextSnapshotPayload.swift:334-447` (formatForHook): 5-way hint priority order matches, all key names match, sanitiser caps match (title 80, url 256, selection 200, link title 120, link url 512, annotation body 800). Only intended diff is the `everywhere-*` -> `openclicky-*` prefix rebrand. Hook binaries (`tools/everywhere-context-hook/src/main.rs` vs `Packages/OpenClickyContextService/Sources/openclicky-context-hook/main.swift`): identical logic — TTL 5min, 64 KB payload cap, atomic claim rename, `[…-ctx] ` prefix check, `hookSpecificOutput` + `systemMessage` JSON shape.

### 21. Sanitiser caps — CONFIRMED byte-parity

Severity: **N/A** (verified)

`OpenClickySanitiser.swift:119-124` mirrors `_redactQueryParams` in `ContextStashWriter.cs:448-455` (17 entries, case-insensitive). `MaxClipboardUrlLen=2048` / `MaxClipboardLinks=200` / `MaxUrlLen=2048` / `MaxTitleLen=200` all match (`OpenClickyContextStashWriter.swift:333-334,519-521` vs `ContextStashWriter.cs:159-161,395-396`). Scheme allowlist `http | https | mailto` matches.

### 22. AX walker gaps beyond first pass — SetText / TryInvokeAction / GetSelectionText / SendShortcut / BoundingRectangleLive absent

Severity: **MEDIUM** (extends first-pass item 5)

`Everywhere.Mac/Interop/AXUIElement.cs:947,843,965,953,446` expose `SetText`, `TryInvokeAction`, `GetSelectionText`, `SendShortcut`, `BoundingRectangleLive`. OpenClicky's `AXVisualElement.swift` (Whiteboard-scoped, 268 lines) has none of them — it is read-only leaf-role snapshotting only. `InputSimulator.swift` fills in `SetText` semantics but only via CGEvent posting; the AX-attribute `SetText` path (used by Everywhere for TypeText-into-focused-textfield when CGEvent lands in the wrong field) is missing. `TryInvokeAction("AXPress")` / `SendShortcut` on a specific AX element are also missing — MCP `click` on an element-index route cannot fall back to AXPress if CGEvent misses.

### 23. `KnownApp` priority / regex-compilation cost — parity check

Severity: **N/A** (verified — no priority field in either)

`Everywhere.Core/Configuration/Settings/McpServerSettings.cs:15-18` — `KnownApp` has ONLY `TitlePattern` + `DiscoverUrl`. No priority. Swift port `OpenClickyKnownAppRule` (`OpenClickyContextSnapshotPayload.swift:210-218`) matches shape. First-match-wins order both sides. The audit briefing worried about a priority field — there is none to port.

### 24. UpstreamConstants — partial port

Severity: **LOW**

`Everywhere.Mcp/Snapshot/UpstreamConstants.cs` centralises 10 tunables. Swift port refers to `AccessibilityTreeMaxDepth = 64` and `SnapshotTextDefaultCharacterLimit = 500` inline (`SemanticExtractor.swift:51-74`) but there is no shared `OpenClickyUpstreamConstants` type. Values are duplicated across `SemanticExtractor.swift`, `InputSimulator.swift` (`maxUnitsPerChunk` 64 matches `MaxKeyboardUnicodeChunkLength`), and screenshot config — no central single-source. Refactor-scale gap, not correctness.

### 25. `SessionStore` / `AppSession` / `AppKey` / `ElementIndexer` / `IndexedNode` absent

Severity: **MEDIUM** (extends first-pass item 5/9)

`Everywhere.Mcp/Snapshot/SessionStore.cs` (63) + `AppSession.cs` (27) + `AppKey.cs` (41) + `ElementIndexer.cs` (239) implement the "epoch-stamped walked-tree cache keyed by app" that every element-index MCP tool call resolves against. Zero of the four types are in OpenClicky (`grep SessionStore /Users/wowdd1/Dev/openclicky/Packages/... /Users/wowdd1/Dev/openclicky/cursor-buddy/*.swift` → zero hits). Consequence: `read_pick` / `expand_element` / `perform_secondary_action` cannot resolve an `element_index` argument at all — they would have to walk from scratch every call. This is the missing spine behind first-pass item 9 (SnapshotRenderer/TreeJsonBuilder absent) — walked-tree + index cache go together.

---

## Second-pass summary (5-line worst)

1. **Input simulator has ZERO MCP tool surface (item 13).** Full `InputSimulator.swift` port exists (26 KB), but `type_text / press_key / click / scroll / drag / set_value / expand_element / perform_secondary_action` are all missing from `Self.mcpToolDescriptors` and `executeSensorTool` — MCP clients have no input path at all.
2. **Clipboard write/read MCP tools missing (item 14).** All four (`clipboard_read / clipboard_paste / clipboard_write / clipboard_copy`) unwired despite `ClipboardCapture.swift` + `ClipboardWriter.swift` shipping full impls.
3. **`SessionStore` / `AppSession` / `ElementIndexer` / `IndexedNode` never ported (item 25).** The epoch-stamped walked-tree index that resolves every `element_index` MCP argument is entirely absent — element-index-based tools cannot function.
4. **Chat bus is 4 of 6 tools short (item 17).** `chat_list / chat_read / chat_create / chat_delete` are missing at both the bus impl (`OpenClickyChatBus.swift` only has `send + subscribe`) and the MCP surface.
5. **8 web-analysis tools (item 16) + `opendia_smoke_check` (item 18) + `search_adapters / strategy_note_* / browser_captcha_present` (item 19) all missing.** The adversarial-web-analysis surface that lets Everywhere reverse-engineer frontend crypto / sourcemaps / signatures is entirely absent, and the adapter-authoring loop has no smoke-check tool.
