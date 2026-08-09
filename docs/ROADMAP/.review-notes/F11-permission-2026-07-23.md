# F11 PermissionPreflight (no prompt) - code review

Everywhere source pinned at `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Reviewed strictly against code.

## Sources
- openclicky preflight: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/PermissionPreflight.swift`
- openclicky types: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift:1105-1150`
- Everywhere: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/PermissionHelper.cs` (52 lines confirmed; task spec said 51 - off-by-one on the trailing brace)

## Checklist verification

### 1. Five permission kinds enumerated - PASS
`PermissionKind` (`CaptureTypes.swift:1109-1126`) declares all five: `.accessibility`, `.screenRecording`, `.inputMonitoring`, `.microphone`, `.automation`. `.allCases` derived from `CaseIterable`; used by tests (`PermissionPreflightTests.swift:93,107,124`).

### 2. Accessibility uses `AXIsProcessTrusted()` (no prompt) - PASS, divergent from Everywhere
- openclicky: `PermissionPreflight.swift:89-91` calls `AXIsProcessTrusted()` bare (no options dictionary). Returns `.granted`/`.denied`.
- Everywhere: `PermissionHelper.cs:22` calls `AXIsProcessTrustedWithOptions(AXTrustedCheckOptionPrompt=true)` - the prompting variant - during app bootstrap.
- This is the required divergence for a preflight. Documented at openclicky `PermissionPreflight.swift:15-23,84-88`.

### 3. Screen recording uses `CGPreflightScreenCaptureAccess()` (no probe) - PASS, divergent from Everywhere
- openclicky: `PermissionPreflight.swift:102-104` calls `CGPreflightScreenCaptureAccess()`.
- Everywhere: `PermissionHelper.cs:35-40` runs `CGImage.ScreenImage(0, CGRect(0,0,1,1), ...)` - a real 1x1 `CGWindowListCreateImage` capture.
- openclicky avoids the side-effecting probe. Documented at `PermissionPreflight.swift:23-27,93-101`.

### 4. Never triggers TCC prompt - PASS
Per-kind audit:
- Accessibility: `AXIsProcessTrusted()` - passive (line 90).
- ScreenRecording: `CGPreflightScreenCaptureAccess()` - documented "check without prompting" (line 103).
- InputMonitoring: `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` (line 112). This is the check-only variant; `IOHIDRequestAccess` is the prompter and is not called.
- Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)` (line 131). Pure getter; `requestAccess(for:)` is the prompter and is not called. Comment at 128-129 states this explicitly.
- Automation: `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)` (line 189-194). The `false` flag is the toggle that keeps the call passive.

No prompt path reachable.

### 5. Automation requires bundle_id target - PASS
- `PermissionPreflight.swift:63-66` accepts `automationTargetBundleId: String?`.
- `checkAutomation` (163-207): guard on line 164-166 returns `.unknown` for nil/empty. AECreateDesc uses `typeApplicationBundleID` (line 177). Wildcard event class/id (`typeWildCard`, lines 191-192).
- Status decode (196-206): `noErr`->granted, `errAEEventNotPermitted (-1743)`->denied, `errAEEventWouldRequireUserConsent (-1744) || procNotFound (-600)`->notDetermined, default unknown.
- `AEDisposeDesc` deferred (line 187) so descriptor is released on every branch.
- Everywhere has no equivalent method in `PermissionHelper.cs`; this is an openclicky extension consolidated from the AppleScript runner subsystem. Documented at `PermissionPreflight.swift:28-32,146-162`.

### 6. Extra checks (InputMonitoring / Microphone) - PASS
Not in Everywhere's `PermissionHelper.cs`; openclicky consolidates them from adjacent Everywhere subsystems (voice input, hotkey tap) per file-header comment lines 28-32. IOHID and AVFoundation mappings above are the documented check-only entry points.

## Findings
1. Every macOS API used is the passive/check-only variant. No prompt-triggering call reachable through `PermissionPreflight.check`.
2. Two intentional deviations from Everywhere (accessibility variant, screen-recording probe->preflight) are both documented in-source with rationale.
3. `AEDisposeDesc` cleanup via `defer` covers all branches - no descriptor leak.
4. `IOHIDCheckAccess` unknown enum handling (line 120-122) collapses future values to `.unknown` via `default`, which matches the `@unknown default` pattern used for `AVAuthorizationStatus` (line 141).

## Verdict

F11 accepted. Five-kind surface is complete, no TCC prompt reachable, `.automation` correctly demands a bundle-id target and passes `askUserIfNeeded: false`. Two intentional deviations from Everywhere are documented and correct for a preflight.
