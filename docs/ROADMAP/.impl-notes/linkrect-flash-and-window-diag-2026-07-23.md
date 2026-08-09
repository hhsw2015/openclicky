# LinkRect flash + window install/dismiss diagnostics

Date: 2026-07-23
Owner: agent (LinkRect UI bug pass)

## Purpose

Two-part change:

1. **Diagnostics**: Instrument every openclicky fullscreen-window install and
   dismiss site so the log tail after the next Alt+L press identifies which
   subsystem's window is leaking on screen (the reported black-tint + drag-rect
   residue at layer 499 (`.screenSaver`), 1728x1080, alpha=1.0 after LinkRect
   dismiss).
2. **700ms link flash**: Port Everywhere's aqua highlight of harvested link
   bounding rects before the overlay dismisses, so the user gets a concrete
   visual confirmation of which links landed in the stash.

The mystery-window bug itself is NOT fixed in this pass — only instrumented so
the next Alt+L cycle self-identifies the culprit via `install_*` without a
matching `dismiss_*`.

## Files touched

| File | Change |
| --- | --- |
| `cursor-buddy/cursor_buddyApp.swift` | Startup snapshot: `openclicky.window.startup_snapshot` enumerating every `NSApp.windows` entry at `applicationDidFinishLaunching`. |
| `cursor-buddy/OverlayWindow.swift` | Install/dismiss log for buddy fullscreen cursor overlay (per screen) and for the agent dock panel. |
| `cursor-buddy/OpenClickyPickElementOverlay.swift` | Install/dismiss log for the pick highlight panel. |
| `cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift` | Install/dismiss log for the outline + badge follower windows. |
| `cursor-buddy/HeyClickyGuidedClickManager.swift` | Install/dismiss log for the guided-click ring overlay. |
| `cursor-buddy/MenuBarPanelManager.swift` | Install/dismiss log for the legacy status-item panel. |
| `cursor-buddy/CodexHUDWindowManager.swift` | Install/dismiss log for the Codex HUD panel (both `hide` and `destroy` paths). |
| `cursor-buddy/OpenClickyNotchCaptureWindowManager.swift` | Install log for the notch capture status panel + main panel; dismiss log for `hide()` and `hideMainPanel`. |
| `cursor-buddy/OpenClickyLinkRectHarvester.swift` | Extended `OpenClickyLinkRectHarvestResult` with `pickBounds: [CGRect]` (aligned by index with `picks`) so flash rects can flow to the overlay. |
| `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` | Added `highlightCapturedLinks(rects:)` and `logFlashEnd(rectCount:)` on the overlay; drag view now stores `capturedQuartzRects` and paints the aqua border+fill. |
| `cursor-buddy/OpenClickyContextHotkeys.swift` | `harvestAndPersistLinkRect` now paints the flash on main, `Task.sleep(700_000_000)`, logs flash_end, then dismisses (before firing the launch phrase). |

## Instrumented window install sites

Event schema: `openclicky.window.installed.<subsystem>` with fields
`{window_num, size_w, size_h, level, alpha, purpose}`. Dismiss twin
`openclicky.window.dismissed.<subsystem>` with `{window_num, reason}`.

| Subsystem | Install site | Dismiss site |
| --- | --- | --- |
| `cursor_overlay` | `OverlayWindow.showOverlay` (per screen) | `OverlayWindow.hideOverlay` |
| `agent_dock` | `OverlayWindow.AgentDockPanel.show` | `.hide` |
| `pick_overlay` | `OpenClickyPickElementOverlay.installPanel` | `.teardown` |
| `annotation_badge_outline` + `annotation_badge` | `OpenClickyAnnotationBadgeOverlay.presentIfNeeded` | `.tearDown` |
| `guided_click` | `HeyClickyGuidedClickManager.arm` | `.disarm` |
| `menu_bar_panel` | `MenuBarPanelManager.showLegacyStatusItemPanel` | `.hidePanel` |
| `codex_hud` | `CodexHUDWindowManager.show` (post-orderFront) | `.hide` and `.destroy` |
| `notch_capture_status` | `OpenClickyNotchCaptureWindowManager.showPanel` | `.hide` |
| `notch_capture_main` | `OpenClickyNotchCaptureWindowManager.showMainPanelWindow` | `.hideMainPanel` |
| LinkRect (already had per-screen install log) | `OpenClickyLinkRectOverlayWindow.installOnAllScreens` | `.dismiss` |

## 700ms flash — Everywhere port

Source references (byte-exact):

- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs:57-72` —
  the `HarvestAsync` block that runs `HighlightCapturedLinks(harvested)` +
  `Task.Delay(700, ct)` while the overlay is still on screen, and only then
  posts `Close()`.
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Views/ScreenSelection/ScreenSelectionWindow.cs:122-154` —
  `SetCapturedLinkRects`: aqua border `Color.FromArgb(0xFF, 0x00, 0xC8, 0xFF)`
  and aqua fill `Color.FromArgb(0x40, 0x00, 0xC8, 0xFF)`, `BorderThickness = 2`.

Port shape:

1. `OpenClickyLinkRectHarvestResult` gained a parallel `pickBounds: [CGRect]`
   populated from the harvest session's `byUrlBounds` map (Quartz global,
   top-left origin — same space as the drag rect).
2. `OpenClickyLinkRectOverlayWindow.highlightCapturedLinks(rects:)` fans the
   rect list out to every per-screen drag view via `setCapturedLinkRects(_:)`,
   which caches the list and forces a redraw.
3. `OpenClickyLinkRectDragView.draw(_:)` now paints the aqua rects on top of
   the (cleared) black tint after drawing the drag rect. Border stroke is 2px,
   colour `RGBA(0.0, 0.784, 1.0, 1.0)` (= `#FF00C8FF`), fill is the same colour
   at 0.25 alpha (= `#4000C8FF`). Byte-exact colour match with Everywhere.
4. `OpenClickyContextHotkeys.harvestAndPersistLinkRect` now:
   - filters `pickBounds` to non-empty rects,
   - hops to main → `highlightCapturedLinks`,
   - `Task.sleep(700_000_000)` (700ms — matches `Task.Delay(700, ct)` in
     Everywhere at LinkRect.cs:63),
   - hops to main → `logFlashEnd`,
   - hops to main → `dismiss()`,
   - then fires `captureLinks` (byte-exact ordering: overlay closes before
     launch phrase, mirrors LinkRect.cs:69 completing before
     `LinkRectHotkeyInitializer.CaptureLinksAsync`).

When `pickBounds` is empty (zero picks) the flash is skipped — matches
Everywhere's `if (harvested.Count > 0)` guard at LinkRect.cs:60 that avoids
sitting on an empty overlay when the user drags over blank space.

## Expected log tail sequence after next Alt+L

For a drag that harvests 3 links, the tail should now show:

```
openclicky.window.startup_snapshot           # once at app launch
...
openclicky.linkrect_overlay.install_panel    # per screen
openclicky.linkrect_overlay.begin
openclicky.linkrect_overlay.mouse_down_anchor
openclicky.linkrect_overlay.mouse_drag_current  (many)
openclicky.linkrect_overlay.mouse_up
openclicky.linkrect_harvest.debug
openclicky.linkrect_overlay.flash_paint      # NEW — link_count=3, first_rect_*
                                             # (~700ms sleep here)
openclicky.linkrect_overlay.flash_end        # NEW — link_count=3
openclicky.linkrect_overlay.dismiss_step (x3 per screen)
openclicky.linkrect_overlay.dismiss
```

Any other install/dismiss pair from `openclicky.window.installed.*` /
`openclicky.window.dismissed.*` should be balanced. Any subsystem with an
install log but NO matching dismiss log after the drag completes is the
culprit for the persistent fullscreen residue.

## User instruction — how to find the mystery fullscreen window

After the next Alt+L drag:

```
curl -sS -H "x-openclicky-token: $TOKEN" \
  'http://127.0.0.1:32123/agent/log/tail?count=500' \
  | grep 'openclicky.window'
```

Compare install vs dismiss counts per subsystem. The subsystem name embedded
in the unbalanced `openclicky.window.installed.<subsystem>` (with `size_w` /
`size_h` matching the reported 1728x1080 and `level=499`) will identify the
leaked window. Cross-reference with the `startup_snapshot` at app launch to
rule out pre-existing surfaces.

## Verification

- `bash scripts/sign-and-install.sh` — `** BUILD SUCCEEDED **`, codesigned,
  swapped into `/Applications/OpenClicky.app`, PID launched.
- Zombie Node children from the previous PID (77454/77455/77456 rooted in the
  now-dead pid 77340) killed; only the current PID (90610) children remain.

## Constraints honoured

- LinkRect dismiss order unchanged: `flash_paint → sleep 700ms → flash_end →
  overlay.dismiss() → captureLinks`. The `dismiss()` path
  (`dismiss_step` × 3) is byte-exact and untouched.
- No behavioural fixes attempted for the mystery fullscreen window this pass —
  only observability. The instrument-first policy from the task brief is
  preserved.
- No changes outside the file allowlist.
