# Phase 5 — ScreenListCapture port notes (2026-07-23)

## Source of truth

- Everywhere: `src/Everywhere.Mac/Interop/NSScreenVisualElement.cs`
  @30e03e9dcfdd4247fd679828ed86e9042f32d809, 206 lines.
- Roadmap: `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 15
  ("ScreenList + MultiDisplay", P1).

## What Everywhere actually does

`NSScreenVisualElement` wraps a single `NSScreen`. It exposes:

- `Id => "Screen:{GetScreenNumber(_screen)}"` where
  `GetScreenNumber = (screen.DeviceDescription["NSScreenNumber"] as NSNumber)?.Int32Value ?? 0`
  (L167). That maps 1:1 to `CGDirectDisplayID` (UInt32) — Cocoa's
  documented backing type for `NSScreenNumber` is a plain `NSNumber`
  of `CGDirectDisplayID`.
- `Name => _screen.LocalizedName` (L51). Available since macOS 10.15.
- `BoundingRectangle` (L53-68):
  1. Read `_screen.Frame` (Cocoa bottom-left global rect).
  2. Read `NSScreen.Screens[0].Frame` for the primary screen height.
  3. Return `PixelRect(x, primary.Height - (frame.Y + frame.Height),
     width, height)`.

Enumeration lives in `ScreenSiblingAccessor` (L170-206) and just
walks `NSScreen.Screens`. `_index = Array.IndexOf(_screens, element._screen)`,
sibling forwards / backwards iterate up or down from that index.

There is no explicit "primary screen" test in the source — Cocoa
guarantees `NSScreen.Screens[0]` is the display containing the menu
bar (the primary). Everywhere depends on that ordering when it
takes `NSScreen.Screens[0].Frame` as the y-flip reference.

## Y-flip formula (byte-exact)

C# (L62-64):
```csharp
var primaryFrame = NSScreen.Screens[0].Frame;
var x = (int)frame.X;
var y = (int)(primaryFrame.Height - (frame.Y + frame.Height));
```

Everywhere truncates to int. We keep `CGFloat` because Retina layouts
produce fractional origins that we do not want to drop; the arithmetic
is otherwise identical:
```
quartz.x = cocoa.origin.x
quartz.y = primaryHeight - (cocoa.origin.y + cocoa.height)
```
This is the same formula already used by
`FocusedWindowCapture.displayIndex(for:)` (L228-254 of that file) and
`WindowEnumerationCapture.quartzScreenFrames()` — the port stays
consistent across the three capture surfaces.

## Fields to extract

Direct 1:1 with the C# source:

| Field                | Source in NSScreen                                       |
|----------------------|----------------------------------------------------------|
| `displayID`          | `deviceDescription[NSScreenNumber]` NSNumber (UInt32)    |
| `name`               | `localizedName` (macOS 10.15+)                           |
| `frameCocoa`         | `screen.frame` (bottom-left)                             |
| `frameQuartz`        | y-flipped via primary height                             |
| `visibleFrameQuartz` | `screen.visibleFrame` y-flipped                          |
| `backingScaleFactor` | `screen.backingScaleFactor`                              |

Openclicky adds:

- `index` — position in `NSScreen.screens` (0 = primary). Everywhere
  computes this on demand in `ScreenSiblingAccessor.EnsureResources`;
  we materialise it eagerly because callers otherwise have to
  recompute the same index scan every time.
- `isPrimary` — `index == 0`. Convenience for the router / stash
  layer so a downstream consumer does not have to hard-code the
  Cocoa "primary is screens[0]" invariant.

We deliberately do NOT surface `visibleFrameCocoa` — a
Quartz-only visible-frame is enough for hit-testing and menu-bar /
dock clearance calculations. The Cocoa frame is only exposed for
round-trip debug on the full frame.

## Multi-display edge cases

- **Retina scaling.** `backingScaleFactor` is 2.0 on Retina, 1.0 on
  external displays that lack HiDPI. The frames stay in point units
  (Cocoa's convention); pixel dimensions are `frame * backingScaleFactor`.
  We store the raw frames and the scale so callers can compute either.
- **External display disconnect.** `NSScreen.screens` refreshes on
  `didChangeScreenParametersNotification`. The capture is called
  synchronously and reads the current array — the caller is
  responsible for re-invoking on the notification if it wants live
  updates. That matches Everywhere: `ScreenSiblingAccessor` caches
  `_screens` per traversal but never subscribes to change events.
- **Headless / SSH.** `NSScreen.screens` is empty. We return `[]`.
  Everywhere would return `PixelRect.Empty` (L167 falls back to 0).
- **Mirrored displays.** Each mirror surfaces as a separate
  `NSScreen`, sharing the same `NSScreenNumber`. We do not
  de-duplicate — matches Everywhere, which does not either.
- **Negative Quartz Y.** When a secondary display sits *above* the
  primary in the Cocoa arrangement, the flipped `quartzFrame.origin.y`
  is negative. This is correct and mirrors Everywhere. Tests must
  not assert `origin.y >= 0`.

## Public API

```swift
public enum ScreenListCapture {
    public static func enumerateAll() -> [ScreenInfo]
}
```

Front of the returned array is the primary screen (`NSScreen.screens[0]`
= `index == 0` = `isPrimary == true`). Subsequent entries follow
AppKit's iteration order over `NSScreen.screens`.

## Deviations from source

1. **Fractional coordinates.** Everywhere truncates to `int`
   (`(int)frame.X`). We keep `CGFloat` to preserve half-pixel origins
   on Retina layouts. The truncation was cosmetic in Everywhere — the
   surrounding code all consumes `PixelRect` which is int-only. Our
   `CGRect` type is float-native.
2. **Eager `index` / `isPrimary`.** Precomputed rather than derived
   on demand.
3. **`visibleFrameQuartz`.** Not present in Everywhere. Router needs
   the menu-bar/dock-clearance rect to place OpenClicky's HUD panels;
   we surface it here so callers do not re-flip in every consumer.
4. **`backingScaleFactor`.** Not read by Everywhere on this element
   (it lives on `SnapshotRenderer`). We carry it because MultiDisplay
   captures on the Screenshot path need scale to compute pixel dims.

Every added field is a pure function of the underlying `NSScreen`; no
new AppKit API surface is used.

## Test plan

Headless-safe (skips when `NSScreen.screens` is empty):

- `enumerateAll` returns non-empty when a WindowServer session is
  attached.
- `screens[0].isPrimary == true`, `index == 0`.
- All entries have `displayID != 0`, positive `frameQuartz.width` /
  `.height`, `backingScaleFactor > 0`.
- `frameQuartz` and `frameCocoa` round-trip via the primary height:
  `quartz.y == primaryCocoaHeight - (cocoa.y + cocoa.height)`.
- Multi-display: `displayID` unique across all entries; index scan
  matches `NSScreen.screens` order.
- JSON round-trip on `ScreenInfo`.
