// Ported from Everywhere: src/Everywhere.Mcp/Tools/ReadPickTool.cs + AddAnnotationTool.cs + ReadAnnotationsTool.cs + ClearAnnotationsTool.cs + ReadWhiteboardTool.cs + ReadWhiteboardImageTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// MCP-facing surface for the Layer-4 UX stash tools (`read_pick`,
// `add_annotation`, `read_annotations`, `clear_annotations`,
// `read_whiteboard`, `read_whiteboard_image`). Each static method mirrors
// the corresponding `[McpServerTool(Name = "...")]` in Everywhere's
// per-tool C# source, keeping the same argument order and semantic. Wire
// snake_case round-trips via the `CodingKeys` on the return types in
// `Types/CaptureTypes.swift`.
//
// Design fidelity notes vs Everywhere:
//   * `readPick` operates on the value snapshot Swift `PickStash` stores
//     (`PickedElement`), not a live AX ref. The mode argument still round-
//     trips ("auto" | "links" | "text" | "full"), but formatting collapses
//     to "render whatever the snapshot has" — there is no `ElementIndexer`
//     walk to count hyperlinks with. See phase7-stashtools impl notes.
//   * `addAnnotation` accepts the four Everywhere source strings
//     (`pin`|`whiteboard`|`selected`|`linkrect`) and returns
//     `AnnotationOpResult(ok:, count:<queued>)`. Oversize / queue-depth
//     rejections surface as `ok:false` matching Everywhere's
//     `ToolErrors.Error(...)` short-circuit shape.
//   * `readAnnotations` peeks (does NOT consume) — mirrors Everywhere's
//     `AnnotationStash.Peek()` semantics. The MCP bridge wraps the
//     `[AnnotationItem]` result into the `{count, annotations:[]}` wire
//     shape at the JSON boundary.
//   * `readWhiteboard` consumes regions via `WhiteboardStash.take()`
//     but leaves the image bytes side-table alone (5-min TTL survives
//     the region consumption — required for the two-tool flow).
//   * `readWhiteboardImage(imageId:)` parses the string as `UUID` and
//     returns nil on unparseable or missing bytes (Everywhere keys by
//     string; the Swift stash keys by `UUID`).

import Foundation
import CoreGraphics

/// Wraps the three Layer-4 UX stashes with the six MCP-facing tool
/// methods. Namespace-only enum in the style of `OpenClickyMemoryTools`;
/// callers do not instantiate.
public enum OpenClickyStashTools {

    // MARK: - read_pick

    /// MCP tool name: `read_pick`. Reads and consumes the fresh pin.
    /// When the stash is empty (or the pin has expired) returns a
    /// `pinned:false` result. Mirrors Everywhere `ReadPickTool.ReadPick`
    /// (`ReadPickTool.cs:22-101`) collapsed to the fields the Swift
    /// `PickedElement` snapshot carries.
    ///
    /// - Parameters:
    ///   - mode: Output mode — `"auto"` (default), `"links"`, `"text"`,
    ///     or `"full"`. Case-insensitive; unknown values collapse to
    ///     `"full"` (matches Everywhere's `ResolveMode`
    ///     `ReadPickTool.cs:109-125`).
    ///   - includeTreeJson: When `true`, populate `treeJson` with a
    ///     JSON encoding of the picked element. Matches Everywhere's
    ///     `include_tree_json` (`ReadPickTool.cs:26, 78`).
    ///   - stash: Injection point for tests. Defaults to the
    ///     process-wide singleton.
    public static func readPick(
        mode: String = "auto",
        includeTreeJson: Bool = false,
        stash: PickStash = .shared
    ) -> ReadPickResult {
        // Divergence from Everywhere: read_pick is idempotent / peek-only.
        // The realtime voice model may call read_pick multiple times per
        // turn (verify, elaborate, follow-up). Draining on each read
        // would silently lose the pin between calls. User manually
        // clears via Alt+C.
        let all = stash.peekAll()
        guard let latest = all.last else {
            // Everywhere returns `{pinned:false, picked_index:null,
            // app:null, element:null}` here; we match by leaving all
            // optionals nil.
            return ReadPickResult(pinned: false, consumedPin: false)
        }

        let resolved = resolvePickMode(mode)
        let appKey = pickAppKey(from: latest)
        // Latest pin as the legacy single-element view.
        let elementDict = buildElementDict(from: latest, mode: resolved)
        // Full list — divergence from Everywhere (multi-pin support).
        let elementsList = all.map { buildElementDict(from: $0, mode: resolved) }
        let treeJson: String?
        if includeTreeJson {
            treeJson = encodePickedElementJson(latest)
        } else {
            treeJson = nil
        }

        return ReadPickResult(
            pinned: true,
            pickedIndex: resolved,
            app: appKey,
            element: elementDict,
            elements: elementsList,
            treeJson: treeJson,
            consumedPin: false
        )
    }

    // MARK: - add_annotation

    /// MCP tool name: `add_annotation`. Queue a user note against a
    /// perception anchor. Mirrors Everywhere `AddAnnotationTool.AddAnnotation`
    /// (`AddAnnotationTool.cs:22-57`).
    ///
    /// Returns `AnnotationOpResult(ok:true, count:<post-insert count>)`
    /// on success. `ok == false, count == currentCount` on validation
    /// failure or stash rejection — mirrors Everywhere's
    /// `ToolErrors.Error(...)` short-circuit but keeps the tool
    /// non-throwing at the Swift boundary so the bridge can serialise
    /// uniformly.
    ///
    /// - Parameters:
    ///   - source: One of `"pin"`, `"whiteboard"`, `"selected"`,
    ///     `"linkrect"` (case-insensitive). Unknown values fail closed.
    ///   - body: Free-form note text. Trimmed; empty rejected.
    ///   - anchorLabel: Short human-readable target description.
    ///     Trimmed; empty rejected.
    ///   - anchorRef: Optional opaque id for the anchor. Trimmed;
    ///     empty string collapses to nil (matches
    ///     `AddAnnotationTool.cs:46`).
    ///   - stash: Injection point for tests.
    public static func addAnnotation(
        source: String,
        body: String,
        anchorLabel: String,
        anchorRef: String?,
        stash: AnnotationStash = .shared
    ) -> AnnotationOpResult {
        // Everywhere validates in order: source, body, anchor_label.
        // Empty-or-whitespace fails each check.
        let sourceTrimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceTrimmed.isEmpty {
            return AnnotationOpResult(ok: false, count: stash.count)
        }
        guard let parsedSource = parseAnnotationSource(sourceTrimmed) else {
            return AnnotationOpResult(ok: false, count: stash.count)
        }
        let bodyTrimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if bodyTrimmed.isEmpty {
            return AnnotationOpResult(ok: false, count: stash.count)
        }
        let labelTrimmed = anchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if labelTrimmed.isEmpty {
            return AnnotationOpResult(ok: false, count: stash.count)
        }
        let refTrimmed: String? = {
            guard let raw = anchorRef?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            return raw
        }()

        let item = AnnotationItem(
            source: parsedSource,
            body: bodyTrimmed,
            anchorRef: refTrimmed,
            anchorLabel: labelTrimmed,
            capturedAt: Date()
        )
        do {
            let queued = try stash.append(item)
            return AnnotationOpResult(ok: true, count: queued)
        } catch {
            return AnnotationOpResult(ok: false, count: stash.count)
        }
    }

    // MARK: - read_annotations

    /// MCP tool name: `read_annotations`. Snapshot the queued
    /// annotations WITHOUT consuming them. Mirrors Everywhere
    /// `ReadAnnotationsTool.ReadAnnotations` (`ReadAnnotationsTool.cs:19-33`).
    ///
    /// The MCP bridge wraps the result as `{count, annotations:[...]}`
    /// at the JSON boundary; the value-type return keeps tests simple.
    public static func readAnnotations(
        stash: AnnotationStash = .shared
    ) -> [AnnotationItem] {
        stash.peek()
    }

    // MARK: - clear_annotations

    /// MCP tool name: `clear_annotations`. Drop every queued annotation.
    /// Returns `AnnotationOpResult(ok:true, count:<pre-clear count>)`,
    /// matching Everywhere's `{cleared:<int>}` payload
    /// (`ClearAnnotationsTool.cs:16-22`).
    public static func clearAnnotations(
        stash: AnnotationStash = .shared
    ) -> AnnotationOpResult {
        let before = stash.count
        stash.clearWithEvent()
        return AnnotationOpResult(ok: true, count: before)
    }

    // MARK: - read_whiteboard

    /// MCP tool name: `read_whiteboard`. Consumes the pending region
    /// slot and renders one markdown block per region. Image bytes
    /// side-table survives the consumption (5-min TTL shared with the
    /// region slot). Mirrors Everywhere `ReadWhiteboardTool.ReadWhiteboard`
    /// (`ReadWhiteboardTool.cs:22-191`) collapsed to the fields the
    /// Swift `WhiteboardRegion` value snapshot carries.
    public static func readWhiteboard(
        stash: WhiteboardStash = .shared
    ) -> ReadWhiteboardResult {
        guard let regions = stash.take() else {
            return ReadWhiteboardResult(
                drawn: false,
                regionCount: 0,
                markdown: "",
                consumed: false
            )
        }
        let md = renderWhiteboardMarkdown(regions)
        return ReadWhiteboardResult(
            drawn: true,
            regionCount: regions.count,
            markdown: md,
            consumed: true
        )
    }

    // MARK: - read_whiteboard_image

    /// MCP tool name: `read_whiteboard_image`. Fetch the PNG bytes for
    /// one image surfaced by a prior `read_whiteboard` call. Mirrors
    /// Everywhere `ReadWhiteboardImageTool.ReadWhiteboardImage`
    /// (`ReadWhiteboardImageTool.cs:21-56`).
    ///
    /// Returns nil when `imageId` is not a valid UUID, the id is
    /// unknown, or the stash's shared TTL has expired.
    public static func readWhiteboardImage(
        imageId: String,
        stash: WhiteboardStash = .shared
    ) -> Data? {
        guard let uuid = UUID(uuidString: imageId) else { return nil }
        return stash.imageBytes(for: uuid)
    }

    // MARK: - private helpers

    /// Normalise the `mode` argument. Case-insensitive; unknown values
    /// collapse to `"full"`, matching Everywhere's `ResolveMode`
    /// (`ReadPickTool.cs:109-125`) with the walk-based "auto → links
    /// vs full" heuristic replaced by a simple "auto → full" fallback
    /// (no walked node list to count hyperlinks against).
    private static func resolvePickMode(_ requested: String) -> String {
        let m = requested
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch m {
        case "links", "text", "full":
            return m
        case "auto":
            return "full"
        default:
            return "full"
        }
    }

    /// Build the flattened `element` dict handed back in `ReadPickResult`.
    /// Keys mirror Everywhere's `FocusedContextResult` fields. Values are
    /// stringified so the envelope stays JSON primitive-only.
    private static func buildElementDict(
        from picked: PickedElement,
        mode: String
    ) -> [String: String] {
        var dict: [String: String] = [:]
        dict["mode"] = mode
        if let role = picked.role { dict["role"] = role }
        if let title = picked.title { dict["title"] = title }
        if let value = picked.value, !value.isEmpty { dict["value"] = value }
        if let bundle = picked.bundleId { dict["bundle_id"] = bundle }
        dict["pid"] = String(picked.pid)
        dict["bounds"] = formatBounds(picked.bounds)
        if mode == "text" || mode == "links" {
            // Skill-style markdown pipeline in Everywhere emits the
            // rendered subtree as `markdown`. The Swift snapshot has
            // just one node; surface its display name so consumers
            // treating this like a `browse` result see a usable line.
            let label = picked.title ?? picked.value ?? picked.role ?? ""
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                dict["markdown"] = mode == "links" ? "- \(trimmed)\n" : "\(trimmed)\n"
            } else {
                dict["markdown"] = ""
            }
        }
        return dict
    }

    /// `AppKey.FromProcessId(pid)` analogue. Everywhere prefers the
    /// bundle-id lowercased when available, falling back to the pid
    /// string; the Swift port surfaces the bundle id verbatim.
    private static func pickAppKey(from picked: PickedElement) -> String {
        if let bundle = picked.bundleId, !bundle.isEmpty {
            return bundle
        }
        return "pid:\(picked.pid)"
    }

    /// Round-trip encoding of the single `PickedElement` snapshot for
    /// `include_tree_json`. Uses the type's Codable synthesis so the
    /// JSON stays in sync with any future field additions.
    private static func encodePickedElementJson(_ picked: PickedElement) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(picked),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Deterministic pretty-print for a Quartz-space CGRect. Format:
    /// `"x,y wxh"` in integer points (matches the Everywhere
    /// `(empty-text leaf at X,Y WxH)` marker convention in
    /// `ReadWhiteboardTool.cs:135-138`).
    private static func formatBounds(_ rect: CGRect) -> String {
        let x = Int(rect.origin.x.rounded())
        let y = Int(rect.origin.y.rounded())
        let w = Int(rect.size.width.rounded())
        let h = Int(rect.size.height.rounded())
        return "\(x),\(y) \(w)x\(h)"
    }

    /// String → `AnnotationSource` enum. Matches Everywhere's
    /// `Enum.TryParse<AnnotationSource>(source, ignoreCase: true)`
    /// (`AddAnnotationTool.cs:36`) semantics against the four wire
    /// tokens `pin`/`whiteboard`/`selected`/`linkrect`.
    private static func parseAnnotationSource(_ raw: String) -> AnnotationSource? {
        switch raw.lowercased() {
        case "pin":         return .pin
        case "whiteboard":  return .whiteboard
        case "selected":    return .selected
        case "linkrect":    return .linkRect
        default:            return nil
        }
    }

    /// Render one markdown block per region. Header follows Everywhere's
    /// convention (`ReadWhiteboardTool.cs:43-49`):
    /// `"## Region N (kind-label, N leaves[, N images], confidence X.XX)"`.
    /// Body carries the region's OCR text when available, otherwise the
    /// empty-region marker used by Everywhere's fallback path
    /// (L133-138).
    private static func renderWhiteboardMarkdown(_ regions: [WhiteboardRegion]) -> String {
        var sb = ""
        for (i, r) in regions.enumerated() {
            let kindLabel = whiteboardKindLabel(r.gestureKind)
            // Swift stash carries at most one implicit "leaf" per region
            // (the region rect itself); leaf-count fidelity vs Everywhere
            // is lost at the value-snapshot boundary. Emit "1 leaf" so
            // the header shape stays parseable — see phase7 impl notes.
            sb.append("## Region \(i + 1) (\(kindLabel), 1 leaf)\n\n")
            let body = (r.ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                sb.append(body)
                if !body.hasSuffix("\n") {
                    sb.append("\n")
                }
            } else {
                // Empty-text region fallback, mirrors Everywhere's
                // `(empty-text leaf at X,Y WxH)` marker.
                sb.append("(empty-text leaf at \(formatBounds(r.bboxScreen)))\n")
            }
            sb.append("\n")
        }
        return sb
    }

    /// Maps the wire gesture-kind string onto the Everywhere kind
    /// label. Unknown values collapse to `"unknown gesture"`, matching
    /// `ReadWhiteboardTool.cs:262-269` `_ => "unknown gesture"`.
    private static func whiteboardKindLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "circle":    return "circle = emphasis"
        case "underline": return "underline = focus on a single line"
        case "arrow":     return "arrow = pointing at this leaf"
        case "x":         return "x = strike-through / exclude"
        default:          return "unknown gesture"
        }
    }
}
