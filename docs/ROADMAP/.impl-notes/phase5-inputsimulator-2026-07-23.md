# Phase 5 — InputSimulator Port (2026-07-23)

Port target: Everywhere `src/Everywhere.Mac/Mcp/MacInputSimulator.cs`
@30e03e9d (389 lines), plus keycode + modifier tables from
`src/Everywhere.Mac/Mcp/MacKeyCodes.cs` @30e03e9d (105 lines) and the
CGEventFlags mapping helpers referenced by
`src/Everywhere.Mac/Interop/KeyMapping.cs` @30e03e9d (107 lines).

## Everywhere source read

### `MacInputSimulator.cs`

Implements `IInputSimulator` with:

- `MoveTo(x, y, targetPid?)` — creates a `CGEventSource` (state id switches
  by targeting: `HidSystemState` for global, `CombinedSessionState` when a
  pid is supplied), then `PostMouse(..., MouseMoved, ...)`.
- `Click(x, y, clickCount, MouseButton, targetPid?)` — for each click:
  a `MouseMoved` at target coords, then `<btn>Down` + `<btn>Up`, with the
  `MouseEventClickState` field set to `clickCount` so double / triple
  click semantics land. Between calls `PostMouse` sleeps 30 ms.
- `DragTo(fromX, fromY, toX, toY, targetPid?)` — mouse move → button
  down at `from` → 10 `LeftMouseDragged` steps linearly interpolated
  between `from` and `to` → button up at `to`.
- `TypeText(text, targetPid?)` — grapheme-aware: uses
  `StringInfo.GetTextElementEnumerator` (Unicode TR29 clusters), packs
  clusters into a UTF-16 buffer capped at `maxUTF16Units = 64`, and
  posts each chunk as a keydown+keyup pair whose `virtualKey` is `0`
  but whose payload is set via `CGEventKeyboardSetUnicodeString`. 20 ms
  sleep between chunks. A single grapheme longer than the 64-unit cap
  is posted alone (never split mid-cluster — ZWJ / flag sequences must
  survive).
- `PressKey(xdotoolKeyName, targetPid?)` — parses lowercased,
  `+`-separated tokens. Last token = main key (must resolve via
  `MacKeyCodes.KeyByName`). Preceding tokens = modifiers (each must
  resolve via `MacKeyCodes.Modifiers` to `(flag, virtualKey)`). Emits
  modifier keydowns in order (accumulating `activeFlags`), then main
  keydown + keyup with `activeFlags`, then modifier keyups in reverse
  order. Sleep 100 ms after the sequence.
- `Scroll(direction, pages, targetPid?)` — computes an integer line
  delta as `round(12 * pages)` clamped to `[1, int.MaxValue]`, maps
  `direction ∈ {up,down,left,right}` to a `(w1, w2)` pair (w1 = vertical,
  w2 = horizontal, sign reversed to match Everywhere's scroll model),
  then creates `CGScrollEventUnit.Line` two-axis event. 100 ms sleep.

Event posting:
- `PostEvent(ev, targetPid?)` — targeted path: `CGEventPostToPid(pid, ev)`;
  global path: `CGEventPost(HidEventTap, ev)`.
- **Not** `SessionEventTap`. The C# source's own comment (lines 224-227)
  explains: `HidEventTap` sits below the session layer so posted events
  reach SwiftUI's gesture recognizers; `SessionEventTap` posts *above*
  that layer where gestures may be filtered out, causing regressions
  like "Calculator '7' click looks fine but does nothing".
- This matches openclicky's existing `SelectedTextCapture.sendCopyKey`,
  which already uses `.cghidEventTap` for the same reason (documented
  in `feat(mac/click): global event tap = .cghidEventTap`).

### `MacKeyCodes.cs`

Contains four modifier flag masks + the `kVK_*` Carbon virtual-key
constants (letters, digits, arrows, function keys, keypad, editing keys,
modifiers) plus two lookup dictionaries:

- `KeyByName: Dictionary<string, ushort>` — xdotool-style names to
  Carbon vk codes. Alias sets: `return`/`enter`, `space`/`spacebar`,
  `escape`/`esc`, `backspace`/`delete` → 0x33 (kVK_Delete), `del`/
  `forwarddelete` → 0x75 (kVK_ForwardDelete), `insert` → 0x72 (Help
  key), page up/down with `pageup`/`page_up`/`prior` and
  `pagedown`/`page_down`/`next`, keypad numerics `kp_0..kp_9`, and
  keypad aliases `kp_home`/`kp_left`/`kp_up`/... that map to the
  non-keypad equivalents (Everywhere leans on those because macOS's
  keypad-nav keys share vk codes with the arrow cluster on many
  layouts).
- `Modifiers: Dictionary<string, (ulong Flag, ushort KeyCode)>` — flags
  come from `CGEventFlags` (`Shift=0x00020000`, `Control=0x00040000`,
  `Alternate=0x00080000`, `Command=0x00100000`); keycodes are the
  Carbon vk codes for the left-hand modifier keys. Aliases:
  `cmd`/`command`/`super`/`meta` → Command, `option`/`alt` → Alternate,
  `control`/`ctrl` → Control, `shift` → Shift.

### `Interop/KeyMapping.cs`

Not directly consumed by the port — it maps `CGEventFlags` ↔
Avalonia's `KeyModifiers` for Everywhere's UI side. Verified only that
the flag constants (`Shift`, `Control`, `Alternate`, `Command`) agree
with the raw bit values in `MacKeyCodes.cs`; they do.

## OpenClicky adaptation

### Placement

- File: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/InputSimulator.swift`
- Tests: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/InputSimulatorTests.swift`
- Renamed to `InputSimulator` (not `MacInputSimulator`) so the intent
  reads as openclicky-native, not "the MCP click backend". OCCU still
  owns MCP `click` / `type_text` / `press_key` / `scroll` / `drag` via
  `LibAxHelper.dylib`; this port serves openclicky's own use cases:
  - LaunchPhrase / macro injection (see `ContextStashWriter.TryFireLaunchPhrase`
    on the Everywhere side).
  - Targeted agent input (typing into HUDs, dispatching Cmd-⇧-3, etc.).

### Public API

Mirrors Everywhere signatures but simplified to the five verbs the
task calls out:

```swift
public enum InputSimulator {
    public static func typeText(_ text: String, delayMs: Int = 30)
    public static func pressKey(_ key: String, modifiers: [String] = []) throws
    public static func click(at point: CGPoint,
                             button: MouseButton = .left,
                             clickCount: Int = 1)
    public static func scroll(at point: CGPoint, dx: Int32, dy: Int32)
    public static func drag(from: CGPoint, to: CGPoint)
}

public enum MouseButton { case left, right, middle }
```

`pressKey` also accepts a fused xdotool string
(`"cmd+shift+c"`)  because the C# side's single-argument
`PressKey(xdotoolKeyName)` is the primary shape used from
`ContextStashWriter.TryFireLaunchPhrase`. The Swift shape supports
both by parsing the fused form when `modifiers` is empty and a `+` is
present in `key`.

### Grapheme-aware `typeText`

Swift makes this cleaner than the C# version — `String` iterates by
extended grapheme cluster natively (`for char in text`). Chunking rule
matches OCCU (referenced by both Everywhere and openclicky):

```
maxUnitsPerChunk = 64          // UTF-16 code units, per CGEvent limit
buffer = ""
for cluster in text {
    if !buffer.isEmpty && buffer.utf16.count + cluster.utf16.count > 64 {
        flush(buffer); usleep(20_000); buffer = ""
    }
    if cluster.utf16.count > 64 {
        // single cluster larger than cap — post alone to avoid split
        flush(String(cluster)); usleep(20_000)
    } else {
        buffer.append(cluster)
    }
}
if !buffer.isEmpty { flush(buffer) }
```

Where `flush(chunk)`:

- creates `CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)`
  and matching `keyDown: false`;
- fills the payload via `CGEvent.keyboardSetUnicodeString(_:)` on both
  down and up events (Everywhere sets the same buffer on both);
- posts to `.cghidEventTap`.

For pure-ASCII ranges we do **not** short-circuit to the keycode table
(Everywhere doesn't either). Unicode string path handles ASCII correctly
and keeps modifier state clean — critical for LaunchPhrase where the
phrase may already be typed while a hotkey modifier is briefly down.

### `pressKey` — modifier hold-and-tap

Same sequence as C#:

1. Look up the main keycode via the `keyByName` table.
2. Look up each modifier via the `modifiers` table (case-insensitive,
   trimmed, lowercased).
3. Post modifier keydowns in order, accumulating a `CGEventFlags`
   value on each event.
4. Post main keydown then main keyup, both stamped with the full
   accumulated flag set.
5. Post modifier keyups in *reverse* order — same ordering property
   the C# source relies on so modifier release matches AppKit's
   expectations.

Unknown key name → the function throws `InputSimulator.KeyError` so
the caller can surface a useful diagnostic (Everywhere throws
`ArgumentException`).

### `click` / `drag` / `scroll`

- `click` uses `PostMouse(MouseMoved)` first, then `Down` + `Up`, and
  sets `mouseEventClickState` to `clickCount` on both down and up. For
  N-click, Everywhere loops N times reusing the same event source; we
  do the same. 30 ms sleep between `PostMouse` calls to match the
  C# path (`Thread.Sleep(30)` in `PostMouse`).
- `drag` mirrors Everywhere: move → LeftMouseDown at `from` → 10
  `LeftMouseDragged` steps, `p = step / 10.0` linear lerp → LeftMouseUp
  at `to`.
- `scroll` takes raw `(dx, dy)` line deltas. Everywhere's
  `ComputeScrollDelta(pages)` is a caller-side concern (a `.pages`
  API on top). Task requested the low-level `(dx, dy)` shape; the
  callers can multiply by 12 if they want page semantics. Wheel1 is
  vertical, wheel2 horizontal — matches
  `CGEventCreateScrollWheelEvent2(_, .line, 2, w1, w2, 0)`.

### CGEventTap choice

`.cghidEventTap` (Swift enum case for `kCGHIDEventTap`). Byte-identical
to Everywhere's `CGEventTapLocation.HidEventTap = 0`. Task explicitly
called out this alignment.

### Event source

Everywhere creates one `CGEventSource` per verb (`HidSystemState` for
global, `CombinedSessionState` for pid-targeted). openclicky's shape
does not expose a `targetPid` parameter in the five public verbs (per
task), so all sources use the global `HidSystemState`. Swift's
`CGEventSource(stateID: .hidSystemState)` is the equivalent.

## Types appended to CaptureTypes.swift

Only one addition:

```swift
public enum KeyCode: UInt16, Codable, Sendable {
    case a = 0x00, b = 0x0B, c = 0x08, ...
}
```

Rationale for putting `KeyCode` in the shared types file: it's a
codable enum useful to callers who want to serialise a chord for a
LaunchPhrase config. `MouseButton` stays with `InputSimulator`
because it has no wire representation yet.

## Test strategy

XCTest coverage, all headless-safe:

1. `typeText` grapheme decomposition — inject a fake sink so we can
   assert on the sequence of chunks *without* actually posting. Since
   the port itself uses CGEvent globals we cannot inject easily; the
   fallback is to call `typeText("hello")` and assert it doesn't
   throw / crash, plus unit-test the internal chunking function
   exposed as `internal` so the test target can see it.
2. `pressKey("Return")` — verify keycode lookup returns 0x24. Do it
   by exposing `internal static func resolve(_ name:) -> UInt16?` on
   `InputSimulator` and asserting `resolve("return") == 0x24`.
3. `pressKey("cmd+c")` — assert modifier parsing yields
   `([(.maskCommand, 0x37)], main = 0x08)`. Same pattern: expose an
   internal `parse` helper.
4. `pressKey("你好" as a modifier)` — invalid modifier / key name,
   assert throws.
5. Actual event posting: `XCTSkipIf` when the process cannot post
   HID events (headless CI). We do a smoke call and only assert no
   crash. Full behavioural coverage requires a real WindowServer +
   Input Monitoring TCC grant, which is the same limitation
   `SelectedTextCaptureTests` runs into.

## Verification checklist

- [ ] Keycode table matches `MacKeyCodes.cs` byte-for-byte.
- [ ] Modifier flag masks match: `shift=0x00020000`, `control=0x00040000`,
  `alternate=0x00080000`, `command=0x00100000`.
- [ ] Event tap constant matches: `.cghidEventTap` ⇔ HID=0.
- [ ] Grapheme chunk size 64 UTF-16 units, 20 ms between chunks.
- [ ] `click` posts move + N × (down, up) with `clickState` field set.
- [ ] `drag` uses 10 interpolation steps.
- [ ] Modifier keydowns forward, keyups reverse.
- [ ] `swift test` green.
