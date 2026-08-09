# Overlay Crash Real Fix — 2026-07-23

Follow-up to `hotkey-path-audit-2026-07-23.md`. The previous fix
(removing `canBecomeKey=true`, switching `orderFrontRegardless` →
`orderFront(nil)`) did not stop the SIGABRT: an XPC-hosted Safari
`SPCompletionListServiceViewController` NSRemoteView is registered
in-process as an observer of `NSWindowWillOrderOnScreenNotification`,
and every `orderFront` posted from any of our overlay panels trips
its `containingWindowWillOrderOnScreen:` assertion.

## Approach

**Option A (Obj-C @try/@catch wrapper).** Swift can't natively catch
Objective-C exceptions, so route the offending window-ordering calls
through a thin `.m` shim that wraps them in `@try/@catch`. When the
raise throws, we swallow the exception, log it via `HeyClickyLog`, and
continue. Option B (single hidden host window shared across all
overlays) was considered but rejected as a larger refactor — Option A
is the minimum-risk landing.

## Files created

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyOverlayObjCBridge.h`
  Declares three C entry points (`OpenClickySafeOrderFront`,
  `OpenClickySafeOrderFrontRegardless`,
  `OpenClickySafeMakeKeyAndOrderFront`).
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyOverlayObjCBridge.m`
  Implements each shim as `@try { [window orderFront:nil]; return YES; }
  @catch (NSException *e) { NSLog; return NO; }`.
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/cursor-buddy-Bridging-Header.h`
  Imports `OpenClickyOverlayObjCBridge.h` so the Swift target sees the
  three C functions.

## Files modified

- `/Users/wowdd1/Dev/openclicky/cursor-buddy.xcodeproj/project.pbxproj`
  Added `SWIFT_OBJC_BRIDGING_HEADER =
  "cursor-buddy/cursor-buddy-Bridging-Header.h";` to both Debug and
  Release build configurations of the `cursor-buddy` target (previously
  no bridging header was configured). The three new source files are
  picked up automatically by the `PBXFileSystemSynchronizedRootGroup`
  (only `Info.plist` is in the exception list; new `.h`/`.m` files at
  the group root are added to the target on the next build).

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyPickElementOverlay.swift`
  Replaced `panel.orderFront(nil)` inside `installPanels()` (was ~L91)
  with a call to `OpenClickySafeOrderFront(panel)` and a
  `HeyClickyLog.log("openclicky.pick_overlay.order_front_failed", …)`
  branch on failure. The panel is still appended to `panels` so
  teardown can `orderOut` it cleanly.

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift`
  Replaced `panel.orderFront(nil)` inside `begin()` (was ~L289) with
  the `OpenClickySafeOrderFront` wrapper + failure log. Panel and view
  are still appended to their collections so `cancel()`/`end()` can
  tear them down cleanly.

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyLinkRectOverlayWindow.swift`
  Replaced `overlay.window.makeKeyAndOrderFront(nil)` inside
  `installOnAllScreens()` (was ~L76) with
  `OpenClickySafeMakeKeyAndOrderFront(overlay.window)` + failure log.

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift`
  - **Fix 2 (tap options + swallow keystroke):** `CGEvent.tapCreate`
    now uses `options: .defaultTap` instead of `.listenOnly`. The
    callback signature changed: `handleGlobalEventTap` now returns
    `Bool`, and the tap C-callback returns `nil` (drop event) when a
    hotkey matched. This means Shift+Space no longer leaks a literal
    space into the frontmost text field. Unmatched keystrokes pass
    through unchanged. The file-level design-notes comment was updated
    to reflect the new tap mode.
  - **Fix 3 (unify StashWriter singleton):** the `private let
    stashWriter = OpenClickyContextStashWriter()` fresh-instance field
    is gone. Replaced by a `@MainActor`-isolated computed property
    that returns `OpenClickyContextStashWriter.shared` so `writeLock`
    and `_phraseInFlight` guards actually coalesce with the
    auto-capture paths (whiteboard commit, LinkRect harvest, pin
    release). Call sites in `performSnapshotContext` and
    `harvestAndPersistLinkRect` were adjusted to reach the shared
    singleton directly from their `Task { @MainActor }` /
    `Task.detached` blocks.
  - Added `HeyClickyLog.log("openclicky.hotkey.snapshot_context.fired")`
    and `HeyClickyLog.log("openclicky.hotkey.agent_pick_element.fired")`
    in the two `perform*` methods so the audit-flagged "we can't see
    whether the hotkey ever reached Layer 4" question is answerable
    from Settings → Logs going forward.

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyAppActivator.swift`
  **Fix 4 (visible failure signal):** every `NSLog` inside
  `fireLaunchPhrase` was replaced with a `HeyClickyLog.log` call
  (`openclicky.launch_phrase.no_frontmost_detection`,
  `.skipped_in_flight`, `.settle_failed`,
  `.focus_stolen_pre_type`, `.focus_stolen_pre_return`, `.fired`,
  `.return_failed`). These events surface in Settings → Logs so the
  user sees WHY the launch phrase never fired instead of the silent
  fire-and-forget failure the audit flagged. The
  `tryCarbonSetFront` stub was left alone — implementing that
  properly needs a separate Carbon P/Invoke shim and is out of scope
  for this crash fix.

## Not touched (per constraints)

- Merge-endpoint work on `/mcp` → `/mcp/sensor`.
- Any F31 files.
- Codex config template.
- The Carbon focus-race shim (`tryCarbonSetFront` remains a no-op).
- Whiteboard `orderFrontRegardless` — Whiteboard never called
  `orderFrontRegardless`; it uses `orderFront(nil)` which is now
  wrapped.

## Verification

- `bash scripts/sign-and-install.sh` — **BUILD SUCCEEDED**, app
  code-signed with the persistent dev cert, running as pid 73152.
- The Obj-C bridging header registered cleanly; the three C entry
  points resolve from Swift without further pbxproj edits (the
  `PBXFileSystemSynchronizedRootGroup` auto-picks up `.h`/`.m` files
  under `cursor-buddy/`).
- Alt+S / Shift+Space runtime verification was **not** performed by
  this automation run — the audit calls for the user to press the
  hotkeys manually and verify (a) no crash and (b) that
  `~/Library/Application Support/OpenClicky/context-stash.json` gets
  written within 500 ms of Shift+Space. Sockets, pids, and codesign
  identity are green in the install script output.

## Expected user-visible behaviour after this fix

1. **Alt+S**: previously SIGABRT during `installPanels`; now either
   the pick overlay appears normally, OR one/more panels' `orderFront`
   raises and is swallowed. A swallowed raise is logged as
   `openclicky.pick_overlay.order_front_failed` in Settings → Logs;
   the process survives either way.
2. **Shift+Space**: no more literal space leaked into the frontmost
   text field (tap now `.defaultTap` and callback returns nil for
   matched bindings). The stash write itself was structurally correct
   before; the audit's "no writes ever" hypothesis was almost
   certainly caused by cascading crashes from Alt+S tearing down the
   process before a subsequent Shift+Space could complete. With Alt+S
   no longer crashing, Shift+Space should now complete and drop
   `~/Library/Application Support/OpenClicky/context-stash.json` on
   first press. Launch-phrase failures are now visible in Settings →
   Logs.
3. **Alt+D (Whiteboard)** and **Alt+L (LinkRect)**: the identical
   `NSRemoteView`-observer failure family they shared with Alt+S is
   now covered by the same wrapper.
