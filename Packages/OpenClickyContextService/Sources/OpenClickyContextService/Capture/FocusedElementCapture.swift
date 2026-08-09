// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs + src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Resolves the "focused UI element" for a given pid and harvests the
// Everywhere-parity attribute fan-out (role, subrole, name cascade,
// value with secure-field guard, help, description, placeholder, state
// flags, meaningful actions, Quartz bounds).
//
// Resolution algorithm:
//   1. Guard `pid > 0`.
//   2. `AXUIElementCreateApplication(pid)` -> app element.
//   3. `AXUIElementCopyAttributeValue(app, "AXFocusedUIElement")`.
//   4. Nil / non-success / non-AXUIElement type -> return `nil`.
//
// This mirrors `VisualElementContext.FocusedElement` (VisualElementContext.cs:12)
// but scoped to a specific pid instead of the systemwide element — the
// per-pid variant is what Everywhere's own MCP callers ultimately need
// (see the AppKey.FromProcessId envelope pattern).
//
// Name cascade is 1:1 with `AXUIElement.Name` (AXUIElement.cs:257-315):
//   AXTitle -> AXDescription -> AXHelp -> (if label-bearing)
//   AXValue -> AXTitleUIElement -> first AXStaticText child ->
//   AXIdentifier.
//
// State bits are 1:1 with `AXUIElement.States` (AXUIElement.cs:218-251).
// Emission order matches Everywhere's numeric `VisualElementStates` enum
// order (`IVisualElement.cs:60-84`) — Offscreen, Disabled, Focused,
// Selected, Password, Expanded, Checked. Names are lowercased to fit the
// openclicky-shaped envelope (`SemanticExtractor.statesList` keeps the
// Everywhere PascalCase). The port's `readBool` accepts both CFBoolean
// and CFNumber-backed 0/1 to match `NSNumber.BoolValue` semantics.
// Action filter is 1:1 with `SnapshotActionFilter.Filter`
// (SnapshotActionFilter.cs:17-40): whitelist + "AX" prefix strip + dedup.
//
// AXValue coercion is split into two helpers — `readValueRaw`
// (no transform, used inside the Name cascade to match Everywhere's
// `GetAttribute<NSObject>(Value)?.ToString()` at AXUIElement.cs:281,296,355)
// and `readValueTransformed` (AXCheckBox 0->false/else->true, used for the
// user-visible value field and matching `GetText` at AXUIElement.cs:549-556).
//
// Password / secure text field: `value` is forced to `nil` when
// `AXSubrole == "AXSecureTextField"`. This is stricter than Everywhere
// (Everywhere returns the raw AXValue and the snapshot writer elides
// it downstream) — the task rule "never leak" is applied at the
// capture boundary here.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Focused-element AX detail capture. Wraps
/// `AXUIElementCreateApplication(pid) -> AXFocusedUIElement` and harvests
/// the attribute set Everywhere's snapshot writer + tree walker read.
public enum FocusedElementCapture {

    // MARK: AX attribute constants
    //
    // Each mirrors an entry in `AXAttributeConstants.cs`. Kept local so
    // this file stays independent of sibling captures.

    private static let attrFocusedUIElement: CFString = "AXFocusedUIElement" as CFString
    private static let attrRole: CFString = "AXRole" as CFString
    private static let attrSubrole: CFString = "AXSubrole" as CFString
    private static let attrTitle: CFString = "AXTitle" as CFString
    private static let attrDescription: CFString = "AXDescription" as CFString
    private static let attrHelp: CFString = "AXHelp" as CFString
    private static let attrValue: CFString = "AXValue" as CFString
    private static let attrPlaceholder: CFString = "AXPlaceholderValue" as CFString
    private static let attrIdentifier: CFString = "AXIdentifier" as CFString
    private static let attrTitleUIElement: CFString = "AXTitleUIElement" as CFString
    private static let attrChildren: CFString = "AXChildren" as CFString
    private static let attrPosition: CFString = "AXPosition" as CFString
    private static let attrSize: CFString = "AXSize" as CFString
    private static let attrEnabled: CFString = "AXEnabled" as CFString
    private static let attrSelected: CFString = "AXSelected" as CFString
    private static let attrExpanded: CFString = "AXExpanded" as CFString
    private static let attrFocused: CFString = "AXFocused" as CFString
    private static let attrHidden: CFString = "AXHidden" as CFString

    /// Everywhere's `AXSecureTextField` subrole literal (AXUIElement.cs:242).
    private static let secureTextFieldSubrole = "AXSecureTextField"

    // MARK: Public API

    /// Resolve the focused UI element for `pid` and harvest attributes.
    /// Returns nil when pid <= 0, the app element can't be created, or
    /// `AXFocusedUIElement` is absent / unreadable.
    public static func capture(pid: Int32) -> FocusedElementInfo? {
        guard pid > 0 else {
            CaptureLog.log("openclicky.ax.focused_element_skip",
                           direction: "internal",
                           ["reason": "pid<=0", "pid": "\(pid)"])
            return nil
        }

        // Bound the SystemWide AX messaging timeout to 1s on first
        // touch. Mirrors Everywhere's static-ctor at AXUIElement.cs:471-475.
        AXQuirksInstaller.ensureAXBootstrap()

        let app = AXUIElementCreateApplication(pid)
        guard let element = copyElementAttribute(app, attrFocusedUIElement) else {
            CaptureLog.log("openclicky.ax.focused_element_miss",
                           direction: "error",
                           ["pid": "\(pid)", "attr": "AXFocusedUIElement"])
            return nil
        }

        guard let role = readString(from: element, attribute: attrRole),
              !role.isEmpty else {
            // Everywhere's Role getter always populates (AXUIElement.cs:494)
            // — a missing role means the element is torn down; treat as nil.
            CaptureLog.log("openclicky.ax.focused_element_role_missing",
                           direction: "error",
                           ["pid": "\(pid)"])
            return nil
        }
        let subrole = readString(from: element, attribute: attrSubrole)
        let isSecure = (subrole == secureTextFieldSubrole)

        let title = readString(from: element, attribute: attrTitle)
        let name = readName(from: element, role: role)
        let help = readString(from: element, attribute: attrHelp)
        let description = readString(from: element, attribute: attrDescription)
        let placeholder = readString(from: element, attribute: attrPlaceholder)
        let value = isSecure ? nil : readValueTransformed(from: element, role: role)
        let states = readStates(from: element, role: role, subrole: subrole, isSecure: isSecure)
        let actions = readMeaningfulActions(from: element)
        let bounds = readBounds(from: element)

        CaptureLog.log(
            "openclicky.ax.focused_element",
            [
                "pid": "\(pid)",
                "role": role,
                "subrole": subrole ?? "",
                "has_title": title == nil ? "false" : "true",
                "has_name": name == nil ? "false" : "true",
                "is_secure": isSecure ? "true" : "false",
                "state_count": "\(states.count)",
                "action_count": "\(actions.count)",
                "bounds_x": "\(Int(bounds.origin.x))",
                "bounds_y": "\(Int(bounds.origin.y))",
                "bounds_w": "\(Int(bounds.size.width))",
                "bounds_h": "\(Int(bounds.size.height))"
            ]
        )

        return FocusedElementInfo(
            pid: pid,
            role: role,
            subrole: subrole,
            title: title,
            name: name,
            value: value,
            placeholder: placeholder,
            help: help,
            description: description,
            states: states,
            actions: actions,
            bounds: bounds,
            isSecure: isSecure
        )
    }

    // MARK: Name cascade
    //
    // 1:1 with `AXUIElement.Name` (AXUIElement.cs:257-315):
    //   1. AXTitle (non-whitespace)
    //   2. AXDescription
    //   3. AXHelp
    //   4. If label-bearing role: AXValue as string
    //   5. If label-bearing role: AXTitleUIElement -> its Value, then Title
    //   6. If label-bearing role: first AXStaticText child value/title
    //      (scan up to 12 immediate children)
    //   7. AXIdentifier

    private static func readName(from element: AXUIElement, role: String) -> String? {
        if let t = readNonEmptyString(from: element, attribute: attrTitle) { return t }
        if let d = readNonEmptyString(from: element, attribute: attrDescription) { return d }
        if let h = readNonEmptyString(from: element, attribute: attrHelp) { return h }

        if isLabelBearingRole(role) {
            if let v = readValueRaw(from: element),
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
            if let titleElement = copyElementAttribute(element, attrTitleUIElement) {
                if let tv = readValueRaw(from: titleElement),
                   !tv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return tv
                }
                if let tt = readNonEmptyString(from: titleElement, attribute: attrTitle) {
                    return tt
                }
            }
            if let childText = firstChildStaticTextValue(from: element) {
                return childText
            }
        }

        if let id = readNonEmptyString(from: element, attribute: attrIdentifier) {
            return id
        }
        return nil
    }

    /// 1:1 with `IsLabelBearingRole` (AXUIElement.cs:325-335).
    private static func isLabelBearingRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXMenuButton", "AXPopUpButton",
             "AXCheckBox", "AXRadioButton",
             "AXMenuItem", "AXMenuBarItem",
             "AXLink", "AXImage",
             "AXDisclosureTriangle",
             "AXCell", "AXRow":
            return true
        default:
            return false
        }
    }

    /// 1:1 with `TryFirstChildStaticTextValue` (AXUIElement.cs:337-363).
    /// Uses the raw `AXChildren` attribute (not `Children`, which fans
    /// out into Rows/VisibleChildren/Contents at 4x IPC per child).
    private static func firstChildStaticTextValue(from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attrChildren, &raw)
        guard err == .success, let value = raw,
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }
        let array = value as! CFArray
        let count = CFArrayGetCount(array)
        var seen = 0
        for i in 0..<count {
            if seen >= 12 { break }
            guard let childPtr = CFArrayGetValueAtIndex(array, i) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(childPtr).takeUnretainedValue()
            seen += 1
            guard let childRole = readString(from: child, attribute: attrRole),
                  childRole == "AXStaticText" else { continue }
            if let v = readValueRaw(from: child),
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
            if let t = readNonEmptyString(from: child, attribute: attrTitle) {
                return t
            }
        }
        return nil
    }

    // MARK: Value

    /// Coerce AXValue to string with NO role-conditional transform.
    ///
    /// 1:1 with Everywhere's `GetAttribute<NSObject>(Value)?.ToString()`
    /// call sites in `AXUIElement.Name` (AXUIElement.cs:281, :296) and
    /// `TryFirstChildStaticTextValue` (AXUIElement.cs:355). Those sites
    /// deliberately skip the AXCheckBox 0/1 -> false/true rewrite so a
    /// checkbox's label ("Remember me") never gets turned into "true".
    ///
    /// Strings pass through as-is. Numbers / bools stringify (kept for
    /// non-checkbox call sites: some AX label channels expose numeric
    /// values, e.g. progress indicators). Opaque AXValueRef wrappers
    /// return nil.
    private static func readValueRaw(from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attrValue, &raw)
        guard err == .success, let value = raw else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return value as? String
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            return (value as? NSNumber)?.stringValue
        }
        return nil
    }

    /// Coerce AXValue to string with the AXCheckBox 0->false / else->true
    /// transform applied.
    ///
    /// 1:1 with `AXUIElement.GetText` (AXUIElement.cs:549-556). Used only
    /// for the user-visible `value` field on the returned
    /// `FocusedElementInfo` — the name cascade uses `readValueRaw`
    /// instead.
    private static func readValueTransformed(from element: AXUIElement, role: String) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attrValue, &raw)
        guard err == .success, let value = raw else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            let s = value as? String
            if role == "AXCheckBox", let text = s {
                return text == "0" ? "false" : "true"
            }
            return s
        }
        if typeID == CFBooleanGetTypeID() {
            let b = CFBooleanGetValue((value as! CFBoolean))
            return b ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            let n = value as! CFNumber
            if role == "AXCheckBox" {
                var intValue: Int = 0
                CFNumberGetValue(n, .nsIntegerType, &intValue)
                return intValue == 0 ? "false" : "true"
            }
            return (value as? NSNumber)?.stringValue
        }
        return nil
    }

    // MARK: States
    //
    // 1:1 with `AXUIElement.States` (AXUIElement.cs:218-251). Emits
    // lowercase strings. Emission order matches Everywhere's numeric
    // `VisualElementStates` enum order (`IVisualElement.cs:60-84`) as
    // seen by `Enum.GetValues<VisualElementStates>()` iteration:
    //   Offscreen (1<<0), Disabled (1<<1), Focused (1<<2),
    //   Selected (1<<3), Password (1<<5), Expanded (1<<6),
    //   Checked (1<<13).

    private static func readStates(from element: AXUIElement,
                                   role: String,
                                   subrole: String?,
                                   isSecure: Bool) -> [String] {
        var out: [String] = []
        if let hidden = readBool(from: element, attribute: attrHidden), hidden == true {
            out.append("offscreen")
        }
        if let enabled = readBool(from: element, attribute: attrEnabled), enabled == false {
            out.append("disabled")
        }
        if let focused = readBool(from: element, attribute: attrFocused), focused == true {
            out.append("focused")
        }
        if let selected = readBool(from: element, attribute: attrSelected), selected == true {
            out.append("selected")
        }
        if isSecure {
            out.append("password")
        }
        if let expanded = readBool(from: element, attribute: attrExpanded), expanded == true {
            out.append("expanded")
        }
        // Checked: AXCheckBox / AXRadioButton with numeric AXValue > 0
        // (AXUIElement.cs:247-250).
        if role == "AXCheckBox" || role == "AXRadioButton" {
            var raw: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, attrValue, &raw)
            if err == .success, let v = raw, CFGetTypeID(v) == CFNumberGetTypeID() {
                let n = v as! CFNumber
                var intVal: Int = 0
                if CFNumberGetValue(n, .nsIntegerType, &intVal), intVal > 0 {
                    out.append("checked")
                }
            }
        }
        return out
    }

    // MARK: Actions
    //
    // 1:1 with `SupportedActions` (AXUIElement.cs:507+) plumbed through
    // `SnapshotActionFilter.Filter` (SnapshotActionFilter.cs:17-40).

    /// Everywhere's meaningful-actions whitelist (SnapshotActionFilter.cs:17-21).
    private static let meaningfulActions: Set<String> = [
        "Press", "Confirm", "Open", "ShowMenu",
        "Increment", "Decrement", "Pick", "Cancel", "Delete", "Raise",
    ]

    private static func readMeaningfulActions(from element: AXUIElement) -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(element, &names)
        guard err == .success, let array = names else { return [] }
        let count = CFArrayGetCount(array)
        var out: [String] = []
        out.reserveCapacity(4)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let cfStr = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
            let str = cfStr as String
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let stripped = trimmed.hasPrefix("AX") ? String(trimmed.dropFirst(2)) : trimmed
            guard !stripped.isEmpty else { continue }
            guard meaningfulActions.contains(stripped) else { continue }
            guard !out.contains(stripped) else { continue }
            out.append(stripped)
        }
        return out
    }

    // MARK: Bounds
    //
    // 1:1 with `AXUIElement.QueryBoundingRectangle`
    // (AXUIElement.cs:448-465). Missing either attribute -> .zero.

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

    // MARK: AX plumbing (shared readers)

    /// Copy attribute expected to be an AXUIElement (e.g. AXTitleUIElement,
    /// AXFocusedUIElement).
    private static func copyElementAttribute(_ element: AXUIElement,
                                             _ attribute: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Read a string-typed AX attribute. Nil on non-success / non-string
    /// / empty CFString.
    private static func readString(from element: AXUIElement,
                                   attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    /// Same as `readString` but nils out whitespace-only results
    /// (matches Everywhere's `!string.IsNullOrWhiteSpace(...)` guards).
    private static func readNonEmptyString(from element: AXUIElement,
                                           attribute: CFString) -> String? {
        guard let s = readString(from: element, attribute: attribute) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// Read a bool-typed AX attribute. Nil on missing / non-CFBoolean —
    /// distinct from `false` so state extraction can preserve
    /// Everywhere's `?.BoolValue == true` semantic (a missing attribute
    /// is *not* the same as an explicit false).
    private static func readBool(from element: AXUIElement,
                                 attribute: CFString) -> Bool? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        // Some apps report Enabled / Selected as NSNumber.
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            let n = value as! CFNumber
            var intVal: Int = 0
            if CFNumberGetValue(n, .nsIntegerType, &intVal) {
                return intVal != 0
            }
        }
        return nil
    }
}
