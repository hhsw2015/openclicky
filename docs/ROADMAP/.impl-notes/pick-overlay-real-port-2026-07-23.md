# Pick-element overlay: real port from Everywhere `ScreenSelectionSession`

Date: 2026-07-23
Owner: pick-overlay port
Author: agent (post scope-correction)

## Scope

macOS 26 broke openclicky's Alt+S PickElement overlay. Symptom: dim
overlay appeared but the mouse did not hit-test AX elements — no green
outline followed the cursor, clicks captured nothing.

The port was corrected mid-flight after the coordinator flagged an
architecture mismatch: Everywhere does not dim the screen for pick
mode. It shows a crosshair cursor and paints one small floating
highlight rect around the hovered AX element. This impl-note documents
the final port.

## Root cause of the failure (previous impl)

Prior file: one fullscreen dim `NSPanel` per `NSScreen`, alpha 0.15
tint, `canBecomeKey=false` (correctly kept for the macOS 26 SIGABRT
fix). The panel's `NSView.mouseMoved` never fired because
`canBecomeKey=false` blocks the tracking-area event path. A follow-up
attempt added global NSEvent monitors but wired the panel content view
name incorrectly and had coord-conversion bugs.

## Everywhere algorithm (source of truth)

`src/Everywhere.Mac/Interop/VisualElementContext.Picker.cs` (38 lines)
subclasses `ScreenSelectionSession` and returns
`SelectedElement` when the picking window closes. The base session
(`ScreenSelectionSession.cs`, ~446 lines) is what actually drives the
UX:

- `NSEvent.CurrentMouseLocation` gives Cocoa-global coords
  (bottom-left origin).
- `HandlePointerMoved` converts to Quartz-global by
  `primaryScreenHeight - point.Y`.
- `GetElementAtPoint()` walks the CGWindowList to find candidate
  window-owner pids, then calls
  `AXUIElement.ElementFromPid(...).ElementAtPosition(x, y)` (which is
  `AXUIElementCopyElementAtPosition` on an app-scoped element).
- The hit element's `BoundingRectangle` becomes the mask rect. In
  Everywhere the "mask" is fullscreen dim windows with the hit rect
  cut out; but the pick indicator is small and only surrounds the
  hovered element. The correction from the coordinator: openclicky
  just draws the highlight outline, no dim.

The Escape / right-click / mode-switch machinery is via a CGEvent
listener (Everywhere's `CGEventListener.Default.EventReceived`). We
substitute NSEvent monitors on macOS.

## openclicky implementation (final)

`cursor-buddy/OpenClickyPickElementOverlay.swift` rewritten:

- **One** `NSPanel` (`PickHighlightPanel`). Not one per screen.
- Content: `PickHighlightView` draws a 2px `.systemGreen` rounded
  outline inset by 1px so the stroke is fully visible.
- Panel style: `[.borderless, .nonactivatingPanel]`, `isOpaque=false`,
  `backgroundColor=.clear`, `hasShadow=false`, `ignoresMouseEvents=true`,
  `level=.screenSaver`, `canBecomeKey=false`, `canBecomeMain=false`.
- Frame starts at `.zero` (invisible) and is set on every hit.
- Installed once via `OpenClickySafeOrderFront(panel)` (preserving the
  Obj-C @try/@catch wrapper from
  `OpenClickyOverlayObjCBridge.m` that shields the macOS 26
  `NSInternalInconsistencyException` from
  `-[NSRemoteView containingWindowWillOrderOnScreen:]`).

Monitors installed by `installEventMonitors()`:

| Monitor | Type | Matching | Purpose |
| ------- | ---- | -------- | ------- |
| `localKeyMonitor` | local | `.keyDown` | Escape (keyCode 53) -> `cancel("escape")` |
| `globalRightClickMonitor` | global | `.rightMouseDown` | Cancel with reason `right_click` |
| `globalMoveMonitor` | global | `.mouseMoved` | Hit-test when pointer is over another app |
| `localMoveMonitor` | local | `.mouseMoved` | Hit-test when pointer is over an openclicky window (highlight panel itself uses `ignoresMouseEvents=true` so events pass through to underlying app; local monitor is defence in depth) |
| `globalClickMonitor` | global | `.leftMouseDown` | Capture element on click |
| `localClickMonitor` | local | `.leftMouseDown` | Same for our own frontmost case |

30 fps throttle (`1.0/30.0`) gates `AXUIElementCopyElementAtPosition`
via `lastHitAt`. Own-process elements (`AXUIElementGetPid == getpid()`)
are filtered out so the highlight doesn't clamp to our own menu bar.

Click capture calls the existing `handleClick(on:at:)` pipeline
untouched — it still does:

1. `copyStringAttribute` for role / title / value
2. `AXUIElementGetPid` + `NSRunningApplication` for bundleId
3. `copyBoundsAttribute` for bounds
4. `AnnotationBadgeOverlayClassifier.pinAnchorID(for:)`
5. `OpenClickyPinnedAXElementRegistry.store(element, for: anchorID)`
   BEFORE `PickStash.shared.set(...)` so the badge overlay's
   `.pickStashDidChange` handler can install its AXFollower.

## Coordinate math (worked example)

Setup (Retina 27" primary, one 24" secondary to the right):

- Primary `NSScreen.frame` = `(0, 0, 3008, 1692)` in Cocoa points.
- Secondary `NSScreen.frame` = `(3008, 300, 1920, 1080)` in Cocoa
  points (Cocoa Y grows up from bottom of primary).
- Primary height = 1692.

Pointer sitting at Cocoa global `(400, 1500)` (near top-left of
primary):

```
axPoint.x = 400
axPoint.y = primaryHeight - cocoa.y  = 1692 - 1500 = 192
```

`AXUIElementCopyElementAtPosition(sysWide, 400, 192, &el)` returns the
element under that point. Its `AXPosition + AXSize` combine to a
Quartz-global CGRect, say `axFrame = (300, 150, 220, 60)` (top-left at
300, 150).

Convert back to Cocoa global for `NSPanel.setFrame`:

```
cocoaY = primaryHeight - axFrame.origin.y - axFrame.height
       = 1692 - 150 - 60
       = 1482
cocoaFrame = NSRect(x: 300, y: 1482, width: 220, height: 60)
```

That is the Cocoa-global rect the panel snaps to, which lands the
2px green stroke exactly around the AX element's true position.

Off-primary screen worked example: if the element straddles onto the
secondary display with Quartz `axFrame = (3200, 400, 200, 40)` (i.e.
top-left is 3200 across, 400 down from primary top):

```
cocoaY = 1692 - 400 - 40 = 1252
cocoaFrame = (3200, 1252, 200, 40)
```

Since `NSPanel.setFrame` uses Cocoa-global coords (0 at primary
bottom-left), 3200 lands correctly on the secondary display. No
per-screen translation needed — we do not maintain per-panel origins
because there is only one panel.

## Log events

All emitted via `HeyClickyLog.log(event:lane:direction:fields:)` and
visible in Settings → Logs (bridge: `GET /agent/log/tail?count=N`).

| Event | Direction | Emitted from | Fields |
| ----- | --------- | ------------ | ------ |
| `openclicky.pick_overlay.begin` | internal | `begin()` | `screen_count` |
| `openclicky.pick_overlay.order_front_failed` | error | `installPanel()` on `OpenClickySafeOrderFront` NO | `-` |
| `openclicky.pick_overlay.mouse_move` | internal | `performHitTest()` | `cursor_qx`, `cursor_qy` |
| `openclicky.pick_overlay.ax_hit_ok` | internal | `performHitTest()` on element resolved | `role`, `title`, `bounds_w/h/x/y` |
| `openclicky.pick_overlay.ax_hit_fail` | error | `performHitTest()` and `performClickCapture()` failures | `ax_error`, `reason` |
| `openclicky.pick_overlay.click_captured` | internal | `handleClick(on:at:)` | `role`, `title`, `pid`, `bundle_id`, `bounds_w/h` |
| `openclicky.pick_overlay.dismiss` | internal | `cancel(reason:)` | `reason` (`escape` / `right_click` / `click_no_element` / `user_cancelled`) |

## Preserved constraints

- `PickHighlightPanel.canBecomeKey = false` — macOS 26 SIGABRT fix
  from `docs/ROADMAP/.impl-notes/overlay-crash-real-fix-2026-07-23.md`
  stays in place.
- `OpenClickySafeOrderFront(panel)` wraps every `orderFront:` (both at
  install and after each frame move to re-assert level on cross-screen
  jumps).
- `OpenClickyContextHotkeys.swift` untouched.
- F28 observer + task planning untouched.
- `handleClick(on:at:)` capture pipeline unchanged.

## Build

```
$ bash scripts/sign-and-install.sh
[0/5] verify cert exists in login keychain
[1/5] xcodebuild
** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=93316  identifier=com.jkneen.openclicky
  Authority=OpenClicky Dev Sign
[5/5] done.
```

Zombie `boot.js` children from the previous install (ppid=1 after
prior OpenClicky exit) were killed after install.

## How to verify

1. User presses Alt+S. Should see the crosshair cursor and NO dim.
2. Move the mouse over any window (Finder, browser, Xcode…). Small
   green rounded outline should follow the hovered AX element in
   real time.
3. Click any element. Overlay disappears, `PickStash` receives the
   `PickedElement`, badge overlay wakes up.
4. Alternate: press Escape or right-click to cancel; overlay
   disappears without writing to `PickStash`.

Log-tail verification (fill in real token):

```bash
TOKEN=$(defaults read com.jkneen.openclicky openClickyExternalControlBridgeToken)
curl -sS -H "x-openclicky-token: $TOKEN" \
  'http://127.0.0.1:32123/agent/log/tail?count=300' \
  | grep pick_overlay
```

A successful pick session emits (in order):
`begin` (1x) -> `mouse_move` (many, throttled 30fps) -> `ax_hit_ok`
(one per successful resolve) -> `click_captured` (1x on click) ->
`dismiss` (1x with `reason=user_cancelled` from `teardown()` via the
end of `handleClick`). An empty pick (right-click / escape) skips
`click_captured` and dismisses with the matching reason.

If `ax_hit_fail` shows `ax_error != 0`, TCC Accessibility isn't
granted or the AX-inspected app is process-scoped in a way that
denies system-wide reads (rare). If `mouse_move` never fires,
`NSEvent.addGlobalMonitorForEvents` isn't receiving events — check
Input Monitoring TCC prompt (macOS grants global mouse monitors under
Input Monitoring).
