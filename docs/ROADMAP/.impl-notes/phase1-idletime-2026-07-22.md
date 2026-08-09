# Phase 1 - IdleTime port investigation (2026-07-22)

## Ground truth

- Source: `~/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacIdleTimeReader.cs`
- Rev: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- Line count: **29 lines**
- Consumer: `~/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetIdleTimeTool.cs`

## Semantics extracted

```csharp
public double GetIdleSeconds()
{
    try { return CGEventSourceSecondsSinceLastEventType(0, 0xFFFFFFFF); }
    catch { return 0; }
}
```

Behaviour contract:

1. Backing API: `CGEventSourceSecondsSinceLastEventType(int stateID, uint eventType)` from `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics`.
   - **NOT IOKit HIDIdleTime** (task prompt guessed wrong; Everywhere uses CoreGraphics).
2. `stateID = 0` -> `kCGEventSourceStateCombinedSessionState`. Combined session state = union of hardware + posted events.
3. `eventType = 0xFFFFFFFF` (`uint.MaxValue`, aka `~0`) -> "any input event". Documented CoreGraphics behaviour: passing an out-of-range event type returns the age of the most recent event of any type.
4. Return unit: **`double` seconds** since the last input event (keyboard / mouse / trackpad / etc.).
5. Return value on error: `0` (the C# `try/catch` swallows all exceptions and returns 0).
6. No caching, no state, no cross-call coupling. Each call is an independent CoreGraphics query.

Consumer `GetIdleTimeTool.cs` wraps this in `{"idle_seconds": number}` JSON.

## Return type semantics

Everywhere's shape is a plain scalar (`double GetIdleSeconds()`), not a struct. Two options:

- Option A: match exactly - `IdleTimeCapture.capture() -> TimeInterval`.
- Option B: wrap in `IdleTimeInfo { seconds: TimeInterval }` for future extensibility (e.g. per-source breakdown, event-type ages).

Choice: **Option B**, add `IdleTimeInfo` to `Types/CaptureTypes.swift`. Rationale:

- Matches the shape of sibling captures (`FrontmostAppInfo`, `ClipboardInfo`) - all wrap a scalar or two in a Codable/Sendable struct so downstream stash/IPC can round-trip.
- One-field struct is trivial and cheap.
- Makes the "seconds" unit explicit at the type level (`TimeInterval` alone is ambiguous vs a duration).

Public API:

```swift
public struct IdleTimeInfo: Codable, Sendable, Equatable {
    public let seconds: TimeInterval
}

public enum IdleTimeCapture {
    public static func capture() -> IdleTimeInfo?
}
```

`nil` return matches Everywhere's implicit "unavailable" case: the C# path returns `0` on catch but that is indistinguishable from a genuine "user just typed" reading. Swift-side, we return `nil` only if the CoreGraphics call fails in a way we can detect (returns a negative value, which is documented as "invalid"); otherwise we return the value (including `0.0`). This is a strict superset of Everywhere's behaviour.

## Swift binding

`CGEventSourceSecondsSinceLastEventType` is declared in `CoreGraphics/CGEvent.h` and re-exported via `import CoreGraphics`:

```swift
public func CGEventSourceSecondsSinceLastEventType(
    _ stateID: CGEventSourceStateID,
    _ eventType: CGEventType
) -> CFTimeInterval
```

Constants:

- `CGEventSourceStateID.combinedSessionState` (rawValue `0`) matches Everywhere's `0`.
- `CGEventType` is a `UInt32` enum. `uint.MaxValue` (0xFFFFFFFF) is not one of the named cases; Swift's strict enum bridging requires `CGEventType(rawValue: ~0)`. Empirically this is `kCGAnyInputEventType` (unofficial, documented in Apple sample code as the sentinel for "any event age").

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 18:

> IdleTime | `MacIdleTimeReader.cs` | `Capture/IdleTimeCapture.swift` | P1

Source path, target file, priority all correct. No doc edit needed.

## Testing plan

XCTest:

1. `capture()` returns a non-nil value with `seconds >= 0`.
2. Two calls with a short `Thread.sleep` between them: second `seconds` >= first `seconds` (idle time monotonically increases while no input happens; the tests run headlessly so no input is injected).
3. Cold call does not crash.
4. `IdleTimeInfo` JSON round-trip preserves value.
