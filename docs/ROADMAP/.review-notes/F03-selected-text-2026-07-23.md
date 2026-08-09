# F03 Review — SelectedText 3-strat fallback + SelectionCache

- Reviewed: 2026-07-23
- Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- Verdict: PASS with one caller-side note (task's "AX-only branch inside SelectedTextCapture" is not present — the equivalent behaviour lives at the caller).

## Files under review

- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SelectedTextCapture.swift`
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SelectionCache.swift`
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (lines 570-630)

## Reference source

- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.TextSelection.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/SelectionCache.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetSelectedTextTool.cs`

## 1. Three-strategy fallback order — PASS

Reference order (`VisualElementContext.TextSelection.cs:244-259` in `GetTextViaAXAPI`, plus the
strategy-3 chain in `BeginDetect` at `:208-216`):

- Strat 1 — `AXSelectedText` on `AXFocusedUIElement` (with `AXFocusedWindow` fallback) — `:238-249`
- Strat 2 — walk `AXChildren`, `AXSelectedText` on each — `:252-259`
- Strat 3 — Cmd-C via `GetTextViaClipboardAsync` — `:270-316`

Port sites in `SelectedTextCapture.swift`:

- Strat 1 — `capture(...)` line 110 -> `readSelectedText(focused)` (lines 191-202) after focus lookup
  (`focusedElement(of:)` at lines 165-173, which does the `AXFocusedUIElement` -> `AXFocusedWindow`
  two-step verbatim).
- Strat 2 — `capture(...)` lines 117-123, iterating `copyChildren(focused)` (single-level, matches
  reference's `foreach (var child in focusElement.Children)`).
- Strat 3 — `capture(...)` line 133 -> `clipboardCmdCFallback(pid:)` at lines 277-313.

Ordering, short-circuit on non-empty (mirrors `!string.IsNullOrEmpty(text)` at ref lines 246 and 255),
and the pid self-guard at line 98 (`pid == ProcessInfo.processInfo.processIdentifier`) matching
ref line 196 (`pid == Environment.ProcessId`) all line up.

## 2. SelectionCache — PASS

Reference: `SelectionCache.cs`.

- `Ttl = TimeSpan.FromMinutes(2)` (`:14`) — port has `public static let ttl: TimeInterval = 120`
  (`SelectionCache.swift:41`). Also asserted by
  `SelectedTextCaptureTests.swift:83` (`XCTAssertEqual(SelectionCache.ttl, 120)`).
- Single-slot, most-recent-wins — reference fields `_text`, `_appKey`, `_capturedAtUtc`
  at `:19-21`; port fields `text`, `appKey`, `capturedAt` at `SelectionCache.swift:53-55`. Port
  `store(...)` (`:84-92`) overwrites all three unconditionally when the incoming text is non-empty,
  matching ref `OnNext` (`:41-54`).
- `GetFresh` semantics — ref `:31-39`: return `null` if `string.IsNullOrEmpty(_text)` or
  `now - _capturedAtUtc > Ttl`. Port `getFresh()` (`:72-79`): return `nil` if `stored.isEmpty` or
  `clock().timeIntervalSince(captured) > ttl`. Strict `>` comparison preserved, verified by
  boundary test `test_getFresh_returnsValue_atTtlBoundary` (`SelectedTextCaptureTests.swift:50-56`).
- Injected clock — ref `TimeProvider _clock` (`:17,25`); port `clock: () -> Date` (`:49,57-63`).
- Thread safety — ref `Lock _gate` (`:16`), port `NSLock` (`:51`); app-key resolution happens outside
  the lock at ref `:46` and port stores an already-resolved key (resolution done at the call site in
  `SelectedTextCapture.swift:103`).

Empty-text-write ignored: `SelectionCache.swift:85` (`if text.isEmpty { return }`) matches
ref `:43` (`if (string.IsNullOrEmpty(value.Text)) return;`). Test coverage:
`SelectedTextCaptureTests.swift:58-62`.

## 3. Cmd-C fallback timing — PASS

Reference `GetTextViaClipboardAsync` (`:270-316`) + `SendCopyKeyAsync` (`:318-338`):

- `NSPasteboard.changeCount` pre-snapshot — ref `newClipboardSequence = GetClipboardSequence()` at
  `:273` (also `:302`); port at `SelectedTextCapture.swift:279`
  (`let preSequence = pasteboard.changeCount`).
- 10 iterations × 10 ms poll — ref `for (var i = 0; i < 10; i++) { await Task.Delay(10); ... }` at
  `:299-307`; port constants `clipboardPollIterations = 10` (`:267`) and
  `clipboardPollIntervalMs: UInt32 = 10` (`:263`), loop at `:295-301`.
- 5 ms delay between Cmd-C keyDown and keyUp — ref `await Task.Delay(5)` at `:329`; port constant
  `cmdKeyDelayMs: UInt32 = 5` (`:271`), applied at `:337` and `:341`.
- Restore original — ref writes back only the string via `WriteClipboard(originalClipboardContent)`
  at `:312`; port at `:305-310` prefers the item-level snapshot but falls back to the string-only
  path (`pasteboard.clearContents(); pasteboard.setString(original, forType: .string)`) when the
  deeper snapshot is nil, so the reference contract is preserved even in the degraded case.
- `CGEvent` posting — ref chooses `PostToPid` when `pid != 0` else `.HID` (`:326-337`); port at
  `SelectedTextCapture.swift:335-343` does the same (`down.postToPid(pid)` vs
  `down.post(tap: .cghidEventTap)`).

## 4. Password / secure-field skip — PASS (intentional divergence, verified)

Reference: no secure-field guard anywhere in `VisualElementContext.TextSelection.cs`,
`SelectionCache.cs`, or `GetSelectedTextTool.cs`. `GetTextViaClipboardAsync` (`:270-316`) will happily
send Cmd-C to a password field.

Port adds a guard at `SelectedTextCapture.swift:128-130` that returns `nil` before Strategy 3 if
`isSecureField(focused)` — implemented at `:231-242` by checking either `AXSubrole == AXSecureTextField`
or `AXRole == AXSecureTextField` (`kAXSecureTextFieldSubrole` literal). Divergence is documented in
the file header at `:27-33` and rationalised: Strat 1/2 are already no-ops on secure fields
(`AXSelectedText` returns nil), so the guard only affects Strat 3 where a Cmd-C would leak the
password into the pasteboard even after "restore" (kernel-level pasteboard listeners see the
transient value).

## 5. Full pasteboard restore vs string-only — PASS (intentional divergence, verified)

Reference: `ReadClipboard` (`:358-373`) returns `pasteboard.GetStringForType(NSPasteboardTypeString)`;
`WriteClipboard` (`:375-395`) calls `ClearContents()` + `SetStringForType`. Only the `.string` type
is preserved.

Port: `snapshotPasteboard` (`SelectedTextCapture.swift:356-374`) walks every
`NSPasteboardItem` and captures every `type -> data` pair; `restorePasteboard` (`:376-393`)
recreates each item with all types. Fallback to the reference's string-only behaviour when
`pasteboardItems` is nil (call site `:305-310`). Divergence documented in the header at `:33-38`.

## 6. Grapheme-safe boundary — PASS (Character iteration, no unicodeScalars)

Neither `SelectedTextCapture.swift` nor `SelectionCache.swift` uses `unicodeScalars` — verified by
inspection. The single length computation is `text.count` (`SelectedTextCapture.swift:153` in
`makeInfo`), which iterates `Character` clusters. `SelectedTextInfo.length` semantics documented at
`CaptureTypes.swift:614-616`. Grapheme preservation is asserted end-to-end by
`SelectedTextInfoTests.test_selectedTextInfo_preservesGraphemeSequences`
(`SelectedTextCaptureTests.swift:111-125`) using ZWJ family emoji + Arabic RTL.

## 7. Skip Strat 3 during preflight ("AX-only branch") — NEEDS ATTENTION (finding recategorised, not a defect)

Task item: openclicky is said to have an "AX-only" branch inside `SelectedTextCapture` that skips
Strategy 3 for preflight callers.

Actual state of the code:

- `SelectedTextCapture.capture(cache:)` has **no** such flag. It always attempts Strat 1 -> 2 ->
  password-guard -> 3. Signature at `SelectedTextCapture.swift:78` is a single-arg entry point.
- Grep across the port (`axOnly`, `AXOnly`, `skipCmdC`, `no.?clipboard`) returns 0 hits.
- The "no Cmd-C during hotkey preflight" behaviour actually lives at the CALLER:
  `cursor-buddy/OpenClickyContextStashWriter.swift:122-131` bypasses `SelectedTextCapture.capture(...)`
  entirely and reads `SelectionCache.shared.getFresh()` directly ("Selection: cache-only for the
  manual-preflight path so we never disrupt the user's clipboard with a Cmd-C poll on hotkey press").

Assessment: functional intent (do not Cmd-C during preflight) is achieved. Everywhere itself has no
equivalent because its capture is mouse-hook driven, so there is nothing to diff against. The
task-brief phrasing implied the toggle is inside `SelectedTextCapture`; it is not. If the roadmap
wants an "axOnly" parameter on `capture(...)` so future callers do not have to reimplement the
cache-only read, that is a pending API surface — flagged as follow-up, not a parity bug.

## 8. Cross-cutting divergences (documented in header, verified against reference)

- `AXEnhancedUserInterface` / `AXManualAccessibility` opt-in flips at ref `:261-266` are
  deliberately NOT ported into `SelectedTextCapture`. Header note at `:44-48`.
  `AXQuirksInstaller.swift` exists and owns those flips (confirmed via `grep`:
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AXQuirksInstaller.swift:9-15,124-128`).
- `_clipboardSequence` pre-mousedown early-exit at ref `:277-284` is intentionally omitted because
  openclicky is not mouse-hook driven; there is no pre-value to compare against. Header note at
  `:39-43`.
- `SelectedTextSource.child` and `.clipboardCmdC` are openclicky subdivisions of Everywhere's single
  `"focused"` / `"clipboard"` source values. Documented at `CaptureTypes.swift:570-582`. Wire
  compatibility note calls out how downstream JSON that must interop should collapse `.child` into
  `"focused"` at the envelope layer.

## Follow-ups (not blocking)

1. Consider adding an `axOnly: Bool = false` parameter to `SelectedTextCapture.capture(...)` so the
   preflight-side "no Cmd-C" contract is encoded in the capture API instead of being repeated at
   every hotkey call site (currently only `OpenClickyContextStashWriter.swift:122-131`).
2. `SelectedTextInfo.length` is currently computed at construction sites as `text.count`
   (`SelectedTextCapture.swift:153`, `:82-86`, `:112`, `:120`, `:135`). Once more producers appear it
   may be worth moving the derivation inside `SelectedTextInfo.init` to prevent drift, but this is
   cosmetic.
