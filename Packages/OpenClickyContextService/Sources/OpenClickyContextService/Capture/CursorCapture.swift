// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Cursor position capture. 1:1 port of the Cocoa->Quartz coordinate
// conversion Everywhere performs inside `VisualElementContext.
// ElementFromPointer` (`VisualElementContext.cs:48-67`).
//
// Everywhere pipes the point straight into `AXUIElementCopyElementAtPosition`
// and never surfaces the raw coord upward. openclicky exposes the two halves
// separately (cursor point here; hit-test in `ElementUnderCursorCapture.swift`)
// so the roadmap's "CursorPosition" and "ElementAtPoint" abilities can be
// requested and cached independently.
//
// Coordinate contract:
//   - `NSEvent.mouseLocation` is Cocoa (bottom-left origin, primary screen).
//   - We flip via `primary.frame.height - mouseLocation.y` to yield **global
//     Quartz** coords (top-left origin). This matches the point AX expects
//     and the space `AXPosition`/`AXSize` operate in for windows and elements.
//   - Multi-display: negative x/y is legal for a cursor on a display to the
//     left of / above the primary. We do not clamp.
//
// Nil / error paths:
//   - No screens (`NSScreen.screens.isEmpty`, headless): still emit a point
//     using `NSEvent.mouseLocation` verbatim and `displayIndex = -1`.
//     Everywhere's null-return path (`if (screen is null) return null;`) is
//     unreachable per its own NRT contract; we choose "always emit" so the
//     caller can distinguish "no cursor" (nil struct) from "no display map"
//     (displayIndex == -1).

import Foundation
import AppKit
import CoreGraphics

/// Reads the current global cursor position and reports which screen it
/// sits on.
///
/// Mirrors Everywhere's `VisualElementContext.ElementFromPointer`
/// (`VisualElementContext.cs:48-67`) — but stops at the coordinate.
/// The AX hit-test half lives in `ElementUnderCursorCapture`.
public enum CursorCapture {

    // MARK: Public API

    /// Snapshot the cursor position in **global Quartz** coordinates.
    ///
    /// Returns `nil` only in the currently unreachable case where AppKit
    /// fails to report a mouse location (would require the shared
    /// `NSApplication` not to be initialised). All other cases — off
    /// every screen, negative coords, headless — return a valid struct.
    public static func capture() -> CursorPosition? {
        // `NSEvent.mouseLocation` is Cocoa: origin is bottom-left of the
        // *primary* display. Documented at
        // https://developer.apple.com/documentation/appkit/nsevent/1533063-mouselocation
        let cocoaPoint = NSEvent.mouseLocation

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            // Headless / no display: pass through raw Cocoa coords and mark
            // display as unknown. Downstream code can still write a snapshot.
            return CursorPosition(
                point: cocoaPoint,
                displayIndex: -1,
                capturedAtUnix: Date().timeIntervalSince1970
            )
        }

        // Cocoa -> Quartz global flip. `NSScreen.screens[0]` is the primary
        // display in AppKit. Everywhere uses the same anchor for its
        // `screen.Frame.Height - (mouseLocation.Y - screen.Frame.Y)` flip
        // (`VisualElementContext.cs:61`).
        let primary = screens[0]
        let quartzPoint = CGPoint(
            x: cocoaPoint.x,
            y: primary.frame.height - cocoaPoint.y
        )

        let displayIdx = displayIndex(for: quartzPoint, screens: screens) ?? -1

        CaptureLog.log(
            "openclicky.cursor.capture",
            [
                "x": "\(Int(quartzPoint.x))",
                "y": "\(Int(quartzPoint.y))",
                "display_index": "\(displayIdx)"
            ]
        )

        return CursorPosition(
            point: quartzPoint,
            displayIndex: displayIdx,
            capturedAtUnix: Date().timeIntervalSince1970
        )
    }

    // MARK: Multi-display resolution

    /// Which `NSScreen.screens` index contains `quartzPoint`.
    ///
    /// Same shape as `FocusedWindowCapture.displayIndex(for:)` (kept local
    /// per Everywhere's per-file layout — see `NSScreenVisualElement.cs:57-67`
    /// for the flip). Returns nil when the point is off every display.
    private static func displayIndex(for quartzPoint: CGPoint,
                                     screens: [NSScreen]) -> Int? {
        // Primary height for Cocoa -> Quartz flip of each screen frame.
        let primaryHeight = screens[0].frame.height

        for (index, screen) in screens.enumerated() {
            let cocoaFrame = screen.frame
            let quartzFrame = CGRect(
                x: cocoaFrame.origin.x,
                y: primaryHeight - (cocoaFrame.origin.y + cocoaFrame.height),
                width: cocoaFrame.width,
                height: cocoaFrame.height
            )
            if quartzFrame.contains(quartzPoint) {
                return index
            }
        }
        return nil
    }
}
