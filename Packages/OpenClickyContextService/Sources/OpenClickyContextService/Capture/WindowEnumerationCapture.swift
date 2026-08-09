// Ported from Everywhere: src/Everywhere.Mac/Interop/WindowHelper.cs @30e03e9d + SkyLightInterop.cs
//
// Enumerates macOS windows via CoreGraphics. Mirrors the payload
// Everywhere pulls off `CGWindowListCopyWindowInfo` in two places:
//
//   1. `WindowHelper.RaiseOverlayAboveTarget` (WindowHelper.cs:272-292)
//      -- reads `kCGWindowOwnerPID`, `kCGWindowNumber`,
//      `kCGWindowLayer` off each dict; documents "CGWindowList
//      returns front-to-back order" (L291).
//   2. `ScreenSelectionSession.GetWindowOwnerPidsAtLocation`
//      (ScreenSelectionSession.cs:401-446) -- reads pid + bounds
//      dict `{X, Y, Width, Height}` for hit-testing.
//
// Everywhere's own `SkyLightInterop.cs` contains only capture APIs
// (`CGSCaptureWindowsContentsToRectWithOptions`,
// `CGSHWCaptureWindowList`) -- despite what
// `docs/ROADMAP/10_OVERLAP_ANALYSIS.md` row 242 asserts, there is no
// `SLSGetActiveSpace` / `SLSCopyWindowsWithOptions` call to port.
// This file therefore uses CoreGraphics only; no `@_silgen_name`
// SkyLight bindings.
//
// The wider payload (title / ownerName / bounds / isOnScreen /
// alpha) is materialised eagerly because downstream tools (intent
// classifier, task router) would otherwise re-issue the same
// CoreGraphics call. `screenIndex` uses the same Cocoa->Quartz
// Y-flip math as `FocusedWindowCapture.displayIndex(for:)`.

import AppKit
import CoreGraphics
import Foundation

/// Options controlling `WindowEnumerationCapture.enumerateAll`.
///
/// Field defaults reproduce
/// `WindowHelper.cs:272-274`:
/// `CGWindowListOption.OnScreenOnly | .ExcludeDesktopElements`
/// with `relativeToWindow: 0`. That is Everywhere's canonical
/// "enumerate real user windows above the wallpaper" call and is
/// what openclicky wants for its default `enumerateAll()`.
public struct EnumerateOptions: Sendable, Equatable {

    /// Mirrors `CGWindowListOption.OnScreenOnly`
    /// (`WindowHelper.cs:273`). When `true`, only windows currently
    /// mapped to a display are returned.
    public let onScreenOnly: Bool

    /// Mirrors `CGWindowListOption.ExcludeDesktopElements`
    /// (`WindowHelper.cs:273`). When `true`, drops the desktop
    /// wallpaper element, Dock, and other kCGDesktopWindowLevel
    /// entries.
    public let excludeDesktopElements: Bool

    /// Passthrough for the `relativeToWindow` argument of
    /// `CGWindowListCopyWindowInfo`. `0` means "no anchor / whole
    /// list" -- what both Everywhere call sites use.
    public let relativeToWindow: CGWindowID

    public init(
        onScreenOnly: Bool = true,
        excludeDesktopElements: Bool = true,
        relativeToWindow: CGWindowID = 0
    ) {
        self.onScreenOnly = onScreenOnly
        self.excludeDesktopElements = excludeDesktopElements
        self.relativeToWindow = relativeToWindow
    }

    /// 1:1 with `WindowHelper.cs:272-274`.
    public static let `default` = EnumerateOptions()
}

/// CoreGraphics-backed window enumerator.
public enum WindowEnumerationCapture {

    // MARK: - Public API

    /// Returns every window matching `options`, front-to-back
    /// (CoreGraphics-native order; not re-sorted).
    ///
    /// Returns `[]` on any of:
    ///   * `CGWindowListCopyWindowInfo` returns `nil` (headless
    ///     session / WindowServer unavailable).
    ///   * The array bridges to something other than `[[String: Any]]`.
    ///   * Every dict is missing pid or wid (shouldn't happen in
    ///     practice; matches Everywhere's `continue` on the missing
    ///     key path, `WindowHelper.cs:287-288`).
    ///
    /// Never throws / crashes; safe to call from headless test hosts.
    public static func enumerateAll(options: EnumerateOptions = .default) -> [EnumeratedWindow] {
        let cgOption = buildOptionMask(options)
        guard let raw = CGWindowListCopyWindowInfo(cgOption, options.relativeToWindow) else {
            CaptureLog.log(
                "openclicky.windowlist.copy_window_info_nil",
                direction: "error"
            )
            return []
        }
        // `as? [[String: Any]]` bridges CFArray-of-CFDictionary to
        // Swift; kCGWindow* string constants come back as native
        // `String` keys.
        guard let dicts = raw as NSArray? as? [[String: Any]] else {
            CaptureLog.log(
                "openclicky.windowlist.bridge_failed",
                direction: "error"
            )
            return []
        }

        // Precompute screen union so we don't recompute per window.
        let screenFrames = quartzScreenFrames()

        var out: [EnumeratedWindow] = []
        out.reserveCapacity(dicts.count)

        for dict in dicts {
            guard let entry = decode(
                dict: dict,
                onScreenAssumed: options.onScreenOnly,
                screenFrames: screenFrames
            ) else { continue }
            out.append(entry)
        }
        CaptureLog.log(
            "openclicky.windowlist.enumerated",
            [
                "raw_count": "\(dicts.count)",
                "kept_count": "\(out.count)",
                "on_screen_only": options.onScreenOnly ? "true" : "false",
                "exclude_desktop": options.excludeDesktopElements ? "true" : "false"
            ]
        )
        return out
    }

    // MARK: - Option mask

    /// Builds the `CGWindowListOption` bitmask from the sugar in
    /// `EnumerateOptions`. Matches the `|` composition in
    /// `WindowHelper.cs:272-274`.
    private static func buildOptionMask(_ options: EnumerateOptions) -> CGWindowListOption {
        var mask: CGWindowListOption = []
        if options.onScreenOnly {
            mask.insert(.optionOnScreenOnly)
        } else {
            mask.insert(.optionAll)
        }
        if options.excludeDesktopElements {
            mask.insert(.excludeDesktopElements)
        }
        return mask
    }

    // MARK: - Per-window decode

    /// Extracts one `EnumeratedWindow` from a CG dict. Returns `nil`
    /// when required keys (pid, wid) are missing -- matches
    /// `WindowHelper.cs:287-288` `continue`.
    private static func decode(
        dict: [String: Any],
        onScreenAssumed: Bool,
        screenFrames: [CGRect]
    ) -> EnumeratedWindow? {
        // Required: pid (kCGWindowOwnerPID).
        // `NSNumber.Int32Value` in C# tolerates NSNumbers of any
        // underlying width; on Swift we bridge to `Int32` via
        // `NSNumber` intermediary.
        guard let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber else {
            return nil
        }
        let pid = pidNum.int32Value

        // Required: wid (kCGWindowNumber).
        guard let widNum = dict[kCGWindowNumber as String] as? NSNumber else {
            return nil
        }
        let wid = widNum.uint32Value

        // Optional: title.
        let title = (dict[kCGWindowName as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        // Optional: owner name.
        let ownerName = (dict[kCGWindowOwnerName as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        // Optional: bounds. CG delivers the dict-representation of
        // `CGRect`, which `CGRect(dictionaryRepresentation:)`
        // decodes 1:1. Missing / malformed -> `.zero` (matches
        // Everywhere's implicit "skip entry with missing bounds"
        // relaxed to "keep entry, empty rect" because pid+wid are
        // the load-bearing fields elsewhere).
        var bounds: CGRect = .zero
        if let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary {
            if let decoded = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                bounds = decoded
            }
        }

        // On-screen. CG only emits this key when
        // `.optionOnScreenOnly` was NOT set (in on-screen-only mode
        // every entry is on-screen by definition). Default to the
        // caller's assumption.
        let isOnScreen: Bool = {
            if let n = dict[kCGWindowIsOnscreen as String] as? NSNumber {
                return n.boolValue
            }
            return onScreenAssumed
        }()

        // Layer (`WindowHelper.cs:290`).
        let layer: Int = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

        // Alpha.
        let alpha: Double = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0

        // Screen index (largest intersection). `nil` when no screen
        // intersects or when we have zero screens.
        let screenIndex: Int? = bounds == .zero
            ? nil
            : largestIntersectionIndex(bounds, screenFrames)

        return EnumeratedWindow(
            pid: pid,
            wid: wid,
            title: title,
            ownerName: ownerName,
            bounds: bounds,
            screenIndex: screenIndex,
            isOnScreen: isOnScreen,
            layer: layer,
            alpha: alpha
        )
    }

    // MARK: - Screen membership

    /// Snapshot of every `NSScreen.screens` frame flipped into Quartz
    /// coords (top-left origin, same space as `kCGWindowBounds`).
    ///
    /// Uses the same math as
    /// `FocusedWindowCapture.displayIndex(for:)`:
    /// `y = primary.height - (frame.origin.y + frame.height)`.
    private static func quartzScreenFrames() -> [CGRect] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.map { screen in
            let cocoa = screen.frame
            return CGRect(
                x: cocoa.origin.x,
                y: primaryHeight - (cocoa.origin.y + cocoa.height),
                width: cocoa.width,
                height: cocoa.height
            )
        }
    }

    /// Returns the index into `frames` with the largest positive-area
    /// intersection with `rect`, or `nil` when none intersects.
    private static func largestIntersectionIndex(_ rect: CGRect, _ frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, frame) in frames.enumerated() {
            let inter = frame.intersection(rect)
            if inter.isNull || inter.isEmpty { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }
}
