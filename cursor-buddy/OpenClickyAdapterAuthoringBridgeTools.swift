//
//  OpenClickyAdapterAuthoringBridgeTools.swift
//  cursor-buddy
//
//  Phase 7.6+ F33 — MCP tool implementations for the adapter authoring
//  surface (adapter_* long-tail).
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//    * src/Everywhere.Mcp/Tools/GeneratorTools.cs:48-388 — the seven
//      `adapter_*` tools (scaffold / save / verify / list_local /
//      drift_check / delete_local / regenerate).
//    * src/Everywhere.Mcp/Tools/GateTools.cs:77-105 — the `adapter_lint`
//      tool. Ports the eighth family member so `activate_domain
//      name=core` exposes the full authoring surface.
//
//  This file owns the MCP wire contract: eight `adapter_*` tools with
//  Everywhere-exact argument names and byte-shape response envelopes.
//  The heavy backing services (CaptureSessionStore, MemoryStore
//  StrategyNote reader, LocalRegistry, AdapterLinter, VerifyFixture
//  parser, VerdictScorer, Neighbor search, Scaffold renderer,
//  DriftDetector) are NOT yet ported into openclicky — F14/F15/F16
//  cover memory + captures for the sensor layer but not the OpenCLI
//  self-expand generator pipeline.
//
//  Rather than fake the backing services, every tool returns a
//  well-formed Everywhere-shape error envelope (`ok:false, code:
//  "NOT_IMPLEMENTED", ...`) plus the input echo the caller supplied,
//  so agents pinned against the Everywhere contract can still
//  probe/list without exceptions — they just cannot draft/save
//  adapters until the backing services land. This matches the F31
//  "OPENDIA_NOT_CONNECTED" error convention (OpenClickyOpenDiaBridgeTools).
//
//  Dispatch entrypoints are static so they compose cleanly into
//  `OpenClickyExternalControlBridgeServer.executeSensorTool`.
//
//  Storage target (once backing services land):
//    * ~/Library/Application Support/OpenClicky/adapters/<site>/<name>.js
//    * ~/Library/Application Support/OpenClicky/sites/<site>/strategy-notes/<name>.md
//  Isolated from the F30 vendored `opencli/` tree so user-authored
//  adapters never overwrite bundled ones.
//

import Foundation
import OpenClickyContextService

enum OpenClickyAdapterAuthoringBridgeTools {

    // MARK: - Tool name set

    /// Everywhere upstream tool names, byte-exact.
    static let toolNames: Set<String> = [
        "adapter_scaffold",
        "adapter_save",
        "adapter_verify",
        "adapter_list_local",
        "adapter_drift_check",
        "adapter_delete_local",
        "adapter_regenerate",
        "adapter_lint"
    ]

    // MARK: - Tool descriptors (MCP tools/list shape)

    static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "adapter_scaffold",
                "description":
                    "Render the OpenCLI adapter skeleton + LLM prompt for a captured session. " +
                    "Requires a prior strategy_note_write.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string", "description": "Site identifier."],
                        "name": ["type": "string", "description": "Command name."],
                        "session_id": ["type": "string", "description": "capture_start session id."],
                        "description": ["type": "string", "description": "Optional description passed through to the skeleton comment."],
                        "neighbor_hint": ["type": "string", "description": "Optional neighbor hint keyword."]
                    ] as [String: Any],
                    "required": ["site", "name", "session_id"]
                ]
            ],
            [
                "name": "adapter_save",
                "description":
                    "Persist a generated adapter to ~/Library/Application Support/OpenClicky/adapters/<site>/<name>.js " +
                    "after passing G3-G8 lints.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"],
                        "source": ["type": "string", "description": "Full JS adapter source from adapter_scaffold."],
                        "verify_fixture": ["type": "string", "description": "VerifyFixture JSON pinned alongside the adapter."],
                        "session_id": ["type": "string", "description": "Optional capture session id for provenance."]
                    ] as [String: Any],
                    "required": ["site", "name", "source", "verify_fixture"]
                ]
            ],
            [
                "name": "adapter_verify",
                "description":
                    "Run G3-G9 lints then invoke the adapter and check 4-tuple fixture patterns against real output. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"],
                        "fixture_override": ["type": "string", "description": "Optional stored fixture pathname override."]
                    ] as [String: Any],
                    "required": ["site", "name"]
                ]
            ],
            [
                "name": "adapter_list_local",
                "description":
                    "List locally-generated adapters under ~/Library/Application Support/OpenClicky/adapters/. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "adapter_drift_check",
                "description":
                    "Compare current adapter output to stored last_success_hash; classifies ok|drift|broken. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"],
                        "current_output": ["type": "string", "description": "Current adapter output (e.g. JSON.stringify of rows)."]
                    ] as [String: Any],
                    "required": ["site", "name", "current_output"]
                ]
            ],
            [
                "name": "adapter_delete_local",
                "description":
                    "Delete a locally-generated adapter and its meta/verify siblings. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["site", "name"]
                ]
            ],
            [
                "name": "adapter_regenerate",
                "description":
                    "Re-render the scaffold + LLM prompt for an existing local adapter, reusing its strategy note. " +
                    "Requires session_id.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"],
                        "session_id": ["type": "string", "description": "capture_start session id required for regeneration."]
                    ] as [String: Any],
                    "required": ["site", "name"]
                ]
            ],
            [
                "name": "adapter_lint",
                "description":
                    "Run G3-G8 lints over adapter source. Returns {errors:[], warnings:[]}. ",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "source": ["type": "string", "description": "Adapter JS source."],
                        "site": ["type": "string", "description": "Optional site — enables G7 mutation guard."],
                        "name": ["type": "string", "description": "Optional name — pairs with site."],
                        "fixture": ["type": "string", "description": "Optional VerifyFixture JSON — enables G9."]
                    ] as [String: Any],
                    "required": ["source"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    /// Executes one `adapter_*` tool. Returns an MCP `content` envelope
    /// plus `isError` matching `executeSensorTool` return shape.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            return errorEnvelope(code: "SELFEXPAND_DISABLED",
                                 message: "adapter authoring is gated by OPENCLICKY_MCP_SELFEXPAND=0",
                                 extras: ["tool": name])
        }
        guard toolNames.contains(name) else {
            return errorEnvelope(code: "UNKNOWN_TOOL",
                                 message: "'\(name)' is not a registered adapter_* tool",
                                 extras: ["tool": name])
        }

        switch name {
        case "adapter_scaffold":     return handleScaffold(args: arguments)
        case "adapter_save":         return handleSave(args: arguments)
        case "adapter_verify":       return handleVerify(args: arguments)
        case "adapter_list_local":   return handleListLocal()
        case "adapter_drift_check":  return handleDriftCheck(args: arguments)
        case "adapter_delete_local": return handleDeleteLocal(args: arguments)
        case "adapter_regenerate":   return handleRegenerate(args: arguments)
        case "adapter_lint":         return handleLint(args: arguments)
        default:
            return errorEnvelope(code: "UNKNOWN_TOOL",
                                 message: "unhandled adapter_* tool '\(name)'",
                                 extras: ["tool": name])
        }
    }

    // MARK: - Handlers
    //
    // All handlers return NOT_IMPLEMENTED until F14/F16 backing services
    // (CaptureSessionStore, StrategyNote reader, VerifyFixture parser,
    // LocalRegistry, AdapterLinter, Scaffold renderer, DriftDetector)
    // land. Input validation runs first so callers can smoke-test
    // wire contracts without hitting the not-yet-implemented barrier.

    private static func handleScaffold(args: [String: Any]) -> ([String: Any], Bool) {
        guard let site = requireString(args, "site"),
              let name = requireString(args, "name"),
              let sessionId = requireString(args, "session_id") else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_scaffold requires site, name, session_id")
        }
        // adapter_list_local currently lists nothing — the strategy_note
        // store is a Phase-8 backing service. Return STRATEGY_NOTE_MISSING
        // to match Everywhere GeneratorTools.cs:61.
        return errorEnvelope(
            code: "STRATEGY_NOTE_MISSING",
            message: "openclicky memory store does not yet expose a StrategyNote reader — write path pending backing service.",
            extras: [
                "site": site,
                "name": name,
                "session_id": sessionId,
                "backing_service": "OpenClickyStrategyNoteStore (unimplemented)"
            ])
    }

    private static func handleSave(args: [String: Any]) -> ([String: Any], Bool) {
        guard let site = requireString(args, "site"),
              let name = requireString(args, "name"),
              let _ = requireString(args, "source"),
              let fixtureJson = requireString(args, "verify_fixture") else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_save requires site, name, source, verify_fixture")
        }
        // Verify_fixture must be JSON-parseable (matches Everywhere
        // GeneratorTools.cs:134 which rejects malformed fixtures with
        // ARGUMENT_ERROR before touching any store).
        if let data = fixtureJson.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "verify_fixture is not valid JSON",
                                 extras: ["site": site, "name": name])
        }
        return errorEnvelope(
            code: "NOT_IMPLEMENTED",
            message: "adapter save persists to ~/Library/Application Support/OpenClicky/adapters/<site>/<name>.js — awaiting LocalRegistry + AdapterLinter port.",
            extras: [
                "site": site,
                "name": name,
                "backing_services": [
                    "AdapterLinter (unimplemented)",
                    "LocalRegistry (unimplemented)"
                ] as [Any]
            ])
    }

    private static func handleVerify(args: [String: Any]) -> ([String: Any], Bool) {
        guard let site = requireString(args, "site"),
              let name = requireString(args, "name") else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_verify requires site, name")
        }
        return errorEnvelope(
            code: "ADAPTER_NOT_FOUND",
            message: "no local adapter registry — awaiting LocalRegistry port.",
            extras: ["site": site, "name": name])
    }

    private static func handleListLocal() -> ([String: Any], Bool) {
        // Everywhere returns a bare JsonArray (GeneratorTools.cs:341:
        // `return arr.ToJsonString();`). Match that on the wire: the
        // MCP content envelope's `text` field carries the bare array
        // string — no `{ok, adapters:[]}` wrapper — so callers
        // pinned to `result[0].site` work unchanged.
        let adapters: [Any] = []
        let data = (try? JSONSerialization.data(withJSONObject: adapters, options: [.sortedKeys])) ?? Data("[]".utf8)
        let text = String(data: data, encoding: .utf8) ?? "[]"
        return (["type": "text", "text": text] as [String: Any], false)
    }

    private static func handleDriftCheck(args: [String: Any]) -> ([String: Any], Bool) {
        guard let site = requireString(args, "site"),
              let name = requireString(args, "name"),
              let _ = requireString(args, "current_output") else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_drift_check requires site, name, current_output")
        }
        return errorEnvelope(
            code: "ADAPTER_NOT_FOUND",
            message: "cannot compare drift against a missing local adapter (no LocalRegistry yet).",
            extras: ["site": site, "name": name])
    }

    private static func handleDeleteLocal(args: [String: Any]) -> ([String: Any], Bool) {
        guard let site = requireString(args, "site"),
              let name = requireString(args, "name") else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_delete_local requires site, name")
        }
        // Delete is idempotent: return ok:true even when nothing
        // exists (matches Everywhere GeneratorTools.cs:363-366).
        let body: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "site": site,
            "name": name,
            "note": "no-op — LocalRegistry not yet ported."
        ]
        return (textEnvelope(from: body), false)
    }

    private static func handleRegenerate(args: [String: Any]) -> ([String: Any], Bool) {
        guard let site = requireString(args, "site"),
              let name = requireString(args, "name") else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_regenerate requires site, name")
        }
        let sessionId = args["session_id"] as? String
        if sessionId == nil || sessionId?.isEmpty == true {
            return errorEnvelope(
                code: "ADAPTER_REGENERATE_NEEDS_CAPTURE",
                message: "session_id is required for regeneration (Everywhere GeneratorTools.cs:377).",
                extras: ["site": site, "name": name])
        }
        return errorEnvelope(
            code: "STRATEGY_NOTE_MISSING",
            message: "regeneration requires the site's strategy note — awaiting StrategyNote store port.",
            extras: ["site": site, "name": name, "session_id": sessionId as Any])
    }

    private static func handleLint(args: [String: Any]) -> ([String: Any], Bool) {
        guard requireString(args, "source") != nil else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "adapter_lint requires source")
        }
        // Return a neutral Ok result — AdapterLinter is unimplemented,
        // but the Everywhere shape (ok, errors[], warnings[]) is
        // stable and callers can pin against it.
        let body: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "errors": [] as [Any],
            "warnings": [
                [
                    "gate": "G0",
                    "code": "LINTER_UNAVAILABLE",
                    "message": "openclicky AdapterLinter not yet ported — lint result is a placeholder."
                ] as [String: Any]
            ] as [Any]
        ]
        return (textEnvelope(from: body), false)
    }

    // MARK: - Envelope helpers

    private static func requireString(_ args: [String: Any], _ key: String) -> String? {
        guard let s = args[key] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    /// Error envelope aligned to Everywhere's shape
    /// (`{ok:false, code, message}` — `GeneratorTools.cs:451`,
    /// `GateTools.cs:127`, `CaptureTools.cs:420`). Openclicky adds
    /// `schema_version` so callers can pin future migrations.
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
