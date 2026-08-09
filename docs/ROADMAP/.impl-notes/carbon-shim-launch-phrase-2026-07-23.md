# Carbon front-process shim for launch-phrase settle failures

Date: 2026-07-23

## Symptom

`openclicky.launch_phrase.settle_failed` fires every hotkey press when
targeting cmux (or any other agent app). Match logic is correct; the
2.4s (16 x 150ms) settle loop just never observes
`NSWorkspace.frontmostApplication == cmux` because
`NSRunningApplication.activate(options:)` is downgraded on macOS 26 for
LSUIElement callers (Openclicky is a menu-bar app with `LSUIElement=true`).

## Fix

Restore the Carbon `SetFrontProcessWithOptions` fallback that Everywhere
uses (`Everywhere/src/Everywhere.Mac/Interop/MacAppActivator.cs:113-123,
264-296` @ 30e03e9d). The Swift SDK marks `GetProcessForPID` /
`SetFrontProcessWithOptions` unavailable, but the C symbols are still
exported from ApplicationServices -> HIServices (Processes.h) and are
callable from Objective-C. Ported the P/Invoke pattern to an Obj-C shim
that Swift reaches through the existing bridging header.

## Files touched

- `cursor-buddy/OpenClickyOverlayObjCBridge.h` (+15 lines)
  - New declaration: `BOOL OpenClickyCarbonSetFrontProcess(pid_t pid);`
  - See lines 38-49.
- `cursor-buddy/OpenClickyOverlayObjCBridge.m` (+30 lines)
  - Adds `#import <ApplicationServices/ApplicationServices.h>` and a
    `#pragma clang diagnostic ignored "-Wdeprecated-declarations"` block
    scoped to the new function.
  - `OpenClickyCarbonSetFrontProcess` body at lines 68-84 calls
    `GetProcessForPID` then `SetFrontProcessWithOptions(&psn, 0x1u)`
    (kSetFrontProcessFrontWindowOnly), mirroring
    `MacAppActivator.cs:294`.
- `cursor-buddy/OpenClickyAppActivator.swift`
  - `tryCarbonSetFront(pid:)` at line 147 is no longer a stub - it
    invokes the shim and logs
    `openclicky.launch_phrase.carbon_set_front { pid, ok }`.
  - Added `openclicky.launch_phrase.nsworkspace_activate` log right
    after `app.activate(...)` in `activate(_:)` (approx line 105) so
    we can confirm the polite path was invoked with the expected
    bundle / name / pid.
  - Added `openclicky.launch_phrase.settle_frontmost_snapshot` log
    right before `settle_failed` in `fireLaunchPhrase`, capturing
    `expected`, `actual_bundle`, `actual_name`, `actual_pid` so we can
    finally see who is holding focus when the loop times out.

## Grep-verify

```
$ grep -n "OpenClickyCarbonSetFrontProcess" cursor-buddy/OpenClickyOverlayObjCBridge.h cursor-buddy/OpenClickyOverlayObjCBridge.m cursor-buddy/OpenClickyAppActivator.swift
cursor-buddy/OpenClickyAppActivator.swift:149:        let ok = OpenClickyCarbonSetFrontProcess(pid)
cursor-buddy/OpenClickyOverlayObjCBridge.h:49:BOOL OpenClickyCarbonSetFrontProcess(pid_t pid);
cursor-buddy/OpenClickyOverlayObjCBridge.m:68:BOOL OpenClickyCarbonSetFrontProcess(pid_t pid) {
```

`tryCarbonSetFront` is still declared (line 148) but now contains the
shim call + log emit at lines 149-158, not the `_ = pid` stub.

## Build verification

`bash scripts/sign-and-install.sh` -> `** BUILD SUCCEEDED **`, signed
with `OpenClicky Dev Sign`, installed to `/Applications/OpenClicky.app`,
launched as pid 1773 (`com.jkneen.openclicky`). No zombie Node children
detected post-install.

## User verification steps

1. Focus a non-cmux app (browser, Finder).
2. Press Shift+Space to fire the snapshot + launch phrase.
3. Tail the log:
   ```
   curl -sS -H "x-openclicky-token: $TOKEN" \
     'http://127.0.0.1:32123/agent/log/tail?count=300' \
     | grep -E 'launch_phrase|carbon_set_front'
   ```
4. Expected ordering:
   - `snapshot_context.fired`
   - `openclicky.launch_phrase.nsworkspace_activate target_bundle=com.cmuxterm.app ...`
   - `openclicky.launch_phrase.carbon_set_front pid=... ok=true`
   - either `openclicky.launch_phrase.fired` (win) OR
     `openclicky.launch_phrase.settle_frontmost_snapshot actual_bundle=...` followed by `settle_failed` (still lose, but now we see who stole focus).

## Everywhere reference

`Everywhere/src/Everywhere.Mac/Interop/MacAppActivator.cs:113-123,
264-296` @ 30e03e9dcfdd4247fd679828ed86e9042f32d809 - the exact P/Invoke
pattern this shim mirrors, including the `kSetFrontProcessFrontWindowOnly`
option bit.

## Not touched (per constraint)

F28 observer, hotkey CGEvent tap, Pick overlay, Whiteboard, LinkRect.
