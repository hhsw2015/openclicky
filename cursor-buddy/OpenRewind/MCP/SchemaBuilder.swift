// SchemaBuilder.swift — tiny DSL for JSON Schema fragments.
//
// MCP `tools/list` responses embed each tool's input schema as JSON
// Schema. Rather than declare these inline as string blobs (unreadable
// and error-prone), we build them with a handful of helpers that
// produce `[String: Any]` dictionaries `JSONSerialization` can encode.
//
// The DSL is intentionally minimal — just enough to describe the five
// MCP tools this server exposes. Extend as new tools land.

import Foundation

public enum JSONSchema {

    // MARK: primitive builders

    public static func string(description: String? = nil,
                              format: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "string"]
        if let description { d["description"] = description }
        if let format { d["format"] = format }
        return d
    }

    public static func integer(description: String? = nil,
                               minimum: Int? = nil,
                               maximum: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "integer"]
        if let description { d["description"] = description }
        if let minimum { d["minimum"] = minimum }
        if let maximum { d["maximum"] = maximum }
        return d
    }

    public static func number(description: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "number"]
        if let description { d["description"] = description }
        return d
    }

    public static func bool(description: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "boolean"]
        if let description { d["description"] = description }
        return d
    }

    /// Loose ISO-8601 / RFC-3339 date-time slot.
    ///
    /// We deliberately do NOT set `format: "date-time"` here. The parser
    /// side (`parseFlexibleDate` in Tools.swift) accepts several variants
    /// — RFC-3339 with `Z`, RFC-3339 with fractional seconds, naive
    /// datetimes without a timezone, and calendar days — so a strict
    /// schema-side regex would reject inputs the server can actually
    /// process. Keep this as plain `type: string` and let the impl vet
    /// the value.
    public static func iso8601(description: String? = nil) -> [String: Any] {
        string(description: description)
    }

    public static func stringArray(description: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "array",
                                "items": ["type": "string"]]
        if let description { d["description"] = description }
        return d
    }

    // MARK: composite

    public static func object(properties: [String: [String: Any]],
                              required: [String] = [],
                              description: String? = nil) -> [String: Any] {
        var d: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { d["required"] = required }
        if let description { d["description"] = description }
        return d
    }

    public static func array(of item: [String: Any],
                             description: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "array", "items": item]
        if let description { d["description"] = description }
        return d
    }
}

// MARK: - Tool registry

/// A single MCP tool descriptor as vended by `tools/list`.
public struct MCPToolDescriptor: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: [String: Any]

    // `[String: Any]` isn't Sendable-checked; instances of this struct
    // are created once at server init and never mutated afterwards.
    public init(name: String,
                title: String,
                description: String,
                inputSchema: [String: Any]) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Wire form emitted inside `tools/list`.
    public func toWire() -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

// MARK: - Schemas for the five OpenRewind tools

public enum OpenRewindToolSchemas {

    public static let search = JSONSchema.object(
        properties: [
            "query": JSONSchema.string(description: "FTS5 query. Words are AND-ed."),
            "from":  JSONSchema.iso8601(description: "Inclusive lower bound, ISO-8601."),
            "to":    JSONSchema.iso8601(description: "Inclusive upper bound, ISO-8601."),
            "limit": JSONSchema.integer(description: "Max hits (default 50).",
                                        minimum: 1, maximum: 500),
            "apps":  JSONSchema.stringArray(description: "Bundle ID filter — restrict to these apps."),
            "websites": JSONSchema.stringArray(description: "URL host substring filter."),
            "meeting":  JSONSchema.bool(description: "If true, restrict to frames flagged as inside a meeting."),
            "starredOnly": JSONSchema.bool(description: "If true, only starred frames."),
        ],
        required: ["query"],
        description: "Full-text search over captured OCR / AX text with Rewind-style scoping."
    )

    public static let timeline = JSONSchema.object(
        properties: [
            "from":  JSONSchema.iso8601(description: "Inclusive lower bound."),
            "to":    JSONSchema.iso8601(description: "Inclusive upper bound."),
            "limit": JSONSchema.integer(description: "Max frames (default 200).",
                                        minimum: 1, maximum: 2000)
        ],
        required: ["from", "to"],
        description: "Time-ordered slice of captured frames."
    )

    public static let aiContext = JSONSchema.object(
        properties: [
            "timestamp":    JSONSchema.iso8601(description: "Point in time to focus on."),
            "neighborhood": JSONSchema.integer(
                description: "Frames on either side of the anchor (default 5).",
                minimum: 0, maximum: 100)
        ],
        required: ["timestamp"],
        description: "AI-optimised context bundle around a moment."
    )

    public static let frame = JSONSchema.object(
        properties: [
            "id":               JSONSchema.integer(description: "Frame id from search/timeline."),
            "includeThumbnail": JSONSchema.bool(description: "Return base-64 JPEG thumbnail.")
        ],
        required: ["id"],
        description: "Full detail (OCR text + boxes + metadata) for one frame."
    )

    public static let summary = JSONSchema.object(
        properties: [
            "date": JSONSchema.string(description: "Calendar day, YYYY-MM-DD.")
        ],
        required: ["date"],
        description: "Daily recap: app minutes, keywords, meetings."
    )

    public static let resolveCitation = JSONSchema.object(
        properties: [
            "frameId": JSONSchema.integer(
                description: "Frame id from an assistant response, e.g. the 42 in [FRAME#42].",
                minimum: 1)
        ],
        required: ["frameId"],
        description: "Resolve a [FRAME#nn] citation to a deep-link, snippet, and thumbnail in one call."
    )

    public static let recap = JSONSchema.object(
        properties: [
            "date": JSONSchema.string(description: "Calendar day, YYYY-MM-DD.")
        ],
        required: ["date"],
        description: "Raw daily signals a host's Recap provider consumes to generate prose. Same fields as `openrewind.summary` but returns machine-readable arrays without any generated text."
    )

    public static let retentionInfo = JSONSchema.object(
        properties: [:],
        required: [],
        description: "Effective retention policy + cutoff. Host apps use this to warn users when their query targets already-purged history."
    )

    public static let currentContext = JSONSchema.object(
        properties: [
            "neighborhood": JSONSchema.integer(
                description: "Neighbours on either side (default 5).",
                minimum: 0, maximum: 100)
        ],
        required: [],
        description: "Full context bundle for whatever frame the Browser's playhead is currently on."
    )
}
