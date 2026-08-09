// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/SemanticExtractor.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
// src/Everywhere.Mcp/Tools/Schemas/SemanticItem.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
// src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
// src/Everywhere.Core/Interop/IVisualElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// First-class "semantic" views on top of the macOS accessibility tree.
//
// Everywhere consumes a pre-walked, indexed flat list
// (`ElementIndexer.IndexedNode[]`) and pulls three views out of it:
//
//   1. ExtractFocused         — the single deepest node whose
//                                Focused flag is set.
//   2. BuildFocusedPath       — that leaf plus every ancestor, root
//                                first, so the agent gets a
//                                "you are inside X -> Y -> Z" breadcrumb.
//   3. ExtractSelected        — every node with the Selected flag.
//
// openclicky delegates the whole AX tree walk to open-codex-computer-use
// (see `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` L11-16). Since we
// don't own an `IndexedNode` array to iterate, this port works one
// level lower: raw `AXUIElement` refs harvested via `AXUIElementCreateApplication`
// and the standard `kAXFocusedUIElement` / `kAXParent` / `kAXChildren`
// attribute triad. The output shape (`SemanticNode`) mirrors
// `SemanticItem` field-for-field minus `element_index` (there is no
// index space to point into).
//
// Parity table (Everywhere -> Swift):
//
//   VisualElementStates.Focused on IndexedNode
//       -> kAXFocusedAttribute (bool) on the AXUIElement.
//   deepest node with Focused
//       -> kAXFocusedUIElement on AXUIElementCreateApplication(pid).
//   Walk ParentIndex up to root, Reverse()
//       -> Walk kAXParent chain, then reverse.
//   Element.Type.ToString()
//       -> AX role -> VisualElementType name string via the mapping
//          copied verbatim from AXUIElement.cs:120-213.
//   BuildItem.Name cascade (Name / GetText / labelled child)
//       -> AXTitle -> AXDescription -> AXHelp -> label-bearing role
//          AXValue -> AXChildren-recursion for a labelled descendant.
//   StatesToList (enum flag names)
//       -> Read the same AX bool attributes AXUIElement.States sets,
//          emit the matching VisualElementStates enum names.
//   SuggestActions(type)
//       -> Identical switch table, keyed on the mapped type string.
//
// Safety:
//   * pid <= 0 returns empty / nil (matches AXUIElement.cs pid guards).
//   * AX attribute failures propagate as nil / defaults; nothing throws.
//   * Ancestor walk capped at kMaxPathDepth (64, matching
//     `UpstreamConstants.AccessibilityTreeMaxDepth = 64` at
//     `UpstreamConstants.cs:11`) and dedup'd by CFHash to survive AX
//     wrappers that hand out parent=self loops (matches the seen
//     HashSet in ElementIndexer.Walk).
//   * FindLabelTextInChildren depth capped at 3 (matches BuildItem
//     `maxDepth: 3` at SemanticExtractor.cs:83).
//   * State bag emitted in Everywhere's numeric enum order
//     (Offscreen, Disabled, Focused, Selected, Password, Expanded,
//     Checked) matching `Enum.GetValues<VisualElementStates>()`
//     iteration order in `SemanticExtractor.cs:StatesToList`.

import Foundation
import AppKit
import ApplicationServices

/// Public API surface matches Everywhere's `SemanticExtractor` static
/// class one method at a time. Each helper documents its C# analogue
/// inline.
public enum SemanticExtractor {

    // MARK: Depth / label caps
    //
    // 1:1 with Everywhere's `UpstreamConstants.AccessibilityTreeMaxDepth`
    // = 64 (`UpstreamConstants.cs:11`). Everywhere's `ElementIndexer.Walk`
    // never produces a `ParentIndex` chain longer than 64. openclicky
    // walks raw AX which has no natural cap, so we mirror the constant
    // directly. Combined with the CFHash-based cycle guard this keeps
    // the path finite even for hostile AX wrappers.
    private static let kMaxPathDepth = 64

    // 1:1 with `FindLabelTextInChildren(element, maxDepth: 3)`
    // (SemanticExtractor.cs:83).
    private static let kLabelSearchMaxDepth = 3

    // 1:1 with `element.GetText(maxLength: 200)`
    // (SemanticExtractor.cs:79).
    private static let kMaxOwnTextLength = 200

    // MARK: AX attribute constants
    //
    // Verbatim copies of `AXAttributeConstants.cs`; per Everywhere's
    // per-file layout each interop file redeclares the constants it
    // needs (see FocusedWindowCapture / ElementUnderCursorCapture).

    private static let attrRole: CFString = "AXRole" as CFString
    private static let attrSubrole: CFString = "AXSubrole" as CFString
    private static let attrTitle: CFString = "AXTitle" as CFString
    private static let attrDescription: CFString = "AXDescription" as CFString
    private static let attrHelp: CFString = "AXHelp" as CFString
    private static let attrValue: CFString = "AXValue" as CFString
    private static let attrIdentifier: CFString = "AXIdentifier" as CFString
    private static let attrParent: CFString = "AXParent" as CFString
    private static let attrChildren: CFString = "AXChildren" as CFString
    private static let attrFocusedUIElement: CFString = "AXFocusedUIElement" as CFString
    private static let attrTitleUIElement: CFString = "AXTitleUIElement" as CFString

    // State attributes — 1:1 with AXUIElement.States getter
    // (AXUIElement.cs:228-251).
    private static let attrEnabled: CFString = "AXEnabled" as CFString
    private static let attrSelected: CFString = "AXSelected" as CFString
    private static let attrExpanded: CFString = "AXExpanded" as CFString
    private static let attrFocused: CFString = "AXFocused" as CFString
    private static let attrHidden: CFString = "AXHidden" as CFString

    // MARK: Public API

    /// Root-to-leaf semantic breadcrumb for the currently focused
    /// element in `pid`'s AX tree.
    ///
    /// 1:1 with `SemanticExtractor.BuildFocusedPath`
    /// (`SemanticExtractor.cs:49-70`), operating over live AX rather
    /// than a pre-walked index:
    ///   1. Locate the deepest focused element via
    ///      `kAXFocusedUIElement` on the app AX ref.
    ///   2. Walk `kAXParent` back to the app / systemwide sentinel.
    ///   3. Reverse the accumulated list so index 0 is the outermost
    ///      ancestor.
    ///
    /// Returns an empty path when the pid is invalid, AX consent is
    /// missing, or no focused element exists in the tree.
    public static func focusedPath(pid: pid_t) -> SemanticFocusPath {
        guard pid > 0 else { return SemanticFocusPath(pid: pid, nodes: []) }

        // Bound the SystemWide AX messaging timeout to 1s on first
        // touch. Mirrors Everywhere's static-ctor at AXUIElement.cs:471-475.
        AXQuirksInstaller.ensureAXBootstrap()

        let app = AXUIElementCreateApplication(pid)
        guard let leaf = copyElementAttribute(app, attrFocusedUIElement) else {
            CaptureLog.log("openclicky.ax.focused_path_no_leaf",
                           direction: "error",
                           ["pid": "\(pid)"])
            return SemanticFocusPath(pid: pid, nodes: [])
        }

        var chain: [AXUIElement] = []
        var seen = Set<Int>()
        var current: AXUIElement? = leaf
        var depth = 0
        while let node = current, depth < kMaxPathDepth {
            let key = elementHash(node)
            if !seen.insert(key).inserted { break }
            chain.append(node)
            depth += 1
            current = copyElementAttribute(node, attrParent)
        }

        let hitCap = depth == kMaxPathDepth
        CaptureLog.log(
            "openclicky.ax.tree_walk",
            [
                "pid": "\(pid)",
                "depth": "\(depth)",
                "budget_remaining": "\(kMaxPathDepth - depth)",
                "hit_cap": hitCap ? "true" : "false"
            ]
        )

        let nodes = chain.reversed().map(buildItem(for:))
        return SemanticFocusPath(pid: pid, nodes: nodes)
    }

    /// Just the deepest focused leaf — first entry emitted by
    /// `focusedPath` from the tail side.
    ///
    /// 1:1 with `SemanticExtractor.ExtractFocused`
    /// (`SemanticExtractor.cs:33-42`): Everywhere finds the deepest
    /// `Focused` node in its indexed list; openclicky reads
    /// `kAXFocusedUIElement` directly (macOS AX exposes exactly that
    /// leaf).
    public static func focused(pid: pid_t) -> SemanticNode? {
        guard pid > 0 else { return nil }
        AXQuirksInstaller.ensureAXBootstrap()
        let app = AXUIElementCreateApplication(pid)
        guard let leaf = copyElementAttribute(app, attrFocusedUIElement) else {
            CaptureLog.log("openclicky.semantic.focused_miss",
                           direction: "error",
                           ["pid": "\(pid)"])
            return nil
        }
        let node = buildItem(for: leaf)
        CaptureLog.log(
            "openclicky.semantic.focused",
            [
                "pid": "\(pid)",
                "type": node.type,
                "state_count": "\(node.states?.count ?? 0)"
            ]
        )
        return node
    }

    /// AX-level "selected" enumeration.
    ///
    /// Everywhere's `SemanticExtractor.ExtractSelected`
    /// (`SemanticExtractor.cs:13-24`) walks every indexed node and
    /// picks the ones with the `Selected` flag — feasible because it
    /// has the pre-walked flat list on hand.
    ///
    /// openclicky does not own the tree walk (delegated to OCCU) and
    /// AX does not expose an app-wide "list all selected elements"
    /// attribute. What it *does* expose is per-container selection:
    ///   * `AXSelectedRows` / `AXSelectedChildren` /
    ///     `AXSelectedText` on the currently focused container.
    ///
    /// This method walks the focus path and, for the leaf, harvests
    /// selected AX children (rows first, then generic children).
    /// Returns an empty list when the focused container exposes no
    /// selection channel — callers who need selected *text* should
    /// use `SelectedTextCapture`.
    public static func selected(pid: pid_t) -> [SemanticNode] {
        guard pid > 0 else { return [] }
        AXQuirksInstaller.ensureAXBootstrap()
        let app = AXUIElementCreateApplication(pid)
        guard let leaf = copyElementAttribute(app, attrFocusedUIElement) else {
            return []
        }

        // Try selected-rows first (tables, outlines), fall through to
        // selected-children (list-box style containers).
        let selectionAttrs: [CFString] = [
            "AXSelectedRows" as CFString,
            "AXSelectedChildren" as CFString
        ]
        for attr in selectionAttrs {
            if let children = copyElementArrayAttribute(leaf, attr), !children.isEmpty {
                return children.map(buildItem(for:))
            }
        }
        return []
    }

    // MARK: Item construction (mirrors SemanticExtractor.BuildItem)

    /// 1:1 with `SemanticExtractor.BuildItem`
    /// (`SemanticExtractor.cs:72-94`). Builds a `SemanticNode`
    /// (formerly `SemanticItem`) from a single AX element by:
    ///   1. Resolving `type` via the AX role -> VisualElementType map.
    ///   2. Applying the text cascade (own name -> own text ->
    ///      labelled descendant).
    ///   3. Reading the state flag bag and stringifying it.
    ///   4. Looking up `available_actions` from the type-driven
    ///      suggestion table.
    private static func buildItem(for element: AXUIElement) -> SemanticNode {
        let role = readString(from: element, attribute: attrRole)
        let subrole = readString(from: element, attribute: attrSubrole)
        let type = mapType(role: role, subrole: subrole)

        var ownText = readName(from: element, role: role) ?? ""
        ownText = ownText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ownText.isEmpty {
            ownText = truncate(readValueText(from: element) ?? "", maxLength: kMaxOwnTextLength)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ownText.isEmpty {
            ownText = findLabelTextInChildren(of: element, maxDepth: kLabelSearchMaxDepth) ?? ""
        }
        let text: String? = ownText.isEmpty ? nil : ownText

        let states = statesList(for: element)
        let actions = suggestActions(for: type)

        return SemanticNode(
            type: type,
            text: text,
            states: states,
            availableActions: actions
        )
    }

    // MARK: AX role -> VisualElementType mapping
    //
    // Verbatim copy of `AXUIElement.Type` (AXUIElement.cs:120-213).
    // Kept case-by-case so any drift shows up as a diff line — do
    // NOT compact into a lookup table.

    private static func mapType(role: String?, subrole: String?) -> String {
        switch role {
        case "AXStaticText":
            return "Label"
        case "AXTextField", "AXTextArea":
            return "TextEdit"
        case "AXButton", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle":
            return "Button"
        case "AXCheckBox":
            return "CheckBox"
        case "AXRadioButton":
            return "RadioButton"
        case "AXComboBox":
            return "ComboBox"
        case "AXList", "AXRuler":
            return "ListView"
        case "AXOutline":
            return "TreeView"
        case "AXTable":
            return "Table"
        case "AXRow":
            return "TableRow"
        case "AXMenuBar", "AXMenu":
            return "Menu"
        case "AXMenuBarItem", "AXMenuItem":
            return "MenuItem"
        case "AXTabGroup":
            return "TabControl"
        case "AXToolbar":
            return "ToolBar"
        case "AXGroup", "AXRadioGroup", "AXSplitGroup", "AXBrowser",
             "AXSheet", "AXDrawer", "AXCell":
            return "Panel"
        case "AXWindow", "AXApplication", "AXSystemWide":
            return "TopLevel"
        case "AXSplitter":
            return "Splitter"
        case "AXSlider":
            return "Slider"
        case "AXScrollBar":
            return "ScrollBar"
        case "AXBusyIndicator":
            return "Spinner"
        case "AXProgressIndicator", "AXLevelIndicator",
             "AXRelevanceIndicator", "AXValueIndicator":
            return "ProgressBar"
        case "AXImage":
            return "Image"
        case "AXLink":
            return "Hyperlink"
        case "AXWebArea":
            return "Document"
        case "AXScrollArea", "AXLayoutArea", "AXLayoutItem",
             "AXGrowArea", "AXMatte", "AXRulerMarker", "AXColumn",
             "AXGrid", "AXPage", "AXPopover":
            return "Panel"
        default:
            break
        }

        // Subrole fallback — 1:1 with AXUIElement.cs:194-211.
        switch subrole {
        case "AXCloseButton", "AXMinimizeButton", "AXZoomButton",
             "AXToolbarButton", "AXSortButton", "AXTabButton":
            return "Button"
        case "AXSearchField":
            return "TextEdit"
        case "AXToggle", "AXSwitch":
            return "CheckBox"
        case "AXStandardWindow", "AXDialog", "AXSystemDialog",
             "AXFloatingWindow", "AXSystemFloatingWindow":
            return "Panel"
        default:
            return "Unknown"
        }
    }

    // MARK: Name cascade
    //
    // 1:1 with AXUIElement.Name (AXUIElement.cs:260-312):
    //   AXTitle -> AXDescription -> AXHelp -> label-role AXValue ->
    //   AXTitleUIElement.Value/Title -> first AXStaticText child value.
    //   AXIdentifier fallback last-ditch.

    private static func readName(from element: AXUIElement, role: String?) -> String? {
        if let title = readString(from: element, attribute: attrTitle),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let desc = readString(from: element, attribute: attrDescription),
           !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return desc
        }
        if let help = readString(from: element, attribute: attrHelp),
           !help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return help
        }
        // AXValue is treated as a label ONLY for the label-bearing
        // roles Everywhere gates on
        // (AXUIElement.IsLabelBearingRole @ AXUIElement.cs:325-335).
        if isLabelBearingRole(role) {
            if let v = readValueText(from: element),
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
            if let titleElement = copyElementAttribute(element, attrTitleUIElement) {
                if let tv = readValueText(from: titleElement),
                   !tv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return tv
                }
                if let tt = readString(from: titleElement, attribute: attrTitle),
                   !tt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return tt
                }
            }
            if let childText = tryFirstChildStaticTextValue(of: element),
               !childText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return childText
            }
        }
        if let id = readString(from: element, attribute: attrIdentifier),
           !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return id
        }
        return nil
    }

    /// 1:1 with `AXUIElement.IsLabelBearingRole` (AXUIElement.cs:325-335).
    private static func isLabelBearingRole(_ role: String?) -> Bool {
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

    /// 1:1 with `AXUIElement.TryFirstChildStaticTextValue`
    /// (AXUIElement.cs:337-363). Scans up to 12 immediate children
    /// (single IPC via AXChildren) and returns the first non-empty
    /// AXStaticText value/title.
    private static func tryFirstChildStaticTextValue(of element: AXUIElement) -> String? {
        guard let children = copyElementArrayAttribute(element, attrChildren) else {
            return nil
        }
        var seen = 0
        for child in children where seen < 12 {
            seen += 1
            let role = readString(from: child, attribute: attrRole)
            guard role == "AXStaticText" else { continue }
            if let v = readValueText(from: child),
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
            if let t = readString(from: child, attribute: attrTitle),
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return t
            }
        }
        return nil
    }

    /// 1:1 with `SemanticExtractor.FindLabelTextInChildren`
    /// (SemanticExtractor.cs:140-154). Recursion capped at
    /// `maxDepth` (default 3).
    private static func findLabelTextInChildren(of element: AXUIElement, maxDepth: Int) -> String? {
        if maxDepth <= 0 { return nil }
        guard let children = copyElementArrayAttribute(element, attrChildren) else {
            return nil
        }
        for child in children {
            let role = readString(from: child, attribute: attrRole)
            if mapType(role: role, subrole: nil) == "Label" {
                let name = readName(from: child, role: role)
                let text = name ?? readValueText(from: child)
                let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return String(trimmed.prefix(kMaxOwnTextLength))
                }
            }
            if let nested = findLabelTextInChildren(of: child, maxDepth: maxDepth - 1) {
                return nested
            }
        }
        return nil
    }

    // MARK: States
    //
    // 1:1 with `SemanticExtractor.StatesToList`
    // (SemanticExtractor.cs:96-109). The flag names emitted here
    // match `VisualElementStates.ToString()` on the C# side, so the
    // wire format is stable.

    private static func statesList(for element: AXUIElement) -> [String]? {
        // Emission order matches Everywhere's
        // `Enum.GetValues<VisualElementStates>()` iteration in
        // `SemanticExtractor.cs:StatesToList`, which follows the numeric
        // enum values from `IVisualElement.cs:60-84`:
        //   Offscreen (1<<0), Disabled (1<<1), Focused (1<<2),
        //   Selected (1<<3), Password (1<<5), Expanded (1<<6),
        //   Checked (1<<13).
        var flags: [String] = []
        if readBool(from: element, attribute: attrHidden) == true {
            flags.append("Offscreen")
        }
        if readBool(from: element, attribute: attrEnabled) == false {
            flags.append("Disabled")
        }
        if readBool(from: element, attribute: attrFocused) == true {
            flags.append("Focused")
        }
        if readBool(from: element, attribute: attrSelected) == true {
            flags.append("Selected")
        }
        let subrole = readString(from: element, attribute: attrSubrole)
        if subrole == "AXSecureTextField" {
            flags.append("Password")
        }
        if readBool(from: element, attribute: attrExpanded) == true {
            flags.append("Expanded")
        }
        let role = readString(from: element, attribute: attrRole)
        if role == "AXCheckBox" || role == "AXRadioButton" {
            if let n = copyNumberAttribute(element, attrValue),
               n.intValue != 0 {
                flags.append("Checked")
            }
        }
        return flags.isEmpty ? nil : flags
    }

    // MARK: Actions
    //
    // 1:1 with `SemanticExtractor.SuggestActions`
    // (SemanticExtractor.cs:111-138). Keyed on the mapped type
    // string (not the enum) so the switch stays trivially auditable.

    private static func suggestActions(for type: String) -> [String]? {
        switch type {
        case "Button", "Hyperlink", "MenuItem", "HeaderItem",
             "TabItem", "RadioButton", "CheckBox":
            return ["click", "perform_secondary_action"]
        case "ListViewItem", "TreeViewItem", "DataGridItem":
            return ["click", "perform_secondary_action"]
        case "TextEdit":
            return ["set_value", "click"]
        case "Slider", "Spinner":
            return ["set_value"]
        case "ComboBox":
            return ["click", "set_value"]
        case "ListView", "TreeView", "DataGrid", "Document":
            return ["scroll", "expand_element"]
        case "Image":
            return ["click"]
        default:
            return nil
        }
    }

    // MARK: AX plumbing
    //
    // Shape mirrors FocusedWindowCapture / ElementUnderCursorCapture
    // — each capture file redeclares its own AX helpers so file
    // boundaries stay independent (matches Everywhere's per-file
    // interop layout).

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyElementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        guard let array = value as? [AXUIElement], !array.isEmpty else { return nil }
        return array
    }

    private static func copyNumberAttribute(_ element: AXUIElement, _ attribute: CFString) -> NSNumber? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFNumberGetTypeID() || typeID == CFBooleanGetTypeID() {
            return value as? NSNumber
        }
        return nil
    }

    private static func readString(from element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private static func readBool(from element: AXUIElement, attribute: CFString) -> Bool? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success, let value = raw else { return nil }
        // Everywhere reads bool attrs via `GetAttribute<NSNumber>(...)?.BoolValue`
        // (`AXUIElement.cs:229-241`). `NSNumber.BoolValue` transparently
        // handles CFBoolean AND CFNumber-backed 0/1. Some SwiftUI /
        // Electron apps expose AXFocused / AXSelected / AXEnabled as
        // `kCFNumberSInt64Type == 1`, so we must accept both type IDs
        // or those state bits silently drop. Mirrors the equivalent
        // path in `FocusedElementCapture.readBool` (L386-403).
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            let n = value as! CFNumber
            var intVal: Int = 0
            if CFNumberGetValue(n, .nsIntegerType, &intVal) {
                return intVal != 0
            }
        }
        return nil
    }

    /// Best-effort string coercion of AXValue, matching
    /// `AXUIElement.cs:281`
    /// (`GetAttribute<NSObject>(AXAttributeConstants.Value)?.ToString()`).
    /// Strings pass through; numbers stringify; AXValueRef wrappers
    /// return nil (Everywhere would emit a debug shape we don't want
    /// to leak).
    private static func readValueText(from element: AXUIElement) -> String? {
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

    /// Cycle guard key. 1:1 with the `seen` HashSet<ulong> in
    /// `ElementIndexer.Walk` (ElementIndexer.cs:67) which uses
    /// `CFHash` on the raw handle. Swift's `CFHash` on `AXUIElement`
    /// is `CFHashCode` (unsigned Int) — wrap into Int for Set<Int>.
    private static func elementHash(_ element: AXUIElement) -> Int {
        Int(bitPattern: UInt(CFHash(element)))
    }

    private static func truncate(_ s: String, maxLength: Int) -> String {
        s.count <= maxLength ? s : String(s.prefix(maxLength))
    }
}
