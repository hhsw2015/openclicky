// Ported from Everywhere: src/Everywhere.Mac/Interop/NSScreenVisualElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Enumerates every attached macOS display and returns a Codable
// `ScreenInfo` tuple per screen. The port collapses Everywhere's
// per-instance `NSScreenVisualElement` + `ScreenSiblingAccessor`
// (L11-206 of the source) into a single stateless call: openclicky's
// consumers do not need the `IVisualElement` tree walk, only the
// snapshot of connected displays.
//
// Field extraction is 1:1 with the C# source:
//   * displayID          <- `deviceDescription[NSScreenNumber]`, matching
//                            `GetScreenNumber` (L165-168).
//   * name               <- `NSScreen.localizedName` (L51).
//   * frameCocoa         <- `NSScreen.frame` (bottom-left, L57).
//   * frameQuartz.y      <- `primaryFrame.Height - (frame.Y + frame.Height)`
//                            (L62-64 of the source). Byte-exact.
//   * visibleFrameQuartz <- `NSScreen.visibleFrame` under the same flip.
//   * backingScaleFactor <- `NSScreen.backingScaleFactor`.
//
// The y-flip formula is shared with `FocusedWindowCapture.displayIndex(for:)`
// and `WindowEnumerationCapture.quartzScreenFrames()`, ensuring the
// three surfaces agree on what "screen N in Quartz coords" means.
//
// Nil / empty semantics:
//   * headless / no WindowServer            -> `[]`
//   * dict missing `NSScreenNumber`         -> entry skipped
//   * whitespace-only `localizedName`       -> `name = nil`
//
// Everywhere makes no attempt to coalesce mirrored displays; neither
// do we. Each mirrored `NSScreen` yields its own `ScreenInfo`, sharing
// `displayID` with its peers (macOS reuses the same CGDirectDisplayID
// across mirrors).

import Foundation
import AppKit
import CoreGraphics

/// Snapshot enumerator for all attached macOS displays.
///
/// Public entry point: `enumerateAll()`. Order matches
/// `NSScreen.screens`, which by AppKit contract places the primary
/// (menu-bar) display at index 0 — the same invariant Everywhere
/// depends on when it takes `NSScreen.Screens[0].Frame` as the y-flip
/// reference (`NSScreenVisualElement.cs:62`).
public enum ScreenListCapture {

    // MARK: - Public API

    /// Returns one `ScreenInfo` per entry in `NSScreen.screens`.
    ///
    /// Guarantees on non-empty results:
    ///   * `[0].isPrimary == true`, `[0].index == 0` (matches AppKit's
    ///     `NSScreen.screens[0]` == primary invariant that Everywhere
    ///     relies on at `NSScreenVisualElement.cs:62`).
    ///   * `displayID` is non-zero for every entry (dicts missing
    ///     `NSScreenNumber` are skipped, matching the `?? 0` fallback in
    ///     Everywhere's `GetScreenNumber` collapsed to a defensive skip).
    ///   * `frameQuartz` uses the byte-exact y-flip from
    ///     `NSScreenVisualElement.cs:62-64`, in `CGFloat` precision
    ///     rather than the C# `int` truncation.
    ///
    /// Returns `[]` on a headless session (`NSScreen.screens` empty).
    /// Never throws.
    public static func enumerateAll() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }

        // Primary Cocoa height is the reference for the y-flip. See
        // `NSScreenVisualElement.cs:62`:
        //     var primaryFrame = NSScreen.Screens[0].Frame;
        let primaryHeight = primary.frame.height

        var out: [ScreenInfo] = []
        out.reserveCapacity(screens.count)

        for (index, screen) in screens.enumerated() {
            guard let entry = build(
                screen: screen,
                index: index,
                primaryHeight: primaryHeight
            ) else { continue }
            out.append(entry)
        }
        return out
    }

    // MARK: - Per-screen decode

    /// Reads every field off a single `NSScreen` and returns the
    /// resulting `ScreenInfo`. Returns `nil` when
    /// `deviceDescription[.screenNumber]` is missing or non-numeric
    /// — matches Everywhere's `?? 0` fallback in `GetScreenNumber`
    /// (`NSScreenVisualElement.cs:167`) collapsed to a skip so the
    /// caller never surfaces a zero-id entry.
    private static func build(
        screen: NSScreen,
        index: Int,
        primaryHeight: CGFloat
    ) -> ScreenInfo? {
        guard let displayID = screenNumber(of: screen), displayID != 0 else {
            return nil
        }

        let cocoaFrame = screen.frame
        let cocoaVisibleFrame = screen.visibleFrame

        // Byte-exact y-flip from `NSScreenVisualElement.cs:62-64`.
        // Kept in CGFloat rather than the C# `int` truncation to
        // preserve half-pixel origins on Retina layouts.
        let quartzFrame = CGRect(
            x: cocoaFrame.origin.x,
            y: primaryHeight - (cocoaFrame.origin.y + cocoaFrame.height),
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
        let visibleFrameQuartz = CGRect(
            x: cocoaVisibleFrame.origin.x,
            y: primaryHeight - (cocoaVisibleFrame.origin.y + cocoaVisibleFrame.height),
            width: cocoaVisibleFrame.width,
            height: cocoaVisibleFrame.height
        )

        let name = normalizedName(screen.localizedName)

        return ScreenInfo(
            displayID: displayID,
            index: index,
            name: name,
            frameQuartz: quartzFrame,
            frameCocoa: cocoaFrame,
            visibleFrameQuartz: visibleFrameQuartz,
            backingScaleFactor: screen.backingScaleFactor,
            isPrimary: index == 0
        )
    }

    // MARK: - Helpers

    /// Reads `deviceDescription[.screenNumber]` and coerces it to a
    /// `CGDirectDisplayID` (== `UInt32`).
    ///
    /// Matches Everywhere's `GetScreenNumber`
    /// (`NSScreenVisualElement.cs:165-168`):
    /// ```
    /// (screen.DeviceDescription["NSScreenNumber"] as NSNumber)?.Int32Value ?? 0
    /// ```
    /// The C# side widens to Int32 for its `PixelRect` id; we keep the
    /// native `UInt32` width because `CGDirectDisplayID` is unsigned.
    private static func screenNumber(of screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let raw = screen.deviceDescription[key] else { return nil }
        if let number = raw as? NSNumber {
            return number.uint32Value
        }
        return nil
    }

    /// Trims whitespace/newlines and returns `nil` when nothing is left.
    /// Matches the non-empty guard style used by
    /// `FocusedWindowCapture.readTitle` — Everywhere itself does not
    /// filter `LocalizedName`, but macOS occasionally reports an empty
    /// string on virtual bridges and headless mirrors.
    private static func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
