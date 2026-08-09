// Ported from Everywhere: src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mac/Interop/AXAttributeConstants.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mac/Interop/NSScreenVisualElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Resolves the "focused window" for a given process via the macOS
// Accessibility API. Everywhere does not have a dedicated
// `MacFocusedWindowReader` file; the concept is derived by composing:
//
//   1. `AXUIElement.FreshFocusedWindowOf(int pid)` — the two-step
//      `AXFocusedWindow -> AXMainWindow` resolution
//      (`AXUIElement.cs:1153-1176`).
//   2. `AXUIElement.Name` — the title cascade
//      (`AXUIElement.cs:257-283`), narrowed here to the window-relevant
//      subset (AXTitle -> AXDescription -> AXHelp).
//   3. `AXUIElement.BoundingRectangle` — AXPosition + AXSize unwrap
//      via AXValueGetValue (`AXUIElement.cs:430-465`).
//   4. `AXMinimized` / `AXMain` bool attributes
//      (`AXAttributeConstants.cs:81-82`).
//   5. `NSScreenVisualElement.Children` — the Cocoa-to-Quartz Y-flip
//      (`NSScreenVisualElement.cs:57-67`) used to intersect a window
//      rect against each `NSScreen.frame`.
//
// The result is bundled into `FocusedWindowInfo` (see
// `Types/CaptureTypes.swift`). Everywhere itself never materialises this
// tuple — its `SnapshotRenderer.cs:34` just prints
// `Window: "<title>", App: <name>`. openclicky needs the fields
// individually so router / stash callers can consume geometry and
// display membership without a second AX round-trip.
//
// Nil semantics (all matching Everywhere's guard chain):
//   * `processId <= 0`                              -> nil
//   * app AX element unreachable (perm denied / bad pid) -> nil
//   * both AXFocusedWindow and AXMainWindow miss    -> nil
//
// No AppleScript. No SPI. `swift test`-safe on machines that lack
// Accessibility consent — the AX calls just return `.apiDisabled` and
// the wrapper surfaces that as nil.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Reads the focused window of an AX-consented process via
/// `AXUIElementCreateApplication(pid) -> AXFocusedWindow`, with the
/// documented `AXMainWindow` fallback.
///
/// Matches `AXUIElement.FreshFocusedWindowOf(int pid)` in Everywhere
/// (`AXUIElement.cs:1153-1176`) for the element resolution step; the
/// field extraction (title / frame / display / minimised / main) mirrors
/// the individual attribute reads Everywhere performs on the resulting
/// ref elsewhere in the same file.
public enum FocusedWindowCapture {

    // MARK: AX attribute names

    /// `kAXFocusedWindowAttribute` — first-choice attribute in
    /// `FreshFocusedWindowOf` (`AXUIElement.cs:1166`).
    private static let attrFocusedWindow: CFString = "AXFocusedWindow" as CFString

    /// `kAXMainWindowAttribute` — fallback used when `AXFocusedWindow`
    /// is absent (`AXUIElement.cs:1171-1173`).
    private static let attrMainWindow: CFString = "AXMainWindow" as CFString

    /// Name cascade — `AXTitle -> AXDescription -> AXHelp`
    /// (`AXUIElement.cs:268-273`). The subsequent branches from the C#
    /// `Name` getter (`AXValue` for label-bearing roles, `AXTitleUIElement`,
    /// `AXIdentifier`, first `AXStaticText` child) are dropped because
    /// AXWindow never advertises a label-bearing role.
    private static let attrTitle: CFString = "AXTitle" as CFString
    private static let attrDescription: CFString = "AXDescription" as CFString
    private static let attrHelp: CFString = "AXHelp" as CFString

    /// Geometry attributes — 1:1 with
    /// `AXUIElement.QueryBoundingRectangle` (`AXUIElement.cs:452-459`).
    private static let attrPosition: CFString = "AXPosition" as CFString
    private static let attrSize: CFString = "AXSize" as CFString

    /// Bool traits declared in `AXAttributeConstants.cs:81-82`.
    private static let attrMinimized: CFString = "AXMinimized" as CFString
    private static let attrMain: CFString = "AXMain" as CFString

    // MARK: Public API

    /// Resolves the focused window of `processId` and returns its
    /// title, frame, display membership, and minimised/main state.
    ///
    /// Returns `nil` when the pid is invalid, the app AX element cannot
    /// be created, or neither `AXFocusedWindow` nor `AXMainWindow`
    /// yield a window. Matches the guard + two-step lookup in
    /// `FreshFocusedWindowOf`.
    ///
    /// Contract preservation vs Everywhere:
    ///   * `pid <= 0` -> `nil` (mirrors `AXUIElement.cs:1163`).
    ///   * `AXFocusedWindow` miss -> retry with `AXMainWindow`
    ///     (mirrors `AXUIElement.cs:1167-1174`).
    ///   * Both miss -> `nil`.
    public static func capture(processId: Int32) -> FocusedWindowInfo? {
        guard processId > 0 else { return nil }

        AXQuirksInstaller.ensureAXBootstrap()

        let app = AXUIElementCreateApplication(processId)

        guard let window = resolveWindow(app: app) else {
            CaptureLog.log(
                "openclicky.ax.focused_window_miss",
                direction: "error",
                ["pid": "\(processId)"]
            )
            return nil
        }

        let title = readTitle(from: window)
        let frame = readFrame(from: window)
        let isMinimized = readBool(from: window, attribute: attrMinimized)
        let isMainWindow = readBool(from: window, attribute: attrMain)
        let displayIndex = frame == .zero ? nil : displayIndex(for: frame)

        CaptureLog.log(
            "openclicky.ax.focused_window",
            [
                "pid": "\(processId)",
                "has_title": title == nil ? "false" : "true",
                "frame_x": "\(Int(frame.origin.x))",
                "frame_y": "\(Int(frame.origin.y))",
                "frame_w": "\(Int(frame.size.width))",
                "frame_h": "\(Int(frame.size.height))",
                "display_index": displayIndex.map(String.init) ?? "",
                "minimized": isMinimized ? "true" : "false",
                "main": isMainWindow ? "true" : "false"
            ]
        )

        return FocusedWindowInfo(
            processId: processId,
            title: title,
            frame: frame,
            displayIndex: displayIndex,
            isMinimized: isMinimized,
            isMainWindow: isMainWindow
        )
    }

    // MARK: AX resolution

    /// Two-step lookup mirroring `AXUIElement.FreshFocusedWindowOf`
    /// (`AXUIElement.cs:1161-1176`):
    /// 1. Read `AXFocusedWindow` on the app element.
    /// 2. If missing, read `AXMainWindow` as fallback (comment L1169:
    ///    "Some apps don't have a focused window after launch.").
    private static func resolveWindow(app: AXUIElement) -> AXUIElement? {
        if let focused = copyElementAttribute(app, attrFocusedWindow) {
            return focused
        }
        return copyElementAttribute(app, attrMainWindow)
    }

    /// Reads an AX attribute that is expected to be another
    /// `AXUIElement` (a window ref, in our case).
    ///
    /// Same shape as `BrowserURLCapture.copyElementAttribute`, kept
    /// local so the two files stay independent (no cross-file
    /// coupling — matches Everywhere's per-file layout of `AXUIElement`
    /// vs `MacBrowserUrlReader`).
    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    // MARK: Field extraction

    /// Title cascade for a window ref. AXWindow's `Name` in
    /// `AXUIElement.cs:257-283` only reaches AXTitle / AXDescription /
    /// AXHelp before it would hit the `IsLabelBearingRole` gate — for
    /// AXWindow that gate is always false, so the port stops there.
    ///
    /// Non-empty guard (`!isEmpty` after trimming) matches
    /// `string.IsNullOrWhiteSpace` in the C# original.
    private static func readTitle(from element: AXUIElement) -> String? {
        for attr in [attrTitle, attrDescription, attrHelp] {
            if let s = readString(from: element, attribute: attr),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    /// Read a string-typed AX attribute. Returns nil on any non-success
    /// status, non-string CFType, or empty CFStringRef.
    private static func readString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    /// Read a bool-typed AX attribute. Missing/unreadable -> `false`.
    /// Matches Everywhere's implicit behaviour: any absent bool
    /// attribute is treated as `false` throughout `AXUIElement.cs`.
    private static func readBool(from element: AXUIElement, attribute: CFString) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else { return false }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    /// Read `AXPosition` + `AXSize` and combine into a Quartz-top-left
    /// `CGRect`. 1:1 with `AXUIElement.QueryBoundingRectangle`
    /// (`AXUIElement.cs:448-465`): if either attribute is missing OR
    /// AXValue unwrap fails, return `.zero` (matches `return default;`).
    private static func readFrame(from element: AXUIElement) -> CGRect {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(element, attrPosition, &posValue)
        let sizeErr = AXUIElementCopyAttributeValue(element, attrSize, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let posRaw = posValue, let sizeRaw = sizeValue,
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return .zero
        }
        // Casting CFTypeRef -> AXValue is safe after the CFTypeID guard.
        let posAXValue = posRaw as! AXValue
        let sizeAXValue = sizeRaw as! AXValue
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAXValue, .cgPoint, &origin),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return .zero
        }
        return CGRect(origin: origin, size: size)
    }

    // MARK: Display membership

    /// Compute which `NSScreen.screens` index the window sits on.
    ///
    /// Matches `NSScreenVisualElement.Children`
    /// (`NSScreenVisualElement.cs:22-45`) which intersects each
    /// screen's Quartz-flipped frame against a candidate window rect.
    /// The flip in `NSScreenVisualElement.cs:57-67`:
    ///     y = primaryFrame.Height - (frame.Y + frame.Height)
    /// converts Cocoa bottom-left origin -> Quartz top-left, which is
    /// the same space `AXPosition` returns for windows.
    ///
    /// Returns `nil` when there are no screens OR no screen's rect has
    /// a positive-area intersection with `windowFrame`. The largest
    /// intersection wins in the multi-display overlap case.
    private static func displayIndex(for windowFrame: CGRect) -> Int? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // Primary screen height is the reference for the Cocoa -> Quartz
        // Y-flip. `NSScreen.screens[0]` is the primary display in AppKit.
        let primaryHeight = screens[0].frame.height

        var bestIndex: Int? = nil
        var bestArea: CGFloat = 0

        for (index, screen) in screens.enumerated() {
            let cocoaFrame = screen.frame
            let quartzFrame = CGRect(
                x: cocoaFrame.origin.x,
                y: primaryHeight - (cocoaFrame.origin.y + cocoaFrame.height),
                width: cocoaFrame.width,
                height: cocoaFrame.height
            )
            let intersection = quartzFrame.intersection(windowFrame)
            if intersection.isNull || intersection.isEmpty { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }
}
