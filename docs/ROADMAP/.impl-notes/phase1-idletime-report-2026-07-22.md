# Phase 1 - IdleTime port report (2026-07-22)

## Files created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/IdleTimeCapture.swift`
  - Public `enum IdleTimeCapture` with `static func capture() -> IdleTimeInfo?`.
  - Wraps `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`.
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/IdleTimeCaptureTests.swift`
  - 6 tests: non-nil reading, non-negative seconds, monotonic without input, cold-call safety, JSON round-trip, zero-seconds validity.

## Files modified

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - Appended `public struct IdleTimeInfo: Codable, Equatable, Sendable { public let seconds: TimeInterval }`.

## Notes files

- `docs/ROADMAP/.impl-notes/phase1-idletime-2026-07-22.md` - investigation.

## Ground-truth mapping

Everywhere source (`MacIdleTimeReader.cs`, 29 lines) uses **CoreGraphics `CGEventSourceSecondsSinceLastEventType`**, not IOKit. The task prompt guessed IOKit HID; ground truth was followed instead.

Constants preserved:
- `stateID = 0` -> `CGEventSourceStateID.combinedSessionState` (rawValue 0).
- `eventType = 0xFFFFFFFF` -> `CGEventType(rawValue: ~0)!` (kCGAnyInputEventType sentinel).

Return unit preserved: **seconds, floating-point** (`TimeInterval` == `Double`).

## Behavioural deviation from Everywhere

- Everywhere catches all exceptions and returns `0`.
- openclicky returns `nil` from `capture()` only when CoreGraphics reports a negative (invalid) reading. `0.0` is still a valid non-nil result. Callers who need the exact Everywhere shape can do `capture()?.seconds ?? 0`.

This is a strict superset - documented in the header comment and in the investigation note.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 18 (IdleTime | `MacIdleTimeReader.cs` | `Capture/IdleTimeCapture.swift` | P1) already matches the source, target, and priority. No doc edit needed.

## Test result

```
cd Packages/OpenClickyContextService && swift test
...
Test Suite 'IdleTimeCaptureTests' passed at 2026-07-22 22:24:31.632.
     Executed 6 tests, with 0 failures (0 unexpected) in 0.294 (0.296) seconds
Test Suite 'All tests' passed at 2026-07-22 22:24:31.632.
     Executed 25 tests, with 0 failures (0 unexpected) in 1.685 (1.692) seconds
```

All 25 package tests pass (6 IdleTime + 19 pre-existing).

## Build result

```
bash scripts/sign-and-install.sh
[0/5] verify cert exists in login keychain
[1/5] xcodebuild
** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=18962  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Signed + installed cleanly on the first attempt.
