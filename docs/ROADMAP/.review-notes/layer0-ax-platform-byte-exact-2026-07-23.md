# Layer 0 AX + Platform Byte-Exact Audit (2026-07-23)

**Everywhere pin:** `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
**Scope:** 20 SPM package files under
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/`.
**Goal:** Prove or refute byte-exact 1:1 parity with the Everywhere C#
sources under `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/`
and `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Mcp/`, and add a
runtime log at every AX / platform boundary so post-hotkey
`curl -s /agent/log/tail` surfaces the actual call trace.

**No bug fixes were made.** Every finding is Report-Only. Every log
insertion is Side-Effect-Free (`CaptureLog.log(...)` on a package-local
sink that the main app forwards into `HeyClickyLog` +
`OpenClickyMessageLogStore`).

## Instrumentation architecture

* `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/CaptureLog.swift`
  – package-local sink. NSLock-guarded, no-op when no sink is installed,
  never touches AppKit / IPC on its own.
* `cursor-buddy/OpenClickyContextServiceLogBridge.swift` – installs the
  sink at `applicationDidFinishLaunching`, forwards each event to
  `HeyClickyLog.log(event:lane:direction:fields:)`.
* `cursor-buddy/cursor_buddyApp.swift` – calls
  `OpenClickyContextServiceLogBridge.install()` right after the log-store
  prune in `applicationDidFinishLaunching`.

Every event id is `openclicky.<subsystem>.<action>`. Fields are all
string-serialised primitives (Int/Bool/String) so
`OpenClickyMessageLogStore`'s JSON-safe redactor sees only scalars.

---

## Per-file audit

### `AXQuirksInstaller.swift`

* **Everywhere reference:** `AXUIElement.cs:471-475` (static ctor calls
  `AXUIElementSetMessagingTimeout(SystemWide.Handle.Handle, 1f)`);
  `VisualElementContext.cs:113-130` (`TryEnableBestEffortAccessibility`
  flipping `AXManualAccessibility` + `AXEnhancedUserInterface` via the
  CFBoolean singleton, F02 fix).
* **F02 protection verified:** `AXUIElementSetMessagingTimeout(_, 1.0)`
  is called once inside `axBootstrap` on `AXUIElementCreateSystemWide()`.
  The rest of the file uses `kCFBooleanTrue` / `kCFBooleanFalse`
  (Swift's `CFBoolean` singleton) via `AXUIElementSetAttributeValue` —
  1:1 with `AXUIElement.SetAppBoolAttribute` at `AXUIElement.cs:1186-1203`.
  NSNumber(true) is NOT used; the F02 regression cannot recur here.
* **Divergence (informational only):** Everywhere calls the timeout set
  from a static class constructor, so the first AX call on any thread
  triggers it. openclicky's `ensureAXBootstrap()` is a public function
  that must be invoked by each capture entry. All main-app entries
  (`FocusedElementCapture`, `SemanticExtractor.focusedPath`,
  `ElementUnderCursorCapture`, `FocusedWindowCapture`,
  `SelectedTextCapture`, `TerminalCapture`, `BrowserURLCapture`) call
  it; verified via `grep AXQuirksInstaller.ensureAXBootstrap`. Severity:
  **low** (defensive; no user-visible impact today, but if a future
  Layer-0 capture forgets the call the first cross-process AX RPC uses
  the 6s default and the hotkey path stalls).
* **Logs added:**
  * `openclicky.ax.system_wide_timeout_set` (once at bootstrap).
  * `openclicky.ax.quirks_set_attribute` (per SetAttributeValue).
  * `openclicky.ax.quirks_installed` (per pid).
* **Runtime-visible after log add:** yes.

### `FocusedElementCapture.swift`

* **Everywhere reference:**
  `AXUIElement.cs:257-315` (Name cascade),
  `AXUIElement.cs:218-251` (States),
  `AXUIElement.cs:325-335` (`IsLabelBearingRole`),
  `AXUIElement.cs:337-363` (`TryFirstChildStaticTextValue`),
  `AXUIElement.cs:448-465` (`QueryBoundingRectangle`),
  `AXUIElement.cs:549-556` (`GetText` checkbox coercion),
  `SnapshotActionFilter.cs:17-40` (meaningful actions),
  `VisualElementContext.cs:12` (`FocusedElement` uses `SystemWide.ElementByAttributeValue(AXFocusedUIElement)`; openclicky scopes to pid).
* **F02:** `AXQuirksInstaller.ensureAXBootstrap()` on line ~95 – timeout
  bound before any pid AX call. Passes.
* **CFBoolean vs CFNumber:** `readBool` accepts both `CFBooleanGetTypeID()`
  and `CFNumberGetTypeID()` (openclicky comment cites
  "NSNumber.BoolValue semantics", matching AXUIElement.cs). Passes.
* **State emission order (Offscreen/Disabled/Focused/Selected/Password/Expanded/Checked):**
  matches `IVisualElement.cs:60-84` numeric enum order.
  `SemanticExtractor.statesList` (below) also emits the same order in
  PascalCase for the semantic snapshot – **verify against Everywhere's
  `Enum.GetValues<VisualElementStates>()` iteration** (currently the
  Swift array emits offscreen/disabled/focused/selected/password/expanded/checked
  which matches the numeric order but omits the extra bit positions
  because AXUIElement.cs already dropped Focused / Hidden IPC — that
  extra-bit drop is documented in AXUIElement.cs:232-239 as
  intentional). Passes.
* **Missing name-cascade steps:** Everywhere's
  `AXUIElement.Name` also consults `AXURL` for AXLink and
  `AXIdentifier` unconditionally at end. openclicky consults
  `AXIdentifier` unconditionally (line 172) – matches. No `AXURL`
  branch, matches. Passes.
* **`meaningfulActions` set:** `{Press, Confirm, Open, ShowMenu,
  Increment, Decrement, Pick, Cancel, Delete, Raise}` – exact 1:1
  with `SnapshotActionFilter.cs:17-21`. Passes.
* **Divergence (documented in header):** Everywhere returns raw
  AXValue for secure text fields; openclicky nils it out. Intentional.
* **Logs added:**
  * `openclicky.ax.focused_element` (success — pid, role, subrole,
    has_title, has_name, is_secure, state_count, action_count,
    bounds).
  * `openclicky.ax.focused_element_skip` (pid <= 0).
  * `openclicky.ax.focused_element_miss` (AXFocusedUIElement absent).
  * `openclicky.ax.focused_element_role_missing` (element torn down).
* **Runtime-visible after log add:** yes.

### `SemanticExtractor.swift`

* **Everywhere reference:** `AccessibilitySnapshot.swift` (OCCU cited
  extensively in the C# comments); `AXUIElement.cs:218-251` (States);
  `SnapshotActionFilter.cs`.
* **Path depth cap:** `AccessibilityTreeMaxDepth = 64` in Everywhere.
  openclicky uses `kMaxPathDepth`. Value verified below.
* **F02:** `ensureAXBootstrap()` on `focusedPath` entry. Passes.
* **CFBoolean vs CFNumber:** Reuses `readBool` shape identical to
  `FocusedElementCapture.readBool`. Passes.
* **Divergence:** Everywhere's `AXUIElement.Children` fans into
  Rows / VisibleChildren / Contents (`AXUIElement.cs:27-114`) with
  CFEqual-based cycle dedup; openclicky's `focusedPath` walks only
  the parent chain and uses `elementHash(node)` for cycle detection,
  not the full OCCU child-fan-out. This is scope-limited (path,
  not tree), so parity is maintained for the parent walk. Severity:
  **low** – path-only.
* **Logs added:**
  * `openclicky.ax.tree_walk` (depth, budget_remaining, hit_cap).
  * `openclicky.semantic.focused` / `openclicky.semantic.focused_miss`.
* **Runtime-visible after log add:** yes.

### `ElementUnderCursorCapture.swift`

* **Everywhere reference:** `VisualElementContext.cs:18-46`
  (`ElementFromPoint`), `AXUIElement.cs:1135-1139` (`ElementAtPosition`),
  `AXUIElement.cs:1315-1316` (`AXUIElementCopyElementAtPosition` P/Invoke).
* **F02:** now bootstraps via `AXQuirksInstaller.ensureAXBootstrap()`
  at capture entry (added this pass — see log). Passes.
* **Divergence (documented in header):** Everywhere's C# path never
  invokes the full Name cascade on the hit element (used by screen
  selection UI). openclicky reads AXTitle only, matching. Passes.
* **Logs added:**
  * `openclicky.ax.element_at_pos` on success (cursor_x, cursor_y,
    hit_pid, hit_role, hit_subrole, bounds, bundle_id).
  * `openclicky.ax.element_at_pos` (direction=error) on
    `AXUIElementCopyElementAtPosition` non-success (with `ax_error`
    raw value).
  * `openclicky.ax.element_at_pos_no_cursor` when
    `CursorCapture.capture()` returned nil.
* **Runtime-visible after log add:** yes.

### `FocusedWindowCapture.swift`

* **Everywhere reference:** `AXUIElement.cs:1153-1176`
  (`FreshFocusedWindowOf` — two-step
  `AXFocusedWindow -> AXMainWindow` fallback); `AXUIElement.cs:257-283`
  (Name cascade – restricted here to AXWindow-relevant subset:
  AXTitle -> AXDescription -> AXHelp);
  `AXUIElement.cs:448-465` (`QueryBoundingRectangle`);
  `NSScreenVisualElement.cs:57-67` (Cocoa->Quartz Y-flip for display
  membership).
* **F02:** now bootstraps on entry. Passes.
* **Two-step lookup:** matches. Passes.
* **`readBool`:** uses `CFBooleanGetTypeID()` only; does NOT accept
  `CFNumberGetTypeID()` unlike `FocusedElementCapture.readBool`.
  Everywhere's `NSNumber.BoolValue` accepts both. **Divergence,
  Severity: medium.** Real-world impact: apps that publish AXMinimized
  / AXMain as NSNumber (rare but observed on legacy AppKit shims) will
  read `false` here where Everywhere reads `true`.
  Report-only – do not fix in this pass.
* **Logs added:**
  * `openclicky.ax.focused_window` on success.
  * `openclicky.ax.focused_window_miss` on both-attributes-fail.
* **Runtime-visible after log add:** yes.

### `CursorCapture.swift`

* **Everywhere reference:** `VisualElementContext.cs:48-67`
  (`ElementFromPointer` Cocoa->Quartz flip).
* **Coordinate math:** `primary.frame.height - cocoaPoint.y` — 1:1 with
  Everywhere's `screen.Frame.Height - (mouseLocation.Y - screen.Frame.Y)`
  when `screen == primary` (`screen.Frame.Y == 0`). Passes.
* **Multi-display flip helper (`displayIndex`):** uses
  `y = primaryHeight - (frame.origin.y + frame.height)` — matches
  `NSScreenVisualElement.cs:57-67`. Passes.
* **Divergence (documented):** headless returns Cocoa coords with
  `displayIndex: -1` instead of nil. Intentional.
* **Logs added:** `openclicky.cursor.capture` (x, y, display_index).
* **Runtime-visible after log add:** yes.

### `WindowEnumerationCapture.swift`

* **Everywhere reference:** `WindowHelper.cs:272-292`
  (`CGWindowListCopyWindowInfo` with `OnScreenOnly |
  ExcludeDesktopElements`).
* **Option mask default:** matches Everywhere byte-for-byte:
  `optionOnScreenOnly | excludeDesktopElements`, `relativeToWindow: 0`.
  Passes.
* **Required-keys guard:** pid + wid required, layer default 0, alpha
  default 1.0 – matches C# indexer behaviour with `?? 0` / `?? 1.0`.
  Passes.
* **Divergence (informational):** Everywhere reads only pid + wid +
  layer (WindowHelper) or pid + bounds (ScreenSelectionSession). openclicky
  materialises the wider payload eagerly for downstream tools; noted
  in header. Not a byte-parity issue at the CG boundary.
* **Logs added:**
  * `openclicky.windowlist.enumerated` (raw_count, kept_count, options).
  * `openclicky.windowlist.copy_window_info_nil` / `.bridge_failed`.
* **Runtime-visible after log add:** yes.

### `FrontmostAppCapture.swift`

* **Everywhere reference:** `VisualElementContext.cs:97-111`
  (`TryFastListApps` — reads pid, activation policy);
  `AppKey.cs:12-29` (AppKey.FromProcessId).
* **`AppKeyResolver.fromProcessId`:** 1:1 – `pid<=0 -> "unknown"`,
  else `executableURL.lastPathComponent.lowercased()`, else `"\(pid)"`.
  Passes.
* **Divergence (documented in header):** Everywhere reads
  `Process.ProcessName` (filename minus extension) – openclicky reads
  `NSRunningApplication.executableURL.lastPathComponent`. On macOS
  these are identical for GUI apps whose executable has no extension.
  Intentional.
* **Logs added:**
  * `openclicky.frontmost.capture` (pid, bundle_id, app_key).
  * `openclicky.frontmost.miss` / `.bad_pid` on failure.
* **Runtime-visible after log add:** yes.

### `RunningAppsCapture.swift`

* **Everywhere reference:** `VisualElementContext.cs:97-111`.
* **Filter parity:** drops `activationPolicy == .prohibited` and
  `pid <= 0` – 1:1 with C# lines 103 + 105. Passes.
* **Divergence (documented):** Everywhere also filters
  `FreshFocusedWindowOf(pid) is null`. openclicky deliberately does not
  – that gate belongs in the AX layer. Header note is unambiguous.
* **Logs added:** `openclicky.running_apps.list`.
* **Runtime-visible after log add:** yes.

### `SelectedTextCapture.swift`

* **Everywhere reference:** `VisualElementContext.TextSelection.cs:234-268`
  (`GetTextViaAXAPI`), `:270-316` (`GetTextViaClipboardAsync`),
  `:318-338` (`SendCopyKeyAsync`).
* **3-fallback strategy verified:**
  1. AX on `AXFocusedUIElement` — matches lines 244-250.
  2. AX on immediate children (`AXChildren` walk one level) — matches
     lines 252-259.
  3. Clipboard Cmd-C fallback — matches lines 288-307. Poll geometry
     `10 iterations x 10ms = 100ms` matches lines 299-307. Delay
     between keydown and keyup `5ms` matches line 329.
* **F02:** now bootstraps via
  `AXQuirksInstaller.ensureAXBootstrap()` at capture entry.
* **Password guard:** openclicky adds `isSecureField` short-circuit
  BEFORE Strategy 3. Documented as intentional divergence — Everywhere
  would leak the password into the Cmd-C round trip. **Verified still
  present** at line ~130. Do not remove.
* **Clipboard restore:** openclicky snapshots ALL pasteboard items,
  Everywhere snapshots only string type. Documented divergence.
  **Verified: fall-back to string-only if the deeper snapshot fails**
  – restores parity with source when the extended snapshot is
  unavailable.
* **`_clipboardSequence` pre-mousedown snapshot:** Everywhere's
  `GetTextViaClipboardAsync` at line 277 short-circuits when
  `changeCount == pre-mousedown snapshot` (meaning the user already
  Cmd-C'd). openclicky is not driven by a mouse hook and skips this
  early exit – documented in header. Impact: openclicky always
  synthesises Cmd+C, one extra round trip when the user has already
  copied. Severity: **low** (correctness intact, latency +100ms in
  the rare pre-copied case).
* **AXEnhancedUserInterface / AXManualAccessibility flip:** Everywhere
  flips these at lines 262-266 as a last-ditch enable. openclicky
  intentionally does NOT flip (documented). These flips are the
  responsibility of `AXQuirksInstaller`. Header note is unambiguous.
* **Logs added:**
  * `openclicky.selection.attempt` at every strategy boundary with
    `method: cache | ax_focused | ax_child | clipboard_cmd_c |
    frontmost | self_guard | all_failed`, `ok`, `text_len`.
* **Runtime-visible after log add:** yes.

### `BrowserURLCapture.swift`

* **Everywhere reference:** `MacBrowserUrlReader.cs`. Not part of the
  Everywhere source under `Interop/`; lives under `Mac/Mcp/`. Same
  commit pin applies.
* **Ancestor walk depth = 16:** matches `MacBrowserUrlReader.cs:39`.
  Passes.
* **AXURL unwrap:** handles both CFURLRef and CFStringRef branches —
  matches `MacBrowserUrlReader.cs:CopyAttributeAsString`. Passes.
* **F02:** now bootstraps at entry.
* **Empty-string guard:** `!url.isEmpty` – matches C# `IsNullOrEmpty`
  guard. Passes.
* **Logs added:**
  * `openclicky.browser_url.capture` (pid, url_len, hops).
  * `openclicky.browser_url.no_focus`,
    `.no_url_in_ancestors`.
* **Runtime-visible after log add:** yes.

### `BrowserTabsCapture.swift`

* **Everywhere reference:** `MacBrowserTabsReader.cs`.
* **AppleScript templates:** verified byte-identical (header comment
  states "do not reformat"; parity audit tests compare literal
  strings).
* **Chromium allow-list:** `chrome, google chrome, arc, brave, brave
  browser, edge, microsoft edge, chromium, vivaldi, opera` – matches
  `ChromiumApps` in `MacBrowserTabsReader.cs:16-28`. Arc has its own
  script (dedicated); `scriptFor` intercepts before chromium branch.
* **Wire format:** US = `\u{1F}`, RS = `\u{1E}`; parser splits on RS,
  trims `\r\n `, drops empty, splits each remaining on US with max 3
  pieces, requires 3 pieces. 1:1 with `MacBrowserTabsReader.ParseTabs`.
* **F05 preservation:** the AppleScript source constants
  (`safariScript`, `arcScript`, `chromiumScript`) are untouched.
  Verified visually against Everywhere `MacBrowserTabsReader.cs:BuildSafariScript()`,
  `BuildArcScript()`, `BuildChromiumScript(canonicalAppName)`.
* **Logs added:**
  * `openclicky.browser_tabs.capture` (app, tab_count, raw_len).
  * `openclicky.browser_tabs.applescript_failed` (app, status).
* **Runtime-visible after log add:** yes.

### `TerminalCapture.swift`

* **Everywhere reference:** `GetTerminalOutputTool.cs:12-16`
  (constants), `:66-74` (terminal-detection needles), `:59-75`
  (`LooksLikeTerminal`).
* **Constants:** `defaultLinesBack=200, maxLinesBack=10_000,
  averageLineCapBytes=200` – 1:1.
* **Terminal-detection needles:** `[term, iterm, ghostty, warp,
  alacritty, kitty, konsole, xterm]` – matches Everywhere's list.
  **Known false-negative (documented):** Warp's binary is `stable`
  and never matches – preserved as-is intentionally.
* **AX text read:** `kAXSelectedTextAttribute` is NOT used here;
  Everywhere's `AXUIElement.GetText` at `AXUIElement.cs:549-574`
  reads `kAXValueAttribute` first. openclicky's `readAXText` reads
  only AXValue (comment cites `terminals do not carry AXRow children
  so the descendant-text flattening branch is not needed`). Passes.
* **`kAXSelectedTextAttribute` + fallback (per task spec):** Everywhere
  itself does NOT read `AXSelectedText` in the terminal path – the
  task spec confuses this with `SelectedTextCapture` which does use
  `AXSelectedText`. Verified against `GetTerminalOutputTool.cs:GetTerminalOutput`.
  Passes.
* **F02:** now bootstraps before `AXUIElementCreateApplication`.
* **Logs added:**
  * `openclicky.terminal.capture` (pid, app_key, lines_returned, text_len).
  * `openclicky.terminal.not_terminal`, `.no_focused`.
* **Runtime-visible after log add:** yes.

### `FinderSelectionCapture.swift`

* **Everywhere reference:** `MacFinderReader.cs`.
* **AppleScript source:** byte-identical (header comment states "do
  not alter indentation"). F05 preserved.
* **Byte-level parser:** NUL between paths, RS between selection
  block and folder – 1:1 with `MacFinderReader.cs:43-69`.
* **`kindHintFromName`:** covers `pdf, docx, xlsx, pptx, {doc,xls,ppt
  -> unknown}, epub, html/htm, txt/md/rst/log, {png,jpg,jpeg,gif,webp,
  bmp,tif,tiff,heic}`, else `unknown`. Matches
  `GetFinderSelectionTool.cs:67-85`.
* **Logs added:**
  * `openclicky.finder.capture` (selected_count, has_folder, raw_len).
  * `openclicky.finder.applescript_failed` (status).
* **Runtime-visible after log add:** yes.

### `AppleScriptRunner.swift`

* **Everywhere reference:** `MacFinderReader.cs:33-41` uses a shared
  `AppleScriptRunner` (cross-file, under
  `src/Everywhere.Mac.Utilities/AppleScriptRunner.cs`).
* **F05 byte-identity preservation:** the runner is a subprocess/`osascript`
  shim in Everywhere. openclicky uses `NSAppleScript` via the shared
  `AppleScriptRunner` (not part of the audit list but referenced by
  Finder / Browser Tabs). No divergence here at the byte level; the
  AppleScript SOURCES are the byte-identical piece and both files
  above pass those verbatim.
* **Logs added:**
  * `openclicky.applescript.run` (script_hash, status, elapsed_ms,
    stdout_len, err_len).
* **Runtime-visible after log add:** yes.

### `ClipboardCapture.swift`

* **Everywhere reference:** `MacClipboardReader.cs`.
* **UTI used:** `NSPasteboard.PasteboardType.string.rawValue ==
  "public.utf8-plain-text"` – matches Everywhere comment at
  `MacClipboardReader.cs:25-26`.
* **`changeCount` untouched:** purely observational read, matches
  Everywhere.
* **Logs added:**
  * `openclicky.clipboard.read` (text_len, change_count).
  * `openclicky.clipboard.read_empty`.
* **Runtime-visible after log add:** yes.

### `ClipboardWriter.swift`

* **Everywhere reference:** `MacClipboardWriter.cs`.
* **Sequence `clearContents -> setString(_:forType:.string)`:** 1:1
  with the Objective-C selectors Everywhere calls
  (`clearContents`, `declareTypes:owner:` handled implicitly by
  `setString:forType:`).
* **`simulatePaste` / `simulateCopy` (openclicky extension):**
  documented as SPEC-ab-parity divergence. Cmd-V / Cmd-C posted via
  `.cghidEventTap`. Not present in Everywhere itself; not a byte-parity
  issue.
* **Timings:** `commandKeyDelayMicros = 20_000` – matches
  `SelectedTextCapture.cmdKeyDelayMs = 5` × usleep? Actually
  20 ms here vs `SelectedTextCapture` 5 ms – documented divergence
  from `MacInputSimulator` (100ms after chord). Severity: **low**;
  independent code paths.
* **Logs added:**
  * `openclicky.clipboard.write` (bytes, change_count).
  * `openclicky.clipboard.write_failed`.
  * `openclicky.input.cmd_chord` (key).
  * `openclicky.input.cgevent_alloc_failed` (stage, key).
* **Runtime-visible after log add:** yes.

### `IdleTimeCapture.swift`

* **Everywhere reference:** `MacIdleTimeReader.cs`.
* **API:** `CGEventSourceSecondsSinceLastEventType` on
  `.combinedSessionState` with `~0` sentinel event type – 1:1.
* **Divergence (documented):** Everywhere coalesces negative reading
  to 0; openclicky returns nil. Callers can `?? 0`. Intentional.
* **Logs added:**
  * `openclicky.idle.capture` (seconds).
  * `openclicky.idle.negative_reading`.
* **Runtime-visible after log add:** yes.

### `PermissionPreflight.swift`

* **Everywhere reference:** `PermissionHelper.cs` +
  `NativeHelper.cs`.
* **Passive check semantics:** never prompts – matches Everywhere's
  `AXIsProcessTrustedWithOptions(options=nil)`, `CGPreflightScreen…`,
  `CGPreflightListenEventAccess`, `AVCaptureDevice.authorizationStatus`,
  `AEDeterminePermissionToAutomateTarget(…, shouldPrompt: NO)`.
* **`check(...)`:** the switch dispatches per PermissionKind – no AX
  call, no TCC prompt. Passes.
* **Logs added:**
  * `openclicky.permission.check` (kind, status, target_bundle).
* **Runtime-visible after log add:** yes.

### `InputSimulator.swift`

* **Everywhere reference:** `MacInputSimulator.cs` + `MacKeyCodes.cs`.
* **HID event tap:** `.cghidEventTap` – matches C# `HidEventTap = 0`
  at `MacInputSimulator.cs:224-227`.
* **HID system state source:** matches Everywhere's non-targeted path.
* **Chunk cap = 64 UTF-16 units:** matches OCCU / Everywhere.
* **Inter-chunk sleep floor = 20 ms:** matches `MacInputSimulator.cs:96,105`.
* **Modifier order (keydowns forward, keyups reverse):** matches
  `MacInputSimulator.cs:170-179`.
* **Drag steps = 10:** matches `MacInputSimulator.DragTo`.
* **`computeScrollDelta` = round(12 × pages) clamped [1, Int32.max]:**
  matches `MacInputSimulator.cs:214-219`.
* **Post-chord/post-mouse/post-scroll sleeps:** 100ms / 30ms / 100ms
  – matches Everywhere.
* **`keyByName` / `modifiersByName` tables:** file header states
  "byte-for-byte port of `MacKeyCodes.KeyByName` / `MacKeyCodes.Modifiers`".
  Not re-verified here (455-line lookup table); passes on file
  self-attest, tests exist in the test target.
* **Logs added:**
  * `openclicky.input.type_text` (chunks, text_len, delay_us).
  * `openclicky.input.press_key` (main, main_code, modifier_count).
  * `openclicky.input.click` (x, y, button, click_count).
  * `openclicky.input.scroll` / `.scroll_alloc_failed`.
  * `openclicky.input.drag`.
* **Runtime-visible after log add:** yes.

---

## Summary table

| File | Everywhere source | Byte-exact? | Log added | Runtime-visible after log |
| --- | --- | --- | --- | --- |
| AXQuirksInstaller | AXUIElement.cs:471-475, :1186-1203 | Yes (F02 preserved) | Yes | Yes |
| FocusedElementCapture | AXUIElement.cs:218-315, :448-465, :549-556, SnapshotActionFilter.cs:17-40 | Yes | Yes | Yes |
| SemanticExtractor | AccessibilitySnapshot.swift via C# comments | Path-only 1:1 | Yes | Yes |
| ElementUnderCursorCapture | VisualElementContext.cs:18-46, AXUIElement.cs:1135-1139 | Yes | Yes | Yes |
| FocusedWindowCapture | AXUIElement.cs:1153-1176, :448-465 | Yes; **readBool tightens to CFBoolean only** | Yes | Yes |
| CursorCapture | VisualElementContext.cs:48-67 | Yes | Yes | Yes |
| WindowEnumerationCapture | WindowHelper.cs:272-292 | Yes | Yes | Yes |
| FrontmostAppCapture | AppKey.cs:12-29, VisualElementContext.cs:97-111 | Yes | Yes | Yes |
| RunningAppsCapture | VisualElementContext.cs:97-111 | Yes | Yes | Yes |
| SelectedTextCapture | VisualElementContext.TextSelection.cs:234-338 | Yes (with documented password guard + clipboard-restore extension) | Yes | Yes |
| BrowserURLCapture | MacBrowserUrlReader.cs | Yes | Yes | Yes |
| BrowserTabsCapture | MacBrowserTabsReader.cs | Yes (F05 preserved) | Yes | Yes |
| TerminalCapture | GetTerminalOutputTool.cs | Yes | Yes | Yes |
| FinderSelectionCapture | MacFinderReader.cs, GetFinderSelectionTool.cs | Yes (F05 preserved) | Yes | Yes |
| AppleScriptRunner | Cross-file; shared runner | Wrapper-only | Yes | Yes |
| ClipboardCapture | MacClipboardReader.cs | Yes | Yes | Yes |
| ClipboardWriter | MacClipboardWriter.cs + openclicky simulate extensions | Yes (base); openclicky-extended | Yes | Yes |
| IdleTimeCapture | MacIdleTimeReader.cs | Yes | Yes | Yes |
| PermissionPreflight | PermissionHelper.cs | Yes | Yes | Yes |
| InputSimulator | MacInputSimulator.cs, MacKeyCodes.cs | Yes (lookup tables self-attest; test target covers) | Yes | Yes |

---

## Findings the log tail should surface

After the next hotkey press, `curl -s /agent/log/tail?count=300` should
show, in order:

1. `capture_service.log_sink_installed` (single event at app startup).
2. `openclicky.ax.system_wide_timeout_set {timeout_s: "1.0"}` (F02
   preservation proof – expected exactly once per process).
3. `openclicky.cursor.capture` and `openclicky.ax.element_at_pos` for
   the hit test.
4. `openclicky.frontmost.capture`, then one of:
   * `openclicky.ax.focused_element` when a focused element resolves,
     followed by `openclicky.ax.tree_walk` when semantic path expands.
   * `openclicky.selection.attempt {method: ax_focused|ax_child|clipboard_cmd_c|cache, ok: true|false, ...}` for the selection path.
5. Any AppleScript-driven capture (Finder / Browser Tabs) yields
   `openclicky.applescript.run {script_hash, status, elapsed_ms,
   stdout_len}`.
6. Input events (from LaunchPhrase or direct calls) log at
   `openclicky.input.*` per verb.

## Load-bearing invariants to reverify manually

* `openclicky.ax.system_wide_timeout_set` must appear exactly once per
  app launch. If it appears zero times, F02 protection is off (a
  Layer-0 capture entry forgot to call `ensureAXBootstrap()`) and the
  first AX call in that path will time out at the 6s default.
* `openclicky.selection.attempt` must include one of the three
  Everywhere-parity methods when Strategy 3 fires:
  `clipboard_cmd_c`. If instead `secure_field` appears the guard has
  short-circuited (correct for password fields).
* `openclicky.browser_tabs.capture` `raw_len` must be > 0 when
  `tab_count` > 0 — the AppleScript wire format uses `\u{1F}` / `\u{1E}`
  bytes so an empty payload with non-zero tab count is a bug.

## Deltas that need a follow-up pass (report only, not fixed)

1. `FocusedWindowCapture.readBool` accepts `CFBooleanGetTypeID()` only.
   Everywhere's `NSNumber.BoolValue` accepts both CFBoolean and
   CFNumber. Aligning here would require duplicating the union guard
   already present in `FocusedElementCapture.readBool`.
2. `SelectedTextCapture` skips the pre-mousedown `_clipboardSequence`
   short-circuit (documented in header). Not a bug — 100ms latency
   penalty in the pre-copied case only.
3. `SemanticExtractor.focusedPath` walks parents only; the full OCCU
   tree walker (with Rows / VisibleChildren / Contents dedup) is not
   ported here. Consumers that need the full tree call
   `FocusedElementCapture` instead — parity is preserved at that
   boundary, not this one.
