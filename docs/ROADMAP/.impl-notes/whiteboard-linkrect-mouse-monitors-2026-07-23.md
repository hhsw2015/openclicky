# Whiteboard + LinkRect NSEvent monitor migration (2026-07-23)

## Problem

Alt+D (Whiteboard) and Alt+L (LinkRect) overlays installed correctly
on macOS 26 (dim tint appeared) but received no drawing/dragging input.
Root cause was the same as Alt+S Pick had before: the overlay panels
carry `canBecomeKey = false` (permanent macOS 26 SIGABRT fix — see
`OpenClickyOverlayObjCBridge`) so `NSView` responder-chain
`mouseDown` / `mouseDragged` / `mouseUp` never fire. Alt+S Pick was
already migrated to `NSEvent.addGlobalMonitorForEvents` +
`addLocalMonitorForEvents`; Whiteboard and LinkRect still relied on
the dead responder path.

Secondary issue: `.listenOnly` CGEvent tap does not consume the Option
modifier, so Chrome / Arc / Edge / Brave interpret Option+D as "open
location" (address bar focus) before our overlay renders, and
Option+L similarly. Fix: force `NSApp.activate(ignoringOtherApps: true)`
immediately after installing the overlay panels — this is the
Everywhere `ScreenSelectionSession` pattern.

## Files touched

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyLinkRectOverlayWindow.swift`

Not touched (per constraints):
- `OpenClickyPickElementOverlay.swift` (already correct — reference)
- `OpenClickyOverlayObjCBridge.m/h` (`SafeOrderFront` wrapper preserved)
- `OpenClickyContextHotkeys.swift` (CGEvent tap, F28 observer)
- `ClickyCodexConfigTemplate.swift`

## Monitor pairs installed

Both overlays install seven `NSEvent` monitors on the "begin overlay"
path and remove them on "teardown" (`end()`, `cancel()`, `dismiss()`).
Every path is global + local so the events land whether our app is
frontmost or not:

| Event mask                | Global | Local | Purpose                                    |
|---------------------------|--------|-------|--------------------------------------------|
| `.leftMouseDown`          | yes    | yes   | Begin stroke / begin drag                  |
| `.leftMouseDragged`       | yes    | yes   | Append stroke point / update drag rect     |
| `.leftMouseUp`            | yes    | yes   | End stroke / finalise drag rect            |
| `.keyDown` (keyCode 53)   | -      | yes   | Escape → cancel                            |
| `.rightMouseDown`         | yes    | -     | LinkRect only: right-click → cancel        |

Global monitors receive callbacks only when the events target other
apps; local monitors only when the events target our own windows. The
pair together covers 100% of the coordinate space regardless of which
app is frontmost.

## Screen-lookup logic (Whiteboard multi-panel)

Whiteboard spawns one `OpenClickyWhiteboardPanel` per `NSScreen`. The
monitor handlers translate `NSEvent.mouseLocation` (Cocoa global,
bottom-left, primary-screen origin) into the correct per-screen view's
local coord space via `viewUnderCursor()`:

```
for (index, view) in overlayViews.enumerated() {
    guard let window = view.window else { continue }
    let frame = window.frame
    if frame.contains(cocoa) {
        let local = CGPoint(x: cocoa.x - frame.origin.x,
                            y: cocoa.y - frame.origin.y)
        return (view, local, index)
    }
}
```

`NSView.isFlipped == false` on `OpenClickyWhiteboardOverlayView`, so
local Y measures upward from view bottom — matches the Cocoa
convention already used everywhere else in the file (matches the
existing `toQuartzGlobal(localPoint:view:)` math). Once resolved, the
handler forwards into three new public entry points on the view:

- `monitorMouseBegan(atLocalPoint:)`
- `monitorMouseMoved(atLocalPoint:)`
- `monitorMouseEnded(atLocalPoint:)`

The original `mouseDown/Dragged/Up` NSView overrides remain as a
defence-in-depth path (they forward to the same methods) but they are
effectively dead code while `canBecomeKey = false`.

## LinkRect coordinate math

LinkRect renders per-screen but stores the drag anchor once at the
window-manager level. The monitor handlers convert `NSEvent.mouseLocation`
to Quartz global (top-left, primary-screen origin) using the standard
flip:

```
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
let quartz = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
```

This matches `OpenClickyLinkRectDragView.quartzPoint(from:)` and lets
us call the existing `began(atQuartz:)` / `moved(toQuartz:)` /
`ended(atQuartz:)` API unchanged. Each per-screen `contentView` still
receives `reset(anchor:)` / `updateEnd(_:)` because those methods run
inside `began/moved/ended`, so the 2px green outline paints on the
correct screen automatically.

## `NSApp.activate` sites

- **Whiteboard**: added in `begin()` right before `installEventMonitors()`.
  Previously absent — this is the Chrome/Arc Option+D race fix.
- **LinkRect**: already present in `installOnAllScreens()` at the tail
  (was line ~93; still there, unchanged).

Both sites log a `.begin` event immediately after activation so the
bridge log tail confirms the sequence.

## Log events added

Whiteboard:
- `openclicky.whiteboard_overlay.begin` — fields: `panel_count`
- `openclicky.whiteboard_overlay.mouse_down` — `screen_index`, `x`, `y`
- `openclicky.whiteboard_overlay.mouse_up` — `stroke_point_count`, `stroke_count`
- `openclicky.whiteboard_overlay.commit` — `stroke_count`, `regions`
- `openclicky.whiteboard_overlay.cancel` — `reason` (`escape`, `cancel`)

LinkRect:
- `openclicky.linkrect_overlay.begin` — `panel_count`
- `openclicky.linkrect_overlay.mouse_down` — `cocoa_x`, `cocoa_y`, `quartz_x`, `quartz_y`
- `openclicky.linkrect_overlay.mouse_up` — `quartz_x`, `quartz_y`, `rect_w`, `rect_h`
- `openclicky.linkrect_overlay.commit` — `rect_w`, `rect_h`
- `openclicky.linkrect_overlay.cancel` — `reason` (`escape`, `right_click`)

## Build result

`bash scripts/sign-and-install.sh` -> `** BUILD SUCCEEDED **`. App
launched at pid 9471; three bundled node children (OpenConnector /
OpenCLI / OpenDia runtimes) parented cleanly to the new pid. No zombie
node processes from the prior instance.

## What to look for in the bridge log tail

```
TOKEN=$(defaults read com.jkneen.openclicky openClickyExternalControlBridgeToken)
curl -sS -H "x-openclicky-token: $TOKEN" \
  'http://127.0.0.1:32123/agent/log/tail?count=300' \
  | grep -E 'whiteboard_overlay|linkrect_overlay'
```

Expected ordering after Alt+D press-drag-release:

```
openclicky.whiteboard_overlay.begin        (panel_count matches display count)
openclicky.whiteboard_overlay.mouse_down   (once per stroke; screen_index maps
                                            to the display where drag started)
openclicky.whiteboard_overlay.mouse_up     (stroke_point_count grows over drag)
openclicky.whiteboard_overlay.commit       (stroke_count non-zero if drew)
```

Expected ordering after Alt+L press-drag-release:

```
openclicky.linkrect_overlay.begin
openclicky.linkrect_overlay.mouse_down     (cocoa_x/y and quartz_x/y both set)
openclicky.linkrect_overlay.mouse_up       (rect_w/h non-zero if actual drag)
openclicky.linkrect_overlay.commit         (matching rect_w/h)
```

If `mouse_down` appears but `mouse_up` does not, the monitor pair
teardown ran too early (regression). If `begin` appears but neither
`mouse_down` fires nor the browser address bar opens, the CGEvent tap
lost the keystroke entirely — orthogonal to this fix.
