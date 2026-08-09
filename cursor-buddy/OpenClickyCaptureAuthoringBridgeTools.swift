//
//  OpenClickyCaptureAuthoringBridgeTools.swift
//  cursor-buddy
//
//  Phase 7.6+ F36 — MCP tool implementations for the capture pipeline
//  (capture_* long-tail).
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//    * src/Everywhere.Mcp/Tools/CaptureTools.cs:54-268 — Everywhere's
//      four browser-tied capture tools: `capture_start`,
//      `capture_stop`, `capture_current`, `capture_export`. These
//      manage a browser-tab-bound CaptureSession backed by
//      CaptureSessionStore, running signature hooks + a background
//      poller over the OpenDia bridge.
//
//  Note: Everywhere does NOT ship a `capture_draft/publish/list/delete/run`
//  authoring surface. Those tool names come from the F36 brief; per
//  the "genuinely absent in Everywhere" fallback clause, we ship
//  them as an openclicky-only user-editable capture template store
//  layered on top of Everywhere's four upstream tools. The
//  templates are lightweight JSON descriptors under
//  `~/Library/Application Support/OpenClicky/captures/` — they are
//  NOT a replacement for Everywhere's CaptureSessionStore, which is
//  the runtime capture channel and stays unimplemented until F14/F16
//  extend to that layer.
//
//  Storage:
//    * ~/Library/Application Support/OpenClicky/captures/<name>.json
//      — one file per user-defined capture template.
//
//  The four Everywhere-upstream tools currently return NOT_IMPLEMENTED
//  envelopes because the backing CaptureSessionStore / signature-hook
//  orchestrator / background poller are not yet ported into
//  openclicky. When they land, this file is the switchboard.
//

import Foundation
import OpenClickyContextService

enum OpenClickyCaptureAuthoringBridgeTools {

    // MARK: - Tool name set

    static let toolNames: Set<String> = [
        // Everywhere upstream:
        "capture_start",
        "capture_stop",
        "capture_current",
        "capture_export",
        // openclicky extensions — user-defined capture templates:
        "capture_draft",
        "capture_publish",
        "capture_list",
        "capture_delete",
        "capture_run"
    ]

    // MARK: - Tool descriptors (MCP tools/list shape)

    static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "capture_start",
                "description":
                    "Start an openclicky capture session bound to a browser tab. Installs the signature-capture " +
                    "hook via OpenDia. Returns {session_id}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "integer", "description": "Chrome tab id. Optional; active tab is auto-detected via get_url when omitted."],
                        "origin": ["type": "string", "description": "Top-frame origin. Optional; auto-detected from the tab URL when omitted."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "capture_stop",
                "description":
                    "Finalize a capture session, drain the signature hook, return sanitized CaptureSession JSON. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Session id from capture_start."]
                    ] as [String: Any],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "capture_current",
                "description":
                    "Live snapshot of a running capture without stopping it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string"]
                    ] as [String: Any],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "capture_export",
                "description":
                    "Write the session's sanitized JSON to ~/Library/Application Support/OpenClicky/captures/<session_id>.json. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string"]
                    ] as [String: Any],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "capture_draft",
                "description":
                    "openclicky extension: draft a user-defined capture template (name + selector + region). " +
                    "Stored under ~/Library/Application Support/OpenClicky/captures/<name>.json.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Template name (unique per user)."],
                        "selector": ["type": "string", "description": "Optional CSS/XPath selector applied during capture_run."],
                        "region": [
                            "type": "object",
                            "description": "Optional screen region {x, y, width, height} in points.",
                            "properties": [
                                "x": ["type": "number"],
                                "y": ["type": "number"],
                                "width": ["type": "number"],
                                "height": ["type": "number"]
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ],
            [
                "name": "capture_publish",
                "description":
                    "openclicky extension: promote a previously drafted capture template to the published lifecycle " +
                    "state. Requires the template to already exist (via capture_draft). Sets `status: \"published\"` " +
                    "in the on-disk JSON so capture_list can filter.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ],
            [
                "name": "capture_list",
                "description":
                    "openclicky extension: list user-defined capture templates on disk. Returns published " +
                    "templates by default; pass include_drafts=true to include drafts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "include_drafts": ["type": "boolean", "description": "Include draft templates alongside published ones (default false)."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "capture_delete",
                "description":
                    "openclicky extension: delete a user-defined capture template.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ],
            [
                "name": "capture_run",
                "description":
                    "openclicky extension: execute a saved capture template. Currently a scaffolding stub — " +
                    "returns NOT_IMPLEMENTED once the screen-capture runner is wired.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            return errorEnvelope(code: "SELFEXPAND_DISABLED",
                                 message: "capture tools are gated by OPENCLICKY_MCP_SELFEXPAND=0",
                                 extras: ["tool": name])
        }
        guard toolNames.contains(name) else {
            return errorEnvelope(code: "UNKNOWN_TOOL",
                                 message: "'\(name)' is not a registered capture_* tool",
                                 extras: ["tool": name])
        }

        switch name {
        // Everywhere upstream — awaiting CaptureSessionStore port.
        case "capture_start":   return handleCaptureStart(args: arguments)
        case "capture_stop":    return handleCaptureStop(args: arguments)
        case "capture_current": return handleCaptureCurrent(args: arguments)
        case "capture_export":  return handleCaptureExport(args: arguments)

        // openclicky extension — template store (usable today).
        case "capture_draft":   return handleDraft(args: arguments)
        case "capture_publish": return handlePublish(args: arguments)
        case "capture_list":    return handleList(args: arguments)
        case "capture_delete":  return handleDelete(args: arguments)
        case "capture_run":     return handleRun(args: arguments)

        default:
            return errorEnvelope(code: "UNKNOWN_TOOL",
                                 message: "unhandled capture_* tool '\(name)'",
                                 extras: ["tool": name])
        }
    }

    // MARK: - Upstream-shape handlers (NOT_IMPLEMENTED)

    private static func handleCaptureStart(args: [String: Any]) -> ([String: Any], Bool) {
        return errorEnvelope(
            code: "NOT_IMPLEMENTED",
            message: "capture_start requires CaptureSessionStore + OpenDia signature-hook orchestrator — awaiting port.",
            extras: [
                "tab_id": args["tab_id"] as Any,
                "origin": args["origin"] as Any
            ])
    }

    private static func handleCaptureStop(args: [String: Any]) -> ([String: Any], Bool) {
        guard let sessionId = args["session_id"] as? String, !sessionId.isEmpty else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_stop requires session_id")
        }
        return errorEnvelope(code: "SESSION_NOT_FOUND",
                             message: "no capture session store (backing service unimplemented).",
                             extras: ["session_id": sessionId])
    }

    private static func handleCaptureCurrent(args: [String: Any]) -> ([String: Any], Bool) {
        guard let sessionId = args["session_id"] as? String, !sessionId.isEmpty else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_current requires session_id")
        }
        return errorEnvelope(code: "SESSION_NOT_FOUND",
                             message: "no capture session store (backing service unimplemented).",
                             extras: ["session_id": sessionId])
    }

    private static func handleCaptureExport(args: [String: Any]) -> ([String: Any], Bool) {
        guard let sessionId = args["session_id"] as? String, !sessionId.isEmpty else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_export requires session_id")
        }
        return errorEnvelope(code: "SESSION_NOT_FOUND",
                             message: "no capture session store (backing service unimplemented).",
                             extras: ["session_id": sessionId])
    }

    // MARK: - openclicky-extension handlers

    /// Persist a template with `status: "draft"`. Overwrites any
    /// existing entry — matches Everywhere's upsert semantic for
    /// user-owned adapter templates.
    private static func handleDraft(args: [String: Any]) -> ([String: Any], Bool) {
        guard let name = args["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CaptureTemplateStore.isSafeName(name) else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_draft requires a safe non-empty name (letters/digits/dashes/dots/underscores).")
        }
        let selector = args["selector"] as? String
        var region: CaptureTemplate.Region?
        if let obj = args["region"] as? [String: Any] {
            let x = numeric(obj["x"]) ?? 0
            let y = numeric(obj["y"]) ?? 0
            let w = numeric(obj["width"]) ?? 0
            let h = numeric(obj["height"]) ?? 0
            region = CaptureTemplate.Region(x: x, y: y, width: w, height: h)
        }
        let template = CaptureTemplate(
            schemaVersion: "1",
            name: name,
            selector: selector,
            region: region,
            status: CaptureTemplate.Status.draft
        )
        do {
            let path = try CaptureTemplateStore.shared.save(template)
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "name": name,
                "status": CaptureTemplate.Status.draft,
                "path": path.path
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "STORE_ERROR",
                                 message: error.localizedDescription,
                                 extras: ["name": name])
        }
    }

    /// Promote an existing draft to `status: "published"`. Refuses if
    /// the template does not exist yet (callers must draft first).
    private static func handlePublish(args: [String: Any]) -> ([String: Any], Bool) {
        guard let name = args["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CaptureTemplateStore.isSafeName(name) else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_publish requires a safe non-empty name.")
        }
        guard let existing = CaptureTemplateStore.shared.load(name: name) else {
            return errorEnvelope(code: "TEMPLATE_NOT_FOUND",
                                 message: "no capture template named '\(name)' — call capture_draft first.",
                                 extras: ["name": name])
        }
        let promoted = CaptureTemplate(
            schemaVersion: existing.schemaVersion ?? "1",
            name: existing.name,
            selector: existing.selector,
            region: existing.region,
            status: CaptureTemplate.Status.published
        )
        do {
            let path = try CaptureTemplateStore.shared.save(promoted)
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "name": name,
                "status": CaptureTemplate.Status.published,
                "path": path.path
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "STORE_ERROR",
                                 message: error.localizedDescription,
                                 extras: ["name": name])
        }
    }

    /// List templates. Default: published only. Pass
    /// `include_drafts=true` to include drafts alongside.
    private static func handleList(args: [String: Any]) -> ([String: Any], Bool) {
        let includeDrafts: Bool = {
            if let b = args["include_drafts"] as? Bool { return b }
            if let n = args["include_drafts"] as? NSNumber { return n.boolValue }
            if let s = args["include_drafts"] as? String {
                return s.lowercased() == "true" || s == "1"
            }
            return false
        }()
        let all = CaptureTemplateStore.shared.listAll()
        let filtered = all.filter { t in
            // Treat missing status as "draft" (older files pre-status).
            let status = t.status ?? CaptureTemplate.Status.draft
            return includeDrafts || status == CaptureTemplate.Status.published
        }
        let arr = filtered.map { t -> [String: Any] in
            var row: [String: Any] = [
                "name": t.name,
                "status": t.status ?? CaptureTemplate.Status.draft
            ]
            if let sel = t.selector { row["selector"] = sel }
            if let r = t.region {
                row["region"] = ["x": r.x, "y": r.y, "width": r.width, "height": r.height] as [String: Any]
            }
            return row
        }
        let body: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "captures": arr
        ]
        return (textEnvelope(from: body), false)
    }

    private static func handleDelete(args: [String: Any]) -> ([String: Any], Bool) {
        guard let name = args["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CaptureTemplateStore.isSafeName(name) else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_delete requires a safe non-empty name")
        }
        do {
            let removed = try CaptureTemplateStore.shared.delete(name: name)
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "name": name,
                "existed": removed
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "STORE_ERROR",
                                 message: error.localizedDescription,
                                 extras: ["name": name])
        }
    }

    private static func handleRun(args: [String: Any]) -> ([String: Any], Bool) {
        guard let name = args["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CaptureTemplateStore.isSafeName(name) else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "capture_run requires a safe non-empty name")
        }
        guard let template = CaptureTemplateStore.shared.load(name: name) else {
            return errorEnvelope(code: "TEMPLATE_NOT_FOUND",
                                 message: "no capture template named '\(name)'",
                                 extras: ["name": name])
        }
        // Runner is not wired to ScreenCaptureKit / OpenDia yet — surface
        // NOT_IMPLEMENTED but echo the loaded template so callers can
        // verify wiring end-to-end.
        var templateJson: [String: Any] = ["name": template.name]
        if let sel = template.selector { templateJson["selector"] = sel }
        if let r = template.region {
            templateJson["region"] = ["x": r.x, "y": r.y, "width": r.width, "height": r.height] as [String: Any]
        }
        return errorEnvelope(
            code: "NOT_IMPLEMENTED",
            message: "capture_run needs a ScreenCaptureKit + OpenDia runner — template loaded, execution pending.",
            extras: ["template": templateJson])
    }

    // MARK: - Envelope helpers

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }

    private static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    /// Error envelope aligned to Everywhere's shape
    /// (`{ok:false, code, message}` — `CaptureTools.cs:420`).
    private static func errorEnvelope(code: String, message: String, extras: [String: Any] = [:]) -> ([String: Any], Bool) {
        var body: [String: Any] = [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "message": message
        ]
        for (k, v) in extras { body[k] = v }
        return (textEnvelope(from: body), true)
    }
}

// MARK: - Capture template model + store

struct CaptureTemplate: Codable, Sendable {
    /// Lifecycle marker distinguishing drafts from published entries.
    /// String constants (not enum) so JSON round-trips a plain string.
    enum Status {
        static let draft = "draft"
        static let published = "published"
    }

    struct Region: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    let schemaVersion: String?
    let name: String
    let selector: String?
    let region: Region?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case selector
        case region
        case status
    }
}

/// Local disk store for user-defined capture templates. This is the
/// F36 openclicky-extension surface and has no upstream Everywhere
/// counterpart.
final class CaptureTemplateStore: @unchecked Sendable {

    static let shared = CaptureTemplateStore()

    private let dir: URL
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.dir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Regex-based name gate — same shape as
    /// Everywhere's Identifier guard. Blocks path traversal and
    /// shell-hostile characters.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        for c in name {
            let ok = c.isLetter || c.isNumber || c == "-" || c == "_" || c == "."
            if !ok { return false }
        }
        return !name.hasPrefix(".") && !name.contains("..")
    }

    func fileURL(for name: String) -> URL {
        dir.appendingPathComponent("\(name).json", isDirectory: false)
    }

    func save(_ template: CaptureTemplate) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(template)
        let url = fileURL(for: template.name)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        return url
    }

    func load(name: String) -> CaptureTemplate? {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(for: name)
        guard let data = try? Data(contentsOf: url),
              let t = try? JSONDecoder().decode(CaptureTemplate.self, from: data) else {
            return nil
        }
        return t
    }

    @discardableResult
    func delete(name: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    func listAll() -> [CaptureTemplate] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [CaptureTemplate] = []
        for f in files where f.hasSuffix(".json") {
            let url = dir.appendingPathComponent(f)
            if let data = try? Data(contentsOf: url),
               let t = try? JSONDecoder().decode(CaptureTemplate.self, from: data) {
                out.append(t)
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}
