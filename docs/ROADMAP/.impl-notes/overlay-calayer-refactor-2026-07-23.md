# CALayer host refactor for three hotkey overlays (2026-07-23)

Root fix for the macOS 26 "overlay tile does not clear" bug that
affected LinkRect (Alt+L), Whiteboard (Alt+D), and Pick (Alt+S).
Every prior workaround inside the per-hotkey NSPanel lifecycle
(`orderOut`, `close`, `contentView = nil`, `alpha=0`, `level =
.baseWindow`, `setFrame(.zero)`, sleep + runloop pump) failed
because macOS 26's WindowServer refuses to drop a `.screenSaver`
borderless-nonactivating panel's last composited tile until an
unrelated event forces a recomposite. Everywhere doesn't hit this
because Avalonia draws direct to CGLayer, bypassing NSPanel.

We now bypass NSPanel too, in the smallest way that keeps AppKit
happy: **one long-lived fullscreen NSWindow per NSScreen**, with
CALayers attached / removed per hotkey session.

## OverlayWindow.swift structure findings (why we couldn't reuse OverlayWindowManager)

`OverlayWindowManager` (`cursor-buddy/OverlayWindow.swift:3346`)
owns a per-screen `OverlayWindow` NSWindow whose contentView is a
`NSHostingView<BlueCursorView>`. It is:

- Only alive when `CompanionManager.showCursorOverlayIfAvailable()`
  was called — which requires Accessibility permission + the
  cursor-buddy sprite feature enabled. The three hotkey overlays
  need to work regardless of that (they use permissions the sprite
  doesn't need — screen recording, AX, input monitoring).
- The `contentView` is a SwiftUI `NSHostingView`. AppKit does back
  it with a CALayer when `wantsLayer` propagates, but SwiftUI owns
  the sublayer tree and re-installs it on view invalidation. Adding
  our own sublayers next to SwiftUI's would work initially but risk
  being clobbered by SwiftUI layout passes.

Solution: a dedicated peer host manager (`OpenClickyOverlayLayerHost`)
in a new file `cursor-buddy/OpenClickyOverlayLayerHost.swift`. Its
contentView is a bare `NSView` with `wantsLayer = true`; SwiftUI is
never in the picture, so sublayers stay put across every host redraw.

## Files changed

| File | Change |
|---|---|
| `cursor-buddy/OpenClickyOverlayLayerHost.swift` (NEW) | Persistent per-screen layer host, click-through by default, mouse-capture refcount, coord helpers. |
| `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` | Rewritten from 3 NSWindow classes + NSView draw path to a `SessionHost` struct that attaches a black tint CAShapeLayer + white 2px border CAShapeLayer to each host. Flash rectangles for captured links become a CAShapeLayer added at flash time. |
| `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift` | Rewritten from per-screen `NSPanel` + `OpenClickyWhiteboardOverlayView` `NSView` (which owned NSBezierPath stroke arrays) to per-host `SessionHost` with N `CAShapeLayer` per stroke, incremental path rebuild on drag. Preview classified overlays and OCR pipeline (`processAndStash`) preserved byte-for-byte from the pre-refactor path. |
| `cursor-buddy/OpenClickyPickElementOverlay.swift` | Rewritten from a small floating NSPanel that got `setFrame`-tracked over the hovered element to one `CAShapeLayer` per host whose `path` is set to a rounded rect on hit-test. |

`OpenClickyContextHotkeys.swift` is untouched — its call sites
(`performLinkRectStub`, `performWhiteboardBegin`,
`performAgentPickElement`) still use the same public API
(`OpenClickyLinkRectOverlayWindow.present(completion:)`,
`OpenClickyWhiteboardOverlayWindow.shared.begin()`/`end()`,
`OpenClickyPickElementOverlay.shared.begin()`).

## Host attachment strategy

```
OpenClickyOverlayLayerHost.shared
  ├── hosts[0]        (NSScreen.screens[0])
  │     LayerHostWindow (borderless, .screenSaver level, alwaysAlive)
  │       LayerHostContentView (NSView, wantsLayer=true)
  │         rootLayer (CALayer, geometryFlipped=false so Cocoa y-up)
  │           <session containers get added here>
  ├── hosts[1]        (NSScreen.screens[1])   -- same shape
  └── ...
```

Idle state: `ignoresMouseEvents = true` on every host window, so
the host is fully click-through and adds zero interaction cost.

Session state: sessions call
`OpenClickyOverlayLayerHost.shared.beginMouseCapture(reason:)` on
install and the matching `endMouseCapture` on teardown. When the
refcount goes positive the host flips to
`ignoresMouseEvents = false` so drags don't leak to the app
underneath.

## Per-hotkey layer lifecycle

### LinkRect (Alt+L)

```
present(completion:)
  -> ensureInstalled()               # bring host up if cold
  -> beginMouseCapture(reason:"linkrect")
  -> for each host:
       container   = CALayer (parent of everything)
       tintLayer   = CAShapeLayer(evenOdd, black α=0.2, fills screen minus drag rect)
       borderLayer = CAShapeLayer(stroke white 2px around drag rect)
     attach container to hostRootLayer
  -> installEventMonitors()          # global+local mouseDown/Dragged/Up + rightClick + Esc

on mouseDown  -> anchor = pointer, renderDragRect updates tint hole + border
on mouseDragged -> update currentQuartz, renderDragRect
on mouseUp:
  -> finish(finalRect):
       remove tintLayer + borderLayer immediately   # user sees drag rect vanish
       endMouseCapture(reason:"linkrect_mouseup")
       teardownEventMonitors()
       completion(.rect(finalRect))               # container stays for the flash
on Esc / right-click  -> cancel() -> dismiss() -> completion(.cancelled)

highlightCapturedLinks(rects:)  (called by hotkey handler)
  -> attach CAShapeLayer with aqua fill+stroke to each host's container

logFlashEnd(rectCount:) then dismiss()
  -> endMouseCapture (if not already released)
  -> remove container.removeFromSuperlayer() for each host
  -> host windows stay alive
```

Preserves harvest -> flash 700ms -> dismiss -> launch-phrase order
in `OpenClickyContextHotkeys.harvestAndPersistLinkRect`.

### Whiteboard (Alt+D)

```
begin() (first press)
  -> beginMouseCapture(reason:"whiteboard")
  -> for each host: container + tintLayer (black α=0.15) attached
  -> NSCursor.crosshair.set()
  -> installEventMonitors()

on mouseDown/Dragged  -> create/append CAShapeLayer per stroke on the
                         host under the cursor; incremental path build
on mouseUp            -> append the release point to the same stroke

end() (second press) OR toggle
  -> teardownEventMonitors()
  -> remove strokeLayers immediately  (ink visually vanishes)
  -> if strokes non-empty:
       classify by host, paint orange-dashed CAShapeLayer preview
  -> 250ms later: remove container from each host
  -> endMouseCapture(reason:"whiteboard_end")
  -> Task.detached: processAndStash(strokes:)  (untouched OCR pipeline)

cancel() (Esc)
  -> remove containers immediately, drop strokes, endMouseCapture
```

### Pick (Alt+S)

```
begin()
  -> ensureInstalled()
  -> for each host: attach one small CAShapeLayer (stroke systemGreen, lw=2, cornerRadius=6)
  -> installEventMonitors()  (mouseMoved, leftMouseDown, rightMouseDown, Esc)
  -> NSCursor.crosshair.push()

on mouseMoved (30fps throttled):
  -> AXUIElementCopyElementAtPosition
  -> for the host containing the AX frame's centre, set the highlight's path
  -> for other hosts, clear path
  -> stash lastHoverElement for the click monitor

on leftMouseDown:
  -> re-hit-test, resolve element (fallback to lastHoverElement)
  -> extract role/title/value/bounds/pid/bundleId  -> PickedElement
  -> AnnotationBadgeOverlayClassifier.pinAnchorID + OpenClickyPinnedAXElementRegistry.store
  -> PickStash.shared.set(picked)
  -> teardown()

teardown()
  -> detachAll(highlight layers)     # green outline disappears immediately
  -> remove all NSEvent monitors
  -> NSCursor.pop()
```

Pick overlay does NOT hold mouse capture — the click needs to pass
through so the app underneath still receives it. This matches
Everywhere's PickerSession behaviour.

## Coordinate conversion updates

The pre-refactor NSView draw paths converted Quartz global
(top-left) -> per-view Cocoa (bottom-left) inline. In the refactor
that helper is centralised on
`OpenClickyOverlayLayerHost.viewLocalRect(fromQuartzGlobal:on:)`
and `viewLocalPoint(fromCocoaGlobal:on:)`. The root layer keeps
`isGeometryFlipped = false` so all CALayer coords are Cocoa
bottom-left (no additional flip needed inside the host).

Coord chain (LinkRect drag rect example):

```
NSEvent.mouseLocation                 -> Cocoa global bottom-left
  |  (flip Y about primary screen height)
  v
Quartz cursor point                   -> top-left
  |  (min/max with anchor)
  v
Quartz drag rect                      -> stored in currentQuartzRect
  |
  |  per host, in renderDragRect:
  v
OpenClickyOverlayLayerHost.viewLocalRect(fromQuartzGlobal:on:)
                                      -> host-local Cocoa bottom-left
  |
  v
tintLayer.path = fullBounds + rectSubpath  (evenOdd fill)
borderLayer.path = rect
```

## Concurrency gotchas

- All layer mutations happen on the main actor (host + sessions
  are `@MainActor`).
- `CATransaction.begin()` / `setDisableActions(true)` / `commit()`
  wraps every layer add / remove so implicit fade animations
  don't leave stale opacity 0.001 layers behind. This is the
  micro-detail that makes the fix actually work — without
  disabling implicit actions, layer removal fades out over ~0.25s
  and macOS 26's compositor pins the fading tile for the same
  time window.
- Mouse-capture refcount handles overlapping overlays sanely: if
  the user manages to fire Alt+L and then Alt+D before the first
  session ends, both `beginMouseCapture` calls stack; the last
  `endMouseCapture` restores click-through. The reentrancy guard
  in `OpenClickyContextHotkeys.performLinkRectStub` normally
  prevents this, but the pattern is robust either way.
- Display hot-plug: `NSApplication.didChangeScreenParametersNotification`
  triggers `rebuild(for:)`, which rebuilds host windows for the
  new screen configuration. In-flight session layers on the old
  hosts vanish with the hosts; the session will lose its ink on
  hot-plug (documented, acceptable — Everywhere has the same
  behaviour).

## Fallback plan

The pre-refactor NSPanel path is fully removed to avoid
maintaining two code paths. If a regression surfaces:

1. `git revert` the commit that lands this refactor; the git
   history preserves the working NSPanel implementation.
2. Or: gate the new code behind a `UserDefaults`-backed flag,
   e.g. `openclicky.overlay.calayer_host_enabled` (default true),
   and re-add a copy of the previous implementation under an
   `else` branch. This was NOT done inline because the panel
   path is what we're actively working around — leaving it live
   as a fallback would keep the tile-cache bug reachable on
   macOS 26. The rollback path is git, not a runtime flag.

Additional safety-net: `OpenClickyOverlayLayerHost` itself is
completely passive when no session is active. The persistent host
windows sit at cursor-overlay level (same as
`OverlayWindowManager`'s buddy overlay), are transparent, are
click-through, and don't participate in the responder chain. They
add three windows to the app-wide window list (one per screen);
in profiling this is indistinguishable from the pre-refactor state
where `OverlayWindowManager` already installed one buddy window
per screen.

## Build result

```
$ bash scripts/sign-and-install.sh
[1/5] xcodebuild
** BUILD SUCCEEDED **
  built: .../Build/Products/Debug/OpenClicky.app
  helper: .../Contents/Helpers/openclicky-context-hook (3263824 bytes)
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=22491 identifier=com.jkneen.openclicky Authority=OpenClicky Dev Sign
[5/5] done.
```

Zombie check: `pgrep -fl "node.*[Oo]penclicky"` -> no matches.

## Expected user test outcomes

1. **Alt+L**: press -> drag -> mouseUp. The tint + border layers
   are removed inside `finish()` before `completion(.rect(_))`
   fires, so the drag rect visually vanishes IMMEDIATELY on
   mouseUp. Then `highlightCapturedLinks(rects:)` attaches the
   aqua CAShapeLayer for 700ms. Then `logFlashEnd` + `dismiss()`
   remove the container. Then cmux gets focus + phrase. No
   residual painted rect.

2. **Alt+D**: press -> draw N strokes -> Alt+D again to commit.
   Stroke layers are removed synchronously in `end()` before the
   OCR pipeline starts, so the ink disappears immediately. The
   orange-dashed classifier preview lingers 250ms and vanishes
   with the container. cmux gets the phrase after
   `OpenClickyContextStashWriter.shared.captureAsync()`.

3. **Alt+S**: press -> move mouse -> small green outline follows
   the current AX element (30fps throttled; CATransaction
   disables implicit position animation so it snaps). Click ->
   `handleClick` populates PickStash and the pinned registry, then
   `teardown()` removes the highlight layer. No residual outline.
