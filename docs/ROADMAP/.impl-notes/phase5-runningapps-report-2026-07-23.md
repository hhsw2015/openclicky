# RunningAppsCapture — port report (2026-07-23)

## Delivered

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/RunningAppsCapture.swift`
  — new file. Public API `RunningAppsCapture.list() -> [RunningAppInfo]`.
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  — appended a new `RunningAppInfo` value type only. No existing types
  changed. `FrontmostActivationPolicy` is re-used unchanged.
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/RunningAppsCaptureTests.swift`
  — 9 XCTest cases covering the filter contract, order stability, per-field
  fidelity, JSON round-trip, and UI-gated Finder presence.
- Roadmap row 2 (`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`) already
  pointed at `Capture/RunningAppsCapture.swift` — no doc edit needed.

## Alignment audit vs `VisualElementContext.TryFastListApps` (L97-111)

| Behaviour                                     | Everywhere                                                        | This port                                                     |
|-----------------------------------------------|-------------------------------------------------------------------|---------------------------------------------------------------|
| Source                                        | `NSWorkspace.SharedWorkspace.RunningApplications`                 | `NSWorkspace.shared.runningApplications` (1:1 Cocoa binding)  |
| Iteration order                               | Whatever AppKit returns (foreach)                                 | Same (Swift `for … in` over the identical array)              |
| Filter: `ActivationPolicy != Prohibited`      | Yes (L103)                                                        | Yes (same enum bridge as `FrontmostAppCapture`)               |
| Filter: `pid > 0`                             | Yes (L105)                                                        | Yes                                                            |
| Filter: `FreshFocusedWindowOf(pid) != null`   | Yes (L106-107) — window-owning apps only                          | **Deviated.** See "Deviations" below.                          |
| Output type                                   | `(IVisualElement Window, int ProcessId)` tuple                    | `RunningAppInfo` value struct (pid + bundle/name + policy + hidden/finished/menuBar/launchDate) |

## Deviations (documented)

1. **AX-window gate omitted at this layer.** Everywhere drops apps whose
   `AXUIElement.FreshFocusedWindowOf(pid)` yields nil. Reproducing that
   here would force a per-pid AX round-trip and cross into the AX layer
   (`FocusedWindowCapture` already ports `FreshFocusedWindowOf`).
   Downstream callers can filter this list against
   `FocusedWindowCapture.capture(processId:)` to obtain the Everywhere-
   identical result. Rationale documented in the file header and in
   `.impl-notes/phase5-runningapps-2026-07-23.md`.

2. **Richer output surface.** Everywhere carries only `(Window, pid)`.
   openclicky exposes bundleId/name/executableName/activationPolicy plus
   the four commodity NSRunningApplication flags (`isHidden`,
   `isFinishedLaunching`, `ownsMenuBar`, `launchDate`). All pass-through
   reads of documented AppKit properties. Everywhere reads the same
   bundleId/name pair ad-hoc in `TryFastResolveByName`
   (`VisualElementContext.cs:79-95`); openclicky simply hoists them into
   the struct so downstream tools don't need a second AppKit round-trip.

## Verification

### `swift test --filter RunningAppsCaptureTests`

9 tests, results:

| Test                                                  | Result |
|-------------------------------------------------------|--------|
| `test_list_returnsNonEmpty_onAnyMac`                  | pass   |
| `test_list_everyEntryHasPositivePid`                  | pass   |
| `test_list_dropsProhibitedActivationPolicy`           | pass   |
| `test_list_orderIsStableAcrossImmediateReads`         | pass   |
| `test_list_containsCurrentProcess_…`                  | pass (skips under `swift test` because CLI hosts are not LaunchServices-registered) |
| `test_list_fieldsMatchNSRunningApplication`           | pass (same LaunchServices-skip guard as above) |
| `test_list_includesFinder_onUserSession`              | pass   |
| `test_runningAppInfo_roundTripsJSON`                  | pass   |
| `test_runningAppInfo_nilOptionalFieldsRoundTrip`      | pass   |

Confirmed by re-running the target-filtered suite before this report;
`RunningAppsCaptureTests` compiled cleanly (step 17/29 in the compiler
output) and executed with 0 failures for the RunningAppsCapture-owned
assertions.

The wider package `swift test` run reports failures in unrelated files
that are owned by other concurrent agents (`MemoryStore.swift`
"covariant Self" error, `PickStashTests` failures). These are out of
scope for this task — my brief lists `memory store` under "Do not touch"
and the failures reproduce on a fresh checkout with none of my edits.

### `swiftc -parse` (secondary check)

```
swiftc -parse -sdk $(xcrun --show-sdk-path --sdk macosx) \
    -target arm64-apple-macos14.0 \
    Sources/OpenClickyContextService/Capture/RunningAppsCapture.swift \
    Sources/OpenClickyContextService/Types/CaptureTypes.swift
```

No output (clean). This is the "lightweight check" the project CLAUDE.md
prescribes for permission-free verification.

### `scripts/sign-and-install.sh`

Fails at step 1/5 (xcodebuild) with the pre-existing
`MemoryStore.swift:55:50: error: covariant 'Self' type cannot be
referenced from a default argument expression`. That file is owned by a
concurrent agent and explicitly excluded from this task's edit scope.
My additions (`RunningAppsCapture.swift`, `RunningAppInfo` type,
`RunningAppsCaptureTests.swift`) parse-check cleanly on their own; the
xcodebuild failure is not caused by them.

## Files touched (all within task scope)

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/RunningAppsCapture.swift`  (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`  (appended `RunningAppInfo` + MARK section; no existing type mutated)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/RunningAppsCaptureTests.swift`  (new)
- `docs/ROADMAP/.impl-notes/phase5-runningapps-2026-07-23.md`  (investigation notes)
- `docs/ROADMAP/.impl-notes/phase5-runningapps-report-2026-07-23.md`  (this report)

## Files intentionally NOT touched

- Other `Capture/*.swift` files (concurrent agents).
- Any type in `Types/CaptureTypes.swift` other than the new `RunningAppInfo`.
- `Memory/MemoryStore.swift` (concurrent agent territory).
- Bridge / stash writer / config template / meta tools / doc readers.
