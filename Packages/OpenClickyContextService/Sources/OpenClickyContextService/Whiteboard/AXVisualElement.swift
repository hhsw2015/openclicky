// Ported from Everywhere: src/Everywhere.Mac/Interop/AXUIElement.cs
//   role table @ :126-183
//   Name cascade @ :257-315
//   QueryBoundingRectangle @ :448-465
// pin @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Thin wrapper around a raw AXUIElement that exposes the four things the
// AnnotationSnapper needs — role-mapped `type`, Quartz-global `boundingRect`,
// raw `children`, and a `getText(maxLength:)` name cascade. We deliberately
// do NOT reuse `FocusedElementCapture` here because the snapper wants raw,
// per-node data with NO logging / no cache; every call happens inside a
// tight rect-pruned walk where the overhead of `CaptureLog.log` per node
// would dominate. Everywhere's `IVisualElement` has the same shape.

import Foundation
import ApplicationServices
import CoreGraphics

/// Everywhere's VisualElementType, narrowed to the leaf-role subset the
/// AnnotationSnapper actually filters on (`AXUIElement.cs:126-183`).
public enum VisualElementType: Sendable, Equatable {
    case label       // AXStaticText
    case hyperlink   // AXLink
    case image       // AXImage
    case other       // everything else — snapper never keeps these
}

/// Wrapper around AXUIElement that ports Everywhere's `IVisualElement`
/// contract for whiteboard snap. Reference-equatable so it drops into the
/// `HashSet<IVisualElement>(ReferenceEqualityComparer.Instance)` shape the
/// PrewarmedTree sidecars use (`AnnotationSnapper.cs:697-699`).
public final class AXVisualElement: Hashable {
    public let element: AXUIElement
    public let type: VisualElementType

    /// Cached bbox — the walker computes it during prune; reuse in Snap
    /// so we don't pay a second AX IPC per node. Mirrors Everywhere
    /// yielding `(Node, Bbox)` tuples in `DescendantsInRect`.
    public let boundingRect: CGRect

    public init(element: AXUIElement, type: VisualElementType, boundingRect: CGRect) {
        self.element = element
        self.type = type
        self.boundingRect = boundingRect
    }

    // MARK: Children — raw AXChildren, matching Everywhere `AXUIElement.cs:27-90`.

    /// Raw children with their own bboxes fetched in-line. Used by the
    /// PrewarmedTree walker (`AnnotationSnapper.cs:762-777`). Do NOT
    /// substitute `AXVisibleChildren` / `AXRows` / `AXContents` here —
    /// see the comment in `FocusedElementCapture.firstChildStaticTextValue`
    /// (:225-251): those attributes fan out at 4× IPC and the snapper's
    /// prune already handles the fan-out shape correctly by walking every
    /// child in order.
    public func children() -> [AXVisualElement] {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttr, &raw)
        guard err == .success,
              let value = raw,
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        let array = value as! CFArray
        let count = CFArrayGetCount(array)
        var out: [AXVisualElement] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(array, i) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            let type = Self.readType(from: child)
            let bb = Self.readBounds(from: child)
            out.append(AXVisualElement(element: child, type: type, boundingRect: bb))
        }
        return out
    }

    // MARK: Text cascade — `AXUIElement.cs:257-315`

    /// 1:1 port of Everywhere's `Name` getter, capped at `maxLength`
    /// (the C# side always reads full and truncates; here we short-circuit
    /// when the caller signals it only needs the first character, e.g.
    /// PrewarmedTree.BuildImpl:738 does `GetText(maxLength: 1)` purely to
    /// answer "is this empty?"). Non-empty precedence:
    ///   AXTitle -> AXDescription -> AXHelp
    ///   (label-bearing roles only): AXValue -> AXTitleUIElement ->
    ///   first AXStaticText child -> AXIdentifier.
    public func getText(maxLength: Int = 1024) -> String {
        if let t = Self.readNonEmpty(element, kAXTitleAttr) { return truncate(t, maxLength) }
        if let d = Self.readNonEmpty(element, kAXDescAttr) { return truncate(d, maxLength) }
        if let h = Self.readNonEmpty(element, kAXHelpAttr) { return truncate(h, maxLength) }
        // Only label-bearing roles get the extended cascade. `AXStaticText`
        // and `AXLink` are label-bearing in Everywhere's table
        // (`AXUIElement.cs:325-335`) — same set we walk in the snapper.
        // Everywhere's cascade also includes Buttons/Menus/etc., but the
        // AnnotationSnapper only ever inspects `.label` / `.hyperlink` /
        // `.image` nodes so the narrower set here is safe.
        switch type {
        case .label, .hyperlink, .image:
            if let v = Self.readValueString(element),
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return truncate(v, maxLength)
            }
            if let te = Self.copyElement(element, kAXTitleUIAttr) {
                if let tv = Self.readValueString(te),
                   !tv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return truncate(tv, maxLength)
                }
                if let tt = Self.readNonEmpty(te, kAXTitleAttr) {
                    return truncate(tt, maxLength)
                }
            }
            if let s = Self.firstStaticTextChildValue(element) {
                return truncate(s, maxLength)
            }
        case .other:
            break
        }
        if let id = Self.readNonEmpty(element, kAXIdentifierAttr) {
            return truncate(id, maxLength)
        }
        return ""
    }

    // MARK: Static readers (parallel to FocusedElementCapture private helpers)

    /// Map AXRole -> our narrow `VisualElementType`. Mirrors the switch
    /// at `AXUIElement.cs:126-183`. Anything not on the leaf-role list is
    /// collapsed to `.other` so the snapper's role filter short-circuits.
    public static func readType(from element: AXUIElement) -> VisualElementType {
        guard let role = readString(element, kAXRoleAttr) else { return .other }
        switch role {
        case "AXStaticText": return .label
        case "AXLink":       return .hyperlink
        case "AXImage":      return .image
        default:             return .other
        }
    }

    /// 1:1 with `QueryBoundingRectangle` (`AXUIElement.cs:448-465`).
    /// Reuses the same shape as `ElementUnderCursorCapture.readBounds`
    /// (:235-257) but re-implemented locally so the snapper doesn't drag
    /// the whole Capture module through a private-ext dependency graph.
    public static func readBounds(from element: AXUIElement) -> CGRect {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        let pErr = AXUIElementCopyAttributeValue(element, kAXPosAttr, &posRaw)
        let sErr = AXUIElementCopyAttributeValue(element, kAXSizeAttr, &sizeRaw)
        guard pErr == .success, sErr == .success,
              let pv = posRaw, let sv = sizeRaw,
              CFGetTypeID(pv) == AXValueGetTypeID(),
              CFGetTypeID(sv) == AXValueGetTypeID() else {
            return .zero
        }
        let pav = pv as! AXValue
        let sav = sv as! AXValue
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(pav, .cgPoint, &pt),
              AXValueGetValue(sav, .cgSize, &sz) else {
            return .zero
        }
        return CGRect(origin: pt, size: sz)
    }

    private static func readString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &raw)
        guard err == .success, let v = raw, CFGetTypeID(v) == CFStringGetTypeID() else {
            return nil
        }
        return v as? String
    }

    private static func readNonEmpty(_ element: AXUIElement, _ attr: CFString) -> String? {
        guard let s = readString(element, attr),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return s
    }

    private static func readValueString(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttr, &raw)
        guard err == .success, let v = raw else { return nil }
        let tid = CFGetTypeID(v)
        if tid == CFStringGetTypeID() { return v as? String }
        if tid == CFNumberGetTypeID() { return (v as? NSNumber)?.stringValue }
        return nil
    }

    private static func copyElement(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &raw)
        guard err == .success, let v = raw, CFGetTypeID(v) == AXUIElementGetTypeID() else {
            return nil
        }
        return (v as! AXUIElement)
    }

    /// 1:1 with Everywhere `TryFirstChildStaticTextValue`
    /// (`AXUIElement.cs:337-363`). Same 12-child scan cap
    /// `FocusedElementCapture.firstChildStaticTextValue` uses (:236).
    private static func firstStaticTextChildValue(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttr, &raw)
        guard err == .success, let v = raw, CFGetTypeID(v) == CFArrayGetTypeID() else {
            return nil
        }
        let arr = v as! CFArray
        let count = CFArrayGetCount(arr)
        var seen = 0
        for i in 0..<count {
            if seen >= 12 { break }
            guard let ptr = CFArrayGetValueAtIndex(arr, i) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            seen += 1
            guard readString(child, kAXRoleAttr) == "AXStaticText" else { continue }
            if let val = readValueString(child),
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
            if let title = readNonEmpty(child, kAXTitleAttr) {
                return title
            }
        }
        return nil
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        if n <= 0 || s.count <= n { return s }
        return String(s.prefix(n))
    }

    // MARK: Hashable / reference-equality
    //
    // Everywhere uses `ReferenceEqualityComparer.Instance` for the
    // `HashSet<IVisualElement>` sidecars (`AnnotationSnapper.cs:697-699`).
    // We match that by hashing on `AXUIElement` identity via `ObjectIdentifier`
    // on the wrapper — two distinct `AXVisualElement` wrappers around the
    // same underlying AX handle count as different, which is fine because
    // the walker only ever creates one wrapper per node during a single
    // traversal.

    public static func == (lhs: AXVisualElement, rhs: AXVisualElement) -> Bool {
        return CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

// MARK: - Attribute constants

// Local mirrors of `AXAttributeConstants.cs`. Kept in this file so the
// whiteboard sub-module doesn't drag in the Capture module.
private let kAXRoleAttr: CFString = "AXRole" as CFString
private let kAXTitleAttr: CFString = "AXTitle" as CFString
private let kAXDescAttr: CFString = "AXDescription" as CFString
private let kAXHelpAttr: CFString = "AXHelp" as CFString
private let kAXValueAttr: CFString = "AXValue" as CFString
private let kAXTitleUIAttr: CFString = "AXTitleUIElement" as CFString
private let kAXChildrenAttr: CFString = "AXChildren" as CFString
private let kAXIdentifierAttr: CFString = "AXIdentifier" as CFString
private let kAXPosAttr: CFString = "AXPosition" as CFString
private let kAXSizeAttr: CFString = "AXSize" as CFString
