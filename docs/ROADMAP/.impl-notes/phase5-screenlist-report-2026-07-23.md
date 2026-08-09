# Phase 5 — ScreenListCapture port report (2026-07-23)

## Deliverables

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ScreenListCapture.swift`
  (new, 157 lines).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/ScreenListCaptureTests.swift`
  (new, 205 lines).
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  appended: `ScreenInfo` value type (~100 lines added, existing types untouched).
- `docs/ROADMAP/.impl-notes/phase5-screenlist-2026-07-23.md` (investigation notes).

## Source alignment

Ported from `src/Everywhere.Mac/Interop/NSScreenVisualElement.cs`
@30e03e9dcfdd4247fd679828ed86e9042f32d809.

- Header pin present on both new files.
- Y-flip byte-exact with C# L62-64:
  `quartz.y = primary.height - (cocoa.y + cocoa.height)`.
  Everywhere truncates to `int`; the port keeps `CGFloat` to preserve
  Retina fractional origins. This is a superset-of-precision deviation
  documented inline in `ScreenListCapture.swift` and in the impl-notes.
- `displayID` sourced from `deviceDescription[NSScreenNumber]` matching
  `GetScreenNumber` at L165-168. Kept as native `UInt32` (Everywhere
  widens to `int32Value`; unsigned matches `CGDirectDisplayID`).
- `name` sourced from `NSScreen.localizedName` matching L51.
  Trimmed-empty coerced to `nil` (defensive; Everywhere returns raw
  string but `LocalizedName` is guaranteed non-empty on physical
  displays only).
- `frameQuartz` / `frameCocoa` extract order matches
  `BoundingRectangle` at L53-68.
- Enumeration order matches `NSScreen.screens`, same array
  `ScreenSiblingAccessor.EnsureResources` iterates (L175-180).
- Additions (`index`, `isPrimary`, `visibleFrameQuartz`,
  `backingScaleFactor`) documented in impl-notes and in-file. All are
  pure functions of `NSScreen` state — no new AppKit surface.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 15
("ScreenList + MultiDisplay") tags the file as
`Capture/ScreenListCapture.swift`, P1 — matches the delivered path.

## Test results

`swift test` (Packages/OpenClickyContextService):
```
Executed 282 tests, with 5 tests skipped and 0 failures (0 unexpected) in 12.363 seconds
```
- ScreenListCaptureTests: 10 tests total. 9 passed, 1 skipped
  (`test_enumerateAll_displayIDsAreUnique` — requires >= 2 displays).
- No regressions across sibling capture suites.

`bash scripts/sign-and-install.sh`:
```
[1/5] xcodebuild -> BUILD SUCCEEDED
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open  openclicky pid=... identifier=com.jkneen.openclicky
[5/5] done.
```

Both gates pass.

## Test coverage (headless-safe)

- `enumerateAll` never throws.
- Guarded by `NSScreen.screens.isEmpty` skip (matches
  `WindowEnumerationCaptureTests` pattern) so CI / ssh runs stay green.
- Primary screen invariants: `screens[0].isPrimary`, `index == 0`,
  `frameQuartz.origin == (0,0)`.
- Field invariants: `displayID != 0`, positive frame dimensions,
  finite frame scalars, `backingScaleFactor > 0`,
  `visibleFrame <= frame`.
- Y-flip round-trip: `cocoa.y == primaryCocoaHeight - (quartz.y + quartz.height)`.
- Multi-display: displayID uniqueness (skipped on single-display; mirror
  case detected + allowed).
- Wire shape: JSON round-trip for populated, fractional-geometry, and
  nil-name variants.

## Files touched

Additions only. No other capture file modified. Bridge / config
template / stash writer untouched.
