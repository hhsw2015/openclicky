//
//  OpenClickyOpenCLIBridgeTools.swift
//  cursor-buddy
//
//  Phase 7.6a F30 — MCP tool implementations for OpenCLI site adapters.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  OpenCLI upstream pin:    9161d99d96ec107cd77f13a30315614129179a1a
//
//  Ports Everywhere's `Everywhere.Mcp.Tools.OpenCliTools` three
//  `opencli_*` MCP tools into Swift. Every response envelope key and
//  argument name is byte-for-byte with the upstream C# — this is the
//  MCP contract the LLM/agent side pins against.
//
//  Dispatch entrypoints are static so they compose cleanly into the
//  existing `OpenClickyExternalControlBridgeServer.executeSensorTool`
//  switch (patched in the same diff — this file only owns tool
//  implementations + descriptor blobs).
//

import Foundation
import os

/// Structured logger for F30 bridge-tool dispatch.
private let f30ToolLog = Logger(subsystem: "com.jkneen.openclicky", category: "Layer7-OpenCLI")

/// Tool descriptors, executor, and envelope helpers for the three
/// `opencli_*` MCP tools.
enum OpenClickyOpenCLIBridgeTools {

    // MARK: - Constants (parity with Everywhere OpenCliTools.cs)

    /// Fuzzy-search result cap for `opencli_list?query=...`. Matches
    /// `OpenCliTools.OpenCliList.Cap`.
    static let queryCap = 60

    // MARK: - Tool name set

    static let toolNames: Set<String> = [
        "opencli_list",
        "opencli_describe",
        "opencli_run"
    ]

    // MARK: - Tool descriptors (input schemas — MCP tools/list shape)

    static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "opencli_list",
                "description":
                    "List OpenCLI site adapters. No args -> site index (~3KB). " +
                    "site=X -> drill into one site's commands. query=X -> fuzzy match (cap 60). " +
                    "Pair with opencli_run to execute.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": [
                            "type": "string",
                            "description": "Optional site filter (e.g. \"bilibili\"). If set, returns command list for just that site instead of the site index."
                        ],
                        "query": [
                            "type": "string",
                            "description": "Optional case-insensitive substring match on site/name/description. Cap 60 results."
                        ]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "opencli_describe",
                "description":
                    "Full input schema + columns + required OpenCLI args for one action. " +
                    "Call before opencli_run when arguments are non-trivial. " +
                    "Requires site + name.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string", "description": "Site identifier (e.g. \"bilibili\")."],
                        "name": ["type": "string", "description": "Command name (e.g. \"search\")."]
                    ] as [String: Any],
                    "required": ["site", "name"]
                ]
            ],
            [
                "name": "opencli_run",
                "description":
                    "Run an OpenCLI command. PUBLIC adapters work anywhere; cookie/intercept/ui adapters need OpenDia " +
                    "connected — else returns {ok:false, code:\"BROWSER_NOT_READY\", error:\"opendia-not-connected\"}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string", "description": "Site identifier (from opencli_list)."],
                        "name": ["type": "string", "description": "Command name (from opencli_list)."],
                        "arguments_json": [
                            "type": "string",
                            "description": "JSON object of arguments, as a string. Use \"{}\" when there are no args."
                        ]
                    ] as [String: Any],
                    "required": ["site", "name", "arguments_json"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch entry point

    /// Executes one opencli_* tool. Returns an MCP `content` envelope
    /// and an `isError` flag matching the shape
    /// `executeSensorTool(name:arguments:)` returns.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        let t0 = Date()
        let argLen = (try? JSONSerialization.data(withJSONObject: arguments))?.count ?? 0
        let (result, isError) = await dispatch(name: name, arguments: arguments)
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        f30ToolLog.info("openclicky.opencli.tool_call tool=\(name, privacy: .public) arg_len=\(argLen, privacy: .public) ok=\(!isError, privacy: .public) latency_ms=\(latencyMs, privacy: .public)")
        return (result, isError)
    }

    private static func dispatch(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        // Guard: subprocess must be running for anything except a
        // trivial argument check.
        let subprocessRunning = await MainActor.run { OpenClickyOpenCLISubprocess.shared.isRunning }
        if !subprocessRunning {
            return errorEnvelope(
                site: arguments["site"] as? String,
                name: arguments["name"] as? String,
                code: "RUNTIME_HOST_ERROR",
                message: "OpenCLI subprocess is not running. Install Node (`brew install node`) and enable the toggle in Settings, or set OPENCLICKY_MCP_OPENCLI=1."
            )
        }

        switch name {
        case "opencli_list":     return await handleList(args: arguments)
        case "opencli_describe": return await handleDescribe(args: arguments)
        case "opencli_run":      return await handleRun(args: arguments)
        default:
            return errorEnvelope(site: nil, name: nil,
                                 code: "invalid_input",
                                 message: "unknown opencli tool '\(name)'")
        }
    }

    // MARK: - Individual handlers

    private static func handleList(args: [String: Any]) async -> ([String: Any], Bool) {
        var body: [String: Any] = [:]
        if let s = args["site"] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            body["site"] = s
        }
        if let q = args["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            body["query"] = q
        }
        do {
            let response = try await OpenClickyOpenCLISubprocess.shared.requestJSON(
                path: "/list", method: "POST", body: body
            )
            var result = response
            if result["schema_version"] == nil { result["schema_version"] = "1" }
            return (textEnvelope(from: result), (result["ok"] as? Bool) == false ? true : false)
        } catch {
            return errorEnvelope(site: body["site"] as? String, name: nil,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    private static func handleDescribe(args: [String: Any]) async -> ([String: Any], Bool) {
        guard let site = args["site"] as? String, !site.isEmpty,
              let name = args["name"] as? String, !name.isEmpty else {
            return errorEnvelope(site: args["site"] as? String,
                                 name: args["name"] as? String,
                                 code: "invalid_input",
                                 message: "opencli_describe requires 'site' and 'name'")
        }
        let body: [String: Any] = ["site": site, "name": name]
        do {
            let response = try await OpenClickyOpenCLISubprocess.shared.requestJSON(
                path: "/describe", method: "POST", body: body
            )
            var result = response
            if result["schema_version"] == nil { result["schema_version"] = "1" }
            let isError = (result["ok"] as? Bool) == false
            return (textEnvelope(from: result), isError)
        } catch {
            return errorEnvelope(site: site, name: name,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    private static func handleRun(args: [String: Any]) async -> ([String: Any], Bool) {
        guard let site = args["site"] as? String, !site.isEmpty,
              let name = args["name"] as? String, !name.isEmpty else {
            return errorEnvelope(site: args["site"] as? String,
                                 name: args["name"] as? String,
                                 code: "invalid_input",
                                 message: "opencli_run requires 'site' and 'name'")
        }
        let argumentsJson = args["arguments_json"] as? String ?? "{}"
        // Parse-validate JSON shape (matches Everywhere's guard) — but
        // still forward the raw string so the Node side can enforce
        // MaxDepth=16 exactly like the upstream JsonNode parser.
        if !argumentsJson.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = argumentsJson.data(using: .utf8),
                  let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorEnvelope(site: site, name: name,
                                     code: "BAD_ARGS",
                                     message: "arguments_json invalid JSON or not an object")
            }
        }
        let body: [String: Any] = [
            "site": site,
            "name": name,
            "arguments_json": argumentsJson
        ]
        do {
            let response = try await OpenClickyOpenCLISubprocess.shared.requestJSON(
                path: "/run", method: "POST", body: body
            )
            var result = response
            if result["schema_version"] == nil { result["schema_version"] = "1" }
            let isError = (result["ok"] as? Bool) == false
            return (textEnvelope(from: result), isError)
        } catch {
            return errorEnvelope(site: site, name: name,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    // MARK: - Envelope helpers

    /// Wrap a JSON dictionary in an MCP `content` text envelope.
    private static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    private static func errorEnvelope(site: String?, name: String?, code: String, message: String) -> ([String: Any], Bool) {
        var body: [String: Any] = [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "error": message
        ]
        if let site { body["site"] = site }
        if let name { body["name"] = name }
        return (textEnvelope(from: body), true)
    }
}
