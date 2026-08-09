# Phase 7.1 report — PickElement overlay + Annotation ➕ badge

Date: 2026-07-23. Ships the Layer 4 UX visual layer: a crosshair-based
element picker for the AgentPickElement hotkey, and a floating red-➕
badge that follows every currently-pinned element and lets the user
attach a free-text note to `AnnotationStash`.

## Files created

- `cursor-buddy/OpenClickyPickElementOverlay.swift`
  Full-screen click-catching NSPanel (one per screen) with 0.15
  black wash + crosshair cursor. `PickHitView` runs a throttled
  30 fps `AXUIElementCopyElementAtPosition` per mouse-move,
  repaints a 2-px green rounded outline for the hovered element,
  and on click packs a `PickedElement` into `PickStash.shared`.
  Escape / right-click cancels.
- `cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift`
  - Pure classifier `AnnotationBadgeOverlayClassifier` that reads
    `PickStash.peek()` + `AnnotationStash.peek()` and returns
    `(AnnotationAnchor, AnnotationBadgeState)` pairs — the tests
    exercise this without spinning up any AppKit windows.
  - `@MainActor` controller `OpenClickyAnnotationBadgeOverlay`
    subscribes to `.pickStashDidChange`,
    `.annotationStashDidChange`, `.openClickyWhiteboardStashCleared`
    and diffs live anchors against a `[anchorID: BadgePair]`
    dictionary. Each `BadgePair` owns an outline NSPanel + badge
    NSPanel (SwiftUI `NSHostingView` root) + `OpenClickyAXFollower`.
  - Badge collapses/expands via SwiftUI. Commits on Cmd+Enter,
    cancels on Escape, and treats empty-collapse of a ✓ badge as
    "delete annotation" (calls `AnnotationStash.consume`).
  - `OpenClickyPinnedAXElementRegistry` — process-wide side table
    mapping anchor id → boxed live `AXUIElement`, populated by the
    pick overlay's click handler because `PickStash` only carries
    value snapshots and the follower needs the live handle.
- `cursor-buddy/OpenClickyAXFollower.swift`
  AXObserver primary + 100 ms `DispatchSourceTimer` fallback for
  delta-follow. Observes `kAXValueChangedNotification`,
  `kAXWindowMovedNotification`, `kAXWindowResizedNotification`,
  `kAXUIElementDestroyedNotification`. Registers against both the
  target element and its owning window ancestor (best-effort).
- `cursor-buddyTests/OpenClickyAnnotationBadgeOverlayTests.swift`
  XCTest suite covering the classifier: empty state, pick → ➕,
  matching annotation → ✓, multi-count, unrelated notes ignored,
  anchor id stability, and end-to-end stash-driven transitions
  including `clearWithEvent`.

## Files modified

- `cursor-buddy/OpenClickyContextHotkeys.swift`
  `performAgentPickElement` now activates
  `OpenClickyPickElementOverlay.shared.begin()` instead of doing
  the AX hit-test inline. Removed the private AX copy helpers now
  that the overlay owns them.
- `cursor-buddy/CompanionManager.swift`
  Starts / stops `OpenClickyAnnotationBadgeOverlay.shared`
  alongside `contextAwarenessHotkeys` — both share the same
  accessibility-permission gate.
- `cursor-buddyTests/cursor_buddyTests.swift` (+1 line)
  Added missing `import Foundation` (pre-existing broken file:
  Swift 6 `MemberImportVisibility` upcoming feature required the
  explicit import for `NSError` / `Date`). Otherwise the test
  target could not build.
- `cursor-buddyTests/OpenClickyWidgetStateStoreTests.swift`
  Changed `.red` → `.rose` on the accent-theme enum reference
  (pre-existing broken file: `ClickyAccentTheme` has no `.red`
  case, cases are `rose / blue / amber / mint / white`).

## Not touched

- SPM package `Packages/OpenClickyContextService/**` — read-only.
- `HeyClickyChatToolCallClient.swift`, `ClickyCodexConfigTemplate.swift`,
  `OpenClickyContextAwarenessPanel.swift`, notch / bridge / route
  dispatcher — no changes.

## Delta-follow decision

- Primary: `AXObserverCreate` on the pid owning the pinned
  element, then `AXObserverAddNotification` for
  `kAXValueChangedNotification`, `kAXWindowMovedNotification`,
  `kAXWindowResizedNotification`, `kAXUIElementDestroyedNotification`.
  Registers against both the element and its window ancestor so a
  parent-window move fires a callback even if the leaf doesn't
  emit `AXValueChanged`. Observer run-loop source is attached to
  `CFRunLoopGetMain()` so callbacks land on the main thread.
- Fallback: `DispatchSourceTimer` on the main queue, 100 ms
  cadence. Reads the element's `AXPosition` / `AXSize` and
  short-circuits when the rect equals the last seen rect. Runs
  unconditionally alongside the observer so we don't miss moves
  from apps that don't emit the notifications above (Electron
  with hardened AX opt-out, sandboxed Java, some ancient Carbon
  apps).
- The Everywhere reference uses a 50 ms `DispatcherTimer` because
  Avalonia has no direct AX hook. 100 ms was chosen for the Swift
  port on the argument that AXObserver already carries the fast
  path — the timer is a resilience layer, not the primary source.

## Manual test recipe

1. Rebuild + install (`bash scripts/sign-and-install.sh`).
2. Open Settings → Context Awareness. Bind:
   - `AgentPickElement` → your preferred combo (e.g. `⌃⌥P`).
   - `ClearContextStash` → `⌃⌥⇧C`.
3. Grant Accessibility permission if prompted; wait for the app
   to relaunch cleanly.
4. Hover the mouse over Safari's URL bar. Hit
   `AgentPickElement`. Screen dims, crosshair appears; move the
   mouse — the AX element under the pointer gets a 2-px green
   outline.
5. Click on the URL bar. The overlay tears down and a red ➕
   badge appears at the top-right corner of the URL bar.
6. Click the ➕. The badge expands into a 320×110 dark textarea.
   Type `"focus on this"`. Press Cmd+Enter (or click outside).
   The badge collapses back and turns into a green ✓.
7. Scroll the Safari tab so the URL bar moves — the badge tracks
   it via AXObserver / the 100 ms fallback timer.
8. Hit `ClearContextStash`. Badge disappears (PickStash.take()
   from the hotkey action fires `.pickStashDidChange` with an
   empty peek, and the overlay's rebuild pass tears down the
   pair).

## Test status

`OpenClickyAnnotationBadgeOverlayTests.swift` compiles cleanly
via the Swift 6 frontend (verified in the xcodebuild trace).
Running the full test target reveals several pre-existing
compile errors in unrelated test files (`OpenClickyVisualGuidance
OverlayTests.swift`, macros firing outside the main actor). The
two smallest pre-existing breaks (`.red` accent case,
missing `import Foundation`) were fixed in this pass since they
would have blocked any tests from running; the actor-isolation
errors in the visual-guidance tests are out of scope for
Phase 7.1 and left for a dedicated test-infra pass.

The main app target (`cursor-buddy` / `OpenClicky.app`) builds
and signs cleanly via `scripts/sign-and-install.sh`.

## Verification traces

- `swiftc -parse cursor-buddy/OpenClickyPickElementOverlay.swift cursor-buddy/OpenClickyAXFollower.swift cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift`
  → clean, no warnings or errors.
- `bash scripts/sign-and-install.sh`
  → `** BUILD SUCCEEDED **`, codesign OK, installed to
  `/Applications/OpenClicky.app`.
