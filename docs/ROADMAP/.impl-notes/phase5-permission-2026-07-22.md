# Phase 5 - Permission preflight port investigation (2026-07-22)

## Ground truth

- Source: `~/Dev/Everywhere/src/Everywhere.Mac/Interop/PermissionHelper.cs`
- Rev: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- Line count: **51 lines**
- Consumer: bootstrap flow in `Everywhere.Mac` app startup that guarantees
  Accessibility trust before the CGEvent tap arms and prods
  ScreenRecording via a 1x1 sample capture.

## Semantics extracted

```csharp
public static void EnsureAccessibilityTrusted()
{
    var isTrusted = AXIsProcessTrustedWithOptions(
        new NSDictionary(AxTrustedCheckOptionPrompt, NSNumber.FromBoolean(true)));
    if (isTrusted) return;
    NativeMessageBox.Show(...); Environment.Exit(0);
}

public static void RequestForScreenRecordingPermission()
{
    using var _ = CGImage.ScreenImage(0, new CGRect(0, 0, 1, 1),
        CGWindowListOption.OnScreenOnly, CGWindowImageOption.Default);
}
```

Behaviour contract:

1. Accessibility check goes through `AXIsProcessTrustedWithOptions` with
   `AXTrustedCheckOptionPrompt = true`. Everywhere's variant IS a
   prompt-triggering call (System Settings pane appears if not trusted).
2. Screen recording is not really "checked" - Everywhere triggers a real
   1x1 `CGWindowListCreateImage` capture that macOS itself uses as the
   authorization moment.
3. Only two permissions are modelled in Everywhere's `PermissionHelper`:
   Accessibility and Screen Recording. Microphone, Input Monitoring, and
   Automation live in adjacent subsystems (voice input path, hotkey tap,
   AppleScript runner) rather than this helper.

## Deviations for openclicky's `PermissionPreflight`

Task requires a **check-only preflight**. Callers use this before
attempting a capture so they can render a "grant permission" hint
without triggering the system's own prompt. That means the Swift port
intentionally diverges from the C# source in two ways:

1. **Accessibility**: use bare `AXIsProcessTrusted()` (no options
   dictionary). The options-dictionary variant with `prompt = true`
   flips the prompt bit; the no-options variant is documented as a
   passive check. Same underlying result, no side effect.
2. **Screen recording**: use `CGPreflightScreenCaptureAccess()` instead
   of a live `CGWindowListCreateImage(...1x1...)` grab. Preflight was
   introduced macOS 10.15 exactly for this "check without prompting"
   use case.

Neither deviation changes the returned boolean semantics; both prevent
the prompt-storm the task disallows.

## Additional kinds beyond Everywhere source

The task prompt adds three that Everywhere does not model in
`PermissionHelper.cs` (they live elsewhere in Everywhere's codebase):

- **inputMonitoring**: `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`
  from `<IOKit/hid/IOHIDLib.h>`. Passive check, no prompt.
- **microphone**: `AVCaptureDevice.authorizationStatus(for: .audio)`.
  Returns `AVAuthorizationStatus`; passive.
- **automation** (per target bundle id, e.g. `com.apple.finder`):
  `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded = false`
  from AppleEvents (a.k.a. `<CoreServices/AE/AEHelpers.h>` /
  `AppleEventsCore`). The `askUserIfNeeded` flag is exactly the
  "no prompt" toggle we want.

## Status mapping

Return type is a Codable/Sendable enum (mirrors sibling captures):

```swift
public enum PermissionStatus: String, Codable, Sendable {
    case granted        // access confirmed available
    case denied         // access confirmed unavailable
    case notDetermined  // user has not been asked yet (AVAuthorizationStatus/IOHIDAccessType) 
    case restricted     // MDM / parental controls block the grant
    case unknown        // API returned a value we cannot classify
}
```

For APIs that only return `Bool` (`AXIsProcessTrusted`,
`CGPreflightScreenCaptureAccess`), we collapse to `.granted` /
`.denied` only. `.notDetermined` and `.restricted` cannot be
distinguished at that layer.

## Public API

```swift
public enum PermissionKind: String, Codable, Sendable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case microphone
    case automation(targetBundleId: String)  // must pass a target
}

public enum PermissionPreflight {
    public static func check(_ kind: PermissionKind) -> PermissionStatus
}
```

Because `PermissionKind` has an associated value, it cannot conform to
`RawRepresentable` with a `String` raw type in the strict sense. We
either drop the enum's `String` raw representation or split the
automation target into a separate parameter. **Chosen shape:** keep
`PermissionKind` associated-value-free (bare enum with `String` raw
type) and thread the automation target through a companion field on
`PermissionPreflight.check`. Concretely:

```swift
public enum PermissionKind: String, Codable, Sendable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case microphone
    case automation
}

public enum PermissionPreflight {
    public static func check(_ kind: PermissionKind,
                             automationTargetBundleId: String? = nil) -> PermissionStatus
}
```

Calling `.automation` without a bundle id returns `.unknown` (mirrors
the underlying API which requires a target AEDesc). Callers who need
automation checks always know which app they are about to talk to.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 25:

> 25 | ScreenRecording permission preflight | `PermissionHelper.cs` |
> `Capture/PermissionPreflight.swift`

Source path, target file, and priority correct. Row title mentions only
"ScreenRecording" but the file will handle all five kinds; that is a
title truncation, not a data model change. **No doc edit required**.

## Testing plan

XCTest coverage (all non-interactive, no prompt-inducing calls):

1. `check(.accessibility)` returns a `PermissionStatus` value (either
   `.granted` or `.denied`). Don't assert value - depends on env.
2. `check(.screenRecording)` returns a `PermissionStatus` value.
3. `check(.inputMonitoring)` returns a `PermissionStatus` value.
4. `check(.microphone)` returns a `PermissionStatus` value in the
   allowed set (any of `.granted / .denied / .notDetermined /
   .restricted`).
5. `check(.automation, automationTargetBundleId: nil)` returns
   `.unknown` (guard for missing target).
6. `check(.automation, automationTargetBundleId: "com.apple.finder")`
   returns a value. Environment-dependent so no value assertion.
7. Repeated calls do not crash and do not change state (idempotent
   preflight).
8. `PermissionStatus` and `PermissionKind` JSON round-trip.
