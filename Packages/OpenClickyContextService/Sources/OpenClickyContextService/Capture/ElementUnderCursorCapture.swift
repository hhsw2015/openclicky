// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
// src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
// src/Everywhere.Mac/Interop/AXAttributeConstants.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// AX hit-test under a given screen point. 1:1 port of Everywhere's
// `VisualElementContext.ElementFromPoint` (Element mode) chain:
//
//   AXUIElement.SystemWide.ElementAtPosition(point.X, point.Y)
//     -> AXUIElementCopyElementAtPosition(sysHandle, x, y, out elem)
//        (see `AXUIElement.cs:1135-1139` + `AXUIElement.cs:1315-1316`).
//
// Fields on the returned element are pulled with the same attribute
// names Everywhere's `AXAttributeConstants` defines
// (`AXAttributeConstants.cs:8,9,13,15,16,17`). Extraction order matches
// the getters used across `AXUIElement.cs`:
//   1. pid    - `AXUIElementGetPid`               (`AXUIElement.cs:467`)
//   2. role   - `AXRole`                          (`AXAttributeConstants.cs:8`)
//   3. subrole- `AXSubrole`                       (`AXAttributeConstants.cs:9`)
//   4. title  - `AXTitle`                         (`AXAttributeConstants.cs:13`)
//   5. value  - `AXValue`                         (`AXAttributeConstants.cs:15`)
//   6. bounds - `AXPosition` + `AXSize`           (`AXUIElement.cs:452-459`)
//
// Title cascade note: Everywhere's `Name` getter walks
// AXTitle -> AXDescription -> AXHelp -> role-gated AXValue -> ...
// (`AXUIElement.cs:257-283`). On the hit-test path Everywhere never
// invokes the full cascade — the point-hit element is consumed by
// screen selection UI which reads `Role`/`BoundingRectangle` directly.
// The port therefore reads AXTitle only. Fuller name extraction lives
// in `FocusedWindowCapture.readTitle` (which needs AXWindow-shaped
// fallbacks).
//
// Coordinate contract: caller passes a **global Quartz** point (top-left
// origin), the same space `CursorCapture` emits. Everywhere hands this
// to AX verbatim — see `VisualElementContext.cs:24` and the CGFloat
// signature of `CopyElementAtPosition`.
//
// Nil / error paths (all map to `nil`, matching `element != 0` guard in
// `AXUIElement.cs:1138`):
//   - `AXUIElementCopyElementAtPosition` returns `.apiDisabled` (no AX
//     consent for host).
//   - `.cannotComplete` for off-screen / bogus coordinates on some
//     macOS builds.
//   - `.success` with a zero element handle (older macOS behaviour).
//
// The wrapper never throws.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// AX hit-test at a screen point. Wraps
/// `AXUIElementCopyElementAtPosition(systemWide, x, y, &elem)` and
/// harvests the same attribute fan-out Everywhere reads elsewhere
/// (`role/subrole/title/value/bounds/pid`).
public enum ElementUnderCursorCapture {

    // MARK: AX attribute names
    //
    // 1:1 copies of `AXAttributeConstants.cs`. Kept local — matches
    // Everywhere's per-file layout where each interop file redeclares
    // the handful of constants it needs.

    /// `AXAttributeConstants.Role` -> `"AXRole"` (`AXAttributeConstants.cs:8`).
    private static let attrRole: CFString = "AXRole" as CFString

    /// `AXAttributeConstants.Subrole` -> `"AXSubrole"` (`AXAttributeConstants.cs:9`).
    private static let attrSubrole: CFString = "AXSubrole" as CFString

    /// `AXAttributeConstants.Title` -> `"AXTitle"` (`AXAttributeConstants.cs:13`).
    private static let attrTitle: CFString = "AXTitle" as CFString

    /// `AXAttributeConstants.Value` -> `"AXValue"` (`AXAttributeConstants.cs:15`).
    private static let attrValue: CFString = "AXValue" as CFString

    /// Geometry attributes — 1:1 with `QueryBoundingRectangle`
    /// (`AXUIElement.cs:452-459`).
    private static let attrPosition: CFString = "AXPosition" as CFString
    private static let attrSize: CFString = "AXSize" as CFString

    // MARK: Public API

    /// Hit-test at `point` (global Quartz). When `point` is nil, calls
    /// `CursorCapture.capture()` internally — matching Everywhere's
    /// `ElementFromPointer` convenience overload
    /// (`VisualElementContext.cs:48-67`).
    ///
    /// Returns `nil` when the systemwide AX handle rejects the point
    /// (no consent, off-screen on some builds, or empty element ref).
    public static func capture(at point: CGPoint? = nil) -> ElementUnderCursorInfo? {
        // Bootstrap the SystemWide messaging timeout on first touch — F02
        // fix. This is the entry from the hotkey path (element_under_cursor);
        // FocusedElementCapture also bootstraps but calls are pid-scoped,
        // so hit-tests can precede any pid work.
        AXQuirksInstaller.ensureAXBootstrap()

        let hitPoint: CGPoint
        if let p = point {
            hitPoint = p
        } else {
            guard let cursor = CursorCapture.capture() else {
                CaptureLog.log("openclicky.ax.element_at_pos_no_cursor",
                               direction: "error")
                return nil
            }
            hitPoint = cursor.point
        }

        // `AXUIElementCreateSystemWide` = "SystemWide element". Everywhere
        // caches this as a static (`AXUIElement.cs:1133`). We do the same
        // via a lazy static below.
        var element: AXUIElement?
        let axErr = AXUIElementCopyElementAtPosition(systemWide,
                                                     Float(hitPoint.x),
                                                     Float(hitPoint.y),
                                                     &element)
        guard axErr == .success, let hit = element else {
            CaptureLog.log(
                "openclicky.ax.element_at_pos",
                direction: "error",
                [
                    "cursor_x": "\(Int(hitPoint.x))",
                    "cursor_y": "\(Int(hitPoint.y))",
                    "ax_error": "\(axErr.rawValue)"
                ]
            )
            return nil
        }

        // Field extraction. Order matches the C# getters listed in the
        // header comment. `hit` is the AXUIElement guaranteed non-nil.
        let pid = readPid(from: hit)
        let role = readString(from: hit, attribute: attrRole)
        let subrole = readString(from: hit, attribute: attrSubrole)
        let title = readString(from: hit, attribute: attrTitle)
        let value = readValueString(from: hit)
        let bounds = readBounds(from: hit)
        let bundleId = pid > 0
            ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            : nil

        CaptureLog.log(
            "openclicky.ax.element_at_pos",
            [
                "cursor_x": "\(Int(hitPoint.x))",
                "cursor_y": "\(Int(hitPoint.y))",
                "hit_pid": "\(pid)",
                "hit_role": role ?? "",
                "hit_subrole": subrole ?? "",
                "bounds_x": "\(Int(bounds.origin.x))",
                "bounds_y": "\(Int(bounds.origin.y))",
                "bounds_w": "\(Int(bounds.size.width))",
                "bounds_h": "\(Int(bounds.size.height))",
                "bundle_id": bundleId ?? ""
            ]
        )

        return ElementUnderCursorInfo(
            pid: pid,
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            bounds: bounds,
            bundleId: bundleId
        )
    }

    // MARK: SystemWide handle

    /// Lazy 1:1 of `AXUIElement.SystemWide` (`AXUIElement.cs:1133`).
    /// `AXUIElementCreateSystemWide` never fails on macOS but is not
    /// thread-safe to reallocate — cache it once.
    private static let systemWide: AXUIElement = AXUIElementCreateSystemWide()

    // MARK: AX plumbing

    /// 1:1 `AXUIElement.ElementAtPosition` (`AXUIElement.cs:1135-1139`).
    private static func copyElementAtPosition(_ app: AXUIElement,
                                              x: Float,
                                              y: Float) -> AXUIElement? {
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, x, y, &element)
        guard err == .success, let hit = element else { return nil }
        return hit
    }

    /// 1:1 `AXUIElement.ProcessId` (`AXUIElement.cs:467`).
    private static func readPid(from element: AXUIElement) -> Int32 {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(element, &pid)
        return err == .success ? pid : 0
    }

    /// Read a string-typed AX attribute. Nil on non-success / non-string.
    /// Same shape as `FocusedWindowCapture.readString`.
    private static func readString(from element: AXUIElement,
                                   attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    /// Read `AXValue` and coerce to string.
    ///
    /// Mirrors `AXUIElement.cs:281`:
    /// `var v = GetAttribute<NSObject>(AXAttributeConstants.Value)?.ToString()`.
    /// The AXValue can be a string (text fields), NSNumber (toggles/sliders),
    /// or an `AXValueRef` wrapper (rare on non-geometry attrs). We accept
    /// string + number; wrapper types return nil (Everywhere's `.ToString()`
    /// on an AXValueRef would emit a debug shape we don't want to leak).
    private static func readValueString(from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attrValue, &raw)
        guard err == .success, let value = raw else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return value as? String
        }
        if typeID == CFNumberGetTypeID() {
            return (value as? NSNumber)?.stringValue
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false"
        }
        return nil
    }

    /// Read `AXPosition` + `AXSize`, unwrap via `AXValueGetValue`, combine
    /// into a Quartz-top-left `CGRect`. 1:1 `QueryBoundingRectangle`
    /// (`AXUIElement.cs:448-465`) — either attribute missing OR unwrap
    /// failing returns `.zero` (matches C# `return default;`).
    private static func readBounds(from element: AXUIElement) -> CGRect {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(element, attrPosition, &posRaw)
        let sizeErr = AXUIElementCopyAttributeValue(element, attrSize, &sizeRaw)
        guard posErr == .success, sizeErr == .success,
              let posValue = posRaw, let sizeValue = sizeRaw,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return .zero
        }

        let posAXValue = posValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAXValue, .cgPoint, &point),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return .zero
        }
        return CGRect(origin: point, size: size)
    }
}
