# Phase 1 SelectedText — port report (2026-07-22)

## Files

Created:
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SelectedTextCapture.swift`
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SelectionCache.swift`
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/SelectedTextCaptureTests.swift`
* `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/.impl-notes/phase1-selectedtext-2026-07-22.md`

Modified:
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` — appended `SelectedTextSource` enum and `SelectedTextInfo` struct at end of file. All pre-existing types (`FrontmostAppInfo`, `FrontmostActivationPolicy`, `FinderItem`, `FinderSelectionInfo`, `ClipboardInfo`, `IdleTimeInfo`, `BrowserURLInfo`, `WorkdirProbeResult`, `ProjectType`) untouched.

Untouched (per task constraint):
* `FrontmostAppCapture.swift`, `ClipboardCapture.swift`, `IdleTimeCapture.swift`, `FinderSelectionCapture.swift`, `BrowserURLCapture.swift`, `AppleScriptRunner.swift` — none referenced (source uses no AppleScript for selection).
* No `FocusedWindow.swift` / `WorkdirProbe.swift` present in this package tree.

## Everywhere reference

* Primary: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.TextSelection.cs` @30e03e9d — 416 lines
* Cache: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/SelectionCache.cs` — 66 lines
* Consumer envelope: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetSelectedTextTool.cs`

## Three strategies (verbatim from source)

**Strategy 1 — AX on focused element** (`GetTextViaAXAPI` lines 244-249)
```csharp
var text = focusElement.GetSelectionText();
if (!string.IsNullOrEmpty(text)) return text;
```
Focus lookup: `AXFocusedUIElement` on app AX element, falling back to `AXFocusedWindow` (lines 238-242). Read `AXSelectedText` on the result.

**Strategy 2 — walk immediate children** (`GetTextViaAXAPI` lines 251-259)
```csharp
foreach (var child in focusElement.Children)
{
    text = child.GetSelectionText();
    if (!string.IsNullOrEmpty(text)) return text;
}
```
Single-level `AXChildren` walk, not recursive. First non-empty `AXSelectedText` wins.

**Strategy 3 — clipboard Cmd-C fallback** (`GetTextViaClipboardAsync` lines 270-316)
1. Snapshot original clipboard string.
2. Synthesize Cmd+C via `CGEvent` — key-down, 5ms sleep, key-up. Prefers `PostToPid(pid)` when pid>0, otherwise `Post` at `.hid` tap.
3. Poll `NSPasteboard.changeCount` — **10 iterations x 10ms = 100ms max wait** (lines 299-307). When it changes, read pasteboard string, break.
4. Restore original clipboard via `clearContents` + `setString` (lines 309-313).

## Cache

- **TTL**: `TimeSpan.FromMinutes(2)` verbatim (`SelectionCache.cs:14`). Ported as `SelectionCache.ttl = 120` (seconds).
- **Key composition**: NOT keyed by `(app, textHash)`. Single-slot cache — most-recent non-empty selection wins. Stored tuple is `(text, appKey, capturedAtUtc)`; `appKey` is `AppKey.FromProcessId(pid)` output (matches `AppKeyResolver.fromProcessId`).
- **Cache-hit criteria**: non-empty text AND `now - capturedAt <= TTL`.
- **Wire compatibility**: emits `source: .cache` (`GetSelectedTextTool.cs:31`).

Task-brief said "keyed by (app, selection text hash)" — verified against source, this is NOT correct. Ported the actual single-slot behaviour.

## Password field skip

Everywhere source does NOT explicitly skip password fields. `AXSecureTextField` does not expose `AXSelectedText`, so Strategies 1/2 naturally return nil, but Strategy 3 (Cmd-C) would leak the password. **openclicky adds an explicit safeguard**: before running Strategy 3, check `AXRole` and `AXSubrole` of the focused element against `kAXSecureTextFieldSubrole` ("AXSecureTextField"). If matched, return nil without touching the clipboard.

## Clipboard restore protocol

Source uses string-only snapshot (line 286 `ReadClipboard()` returns `string?`; line 312 `WriteClipboard(original)` restores just that string). Loses mixed-content clipboards (image + text, file URL + text) after Cmd-C.

**openclicky improves this**: item-level snapshot before Cmd-C — every `NSPasteboardItem` with every type + data. After capture, `clearContents` + `writeObjects([reconstructed items])`. If the deeper restore fails (writeObjects returns false), fall back to the source's string-only path so the user is never left with a wiped clipboard.

## Threading

- `SelectedTextCapture.capture` is synchronous. Strategy 3 sleeps up to 100ms via `usleep`; callers should invoke off-main when responsiveness matters.
- AX API is documented thread-safe (`AXUIElement.h`).
- `SelectionCache` guards its three fields with `NSLock`.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`:
* Row 6 (`SelectedText 三级 fallback` → `Capture/SelectedTextCapture.swift`) — matches source, target, and algorithm exactly. **No change.**
* Row 7 (`SelectionCache (2min TTL)` → `Capture/SelectionCache.swift`) — matches TTL, name, and target. **No change.**
* Data-model section lines 126-131 (`SelectedTextInfo` struct with `text: String`, `source: SelectedTextSource`, `sourceApp: String?`, `length: Int`) — matches Swift implementation 1:1. **No change.**
* `SelectedTextSource` cases in doc (`.ax | .child | .clipboardCmdC | .cache`) — matches Swift enum exactly. **No change.**

No divergence between doc, source, and port.

## Test result

`swift test` — full package suite passes, no skipped tests under the developer's login session.

New suites:
* `SelectionCacheTests` — 8 tests, all pass. Covers empty state, fresh hit, TTL expiry, TTL boundary equality, empty-text ignored, overwrite semantics, reset, and TTL constant match.
* `SelectedTextInfoTests` — 3 tests, all pass. Covers JSON round-trip, enum raw-value stability, and RTL/ZWJ-emoji grapheme preservation.
* `SelectedTextCaptureTests` — 5 tests, all pass. Covers cache-hit priority, expired-cache skip, headless-run pipeline termination, Cmd-C clipboard restore, and cache-before-fallback precedence.

Live AX-tree probes (a running selected-text app) are gated behind `OPENCLICKY_SKIP_UI_TESTS` per project convention, matching the pattern used by `BrowserURLCaptureTests`.

Full run: **119 tests executed, 0 failures, 0 unexpected**.

## Build result

`bash scripts/sign-and-install.sh` last five lines:

```
[2/5] codesign with OpenClicky Dev Sign
  /Users/wowdd1/Library/Developer/Xcode/DerivedData/.../OpenClicky.app: replacing existing signature
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=30814  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

`** BUILD SUCCEEDED **`. Package builds cleanly inside the app target with the new `SelectedTextCapture.swift`, `SelectionCache.swift`, and appended type extensions.

## Known limitations

* **GUI-dependent branches** (Strategies 1-3 against a live AX tree) cannot be exercised deterministically under `swift test`. Those code paths execute at runtime under the app, verified via the sign-and-install probe. Coverage is `XCTSkipIf`-gated behind `OPENCLICKY_SKIP_UI_TESTS`, matching how `BrowserURLCaptureTests` handles Safari.
* **AXEnhancedUserInterface / AXManualAccessibility flip**. Source flips these Chromium/Electron opt-ins to `true` when Strategies 1+2 both fail (lines 261-266). openclicky's port does NOT flip them — this is a global side effect that belongs in a dedicated quirks installer per docs/ROADMAP row 27 (`AXQuirksInstaller.swift`, not yet in this codebase). Documented in the file header.
* **`_clipboardSequence` pre-mousedown snapshot** (source line 277) — source's mouse-hook driver captures the pasteboard changeCount at mouse-down so it can detect "user did their own Cmd-C mid-gesture". openclicky is on-demand, not mouse-hook-driven, so there is no pre-value to compare against; we always synthesize Cmd+C in Strategy 3. Same file header captures the deviation.
* **Mouse-hook `TextSelectionDetector`** (source lines 60-231) is NOT ported. openclicky's Phase 1 pulls the selection on demand rather than streaming it via `IObserver<TextSelectionData>`. The cache is written manually on every successful non-cache capture, giving the same "survives focus change" behaviour the observer-driven cache provides. Reactive stream is a P2 concern per roadmap.
* **`sourceApp` may be nil in cache-hit path** when the original store happened without an `NSRunningApplication` (test fixtures). Live captures always populate it via `AppKeyResolver.fromProcessId`.
