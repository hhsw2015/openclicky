# Phase 5 - Permission preflight port report (2026-07-22)

## Deliverables

| File | Purpose | Status |
|------|---------|--------|
| `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/PermissionPreflight.swift` | Port of Everywhere `PermissionHelper.cs`, extended to five kinds | new |
| `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` | Appends `PermissionKind`, `PermissionStatus` enums | edited (append only) |
| `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/PermissionPreflightTests.swift` | 11 XCTest cases | new |
| `docs/ROADMAP/.impl-notes/phase5-permission-2026-07-22.md` | Investigation notes | new |
| `docs/ROADMAP/.impl-notes/phase5-permission-report-2026-07-22.md` | This report | new |

## Ground-truth pin

Everywhere source pinned at rev
`30e03e9dcfdd4247fd679828ed86e9042f32d809`, file
`src/Everywhere.Mac/Interop/PermissionHelper.cs` (51 lines). Header of
`PermissionPreflight.swift` cites this pin verbatim as required.

## Public API

```swift
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case microphone
    case automation
}

public enum PermissionStatus: String, Codable, Sendable, Equatable {
    case granted, denied, notDetermined, restricted, unknown
}

public enum PermissionPreflight {
    public static func check(
        _ kind: PermissionKind,
        automationTargetBundleId: String? = nil
    ) -> PermissionStatus
}
```

Automation checks take an optional bundle id via a companion parameter
rather than an associated-value enum case, because keeping
`PermissionKind` a plain `String`-rawed enum lets it Codable-roundtrip
and pattern-match cleanly at call sites. Passing nil / empty target for
`.automation` yields `.unknown` (deterministic, documented).

## Backing APIs (kind by kind)

| Kind | Everywhere source | openclicky binding | Notes |
|------|-------------------|--------------------|-------|
| accessibility | `AXIsProcessTrustedWithOptions` (prompt=true) | `AXIsProcessTrusted()` | Deliberately switched to the passive variant so preflight never prompts. Same trust bit, no side effect. |
| screenRecording | live 1x1 `CGWindowListCreateImage` | `CGPreflightScreenCaptureAccess()` | Deliberately switched to preflight - no black-image side effect, no TCC access-attempt entry. |
| inputMonitoring | (not in `PermissionHelper.cs`) | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` | Everywhere checks this in its hotkey subsystem; openclicky consolidates here. |
| microphone | (not in `PermissionHelper.cs`) | `AVCaptureDevice.authorizationStatus(for: .audio)` | Full four-way status matrix (authorized/denied/notDetermined/restricted). |
| automation | (not in `PermissionHelper.cs`) | `AEDeterminePermissionToAutomateTarget(_, _, _, askUserIfNeeded: false)` | `askUserIfNeeded: false` is the "no prompt" toggle. OSStatus mapped to `PermissionStatus` per header comment. |

## Alignment audit vs Everywhere

Side-by-side of the two Everywhere entry points, byte for byte:

| Everywhere symbol | Everywhere impl | Port impl | Semantic delta |
|-------------------|-----------------|-----------|----------------|
| `EnsureAccessibilityTrusted` | `AXIsProcessTrustedWithOptions(options={AXTrustedCheckOptionPrompt:true})`; if false, show dialog + `Environment.Exit(0)` | `checkAccessibility()` uses `AXIsProcessTrusted()` and returns `.granted`/`.denied` | preflight is check-only; no prompt, no dialog, no process termination. Return-value semantics unchanged (both surface the bool). |
| `RequestForScreenRecordingPermission` | live `CGImage.ScreenImage(..., 1x1, ...)` grab | `checkScreenRecording()` uses `CGPreflightScreenCaptureAccess()` and returns `.granted`/`.denied` | preflight is check-only; no capture attempt, no attributed access entry in TCC. Return-value semantics unchanged. |

Everywhere models nothing else in `PermissionHelper.cs`. The three
additional kinds (inputMonitoring, microphone, automation) are pure
extensions to satisfy openclicky's cross-cutting preflight needs.

## Testing

`swift test --filter PermissionPreflightTests` -> **11/11 passing**.

```
Executed 11 tests, with 0 failures (0 unexpected) in 0.314 seconds
```

Full suite: `swift test` -> **190/190 passing** (no regressions across
existing captures).

Test coverage matrix (per task spec):

| Requirement | Test |
|-------------|------|
| `check(.accessibility)` returns Boolean-ish, env-dependent | `test_check_accessibility_returnsGrantedOrDenied` |
| `check(.screenRecording)` returns Boolean-ish, env-dependent | `test_check_screenRecording_returnsGrantedOrDenied` |
| Doesn't crash if denied | `test_check_doesNotThrowOrCrashInDeniedEnvironments` |
| Doesn't prompt (preflight is check-only) | Enforced by construction (only `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, `IOHIDCheckAccess`, `AVCaptureDevice.authorizationStatus`, and `askUserIfNeeded: false` are called). Also implicitly asserted by `test_check_isSafeToCallRepeatedly` running each kind twice without user interaction. |
| Extra: `inputMonitoring` allowed set | `test_check_inputMonitoring_returnsInAllowedSet` |
| Extra: `microphone` allowed set | `test_check_microphone_returnsInAllowedSet` |
| Extra: `automation` without target -> `.unknown` | `test_check_automation_withoutTargetReturnsUnknown` |
| Extra: `automation` with real target | `test_check_automation_withTargetReturnsInAllowedSet` |
| Extra: `automation` with bogus target | `test_check_automation_withUnknownTargetReturnsUnknownOrNotDetermined` |
| JSON round-trip of `PermissionStatus` / `PermissionKind` | `test_permissionStatus_roundTripsJSON`, `test_permissionKind_roundTripsJSON` |

`bash scripts/sign-and-install.sh` -> **SUCCESS**. Persistent-signed
`OpenClicky.app` built, replaced `/Applications/OpenClicky.app`,
relaunched, pid=96771 with `Authority=OpenClicky Dev Sign`. TCC
identity preserved.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 25 already points at
`Capture/PermissionPreflight.swift` and sources
`PermissionHelper.cs`. No doc edit needed.

## Scope discipline

- Only touched three files inside
  `Packages/OpenClickyContextService/`: the new `PermissionPreflight.swift`,
  the new tests file, and an append-only edit to `Types/CaptureTypes.swift`.
- Did not touch any other capture, any main-app file, any script, or
  any resource.
- Did not run bare `xcodebuild` - built + installed exclusively via the
  sanctioned `scripts/sign-and-install.sh` wrapper.

## Deviations from Everywhere (with rationale)

1. **Accessibility check switched to `AXIsProcessTrusted()`** (no
   options). Everywhere's helper is bootstrap-side and wants to
   *force* the grant; openclicky's preflight is UI-facing and must not
   trigger the system prompt. Both surface the same trust bit.
2. **Screen recording switched to `CGPreflightScreenCaptureAccess()`**.
   Everywhere's live 1x1 capture doubles as a permission prompt +
   silent-fail probe. openclicky needs a passive check with no capture
   side effect. Same underlying TCC state observed.
3. **Return type changed from `void` to `PermissionStatus`**. Callers
   need a value they can render in UI ("Grant screen recording"); C#
   Everywhere uses `Environment.Exit(0)` because the helper is a bootstrap
   assertion.
4. **Extended surface from two kinds to five**. inputMonitoring,
   microphone, automation live outside `PermissionHelper.cs` in
   Everywhere; consolidated here to match the task brief.

All deviations documented inline in
`PermissionPreflight.swift`'s header comment and in
`docs/ROADMAP/.impl-notes/phase5-permission-2026-07-22.md`.
