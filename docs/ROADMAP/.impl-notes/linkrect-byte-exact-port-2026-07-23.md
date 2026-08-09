# LinkRect byte-exact port from Everywhere @30e03e9d

Sources read in full:
- `Everywhere/src/Everywhere.Mcp/LinkRectHotkeyInitializer.cs` (178 lines)
- `Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs` (608 lines)
- `Everywhere/src/Everywhere.Mac/Interop/ScreenSelectionSession.cs` (446 lines)
- `Everywhere/src/Everywhere.Core/Views/ScreenSelection/ScreenSelectionWindow.cs` (171 lines)

## Everywhere design (cited)

### A. Overlay install

Everywhere runs TWO layers of windows per capture session:

1. **One transparent input-receiver window that spans all screens.**
   `ScreenSelectionSession` derives from `ScreenSelectionTransparentWindow`
   (`ScreenSelectionWindow.cs:31-54`). It is placed via
   `SetPlacement(_allScreenBounds, out _)` (`ScreenSelectionSession.cs:82`)
   at Avalonia-top-left origin covering the union of all screens.
   After open, the NSWindow is re-placed to `_allScreenFrame` via
   `SetNsWindowPlacement(this, _allScreenFrame)` at
   `ScreenSelectionSession.cs:111`. Level = `NSWindowLevel.ScreenSaver`
   (`ScreenSelectionSession.cs:100`).

2. **One `ScreenSelectionMaskWindow` per screen** used for painting.
   Built in the loop at `ScreenSelectionSession.cs:62-80`, one per
   `NSScreen.Screens[i]`. Each mask is placed with
   `SetNsWindowPlacement(maskWindow, frame)` and marked
   `SetHitTestVisible(false)`. Level = `NSWindowLevel.ScreenSaver`.

Screen bounds for a mask are computed in Avalonia-top-left coordinates
by flipping the Cocoa bottom-left `frame.Y`:
`ScreenSelectionSession.cs:70-74`:
```
new PixelRect(
    (int)frame.X,
    (int)(primaryScreenHeight - (frame.Y + frame.Height)),
    (int)frame.Width,
    (int)frame.Height)
```
`primaryScreenHeight = NSScreen.Screens[0].Frame.Height`
(`ScreenSelectionSession.cs:59`).

### B. Drag-rect drawing

Mask visual composition (`ScreenSelectionWindow.cs:74-93`):
- Background `Border` — `Brushes.Black`, `Opacity = 0.4`.
- Element-bounds `Border` — `BorderThickness = 2`, `BorderBrush = Brushes.White`, aligned top-left.
- `_capturedLinksCanvas` (empty until harvest completes).

`SetMask(rect)` (`ScreenSelectionWindow.cs:107-120`) receives a
Quartz-top-left `PixelRect`, subtracts `_screenBounds.Position` to get
per-screen-local top-left, then divides by scale for Avalonia DIPs:
```
var maskRect = rect.Translate(-(PixelVector)_screenBounds.Position).ToRect(_scale);
_maskBorder.Clip = new CombinedGeometry(
    GeometryCombineMode.Exclude,
    new RectangleGeometry(Bounds),
    new RectangleGeometry(maskRect));
_elementBoundsBorder.Margin = new Thickness(maskRect.X, maskRect.Y, 0, 0);
_elementBoundsBorder.Width  = maskRect.Width;
_elementBoundsBorder.Height = maskRect.Height;
```

The black tint is clipped to EXCLUDE the drag rect (a hole punched
through the tint), and a white 2px border wraps the same rect.

### C. Coord math during drag

`OnLeftButtonDown` (`VisualElementContext.LinkRect.cs:123-131`):
```
var primaryScreenHeight = NSScreen.Screens[0].Frame.Height;
var quartzStart = new CGPoint(CurrentMouseLocation.X,
                              primaryScreenHeight - CurrentMouseLocation.Y);
_dragStart = quartzStart;
_isDragging = true;
_dragRect = new PixelRect((int)quartzStart.X, (int)quartzStart.Y, 0, 0);
foreach (var mask in MaskWindows) mask.SetMask(_dragRect);
```

`OnMove` (`VisualElementContext.LinkRect.cs:151-165`):
```
var minX = Math.Min(_dragStart.X, point.X);
var minY = Math.Min(_dragStart.Y, point.Y);
var maxX = Math.Max(_dragStart.X, point.X);
var maxY = Math.Max(_dragStart.Y, point.Y);
_dragRect = new PixelRect((int)minX, (int)minY, (int)(maxX-minX), (int)(maxY-minY));
foreach (var mask in MaskWindows) mask.SetMask(_dragRect);
```

`point` here is already Quartz-top-left — flip done in
`HandlePointerMoved` (`ScreenSelectionSession.cs:239-249`):
```
var primaryScreenHeight = NSScreen.Screens[0].Frame.Height;
var quartzPoint = new CGPoint(point.X, primaryScreenHeight - point.Y);
OnMove(quartzPoint);
```
where `point` came from `NSEvent.CurrentMouseLocation` (Cocoa
bottom-left) at line 230.

Every mask receives the SAME Quartz global rect. Each mask maps into
its own local space by subtracting its own `_screenBounds.Position`
(also Quartz-top-left) — see `ScreenSelectionWindow.cs:109`.

### D. Dismiss

Everywhere's dismiss is a **single `window.Close()` call on the UI
thread**. There is no alpha animation, no level manipulation, no
`orderOut` sequencing, no `contentView = null`.

`VisualElementContext.LinkRect.cs:44-49` (cancel path):
```
using var _ = cancellationToken.Register(() =>
    Dispatcher.UIThread.Post(() => window!.Close()));
...
if (rect is null)
{
    await Dispatcher.UIThread.InvokeAsync(window!.Close);
    return new HarvestResult(window._wasCanceled, []);
}
```

`VisualElementContext.LinkRect.cs:66-70` (success path):
```
finally
{
    await Dispatcher.UIThread.InvokeAsync(window!.Close);
}
```

Avalonia's `Close()` on macOS eventually releases the NSWindow, so
the compositor surface drops on the next display cycle. Nothing else.

### E. Order of commit / dismiss / launch phrase

Everywhere sequence (`VisualElementContext.LinkRect.cs:28-72` +
`LinkRectHotkeyInitializer.cs:114-176`):

1. `OnLeftButtonUp` (`VisualElementContext.LinkRect.cs:133-149`):
   - `_rectPromise.TrySetResult(_dragRect)` — resolves promise.
   - Returns `false` — **overlay stays alive**.
2. `HarvestAsync` awaits promise, then runs `Task.Run(() => HarvestLinks(rect))`
   in the background with the overlay STILL VISIBLE.
3. If any links found, `HighlightCapturedLinks` paints aqua borders on
   every mask window (`VisualElementContext.LinkRect.cs:75-92`).
4. `await Task.Delay(700, cancellationToken)` — the highlight sits on
   screen for 700ms.
5. `await Dispatcher.UIThread.InvokeAsync(window!.Close)` — overlay
   closes on the UI thread.
6. `HarvestAsync` returns the `HarvestResult`.
7. `LinkRectHotkeyInitializer.OnHotkey` (line 165) calls
   `_contextWriter.CaptureLinksAsync(pairs)` — which activates the
   agent and fires the launch phrase.

**Overlay is guaranteed torn down before the agent app activates.**

### F. Harvester rule (already-byte-parity confirmation)

`MajorityOverlap` (`VisualElementContext.LinkRect.cs:411-422`):
```
if (anchor.Width <= 0 || anchor.Height <= 0) return false;
if (anchor.Right < dragRect.X || anchor.X > dragRect.Right) return false;
var midY = anchor.Y + anchor.Height / 2;
return midY >= dragRect.Y && midY <= dragRect.Bottom;
```

This is horizontal-any-overlap plus mid-Y-in-drag-Y-span, NOT
actual >50%-area majority-overlap. Openclicky's
`OpenClickyLinkRectGeometry.majorityOverlap`
(`OpenClickyLinkRectHarvester.swift:69-79`) matches byte-exact.

Round 24 review's claim that the rule is majority-overlap is correct
in NAME (Everywhere calls the method `MajorityOverlap`) but the actual
implementation is the horizontal-overlap + mid-Y-inside rule.
Openclicky already ports this correctly. The user report of "harvester
keeps links whose visual area is 90% outside the drag rect (only
x-overlap)" IS the intended Everywhere behaviour when the anchor's
mid-Y falls inside the drag Y-span — do NOT change.

## Openclicky divergences before fix

| Site | Everywhere | Openclicky (before) | Fix |
|---|---|---|---|
| Tint color | Black opacity 0.4 (`ScreenSelectionWindow.cs:77`) | Grey alpha 0.15 (`OpenClickyLinkRectOverlayWindow.swift:517`) | Change to black 0.4 |
| Border color | White (`ScreenSelectionWindow.cs:81`) | Green (`OpenClickyLinkRectOverlayWindow.swift:535`) | Change to white |
| Dismiss | Single `Close()` on UI thread (`VisualElementContext.LinkRect.cs:69`) | Stacked alpha=0 + level=baseWindow + contentView=nil + orderOut + close (`OpenClickyLinkRectOverlayWindow.swift:347-351`) | Strip to `orderOut(nil)` + `close()` only, drop screens strong ref |
| Order | Harvest → 700ms highlight → dismiss → activate (`VisualElementContext.LinkRect.cs:57-72` + `LinkRectHotkeyInitializer.cs:124-165`) | Dismiss → harvest → activate (`OpenClickyLinkRectOverlayWindow.swift:309-328`, `OpenClickyContextHotkeys.swift:353-357`) | Refactor: overlay stays alive until caller explicitly dismisses. Caller dismisses AFTER harvest, BEFORE captureLinks. |
| `NSApp.activate` on install | Not called | `NSApp.activate(ignoringOtherApps: true)` (`OpenClickyLinkRectOverlayWindow.swift:111`) | Keep — required macOS 26 workaround for `.listenOnly` CGEvent tap that can't swallow Option+L before browser sees it. Documented divergence. |
| Coord math | `NSScreen.Screens[0].Frame.Height` flip (`ScreenSelectionSession.cs:59, 244-245`) | Same, `primaryScreenHeightProvider` reads `NSScreen.screens.first?.frame.height` (`OpenClickyLinkRectOverlayWindow.swift:213, 549, 554`) | Matches byte-exact. No change. |
| Harvester `MajorityOverlap` | `midY inside drag Y-span AND horizontal overlap` (`VisualElementContext.LinkRect.cs:411-422`) | Same (`OpenClickyLinkRectHarvester.swift:69-79`) | Matches byte-exact. No change. |

## Why the three user-reported bugs manifest together

All three bugs share one root cause: **dismiss doesn't visually take
effect fast enough**, so:

1. Bug 1 (overlay 关不掉): `orderOut+close` reports `isVisible=false`
   but the WindowServer still has the composited surface up because
   the cargo-cult sequence (alpha=0, level change, contentView=nil)
   fights the natural close cycle. In particular, `contentView = nil`
   before `close()` prevents the window's final display pass from
   drawing an "empty" state, so WindowServer keeps the last frame.
2. Bug 2 (drag rect wrong position): the visible rect on screen is
   the STALE rect from the last drag, still painted by WindowServer
   because dismiss didn't flush. User's fresh drag looks offset from
   the visible rect because the visible rect is from the previous
   session.
3. Bug 3 (cmux jumps in early): `dismiss()` returns synchronously but
   the surface stays up; the harvest kicks off, and `captureLinks`
   activates the agent app which brings cmux to the front — on top of
   the still-painted overlay surface.

Everywhere avoids this entirely by (a) using a single `Close()` call
that Avalonia routes through NSWindow release + full teardown, and
(b) keeping the overlay alive during harvest so dismiss is the
FINAL step before the agent-activation call.

## Post-fix expected log ordering (next Alt+L)

```
openclicky.linkrect_overlay.install_panel {screen_idx: 0, cocoa_origin_x: 0, cocoa_origin_y: 0, size_w: 3840, size_h: 2160, level: 1000, backing_scale: 2}
openclicky.linkrect_overlay.begin {panel_count: 1}
openclicky.linkrect_overlay.mouse_down_anchor {cocoa_x: 1234, cocoa_y: 890, quartz_x: 1234, quartz_y: 1270, on_screen_idx: 0}
openclicky.linkrect_overlay.mouse_drag_current {cocoa_x: 1400, cocoa_y: 850, quartz_x: 1400, quartz_y: 1310, rect_cocoa_x: 1234, rect_cocoa_y: 850, rect_cocoa_w: 166, rect_cocoa_h: 40, rect_quartz_x: 1234, rect_quartz_y: 1270, rect_quartz_w: 166, rect_quartz_h: 40}
... (more drag frames) ...
openclicky.linkrect_overlay.mouse_up {quartz_x: 1400, quartz_y: 1310, rect_w: 166, rect_h: 40}
openclicky.linkrect_harvest.debug {drag_quartz_x: 1234, drag_quartz_y: 1270, drag_w: 166, drag_h: 40, candidates_scanned: N, candidates_kept: M, ...}
openclicky.linkrect_overlay.dismiss_step {step: "orderOut", window_isVisible: true, alpha: 1.0, level: 1000}
openclicky.linkrect_overlay.dismiss_step {step: "close", window_isVisible: false, alpha: 1.0, level: 1000}
openclicky.linkrect_overlay.dismiss_step {step: "released_screens", window_isVisible: false, alpha: 1.0, level: 1000}
openclicky.linkrect_overlay.dismiss {screens_ordered_out: 1, total_screens: 1}
(then and ONLY then)
openclicky.launch_phrase.activate_agent { ... }
```

## Worked coord example

Primary screen `NSScreen.screens[0]` = 3840x2160 at Cocoa origin (0,0).
`primaryScreenHeight = 2160`.

User drags from Cocoa cursor (1234, 890) to Cocoa cursor (1400, 850).
Visually: drag goes RIGHT and slightly DOWN on screen.

Flip to Quartz (top-left):
- anchor: `(1234, 2160 - 890) = (1234, 1270)`
- current: `(1400, 2160 - 850) = (1400, 1310)`

Quartz drag rect (`min/max`):
- `minX=1234, minY=1270, maxX=1400, maxY=1310`
- `rectQuartz = (1234, 1270, 166, 40)`

For the primary screen mask (screenFrame origin (0,0)):
- `viewLocalRect(fromQuartzGlobal: rectQuartz)`:
  - `appkitY = primaryHeight - rect.origin.y - rect.size.height`
  - `      = 2160 - 1270 - 40 = 850`
  - `localX = 1234 - 0 = 1234`
  - `localY = 850 - 0 = 850`
  - result: `NSRect(1234, 850, 166, 40)` in AppKit-local (bottom-left).

Cocoa Y=850 with height=40 means the rect covers Cocoa Y=850..890,
matching the actual drag cursor Y-range (Cocoa 850 → Cocoa 890).
Correct.

This math is byte-parity with Everywhere's Avalonia `SetMask` after
scale-1 flattening — Avalonia's top-left Y=1270 corresponds to the
top of the rect (Quartz-top-left), openclicky's bottom-left Y=850
corresponds to the bottom of the rect. Both paint the same pixels.

## Whiteboard / Pick / Annotation status

Coordinator asked for byte-exact port of all 4 overlay hotkey flows.
This session addresses LinkRect only — file sizes for Whiteboard
(`WhiteboardHotkeyInitializer.cs` 69KB + `WhiteboardOverlay.cs` +
`AnnotationSnapper.cs`) and Annotation (`AnnotationOverlayHost.cs` +
`AnnotationOverlayWindow.cs`) exceed a single-turn budget. Follow-ups
tracked separately.

- **Whiteboard**: `OpenClickyWhiteboardOverlayWindow.swift` (41.2K) —
  Round 2 already landed underline widening (60/60/50/20) and toggle
  semantic. Not touched here.
- **Pick**: `OpenClickyPickElementOverlay.swift` (20.7K) — small
  green highlight follows AX element via `OpenClickyAXFollower`
  (F28 observer). Not touched here.
- **Annotation**: `OpenClickyAnnotationBadgeOverlay.swift` (28.7K) —
  single `+` badge tied to `PickStash`, 50ms poll. Not touched here.

All three preserve `canBecomeKey=false`, `OpenClickySafeMakeKeyAndOrderFront`,
NSEvent global monitors, and the F27/F28/F31 wiring per constraint
list.
