# Phase 7.1 — PickElement overlay + Annotation ➕ badge (impl notes)

Date: 2026-07-23. Layer 4 UX visualisation pass. Wires the AgentPickElement
hotkey to a live crosshair overlay and shows the ➕/✓ annotation badge next
to every pinned / whiteboard-framed / linkrect-hit element, with delta-follow
so the badges track the anchor as it moves.

## Everywhere ground truth

- `src/Everywhere.Core/Views/Annotation/AnnotationOverlayWindow.cs`
  - 24 px round badge, gradient (#AC45F1 → #7A7EF4 → #3DC6F8) that turns
    solid green (#3DC68C) with a ✓ once committed.
  - Expanded popover 320×110, textarea watermark "写点注释… (Esc 收起)"
  - Commit gestures: blur / Esc / Cmd+Enter. Re-editing a committed note
    prefills the textarea. Emptying + collapsing fires `Cleared`.
- `src/Everywhere.Core/Views/Annotation/AnnotationOutlineWindow.cs`
  - Static outline (border color #AC45F1, 2 px, radius 6) that follows
    the anchor via `MoveTo`.
- `src/Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs`
  - Owns a list of `PinOverlayPair` (element + outline + badge).
  - `DispatcherTimer` at 50 ms polls `IVisualElement.BoundingRectangleLive`;
    if the rect goes empty the overlay hides but the pair is kept.
  - `SnapshotContext` tears everything down (the notes have shipped).
  - `PickStash.Cleared` (ClearContextStash hotkey) removes the stash
    entries and tears the overlays down.
  - Multi-pin: appending each new pin adds a new pair; not a single-slot.
- `src/Everywhere.Mac/Interop/VisualElementContext.Picker.cs`
  - The pick session is a screen-selection overlay that reuses the
    generic `ScreenSelectionSession` (element mode by default). We
    reimplement equivalent behaviour: full-screen dim, crosshair cursor,
    green hit outline, click captures.

## OpenClicky mapping

- `PickStash.shared` is single-slot (matches Everywhere semantics),
  fires `.pickStashDidChange` on `set` / `take` / `clearWithEvent`.
- `AnnotationStash.shared` is a queue, fires
  `.annotationStashDidChange` on append/consume/clear.
- `WhiteboardStash.shared` only fires `.openClickyWhiteboardStashCleared`
  on `clearWithEvent`; there is no post-`set` "did change" today. The
  spec named a `.whiteboardStashDidChange` but the SPM package is
  read-only for this phase, so the badge overlay listens for the
  cleared notification and additionally polls `WhiteboardStash.shared`
  from the follow timer (below).
- LinkRect has no dedicated stash class — regions land in the
  `context-stash.json` `picked_links` array. Phase 7.1 does not yet
  ship a linkrect drag overlay (still a stub in `performLinkRectStub`),
  so the badge overlay treats linkrect anchors as future work: the
  observer wiring is in place but no source publishes them yet.

## File plan

Create (new, non-test):

1. `cursor-buddy/OpenClickyPickElementOverlay.swift`
   - `@MainActor final class OpenClickyPickElementOverlay`
   - Full-screen click-catching `NSPanel` (one per screen, cursor
     overlay level, background alpha 0.15).
   - Custom `NSView` subclass that owns an `NSTrackingArea` sized to
     the panel and repaints a 2-px green rounded outline for the AX
     element currently under the pointer. `mouseMoved:` polls
     `AXUIElementCopyElementAtPosition` at ~30 fps by throttling to
     33 ms; the AX call is cheap for a single hit-test.
   - Escape / right-click / any keyDown other than Escape cancels.
   - Left-mouse-down captures the element, packs a `PickedElement`,
     calls `PickStash.shared.set(...)`, then tears down the overlay.

2. `cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift`
   - `@MainActor final class OpenClickyAnnotationBadgeOverlay`
   - Owns a dictionary `[AnchorKey: BadgePair]`. Each pair has an
     `NSPanel` for the outline and another `NSPanel` for the badge
     with an `NSHostingView` root.
   - Subscribes to `.pickStashDidChange`, `.annotationStashDidChange`,
     `.openClickyWhiteboardStashCleared`.
   - On `.pickStashDidChange`: if `.peek()` returns an element, create
     or refresh the pair keyed by pid+bounds; on nil, tear down.
   - `AnnotationStash.shared.peek()` supplies the ✓ / count; recomputed
     after every notification.
   - Uses `OpenClickyAXFollower` per pair.

3. `cursor-buddy/OpenClickyAXFollower.swift`
   - `AXObserverCreate` + `AXObserverAddNotification` for
     `kAXValueChangedNotification`, `kAXWindowMovedNotification`,
     `kAXWindowResizedNotification` on the target's window ancestor.
   - Delivers callbacks on the main run loop.
   - Fallback: a 100 ms `DispatchSourceTimer` polls the AX element's
     `AXPosition` / `AXSize` for cases where observer setup fails
     (Electron / restricted apps).

Modify:

- `cursor-buddy/OpenClickyContextHotkeys.swift`
  - `performAgentPickElement` no longer does the hit-test itself.
    Instead it activates `OpenClickyPickElementOverlay.shared.begin(...)`,
    which resolves to a `PickedElement` and calls `PickStash.set`
    from its click handler.

- `cursor-buddy/CompanionManager.swift`
  - Instantiate `OpenClickyAnnotationBadgeOverlay.shared.start(...)`
    inside the accessibility-permission gate (same spot where
    `contextAwarenessHotkeys.start()` is called) so the badge
    subscriptions are alive while the hotkeys are.
  - Call `.stop()` alongside `contextAwarenessHotkeys.stop()`.

Do NOT touch:

- SPM package (`Packages/OpenClickyContextService/**`) — read-only.
- Bridge / RouteDispatcher / ChatToolCall client — no wiring beyond
  the two managers above.
- `ClickyCodexConfigTemplate.swift`, `OpenClickyContextAwarenessPanel.swift`,
  overlay-adjacent files unrelated to pick/annotate.

## Behaviour crosswalk

| Everywhere step | OpenClicky step |
|-----------------|-----------------|
| AgentPickElement hotkey → `PickerSession.PickAsync` | AgentPickElement hotkey → `PickElementOverlay.begin` |
| Screen-selection overlay tracks element under cursor | Custom NSPanel + `NSTrackingArea` + throttled AX hit-test |
| Click resolves `IVisualElement` → `PickStash.Set` | Click resolves `PickedElement` value type → `PickStash.set` |
| `PickStash.Pinned` event → `AnnotationOverlayHost.OnPinned` | `.pickStashDidChange` → `AnnotationBadgeOverlay.refresh` |
| `DispatcherTimer(50ms)` polls `BoundingRectangleLive` | AXObserver primary + 100 ms `DispatchSourceTimer` fallback |
| `Committed` → `AnnotationStash.Add` | Cmd+Enter / blur → `AnnotationStash.shared.append` |
| `Cleared` → `AnnotationStash.RemoveItem` | Empty-collapse → `AnnotationStash.shared.consume([lastItem])` |
| `ClearContextStash` hotkey tears down overlays | Same, driven by `.pickStashDidChange` firing on `clearWithEvent` |
| `ManualCaptureCompleted` closes overlays | Not wired yet; snapshot writer does not publish a Swift event. Left as TODO. |

## Delta-follow decision

Everywhere uses a 50 ms poll because Avalonia's dispatcher is cheap and
they always run an AX cross-process call in `Task.Run`. On macOS Swift
we have direct AX access, but AX calls to remote pids still hop a
Mach message — 50 ms felt right in Everywhere, but the Everywhere
notes warn 150 ms was noticeably laggy.

Choice: AXObserver primary, 100 ms fallback timer. Reasons:

- AXObserver fires *only* on actual movement, so idle windows do not
  burn CPU.
- Not every AX tree supports observers (Electron, sandboxed Java, and
  some apps that opt out). For those the timer takes over.
- 100 ms fallback keeps feel responsive without hammering AX; the
  Everywhere 50 ms decision was for an implementation that couldn't
  hear AX events at all.

## Tests

Unit test (`cursor-buddyTests/OpenClickyAnnotationBadgeOverlayTests.swift`):

- Build a private `PickStash` + `AnnotationStash` with an injected
  clock, run the classifier `AnchorState` logic that drives the badge
  label — no NSPanel plumbing under XCTest. Assert:
  - PickStash.set → `AnchorState.hasPin == true` and `.badgeLabel == "＋"`
  - AnnotationStash.append matching anchor → `.badgeLabel == "✓ 1"`
  - clearWithEvent → no anchors visible.

The overlay class exposes a `@testable` `AnchorState` snapshot that
the tests exercise; the NSPanel presentation stays in the private
"present" method so no windows are created inside XCTest.

## Verification recipe

1. Bind AgentPickElement + ClearContextStash in Settings → Context
   Awareness.
2. `bash scripts/sign-and-install.sh` — launch fresh app.
3. Hit AgentPickElement while hovering over Safari's URL bar.
4. Overlay dims screen, green outline follows the pointer.
5. Click — outline sticks to the URL bar, red ➕ badge appears next to
   its top-right corner.
6. Click the badge → textarea expands, type "focus on the query", hit
   Cmd+Enter. Badge collapses back to a green ✓ 1.
7. Scroll the surrounding window → badge tracks the URL bar.
8. Hit ClearContextStash → badge disappears.
