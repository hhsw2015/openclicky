// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// On-disk envelope schema. `ContextSnapshotPayload` + `PickedLink` +
// `PayloadAnnotation` from Everywhere's C# side, plus a `formatForHook`
// serialiser that emits the exact multi-line byte layout the openclicky-
// context-hook binary (and any Everywhere-hook binary trained on the same
// envelope shape) knows how to parse.
//
// All optional fields honour `JsonIgnoreCondition.WhenWritingNull` via
// `encodeIfPresent` — a `nil` never lands in the JSON output.

import Foundation

// MARK: - Payload records

/// Mirrors C# `ContextSnapshotPayload` record (`ContextStashWriter.cs:963-990`).
public struct OpenClickyContextSnapshotPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let capturedAtUtc: Date
    public let app: String?
    public let processId: Int32?
    public let windowTitle: String?
    public let url: String?
    public let selectedText: String?
    public let selectedApp: String?
    public let pinPending: Bool?
    public let whiteboardPending: Bool?
    public let whiteboardRegionCount: Int?
    public let pickedLinks: [OpenClickyPickedLink]?
    public let annotations: [OpenClickyPayloadAnnotation]?

    public init(
        schemaVersion: Int,
        capturedAtUtc: Date,
        app: String?,
        processId: Int32?,
        windowTitle: String?,
        url: String?,
        selectedText: String?,
        selectedApp: String?,
        pinPending: Bool? = nil,
        whiteboardPending: Bool? = nil,
        whiteboardRegionCount: Int? = nil,
        pickedLinks: [OpenClickyPickedLink]? = nil,
        annotations: [OpenClickyPayloadAnnotation]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAtUtc = capturedAtUtc
        self.app = app
        self.processId = processId
        self.windowTitle = windowTitle
        self.url = url
        self.selectedText = selectedText
        self.selectedApp = selectedApp
        self.pinPending = pinPending
        self.whiteboardPending = whiteboardPending
        self.whiteboardRegionCount = whiteboardRegionCount
        self.pickedLinks = pickedLinks
        self.annotations = annotations
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case capturedAtUtc = "captured_at_utc"
        case app
        case processId = "process_id"
        case windowTitle = "window_title"
        case url
        case selectedText = "selected_text"
        case selectedApp = "selected_app"
        case pinPending = "pin_pending"
        case whiteboardPending = "whiteboard_pending"
        case whiteboardRegionCount = "whiteboard_region_count"
        case pickedLinks = "picked_links"
        case annotations
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(OpenClickyStashDateFormatter.string(from: capturedAtUtc), forKey: .capturedAtUtc)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(processId, forKey: .processId)
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(selectedText, forKey: .selectedText)
        try c.encodeIfPresent(selectedApp, forKey: .selectedApp)
        try c.encodeIfPresent(pinPending, forKey: .pinPending)
        try c.encodeIfPresent(whiteboardPending, forKey: .whiteboardPending)
        try c.encodeIfPresent(whiteboardRegionCount, forKey: .whiteboardRegionCount)
        try c.encodeIfPresent(pickedLinks, forKey: .pickedLinks)
        try c.encodeIfPresent(annotations, forKey: .annotations)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let s = try c.decode(String.self, forKey: .capturedAtUtc)
        capturedAtUtc = OpenClickyStashDateFormatter.date(from: s) ?? Date()
        app = try c.decodeIfPresent(String.self, forKey: .app)
        processId = try c.decodeIfPresent(Int32.self, forKey: .processId)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        selectedText = try c.decodeIfPresent(String.self, forKey: .selectedText)
        selectedApp = try c.decodeIfPresent(String.self, forKey: .selectedApp)
        pinPending = try c.decodeIfPresent(Bool.self, forKey: .pinPending)
        whiteboardPending = try c.decodeIfPresent(Bool.self, forKey: .whiteboardPending)
        whiteboardRegionCount = try c.decodeIfPresent(Int.self, forKey: .whiteboardRegionCount)
        pickedLinks = try c.decodeIfPresent([OpenClickyPickedLink].self, forKey: .pickedLinks)
        annotations = try c.decodeIfPresent([OpenClickyPayloadAnnotation].self, forKey: .annotations)
    }
}

/// Mirrors C# `PickedLink` (`ContextStashWriter.cs:992-994`).
public struct OpenClickyPickedLink: Codable, Equatable, Sendable {
    public let url: String
    public let title: String?

    public init(url: String, title: String? = nil) {
        self.url = url
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case url, title }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

/// Mirrors C# `PayloadAnnotation` (`ContextStashWriter.cs:996-1001`).
public struct OpenClickyPayloadAnnotation: Codable, Equatable, Sendable {
    public let source: String
    public let body: String
    public let anchorLabel: String
    public let anchorRef: String?
    public let capturedAtUtc: Date

    public init(
        source: String,
        body: String,
        anchorLabel: String,
        anchorRef: String? = nil,
        capturedAtUtc: Date
    ) {
        self.source = source
        self.body = body
        self.anchorLabel = anchorLabel
        self.anchorRef = anchorRef
        self.capturedAtUtc = capturedAtUtc
    }

    enum CodingKeys: String, CodingKey {
        case source, body
        case anchorLabel = "anchor_label"
        case anchorRef = "anchor_ref"
        case capturedAtUtc = "captured_at"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(body, forKey: .body)
        try c.encode(anchorLabel, forKey: .anchorLabel)
        try c.encodeIfPresent(anchorRef, forKey: .anchorRef)
        try c.encode(OpenClickyStashDateFormatter.string(from: capturedAtUtc), forKey: .capturedAtUtc)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        body = try c.decode(String.self, forKey: .body)
        anchorLabel = try c.decode(String.self, forKey: .anchorLabel)
        anchorRef = try c.decodeIfPresent(String.self, forKey: .anchorRef)
        let s = try c.decode(String.self, forKey: .capturedAtUtc)
        capturedAtUtc = OpenClickyStashDateFormatter.date(from: s) ?? Date()
    }
}

// MARK: - Date formatter

/// C# `DateTimeOffset` round-trip format: `2026-07-22T10:00:00.000+00:00`.
/// `.iso8601` alone drops fractional seconds; we bolt them on manually to
/// mirror `System.Text.Json` default.
public enum OpenClickyStashDateFormatter {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

// MARK: - KnownApps

/// Per-app discovery rule — a title regex + a discovery URL. Mirrors
/// Everywhere's `McpServerSettings.KnownApp` record (`McpServerSettings.cs:15-19`).
/// The rich `OpenClickyKnownApp` UI type lives in cursor-buddy alongside the
/// Settings pane; this package-side value type is what `formatForHook`
/// receives so the pure serialiser has zero AppKit / UserDefaults dependency
/// and can be exercised from XCTest without booting the app.
public struct OpenClickyKnownAppRule: Sendable, Equatable {
    public let titlePattern: String
    public let discoverUrl: String

    public init(titlePattern: String, discoverUrl: String) {
        self.titlePattern = titlePattern
        self.discoverUrl = discoverUrl
    }
}

/// 1:1 port of `ContextStashWriter.ResolveDiscoveryUrl` +
/// `ContextStashWriter.ToStatePath` (`ContextStashWriter.cs:743-791`).
///
/// **ReDoS divergence from Everywhere.** Everywhere caps `Regex.IsMatch`
/// via `_knownAppRegexTimeout = TimeSpan.FromMilliseconds(100)`
/// (`ContextStashWriter.cs:754, :775-778`). Swift's `NSRegularExpression`
/// has no per-match timeout, so we instead:
///   1. Cap the input title we feed the engine to `redosInputCap`
///      characters (Everywhere titles are already bounded to 80 grapheme
///      clusters at sanitisation, so 512 raw chars is generous headroom).
///   2. Compile each pattern into an `NSRegularExpression` up front —
///      compilation is the ReDoS surface for well-formed input; the
///      match itself against a bounded 512-char string is O(pattern-
///      dependent) but cannot run away.
///   3. Skip patterns whose compilation throws (invalid syntax).
///
/// See docs/ROADMAP/.review-notes/F21-known-apps-2026-07-23.md.
public enum OpenClickyKnownAppResolver {

    /// Hard cap on the length of the title fed into any regex match.
    /// Keeps a pathological pattern from having unbounded input.
    static let redosInputCap: Int = 512

    /// Iterate `knownApps` in registration order, return the first entry
    /// whose `titlePattern` matches `appTitle` (case-insensitive). Blank
    /// pattern, blank URL, non-http(s) scheme, and unparseable regex are
    /// all silent skips — the next entry may still match.
    ///
    /// Mirrors `ContextStashWriter.cs:756-791`.
    public static func resolveDiscoveryUrl(
        appTitle: String?,
        knownApps: [OpenClickyKnownAppRule]
    ) -> (discoverUrl: String, statePath: String)? {
        guard let title = appTitle, !title.isEmpty, !knownApps.isEmpty else { return nil }
        // Bound the engine input so a pathological pattern can't run away
        // against an attacker-controlled 10MB window title. Substringing
        // on utf16 units keeps the NSRegularExpression range math simple.
        let capped: String
        if title.utf16.count > redosInputCap {
            let end = title.utf16.index(title.utf16.startIndex, offsetBy: redosInputCap)
            capped = String(title[..<title.index(title.startIndex, offsetBy:
                title.utf16.distance(from: title.utf16.startIndex, to: end))])
        } else {
            capped = title
        }
        let searchRange = NSRange(capped.startIndex..., in: capped)

        for rule in knownApps {
            if rule.titlePattern.isEmpty || rule.discoverUrl.isEmpty { continue }
            // Reject malformed / non-http URLs early — matches
            // `ContextStashWriter.cs:768-769`.
            guard let uri = URL(string: rule.discoverUrl),
                  let scheme = uri.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }

            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(
                    pattern: rule.titlePattern,
                    options: [.caseInsensitive]
                )
            } catch {
                // Invalid pattern syntax — silent skip, mirrors C#
                // `catch (ArgumentException)` branch (`ContextStashWriter.cs:785-788`).
                continue
            }

            if regex.firstMatch(in: capped, options: [], range: searchRange) != nil {
                return (rule.discoverUrl, toStatePath(rule.discoverUrl))
            }
        }
        return nil
    }

    /// Derive the fast-path agent-state URL from a discovery URL by
    /// substituting the well-known segment. Mirrors
    /// `ContextStashWriter.cs:743-751`.
    ///
    /// * `.../agent-skills`  -> `.../agent-state`
    /// * `.../xlb-perception` -> `.../agent-state`
    /// * `.../mcp/tools`     -> `http://localhost:5000/.well-known/agent-state`
    ///                          (openclicky-sensor advertises the tool suite; the
    ///                          live "recent view" state still comes from the
    ///                          xlinkBook Flask server itself)
    /// * anything else       -> return `discoverUrl` unchanged
    public static func toStatePath(_ discoverUrl: String) -> String {
        if let range = discoverUrl.range(of: "/agent-skills", options: [.caseInsensitive, .backwards]),
           range.upperBound == discoverUrl.endIndex {
            return discoverUrl[..<range.lowerBound] + "/agent-state"
        }
        if let range = discoverUrl.range(of: "/xlb-perception", options: [.caseInsensitive, .backwards]),
           range.upperBound == discoverUrl.endIndex {
            return discoverUrl[..<range.lowerBound] + "/agent-state"
        }
        if discoverUrl.range(of: "/mcp/tools", options: [.caseInsensitive]) != nil {
            return "http://localhost:5000/.well-known/agent-state"
        }
        return discoverUrl
    }
}

// MARK: - FormatForHook

/// 1:1 port of `ContextStashWriter.FormatForHook` (`ContextStashWriter.cs:618-735`).
/// Byte order is load-bearing — the hook binary reads the first line and
/// downstream tooling greps for individual `[openclicky-*]` prefixes.
public enum OpenClickyStashFormatter {

    public static let currentSchemaVersion: Int = 1

    /// Serialise a payload plus an optional KnownApps table into the
    /// on-disk envelope. `knownApps` defaults to empty so existing
    /// callers / tests keep working; the app's writer passes
    /// `OpenClickyContextAwarenessSettings.shared.knownApps` (bridged
    /// to `[OpenClickyKnownAppRule]`) to reach the `[openclicky-discover]`
    /// hint branch.
    public static func formatForHook(
        _ p: OpenClickyContextSnapshotPayload,
        knownApps: [OpenClickyKnownAppRule] = []
    ) -> String {
        var sb = ""

        // -- Header line ------------------------------------------------
        sb += "[openclicky-ctx] "
        if let app = p.app, !app.isEmpty {
            sb += "app=" + OpenClickySanitiser.sanitiseTokenValue(app, maxChars: 64) + " "
        }
        if let t = p.windowTitle, !t.isEmpty {
            sb += "title=\"" + OpenClickySanitiser.sanitiseUserText(t, maxChars: 80) + "\" "
        }
        if let u = p.url, !u.isEmpty {
            sb += "url=" + OpenClickySanitiser.sanitiseTokenValue(u, maxChars: 256) + " "
        }
        if let s = p.selectedText, !s.isEmpty {
            sb += "selection=\"" + OpenClickySanitiser.sanitiseUserText(s, maxChars: 200) + "\" "
        }
        if p.pinPending == true {
            sb += "pin_pending=true "
        }
        if p.whiteboardPending == true {
            // C# emits no trailing space here (ContextStashWriter.cs:637);
            // preserved verbatim.
            sb += "whiteboard_pending=true regions=\(p.whiteboardRegionCount ?? 0)"
        }
        if let links = p.pickedLinks, !links.isEmpty {
            sb += "picked_links=\(links.count) "
        }
        if let annos = p.annotations, !annos.isEmpty {
            sb += "annotations=\(annos.count) "
        }
        sb += "\n"

        // -- [openclicky-ctx-link] rows ---------------------------------
        if let links = p.pickedLinks, !links.isEmpty {
            for (i, l) in links.enumerated() {
                sb += "[openclicky-ctx-link] #\(i) "
                sb += "url=" + OpenClickySanitiser.sanitiseTokenValue(l.url, maxChars: 512) + " "
                if let t = l.title, !t.isEmpty {
                    sb += "title=\"" + OpenClickySanitiser.sanitiseUserText(t, maxChars: 120) + "\""
                }
                sb += "\n"
            }
        }

        // -- [openclicky-ctx-annotation] rows ---------------------------
        if let annos = p.annotations, !annos.isEmpty {
            for (i, a) in annos.enumerated() {
                sb += "[openclicky-ctx-annotation] #\(i) "
                sb += "source=" + OpenClickySanitiser.sanitiseTokenValue(a.source, maxChars: 32) + " "
                sb += "anchor=\"" + OpenClickySanitiser.sanitiseUserText(a.anchorLabel, maxChars: 200) + "\" "
                if let r = a.anchorRef, !r.isEmpty {
                    sb += "ref=" + OpenClickySanitiser.sanitiseTokenValue(r, maxChars: 96) + " "
                }
                sb += "body=\"" + OpenClickySanitiser.sanitiseUserText(a.body, maxChars: 800) + "\""
                sb += "\n"
            }
        }

        // -- Trailing JSON envelope (BEFORE hint block, mirrors Everywhere
        //    `ContextStashWriter.cs:677-679`). Order matters: hint reads
        //    are byte-scanned by client-side tooling that expects the
        //    JSON payload above the human-readable hint. Trailing `\n`
        //    keeps the JSON line terminated so the following hint block
        //    starts on its own line. -----------------------------------
        sb += "[openclicky-ctx-json] "
        sb += encodePayloadJSON(p)
        sb += "\n"

        // -- Hint block: exactly one of five, in priority order ---------
        // Copy is byte-ported from Everywhere `ContextStashWriter.cs:701-732`
        // with only the `everywhere` -> `openclicky` rebrand applied.
        //
        // KnownApps discovery: mirror Everywhere
        // `ContextStashWriter.cs:684-685` — resolve the app title against
        // the caller-supplied `knownApps` table, then derive the state
        // path from the matched discovery URL. First match wins;
        // priority-order below decides whether the pair is actually
        // rendered as a hint.
        let discoveryPair = OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: p.windowTitle,
            knownApps: knownApps
        )
        let discoveryUrl: String? = discoveryPair?.discoverUrl
        let statePath: String? = discoveryPair?.statePath

        if p.whiteboardPending == true {
            sb += "[openclicky-hint] User drew \(p.whiteboardRegionCount ?? 1) annotated region(s) on a virtual whiteboard for this agent. "
            sb += "CALL FIRST: mcp__openclicky__read_whiteboard — returns one markdown block "
            sb += "per region with the gesture's kind (circle=emphasis, x=exclude, arrow=point, "
            sb += "underline=focus on a single line) and the text the gesture captured. "
            sb += "This is one-shot; reading consumes the slot. "
            sb += "DO NOT use read_pick for whiteboard content — it's a different stash.\n"
        } else if p.pinPending == true, let state = statePath {
            sb += "[openclicky-hint] User pinned a UI element AND this is a known local web app. PREFER: GET "
            sb += state
            sb += "?consume=1 — returns markdown of recent view + pin contents (urls/labels). For deeper exploration of the topic (graph connections, tag groups, curated commands), follow up with the same URL plus &with_meta=1, or call the app's browse skill on the topic. Don't fetch meta unless the user actually needs it.\n"
        } else if p.pinPending == true {
            sb += "[openclicky-hint] The user pinned a UI element for this question. Call the OpenClicky MCP `read_pick` tool with mode='auto' (default) — for a popup of links it auto-returns a compact url+label list (~30 tokens), not the full a11y tree.\n"
        } else if let discovery = discoveryUrl, let state = statePath {
            sb += "[openclicky-discover] openclicky-style local app self-describes at "
            sb += discovery
            sb += ". Fast path: GET "
            sb += state
            sb += "?consume=1 — recent view + interactions as markdown. For deeper exploration (search, topic content, tag sections, graph, agent state, command execution), the OpenClicky sensor MCP exposes an equivalent xlb tool suite: xlb_search_topic, xlb_get_topic, xlb_get_topic_meta, xlb_get_topic_section, xlb_graph, xlb_agent_state, xlb_execute_command, xlb_grammar_help. Prefer these over fetching the discovery URL or shelling into a skill CLI — the MCP tools are faster, token-budgeted, and semantically identical.\n"
        } else {
            sb += "[openclicky-hint] If the user's question needs more than this pointer, call the relevant OpenClicky MCP tool — don't guess.\n"
        }

        return sb
    }

    private static func encodePayloadJSON(_ p: OpenClickyContextSnapshotPayload) -> String {
        let encoder = JSONEncoder()
        // Preserve insertion order (Codable emits keys in the order they
        // appear in the `encode(to:)` method above, which mirrors the C#
        // record property declaration order in
        // `ContextStashWriter.cs:963-990`). Everywhere-parity fingerprint
        // diffs against the same logical payload require identical key
        // ordering, so `.sortedKeys` must NOT be set.
        do {
            let data = try encoder.encode(p)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
}
