# Hotkey End-to-End Path Audit — 2026-07-23

Read-only audit. openclicky @ working tree vs. Everywhere @ 30e03e9dcfdd4247fd679828ed86e9042f32d809.
No source changes.

## Failure modes reported

1. Alt+S (AgentPickElement) → no pick overlay appears. Previously crashed at
   `OpenClickyPickElementOverlay.installPanels` (macOS 26 `NSRemoteView` bug);
   reporter says fix in place — but crash still fires today (see Layer 5 below).
2. Shift+Space (SnapshotContext) → cmux is never brought forward, launch phrase
   never typed. Stash file may or may not be written.

## Environment sanity check (tester's live openclicky)

- `com.jkneen.openclicky openclicky.contextAwareness.hotkeysEnabled` = 1 (masterEnabled ON).
- `openclicky.contextAwareness.hotkey.snapshotContext` = `{"modifiers":131072,"keyCode":49,"enabled":true}` → Shift+Space (matches
  `defaultBinding_SnapshotContext`, `OpenClickyContextAwarenessSettings.swift:222`).
- `openclicky.contextAwareness.hotkey.agentPickElement` = `{"modifiers":524288,"keyCode":1,"enabled":true}` → Alt+S (matches
  `defaultBinding_AgentPickElement`, `OpenClickyContextAwarenessSettings.swift:232`).
- `openclicky.contextAwareness.agentAppId` = `cmux`.
- `openclicky.contextAwareness.launchPhrase` = `take a look`.
- `openclicky.contextAwareness.seededEverywhereDefaults` = 1 (seed ran once).
- `/Applications/cmux.app` exists; Info.plist `CFBundleIdentifier=com.cmuxterm.app`,
  `CFBundleName=cmux`, `CFBundleExecutable=cmux`. `openclicky.contextAwareness.agentAppId="cmux"`
  therefore resolves via `MacAppActivator.matches`'s localizedName / executable branches
  (`OpenClickyAppActivator.swift:263-277`) — bundle id mismatch is a red herring.
- `~/Library/Application Support/OpenClicky/context-stash.json` **does not currently exist**
  (verified with `ls -la`). Never been written by this build.

## Layer-by-layer diff (openclicky vs Everywhere @30e03e9d)

### Layer 1 — CGEvent tap

- openclicky: `cursor-buddy/OpenClickyContextHotkeys.swift:88-138`
  - `CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: keyDown|keyUp, callback:, userInfo: self)`
  - Adds to `CFRunLoopGetMain()` in `.commonModes`.
  - `CGEvent.tapEnable(tap: tap, enable: true)` (line 137).
  - Self-heals on `.tapDisabledByTimeout / .tapDisabledByUserInput` (line 154-158).
- Everywhere Mac: `src/Everywhere.Mac/Interop/CGEventListener.cs:61-78`
  - Same tap location (HID), same head-insert, but `CGEventTapOptions.Default` (not ListenOnly)
    for the `Default` listener registered by `CGEventShortcutListener.cs:26`.
  - Runs its tap on a dedicated background thread (`CGEventListenerThread`, priority Highest,
    line 39-46), not the main run loop.
- **Verdict: DIVERGENT (fine on the tap create), BROKEN on the run-loop hosting**.
- Divergence:
  1. openclicky uses `.listenOnly` — cannot suppress the keystroke reaching the frontmost app
     (Everywhere swallows it via `cgEventRef = 0` in `HandleKeyDown`, `CGEventShortcutListener.cs:84`).
     This is a design choice, not a bug for the "action fires" question, but it means
     Shift+Space still reaches the frontmost app (e.g. inserts a space in a text field
     the very moment the user presses the hotkey).
  2. **The main-run-loop hosting is a live-lock risk in openclicky.** The tap callback lands on
     the main run loop and dispatches back to `DispatchQueue.main` (line 217). When SwiftUI /
     AppKit are busy on main (very likely during Notch expansion or Codex HUD activation),
     the CGEvent thread is Apple's own dispatch queue for the tap; delivery is throttled and
     the OS will disable the tap if the callback takes too long — self-heal at
     line 154 catches it, but bindings can silently fall through during heavy main-thread
     work. Everywhere sidesteps this entirely by using a dedicated worker thread.

### Layer 2 — Matcher

- openclicky: `OpenClickyContextHotkeys.swift:168-200` reads `keyCode` +
  `event.flags`, iterates `settings.activeBindings` (`OpenClickyContextAwarenessSettings.swift:457-463`),
  calls `binding.matches(keyCode:flags:)` at `:123-128` which masks flags to the
  four significant bits before comparing.
- Everywhere: `CGEventShortcutListener.HandleKeyDown` (`CGEventShortcutListener.cs:53-93`)
  translates to Avalonia's `KeyModifiers` (four significant bits also — Ctrl/Shift/Alt/Meta)
  then looks up the shortcut in `_keyboardRegistrations`.
- **Verdict: MATCH**. Openclicky's Alt+S / Shift+Space bindings match correctly in principle.

### Layer 3 — Enqueue vs perform (tap thread → main)

- openclicky: `OpenClickyContextHotkeys.enqueueAction(_:)` at
  `OpenClickyContextHotkeys.swift:216-236`:
  ```
  DispatchQueue.main.async {
     // repeat-suppression check
     if action == .whiteboard { performAction(action); return }
     DispatchQueue.main.asyncAfter(deadline: .now() + 0.180) { performAction(action) }
  }
  ```
  Two hops through main queue — matches Everywhere's 180 ms modifier-release delay.
- Everywhere: `SnapshotContextHotkeyInitializer.OnSnapshotPressed`
  (`SnapshotContextHotkeyInitializer.cs:124-159`):
  ```
  Dispatcher.UIThread.Post(async () => {
      if (OperatingSystem.IsMacOS()) await Task.Delay(180);
      await _writer.CaptureAsync();
  });
  ```
  One hop to UI thread; the 180 ms wait is `await Task.Delay` inside that hop.
- **Verdict: MATCH** (semantics identical: coalesce → hop → 180 ms → perform).

### Layer 4 — Dispatcher

- openclicky: `OpenClickyContextHotkeys.performAction(_:)` at
  `OpenClickyContextHotkeys.swift:260-274` — `@MainActor`, switches on action to
  `performSnapshotContext / performClearContextStash / performAgentPickElement /
  performWhiteboardBegin / performLinkRectStub`. Also fires an NSLog per action
  (`snapshotContext fired`, `agentPickElement fired -> pick overlay`, etc.).
- Everywhere: individual per-hotkey initialisers each own their own callback
  (`SnapshotContextHotkeyInitializer.cs`, `ClearContextStashHotkeyInitializer.cs`,
  `WhiteboardHotkeyInitializer.cs`, `LinkRectHotkeyInitializer.cs`). No shared
  dispatcher.
- **Verdict: DIFFERENT SHAPE, EQUIVALENT SEMANTICS**. Openclicky's dispatcher is fine.

### Layer 5 — Handlers

#### AgentPickElement (Alt+S)

- openclicky: `OpenClickyContextHotkeys.performAgentPickElement`
  (`OpenClickyContextHotkeys.swift:293-302`) → `OpenClickyPickElementOverlay.shared.begin()` →
  `installPanels()` (`OpenClickyPickElementOverlay.swift:77-96`) creates one
  `PickPanel` per screen and posts `panel.orderFront(nil)`.
- The macOS 26 fix (`orderFrontRegardless → orderFront(nil)` at line 91, plus
  `canBecomeKey = false` at line 266) is present in source.
- **BROKEN AT RUNTIME.** From `log show --style compact --last 4h` today at 14:31:51:
  ```
  Terminating app due to uncaught exception 'NSInternalInconsistencyException',
  reason: 'assertion failed: '<NSRemoteView: 0x7b81a68000
  com.apple.SafariPlatformSupport.Helper SPCompletionListServiceViewController>
  notified of <_TtC10OpenClickyP33_..._PickPanel: 0x7b8498ef80>
  but expected (null)' in -[NSRemoteView containingWindowWillOrderOnScreen:] on line 4221'
  
  13  OpenClicky.debug.dylib  ...PickElementOverlayC13installPanels...
  14  OpenClicky.debug.dylib  ...PickElementOverlayC5beginyyF...
  15  OpenClicky.debug.dylib  ...ContextHotkeysC23performAgentPickElement...
  ```
  Same crash class as before, from the exact same call chain, on the current build.
  The `NSRemoteView` assertion is NOT triggered by `canBecomeKey` — it fires because
  a Safari `SPCompletionListServiceViewController` `NSRemoteView` in this process
  (spellcheck / autocomplete popover host, created by AppKit somewhere earlier —
  see the `TUINSRemoteViewController` log lines every ~30 s in the same process)
  has already registered as an observer of `NSWindowWillOrderOnScreenNotification`,
  and when `PickPanel` calls `orderFront`, `AppKit` posts that notification;
  `NSRemoteView.containingWindowWillOrderOnScreen:` checks that the ordering window
  matches an expected value it stashed at attach time, and throws when it does not.
- **Root cause is unchanged by the "canBecomeKey=false" and `orderFront(nil)` fixes.**
  The `orderFront` path itself is the trigger; the only fix that guarantees no
  `NSRemoteView.containingWindowWillOrderOnScreen:` observation is to keep the
  panel out of the ordering broadcast entirely (`NSWindow.SharingType = .none`
  is not enough; you need to detach the panel from AppKit's window list at attach
  time, or `orderOut` the underlying `NSRemoteView`-hosting popover first, or
  install the panel as a `CGSWindow` directly).
- Everywhere: `VisualElementContext.Picker.PickerSession.PickAsync`
  (`VisualElementContext.Picker.cs:12-20`) inherits `ScreenSelectionSession`
  (`ScreenSelectionSession.cs:14`) which is an Avalonia `Window`, NOT an
  `NSPanel`. Placement is done via raw `NSWindow.SetFrame` with
  `NSWindowLevel.ScreenSaver` (`ScreenSelectionSession.cs:100`). No AppKit
  panel machinery, so no `NSRemoteView` sheet-detection.
- **Verdict: BROKEN**. The overlay never appears because the process is torn
  down mid-`installPanels` by an uncaught obj-c exception. This is the primary
  root cause for the reported "Alt+S does nothing".

#### SnapshotContext (Shift+Space)

- openclicky: `OpenClickyContextHotkeys.performSnapshotContext`
  (`OpenClickyContextHotkeys.swift:276-282`):
  ```
  Task { [stashWriter] in await stashWriter.captureAsync() }
  ```
  Uses `self.stashWriter` (line 59), a **process-local instance separate from
  `OpenClickyContextStashWriter.shared`**.
  Then `OpenClickyContextStashWriter.captureAsync` (`OpenClickyContextStashWriter.swift:88-91`)
  calls `captureCoreAsync(drainAnnotations: true)`.
- Inside `captureCoreAsync` (`OpenClickyContextStashWriter.swift:113-244`):
  1. `writeLock.try()` guard.
  2. Frontmost/title/URL/selection collection.
  3. Atomic write to `~/Library/Application Support/OpenClicky/context-stash.json`.
  4. On success + `drainAnnotations=true`: post `.openClickyManualCaptureCompleted`
     notification, then `Task { await activateAgentAndFirePhrase() }` (line 242).
- `activateAgentAndFirePhrase` (`OpenClickyContextStashWriter.swift:477-508`):
  - Trims `agentAppId`, guards on empty.
  - Calls `OpenClickyAppActivator.shared.activate(bundleId)` (line 493).
  - If activate returned `true` and `launchPhrase` non-empty → `await
    OpenClickyAppActivator.shared.fireLaunchPhrase(bundleId:phrase:)`.
- `OpenClickyAppActivator.activate` (`OpenClickyAppActivator.swift:86-119`)
  matches by bundle id / localized name / executable basename, calls
  `NSRunningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])`,
  then `tryCarbonSetFront(pid:)`.
- **`tryCarbonSetFront` is a NO-OP** (`OpenClickyAppActivator.swift:137-140`) —
  it just returns because the Carbon symbols are marked unavailable in the Swift
  SDK and no obj-c bridge has been added. This means openclicky lacks the
  focus-race follow-up that Everywhere uses (`MacAppActivator.cs:114-296`).
- `fireLaunchPhrase` (`OpenClickyAppActivator.swift:173-254`) implements the
  16 × 150 ms settle loop, `_phraseInFlight` interlock, pre-type / pre-Return
  frontmost checks, then `InputSimulator.typeText` + `InputSimulator.pressKey("Return")`.
- `InputSimulator.typeText` / `.pressKey` post via `CGEvent.post(tap: .cghidEventTap)`
  (`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/InputSimulator.swift:502-509,168,194-196,212`).
- Everywhere path (`ContextStashWriter.cs:105 → CaptureCoreAsync → ActivateAgentApp →
  TryFireLaunchPhrase`): identical structure, but `MacAppActivator.TryCarbonSetFront`
  actually calls `GetProcessForPID` + `SetFrontProcessWithOptions` via P/Invoke
  (`MacAppActivator.cs:267-296`).
- **Verdict: STRUCTURALLY MATCHES, EMPIRICALLY BROKEN**. Direct evidence:
  1. `~/Library/Application Support/OpenClicky/context-stash.json` does not exist,
     so no successful `captureCoreAsync` write has ever completed on this build.
     ("Zero writes" is unlikely just from focus-steal; it points to
     `captureCoreAsync` throwing before `writeAtomic`, or the tap not firing at
     all, or the `writeLock.try()` early-return firing every time.)
  2. No NSLog output containing `snapshotContext fired`, `OpenClickyContextStashWriter`,
     `OpenClickyAppActivator`, or `openclicky.launch_phrase` in the last 4 hours
     of `log show` for this process. Compare: `[com.apple.TextInputUI:CursorUI]`,
     `[com.apple.CFNetwork:...]`, and every other subsystem is visible. So either
     `performSnapshotContext` is never being invoked (Layer 1/2/3 problem), OR
     `NSLog` output from the Swift binary is being filtered before it reaches
     the unified log. The stack trace at 14:31:51 shows `performAgentPickElement`
     landing in `installPanels`, so Layer 1-4 clearly works for Alt+S at least
     once. That leaves the "one crash tears down the tap and everything after
     the crash never runs" hypothesis (see "Suspected root causes" below).

#### ClearContextStash (Alt+C)

- openclicky: `performClearContextStash` (`OpenClickyContextHotkeys.swift:284-291`)
  → `stashWriter.clearStash()` + `PickStash/AnnotationStash/WhiteboardStash.clearWithEvent()`.
- Everywhere: `ClearContextStashHotkeyInitializer` → `_writer.ClearStash`
  (`ContextStashWriter.cs:89`, unlinks the stash file + `.tmp`).
- **Verdict: MATCH**. No further action needed once the file is written; the file
  never exists yet, so the clear path is currently a no-op.

#### Whiteboard (Alt+D)

- openclicky: `performWhiteboardBegin` (`OpenClickyContextHotkeys.swift:304-309`)
  → `OpenClickyWhiteboardOverlayWindow.shared.begin()`. Uses `orderFront(nil)`
  with `canBecomeKey = false` (`OpenClickyWhiteboardOverlayWindow.swift:74, 289`).
- Same `NSRemoteView` risk pattern as `OpenClickyPickElementOverlay` — panels
  on all screens use `orderFront(nil)` on a `nonactivatingPanel`. Whether the
  Safari `SPCompletionListServiceViewController` observer trips here too is
  identical dependency-of-Safari-popovers-in-process.
- **Verdict: POTENTIALLY BROKEN**. Same runtime failure family; no crash log
  captured yet only because the tester has been pressing Alt+S, not Alt+D.

#### LinkRect (Alt+L)

- openclicky: `performLinkRectStub` (`OpenClickyContextHotkeys.swift:316-335`)
  → `OpenClickyLinkRectOverlayWindow.present {...}`. But this path uses
  `overlay.window.makeKeyAndOrderFront(nil)` (`OpenClickyLinkRectOverlayWindow.swift:76`)
  — the "makeKey" variant, which is exactly the AppKit path that emits
  `NSWindowWillOrderOnScreenNotification` first. Even with `canBecomeKey = false`
  on the internal window class (line 188), `makeKeyAndOrderFront` on a
  `canBecomeKey=false` window falls back to `orderFront` — same
  notification hits the Safari `NSRemoteView` observer.
- **Verdict: POTENTIALLY BROKEN** for the same reason as AgentPickElement /
  Whiteboard.

## Suspected root causes (ranked)

1. **CRITICAL — `NSRemoteView.containingWindowWillOrderOnScreen:` still fires the
   SIGABRT for `OpenClickyPickElementOverlay.installPanels`.** Log evidence at
   `2026-07-23 14:31:51.650`. The "fix" (removing `canBecomeKey=true` +
   `orderFrontRegardless()` → `orderFront(nil)`) did NOT resolve it — a Safari
   `SPCompletionListServiceViewController` `NSRemoteView` is registered as a
   process-wide observer on the window-ordering notification (visible in the
   log as periodic `TUINSCursorUIController activate:` → `TUINSRemoteViewController`
   creation events, roughly every 15-30 seconds while the app runs) and its
   assertion trips as soon as `PickPanel.orderFront` fires the notification.
   The fix must either (a) close/tear-down the `NSRemoteView` popover BEFORE
   ordering our panel in, (b) install the overlay panel as a `CGSWindow`
   through Carbon `CGSNewWindow` / `CGSOrderWindow` and skip AppKit's ordering
   broadcast, or (c) wrap `installPanels` in `@objc` `try` / `NSSetUncaughtExceptionHandler`
   and re-attempt without the offending panel. Both `OpenClickyWhiteboardOverlayWindow`
   and `OpenClickyLinkRectOverlayWindow` share the same failure mode.

2. **CRITICAL — SnapshotContext never writes the stash file.** No
   `context-stash.json` exists after ~24 hours of the build being live. Two
   plausible explanations, in order:
   1. The tester has only been pressing Alt+S (crashes the app), which happens
      to also kill the still-in-flight `Task { await stashWriter.captureAsync() }`
      from an earlier Shift+Space press because the process itself is torn down.
      Since the app cold-launches without ever reaching a Shift+Space press
      that outlives the next Alt+S crash, no write completes.
   2. `writeLock.try()` (`OpenClickyContextStashWriter.swift:120`) might be
      returning `false` on the very first call because `NSLock.try()` returns
      `false` immediately when the lock is contested — but if this is the
      first ever call there is no contention, so this would only trip if a
      previous `captureCoreAsync` was still in-flight from a hotkey enqueued
      but never de-queued. Not conclusive without instrumentation.
   3. There is NO evidence that the CGEvent tap actually delivers Shift+Space
      to `performSnapshotContext`: no NSLog `snapshotContext fired` line appears
      in the unified log for any recent PID. Contrast with the Alt+S crash
      stack that shows `performAgentPickElement` unambiguously reached.

3. **HIGH — `activateAgentAndFirePhrase` fire-and-forget swallows all errors
   silently.** `Task { await activateAgentAndFirePhrase() }` at
   `OpenClickyContextStashWriter.swift:242` and `:406` — if `NSWorkspace`
   returns an empty running-applications list on the very first call (the
   AppKit-cold path Everywhere calls out in `MacAppActivator.cs:28-53`), the
   activator's priming in `init` (`OpenClickyAppActivator.swift:66-69`) does
   help. But if cmux's process is not running when `activate("cmux")` is
   called, `activate` returns `false`, `activateAgentAndFirePhrase` returns
   without any user-visible error, and the LaunchPhrase is dropped.
   Everywhere's `_logger.LogInformation("AppActivator.Activate({Id}) returned {Raised}.", ...)`
   at `ContextStashWriter.cs:379` catches this in the log; openclicky does
   log it (`OpenClickyContextStashWriter: agent activate(cmux) returned false.`
   at line 494) but the log show pull above shows no such line, again
   consistent with `captureCoreAsync` never reaching that branch.

4. **HIGH — `tryCarbonSetFront` is a stub in openclicky.** For a browser-heavy
   tester (Safari in the process, likely Chrome / Arc frontmost), the polite
   `NSRunningApplication.activate` will lose the focus race against a browser
   that self-reactivates on its own global hotkey. Everywhere's
   `SetFrontProcessWithOptions` path (`MacAppActivator.cs:264-296`) is what
   makes the settle loop converge; without it, the 16 × 150 ms loop is much
   more likely to time out on `agent did not stay frontmost`. The stub is
   documented (`OpenClickyAppActivator.swift:129-140`) but should be treated
   as a hard regression from Everywhere parity.

5. **HIGH — `.listenOnly` tap does not swallow the keystroke.** Shift+Space
   inserts a literal space into whatever app is frontmost the moment the user
   presses the hotkey. Everywhere uses `CGEventTapOptions.Default` and sets
   `cgEventRef = 0` to swallow. Not the reported failure, but a strong
   secondary UX complaint the tester will hit as soon as the primary bug is
   fixed.

6. **MEDIUM — Two singletons for the stash writer.** `OpenClickyContextHotkeys.stashWriter`
   (line 59) creates a fresh `OpenClickyContextStashWriter()` while
   `OpenClickyContextStashWriter.shared` (`OpenClickyContextStashWriter.swift:56`)
   is a separate instance. `writeLock` and `_phraseInFlight` guards therefore
   do NOT coalesce across "manual hotkey" and "auto-capture on pin/whiteboard
   commit" paths. Not the reported failure, but a correctness bug that will
   surface once auto-capture starts firing after Phase 7.

7. **MEDIUM — Main-run-loop-hosted tap can miss keystrokes under load.** See
   Layer 1. Everywhere runs its tap on `CGEventListenerThread` (dedicated
   background thread, priority Highest). Openclicky uses main. Under Notch
   expansion, Codex HUD activation, or SwiftUI redraw storms, the tap's
   delivery deadline can slip and macOS disables the tap; the self-heal
   handler re-enables it, but the missed events are gone. Compounds cause #2
   ("SnapshotContext never fires").

8. **LOW — Reset button and settings live-reload race.** `refreshAllPermissions`
   (`CompanionManager.swift:4161-4201`) is called every 1.5 s by
   `startPermissionPolling` (`:4385-4391`) and calls `contextAwarenessHotkeys.start()`
   each time accessibility is granted. `start()` is idempotent (`OpenClickyContextHotkeys.swift:89`
   `guard eventTap == nil else { return }`), so re-arming is safe. Not
   currently a bug.

## Recommended fixes (read-only audit; not applied)

- **Alt+S (highest priority)**: replace `NSPanel` + `orderFront(nil)` with a
  `CGSNewWindow` / `SkyLight` overlay, OR wrap `installPanels` in an obj-c
  `@try` / `NSSetUncaughtExceptionHandler` guard that survives the
  `NSInternalInconsistencyException` and retries with a workaround, OR
  detect+dismiss the `SPCompletionListServiceViewController` popover before
  ordering our panel in. Apply the same treatment to
  `OpenClickyWhiteboardOverlayWindow` and `OpenClickyLinkRectOverlayWindow`
  (both use `orderFront` / `makeKeyAndOrderFront` on non-activating panels).

- **Add signposted logging to `performSnapshotContext`** so we can see whether
  Shift+Space reaches Layer 4 at all: currently the only trace is `NSLog` which
  isn't showing up in `log show`. Use `os_log` with a stable subsystem
  (`com.jkneen.openclicky.hotkey`) or persist to a file via `HeyClickyLog.log`
  (already used at `OpenClickyContextStashWriter.swift:484` for the empty-agent
  branch — extend to every branch).

- **Implement `tryCarbonSetFront` via an obj-c bridge** (`OpenClicky-Bridging-Header.h`
  + `void oc_carbon_set_front(pid_t)` shim wrapping `GetProcessForPID` +
  `SetFrontProcessWithOptions`) to match Everywhere's focus-race win.

- **Unify to `OpenClickyContextStashWriter.shared`** in `OpenClickyContextHotkeys`
  so `_phraseInFlight` and `writeLock` guards actually coalesce with the
  auto-capture path added by later phases.

- **Move the CGEvent tap to a dedicated worker thread** (mirror
  `CGEventListener.RunLoopThread` at `CGEventListener.cs:49-59`), then hop back
  to main only for the perform stage. Cures the missed-keystrokes-under-load
  class.

- **Change tap options from `.listenOnly` to `.defaultTap`** and consume the
  event so Shift+Space doesn't leak a literal space into the frontmost app.
