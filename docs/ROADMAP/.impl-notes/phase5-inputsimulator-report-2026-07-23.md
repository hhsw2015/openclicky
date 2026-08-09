# Phase 5 — InputSimulator Port Report (2026-07-23)

## Deliverables

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/InputSimulator.swift`
  (new, 420-ish lines, no other source files touched).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/InputSimulatorTests.swift`
  (new, 43 XCTests).
- `KeyCode` public enum appended to
  `Sources/OpenClickyContextService/Types/CaptureTypes.swift`. Only
  addition — no existing type touched. Byte-parity with the
  `MacKeyCodes.cs` `kVK_*` constants (letters, digits, editing keys,
  function keys, keypad, and the four left-hand modifier keys).

Source header set exactly as required:

```
// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacInputSimulator.cs + MacKeyCodes.cs + Interop/KeyMapping.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
```

Impl notes: `docs/ROADMAP/.impl-notes/phase5-inputsimulator-2026-07-23.md`.

## Public API

```swift
public enum MouseButton { case left, right, middle }

public enum InputSimulator {
    public enum KeyError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case unknownModifier(String)
    }

    public static func typeText(_ text: String, delayMs: Int = 30)
    public static func pressKey(_ key: String, modifiers: [String] = []) throws
    public static func click(at point: CGPoint,
                             button: MouseButton = .left,
                             clickCount: Int = 1)
    public static func scroll(at point: CGPoint, dx: Int32, dy: Int32)
    public static func drag(from: CGPoint, to: CGPoint)
}
```

`pressKey` accepts both a fused xdotool string (`"cmd+shift+c"`, the
shape Everywhere's `ContextStashWriter.TryFireLaunchPhrase` uses) and
the split form (`("c", modifiers: ["cmd", "shift"])`, more Swift-y for
programmatic callers).

## Alignment audit — line-by-line vs `MacInputSimulator.cs`

### Event tap constant

- Everywhere: `CGEventPost(CGEventTapLocation.HidEventTap, ev)` where
  `HidEventTap = 0`.
- Swift port: `ev.post(tap: .cghidEventTap)`. Swift's
  `CGEventTapLocation.cghidEventTap` case has raw value 0 — byte match.
- Rationale preserved from source's own comment (MacInputSimulator.cs
  L224-227): HID tap sits below the session layer so SwiftUI gesture
  recognizers see the event. `.cghidEventTap` is also what
  `SelectedTextCapture.sendCopyKey` already uses in this package.

### Keycode table (byte-parity)

Cross-checked against `MacKeyCodes.KeyByName` (91 rows). Every entry
is present with identical hex value in
`InputSimulator.keyByName`, including all aliases:

- `return`/`enter` → 0x24; `space`/`spacebar` → 0x31.
- `escape`/`esc` → 0x35.
- `backspace`/`delete` → 0x33 (kVK_Delete, i.e. left-of-`return`).
- `del`/`forwarddelete` → 0x75 (kVK_ForwardDelete).
- `insert` → 0x72 (Help key, per Everywhere).
- `pageup`/`page_up`/`prior` → 0x74; `pagedown`/`page_down`/`next` → 0x79.
- All `kp_*` keypad aliases including the arrow-cluster overloads.

### Modifier table (byte-parity)

Cross-checked against `MacKeyCodes.Modifiers` (9 rows):

| xdotool alias         | Flag              | Keycode |
|-----------------------|-------------------|---------|
| cmd/command/super/meta| .maskCommand      | 0x37    |
| shift                 | .maskShift        | 0x38    |
| option/alt            | .maskAlternate    | 0x3A    |
| control/ctrl          | .maskControl      | 0x3B    |

Flag raw values verified in `test_flagMasks_matchEverywhereMacKeyCodes`:
`shift=0x00020000, control=0x00040000, alternate=0x00080000,
command=0x00100000` — identical to `MacKeyCodes.cs` L13-16.

### Grapheme decomposition

- Everywhere: `StringInfo.GetTextElementEnumerator` (Unicode TR29),
  UTF-16 buffer capped at 64 units, 20 ms sleep between chunks,
  oversize single grapheme posted alone.
- Swift port: `for cluster in text` (native TR29), `maxUnitsPerChunk = 64`,
  20 ms floor via `minChunkDelayMicros`, oversize cluster flushed
  alone. Verified by:
  - `test_graphemeChunks_neverSplitsMidGrapheme_familyEmoji` — a ZWJ
    family emoji whose UTF-16 length far exceeds a cap of 4 is emitted
    as one chunk.
  - `test_graphemeChunks_flushesBeforeExceedingCap` — every chunk
    stays under the cap and concatenates back to the input.
  - `test_graphemeChunks_cjkAggregatesToChunks` — CJK BMP characters
    fill chunks up to the cap without splitting.

### Modifier hold-and-tap sequence

- Everywhere `PressKey` — modifier keydowns forward with accumulating
  `activeFlags`, main keydown + keyup with full flags, modifier keyups
  reverse.
- Swift port — same three-phase sequence. `test_resolveChord_cmdC_producesExpectedTuple`
  and `test_resolveChord_cmdShiftC_producesTwoModifiersInOrder` verify
  the parse/resolve pipeline; the posting order is a visual match of
  the C# loop.

### Timings

- `PostMouse` → 30 ms sleep. Port uses `postMouseDelayMicros = 30_000`.
- Between grapheme chunks → 20 ms. Port floor
  `minChunkDelayMicros = 20_000`.
- After chord → 100 ms. Port `postChordDelayMicros = 100_000`.
- After scroll → 100 ms. Port `postScrollDelayMicros = 100_000`.
- Drag interpolation → 10 steps. Port `dragInterpolationSteps = 10`.

### Coverage gaps vs `MacInputSimulator.cs`

- `MoveTo` — not exposed as a public verb (task's five-verb surface).
  The internal `postMouse` helper covers the mechanic (drag uses it
  with `.mouseMoved`).
- `targetPid` — not plumbed through the public API. Everywhere's
  targeted path uses `CGEventPostToPid` + `CombinedSessionState`;
  the Swift primitives are available (`CGEvent.postToPid`,
  `CGEventSource(stateID: .combinedSessionState)`), so a future
  overload can add it without touching the current surface. Deferred
  because openclicky's near-term callers (LaunchPhrase, agent macro)
  all target the frontmost app.
- `Scroll(direction, pages, ...)` — the port exposes the low-level
  `(dx, dy)` shape called out by the task. The `pages`-based helper
  (`ComputeScrollDelta(pages) = round(12 * pages)`) is a caller-side
  concern; can layer over on top.

## Test result

```
Test Suite 'InputSimulatorTests' passed
Executed 43 tests, with 0 failures (0 unexpected) in 0.919 seconds
```

Full package build also clean:

```
$ swift build
Build complete!
```

Coverage:

- 20 unit tests on the parse / resolve / lookup helpers (no CGEvent
  side effects — always runnable).
- 4 grapheme decomposition tests (Unicode TR29 correctness).
- 5 `KeyCode` enum tests (byte-parity + Codable round-trip).
- 4 error-path tests for `pressKey` (empty key, unknown key, unknown
  modifier, empty modifier list edge cases).
- 10 smoke tests for the five posting verbs — gated by
  `XCTSkipIf(!canAllocateKeyboardEvent(), ...)` for headless CI, per
  the pattern already used by `SelectedTextCaptureTests`.

## Limitations

- OCCU (`LibAxHelper.dylib`) remains the primary MCP backend for
  `click` / `type_text` / `press_key` / `scroll` / `drag` tools. This
  Swift port is intentionally openclicky-native and serves
  LaunchPhrase-style injection and targeted agent input; it is not
  wired to the MCP tool dispatcher.
- No `targetPid` overload yet (see coverage gap above).
- Behavioural verification of actual event delivery requires a live
  WindowServer session with Input Monitoring TCC granted — the
  smoke tests only verify allocation + non-crash. `swift test` in
  headless CI does not catch delivery-side regressions; the golden-diff
  fixture (Everywhere + openclicky side-by-side) remains the
  authoritative behavioural check.

## Files touched

- `Sources/OpenClickyContextService/Capture/InputSimulator.swift`
  (new).
- `Tests/OpenClickyContextServiceTests/InputSimulatorTests.swift`
  (new).
- `Sources/OpenClickyContextService/Types/CaptureTypes.swift` —
  appended `KeyCode` enum at end; nothing else modified.
- `docs/ROADMAP/.impl-notes/phase5-inputsimulator-2026-07-23.md`
  (new).
- `docs/ROADMAP/.impl-notes/phase5-inputsimulator-report-2026-07-23.md`
  (this file).

No other files, no `Package.swift`, no bridge / stash writer / config
template / route dispatcher touched.
