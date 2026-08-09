# Final port-completeness sweep

Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Scope: context-sensing + MCP only (input-simulator writes explicitly excluded).

Only lists items NOT already fully documented in `full-port-gap-audit.md`. Cross-checked
each pre-existing item against current tree; several are now stale.

## 0. Status of first-pass items (verified)

- item 4 / item 6 CRITICAL "envelope leaves `pin_pending / whiteboard_pending /
  whiteboard_region_count / annotations` at nil": **FIXED**. `OpenClickyContextStashWriter.swift:197,203-205,232-235,250` now reads all three stashes at write time. Old TODO comments cleared.
- item 4 HIGH "no AutoCaptureService / PickStash.Pinned event": **FIXED**.
  `OpenClickyAutoCaptureService.swift` observes `.pickStashDidChange`, debounces (60ms),
  guards `hasFreshPin`, calls `writer.captureAutoPin()`. `CompanionManager.swift:4185`
  starts it, `:4100/:4207` stops it. Full parity with `AutoCaptureService.cs`.
- item 6 HIGH "no `captureAsync(seed)` overload": **PARTIAL**. New `captureAutoPin()`
  entry point covers the auto-pin refresh case; there is still no seed argument, but
  `PickStash.hasFreshPin` inside `captureCoreAsync` supplies the pin — functional parity.
- item 10 CRITICAL "MCP bridge does not expose stash tools": **FIXED**.
  `OpenClickyExternalControlBridge.swift:3147,3173,3190,3213,3241,3259,3264` wire all 7
  cases (`read_pick`, `read_whiteboard`, `read_whiteboard_image`, `add_annotation`,
  `read_annotations`, `clear_annotations`, `pick_element`).
- item 12 KnownApps schema: parity confirmed — both sides have exactly `TitlePattern`
  + `DiscoverUrl`, no priority. No missing field.

## 1. Real remaining MCP-tool gaps (post-cleanup diff)

Machine diff of `[McpServerTool(Name="…")]` across `Everywhere.Mcp/Tools/*.cs` (96 tools)
vs OpenClicky descriptor names + dispatch cases (127 including OpenDia's 120 browser_*),
after excluding the 8 input-simulator writes: **24 tools missing.**

Severity HIGH:
- **Clipboard MCP surface — 4/4 missing.** `clipboard_read`, `clipboard_write`,
  `clipboard_paste`, `clipboard_copy` — impls exist (`ClipboardCapture.swift` read;
  `ClipboardWriter.swift:68,118,136` write/paste/copy) but zero MCP wire.
  Fix: add 4 descriptors + dispatch cases (~15 min), same pattern as `screenshot`.
- **Chat bus — 4/6 missing.** `chat_list`, `chat_read`, `chat_create`, `chat_delete`
  absent at impl AND wire. `OpenClickyChatBus.swift` only exposes `send` + `subscribe`.
  Everywhere `ChatBusTools.cs` registers all 6.
  Fix: extend `OpenClickyChatBus` with channel storage + 4 handlers; wire in
  `OpenClickyChatBusTools`.

Severity MEDIUM:
- **`get_app_context` / `get_app_state` — no impl, no wire.** `GetAppContextTool.cs`
  (multi-app enumeration variant of `get_focused_context`) and `GetAppStateTool.cs`
  (KnownApp agent-state URL fetcher) unported. Resolver machinery already ships in
  `OpenClickyContextSnapshotPayload.swift:253-315`; only the MCP surface is missing.
- **Web analysis tools — 8/8 missing.** `web_verdict_score`, `web_signature_scheme`,
  `web_techstack`, `web_js_search`, `web_crypto_scan`, `web_sourcemap_list_candidates`,
  `web_sourcemap_resolve`, `web_js_fetch_same_origin`. `AnalysisTools.cs` (11KB) has
  no swift port. `OpenClickyWebBridgeTools.swift` only covers `web_search` +
  `web_fetch_url`.

Severity LOW-MEDIUM:
- **`opendia_smoke_check`** (Everywhere `GeneratorTools.cs:390`) — adapter-authoring
  loop preflight; no swift port, no wire.
- **`search_adapters`** (BM25 over OpenCLI adapter catalog, `SearchTools.cs:114`) — no port.
- **`strategy_note_get` / `strategy_note_write`** — impl half-present:
  `OpenClickyMetaTools.swift:474 validateStrategyNote` ships and is unit-tested
  (`OpenClickyMetaToolsTests.swift:364-482`) but has NO caller outside tests and NO
  MCP descriptor. `OpenClickyAdapterAuthoringBridgeTools.swift:70` still tells callers
  "Requires a prior strategy_note_write" — a tool that does not exist over MCP.
  Fix hint: wire two thin descriptors that persist / retrieve the note (Everywhere's
  storage is `Preferences`-backed; simple UserDefaults will do).
- **`browser_captcha_present`** (OpenDia-forwarded, `CaptureTools.cs:274`) — no port.

## 2. Impl-without-wire (Swift funcs with no non-test caller)

- `OpenClickyMetaToolRegistry.validateStrategyNote(_:)` — only referenced by the tests
  above. See item 1 (strategy_note_write MCP wire).
- `ClipboardWriter.writeText / simulatePaste / simulateCopy` — see item 1 (clipboard MCP wire).
- `AnnotationStash.drain()`, `.removeItem(_:)`, `.remove(at:)` — public API but no
  caller in cursor-buddy or context service outside tests. Not a bug; flagged as dead surface.

## 3. Stash consumption audit

| Stash | Writer | Reader (non-test) |
|---|---|---|
| PickStash | `OpenClickyPickElementOverlay.swift:465 .set()` | writer `:197 .hasFreshPin`; `OpenClickyAutoCaptureService.swift:139 .hasFreshPin`; `OpenClickyStashTools.swift:64 .take()` (read_pick); hotkeys `:381 .clearWithEvent()` |
| WhiteboardStash | `OpenClickyWhiteboardOverlayWindow.swift:883 .set()` | writer `:203 .peek()`; `OpenClickyStashTools.swift:205 .take()` (read_whiteboard); badge overlay `:263` + hotkeys `:383 .clearWithEvent()` |
| AnnotationStash | `OpenClickyStashTools.swift:159 .append()` via `add_annotation` MCP | writer `:641 .peek()`; `:300 .consume()`; `read_annotations` / `clear_annotations` MCP |

All three balanced. No writes-never-read or reads-never-written.

## 4. Envelope field wire (`captureCoreAsync`)

Every field sourced. No `nil` hardcodes remain:

| Field | Source |
|---|---|
| `app` | `FrontmostAppCapture.capture().appKey` |
| `processId` | Frontmost pid |
| `windowTitle` | `FocusedWindowCapture.capture(processId:)` |
| `url` | `BrowserURLCapture.capture(processId:)` -> `OpenClickySanitiser.redactCredentials` |
| `selectedText` / `selectedApp` | `SelectionCache.shared.getFresh()` |
| `pinPending` | `PickStash.shared.hasFreshPin` |
| `whiteboardPending` / `whiteboardRegionCount` | `WhiteboardStash.shared.peek()` |
| `pickedLinks` | `tryReadXlbMultiPick()` merged with `extraLinks` (LinkRect) |
| `annotations` | `peekAnnotationsForPayload()` when `drainAnnotations=true` |

## 5. Hotkey wire

All five present + dispatched in `OpenClickyContextHotkeys.swift:349-362`:
- `.snapshotContext` -> `performSnapshotContext` -> `writer.captureAsync()`.
- `.clearContextStash` -> `performClearContextStash` -> writer + 3 stash `clearWithEvent`.
- `.agentPickElement` -> `performAgentPickElement` -> `OpenClickyPickElementOverlay.shared.begin()`.
- `.whiteboard` -> `performWhiteboardBegin` -> overlay begin/end toggle.
- `.linkRect` -> `performLinkRectStub` -> overlay + `writer.captureLinks(_:)`.

## 6. Stub/TODO leftovers

Grep of `Phase 7 TODO|Phase 8 TODO|// unwired|// deferred`:
- `OpenClickyContextStashWriter.swift:86` — doc comment mentions "(Phase 7 TODO)
  activates the configured agent" — the actual activation IS implemented at
  `:308-` via `activateAgentAndFirePhrase`; comment is stale, safe to drop.
- `ClipboardCapture.swift:70-72` + `CaptureTypes.swift:292-302` — `filePaths`,
  `imageData`, `rtfData` marked `TODO(P1)`. Non-blocking; Everywhere's
  `GetClipboardTool` is text-only too. Only relevant if the clipboard MCP write
  surface (item 1) grows to file/image variants.

## 7. Summary of newly-actionable fixes (post-existing-audit)

None escalate to CRITICAL — the three CRITICALs in `full-port-gap-audit.md` are now
either fixed (item 6, item 10) or unchanged (item 1, Whiteboard AX-snap engine). New
HIGH items are all "impl ships but MCP wire absent":

1. Clipboard MCP tools (4) — 15 min mechanical wire.
2. Chat bus tools (4) — needs impl + wire.
3. `strategy_note_get / _write` MCP wire — validator exists, needs 2 descriptors.
4. `get_app_context / get_app_state` MCP tools — needs impl + wire.
5. `opendia_smoke_check`, `search_adapters`, `browser_captcha_present` — LOW impact,
   authoring-loop only.
6. 8 web-analysis tools — MEDIUM impact, adversarial-web-analysis surface entirely
   absent.

Whiteboard AX-snap engine (first-pass CRITICAL #1) remains the only real
implementation gap; port plan is `whiteboard-annotation-snapper-port-plan.md`.
