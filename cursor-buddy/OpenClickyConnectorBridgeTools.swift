//
//  OpenClickyConnectorBridgeTools.swift
//  cursor-buddy
//
//  Phase 7.5 F29 — MCP tool implementations for open-connector.
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
//  Ports Everywhere's `Everywhere.Mcp.Tools.ConnectorTools` (the 6
//  `connector_*` MCP tools) into Swift. Every response envelope and
//  argument name is byte-for-byte with the upstream C# — this is the
//  MCP contract the LLM/agent side pins against.
//
//  Dispatch entrypoints are static so they compose cleanly into the
//  existing `OpenClickyExternalControlBridgeServer.executeSensorTool`
//  switch (patched in a separate diff — this file only owns the tool
//  implementations + descriptor blobs).
//

import Foundation
import os

/// Structured logger for F29 bridge-tool dispatch. Emits per-call
/// latency + ok flag so a Console.app trace can profile the layer-7
/// audit surface end-to-end.
private let f29ToolLog = Logger(subsystem: "com.jkneen.openclicky", category: "Layer7-Connector")

/// Tool descriptors, executor, and envelope helpers for the six
/// `connector_*` MCP tools.
enum OpenClickyConnectorBridgeTools {

    // MARK: - Constants (parity with Everywhere ConnectorTools.cs)

    /// The Everywhere upstream SHA whose provider manifest we mirror.
    /// Piped into every tool response as `upstream_sha` so LLM sanity
    /// checks can detect drift.
    static let upstreamSha = "847efc10cdff5d6c50b9905ac05c663246f70684"

    /// Fuzzy-search result cap for `connector_list?query=...`. Matches
    /// `ConnectorTools.ConnectorList.Cap`.
    static let queryCap = 60

    // MARK: - Tool name set (used by the bridge's role gate)

    static let toolNames: Set<String> = [
        "connector_list",
        "connector_describe",
        "connector_run",
        "connector_connect",
        "connector_disconnect",
        "connector_list_connections"
    ]

    // MARK: - Tool descriptors (input schemas — MCP tools/list shape)

    static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "connector_list",
                "description":
                    "List SaaS providers integrated via open-connector. " +
                    "No args → provider index (name + action count + categories). " +
                    "service=X → drill into one provider's actions. " +
                    "query=X → fuzzy search across all providers (cap 60). " +
                    "Pair with connector_describe for schemas, connector_run to execute. " +
                    "Prefer this over connector_run when unsure which action fits.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "service": [
                            "type": "string",
                            "description": "Optional service filter (e.g. \"github\")."
                        ],
                        "query": [
                            "type": "string",
                            "description": "Optional case-insensitive substring match on service/action name/description. Cap 60."
                        ]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "connector_describe",
                "description":
                    "Full input/output JSON schema + required OAuth scopes for one action. " +
                    "Call before connector_run when arguments are non-trivial.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "service": ["type": "string", "description": "Service id (from connector_list)."],
                        "name": ["type": "string", "description": "Action name (from connector_list)."]
                    ] as [String: Any],
                    "required": ["service", "name"]
                ]
            ],
            [
                "name": "connector_run",
                "description":
                    "Execute one provider action. Credentials must be configured " +
                    "(env var EVERYWHERE_CONNECTOR_<SERVICE>_PAT or via connector_connect). " +
                    "arguments_json is a JSON object matching the action's inputSchema — " +
                    "call connector_describe first if unsure. " +
                    "connection routes to a named connection (e.g. \"work\" → github:work); " +
                    "omit for the default connection.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "service": ["type": "string", "description": "Service id (from connector_list)."],
                        "name": ["type": "string", "description": "Action name (from connector_list)."],
                        "arguments_json": [
                            "type": "string",
                            "description": "JSON object of arguments, as a string. Use \"{}\" if no args."
                        ],
                        "connection": [
                            "type": "string",
                            "description": "Optional named connection (Phase 12). Empty = default connection."
                        ]
                    ] as [String: Any],
                    "required": ["service", "name", "arguments_json"]
                ]
            ],
            [
                "name": "connector_connect",
                "description":
                    "Store an api_key credential for a provider (auth_type=api_key). " +
                    "Overwrites any existing connection with the same (service, connection) tuple. " +
                    "Persists to the macOS Keychain (encrypted at rest). " +
                    "connection lets you keep multiple accounts per service — e.g. github + \"work\" " +
                    "for a work PAT alongside the personal one. Empty = default connection. " +
                    "For OAuth providers, omit api_key to receive an authorization URL instead.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "service": ["type": "string", "description": "Service id (e.g. \"github\", \"openai\")."],
                        "api_key": [
                            "type": "string",
                            "description": "API key value (personal access token, api key, etc.). Omit for OAuth kickoff."
                        ],
                        "display_name": [
                            "type": "string",
                            "description": "Optional friendly label shown to the user."
                        ],
                        "connection": [
                            "type": "string",
                            "description": "Optional connection name. Empty = default connection (Phase 12)."
                        ]
                    ] as [String: Any],
                    "required": ["service"]
                ]
            ],
            [
                "name": "connector_disconnect",
                "description": "Delete a stored credential for a provider. Idempotent. connection empty = default.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "service": ["type": "string", "description": "Service id whose stored credential should be removed."],
                        "connection": [
                            "type": "string",
                            "description": "Optional connection name (Phase 12). Empty = default connection."
                        ]
                    ] as [String: Any],
                    "required": ["service"]
                ]
            ],
            [
                "name": "connector_list_connections",
                "description": "List provider connections currently configured on this daemon. Values are never returned — only labels + auth types.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ]
        ]
    }

    // MARK: - Dispatch entry point

    /// Executes one connector_* tool. Returns the MCP `content` envelope
    /// and an `isError` flag — matching the shape
    /// `executeSensorTool(name:arguments:)` returns.
    ///
    /// The caller is expected to be `OpenClickyExternalControlBridgeServer.executeSensorTool`.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        let t0 = Date()
        let argLen = (try? JSONSerialization.data(withJSONObject: arguments))?.count ?? 0
        // Guard: subprocess must be running for anything except the
        // static Keychain-backed listing.
        let subprocessRunning = await MainActor.run { OpenClickyConnectorSubprocess.shared.isRunning }
        let (result, isError) = await dispatch(name: name, arguments: arguments,
                                                subprocessRunning: subprocessRunning)
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        f29ToolLog.info("openclicky.connector.tool_call tool=\(name, privacy: .public) arg_len=\(argLen, privacy: .public) ok=\(!isError, privacy: .public) latency_ms=\(latencyMs, privacy: .public)")
        return (result, isError)
    }

    private static func dispatch(name: String, arguments: [String: Any], subprocessRunning: Bool) async -> ([String: Any], Bool) {
        switch name {
        case "connector_list_connections":
            return await handleListConnections(args: arguments)
        case "connector_disconnect":
            return await handleDisconnect(args: arguments)
        default:
            break
        }

        guard subprocessRunning else {
            return errorEnvelope(
                service: arguments["service"] as? String,
                name: arguments["name"] as? String,
                code: "RUNTIME_HOST_ERROR",
                message: "Connector runtime is not running. Enable it in Settings → Connector or run `brew install node` and toggle again."
            )
        }

        switch name {
        case "connector_list":       return await handleList(args: arguments)
        case "connector_describe":   return await handleDescribe(args: arguments)
        case "connector_run":        return await handleRun(args: arguments)
        case "connector_connect":    return await handleConnect(args: arguments)
        default:
            return errorEnvelope(service: nil, name: nil,
                                 code: "invalid_input",
                                 message: "unknown connector tool '\(name)'")
        }
    }

    // MARK: - Individual handlers

    private static func handleList(args: [String: Any]) async -> ([String: Any], Bool) {
        var body: [String: Any] = [:]
        if let s = args["service"] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            body["service"] = s
        }
        if let q = args["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            body["query"] = q
        }
        body["cap"] = queryCap
        do {
            let response = try await OpenClickyConnectorSubprocess.shared.requestJSON(
                path: "/providers", method: "POST", body: body
            )
            var result = response
            if result["upstream_sha"] == nil {
                result["upstream_sha"] = upstreamSha
            }
            if result["schema_version"] == nil {
                result["schema_version"] = "1"
            }
            if result["ok"] == nil { result["ok"] = true }
            return (textEnvelope(from: result), (result["ok"] as? Bool) == false ? true : false)
        } catch {
            return errorEnvelope(service: body["service"] as? String, name: nil,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    private static func handleDescribe(args: [String: Any]) async -> ([String: Any], Bool) {
        guard let service = args["service"] as? String, !service.isEmpty,
              let name = args["name"] as? String, !name.isEmpty else {
            return errorEnvelope(service: args["service"] as? String, name: args["name"] as? String,
                                 code: "invalid_input",
                                 message: "connector_describe requires 'service' and 'name'")
        }
        let body: [String: Any] = ["service": service, "name": name]
        do {
            let response = try await OpenClickyConnectorSubprocess.shared.requestJSON(
                path: "/describe", method: "POST", body: body
            )
            var result = response
            if result["upstream_sha"] == nil { result["upstream_sha"] = upstreamSha }
            if result["schema_version"] == nil { result["schema_version"] = "1" }
            if result["ok"] == nil { result["ok"] = true }
            return (textEnvelope(from: result), (result["ok"] as? Bool) == false ? true : false)
        } catch {
            return errorEnvelope(service: service, name: name,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    private static func handleRun(args: [String: Any]) async -> ([String: Any], Bool) {
        guard let service = args["service"] as? String, !service.isEmpty,
              let name = args["name"] as? String, !name.isEmpty else {
            return errorEnvelope(service: args["service"] as? String, name: args["name"] as? String,
                                 code: "invalid_input",
                                 message: "connector_run requires 'service' and 'name'")
        }
        let argumentsJson = args["arguments_json"] as? String ?? "{}"
        // Parse to validate JSON shape (matches Everywhere's guard).
        var parsedArgs: [String: Any] = [:]
        if !argumentsJson.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = argumentsJson.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorEnvelope(service: service, name: name,
                                     code: "invalid_input",
                                     message: "arguments_json is invalid JSON or not an object")
            }
            parsedArgs = obj
        }
        // Normalize connection.
        let rawConnection = args["connection"] as? String
        let connection: String?
        do {
            connection = try OpenClickyConnectorCredentialStore.normalizeConnection(rawConnection)
        } catch {
            return errorEnvelope(service: service, name: name,
                                 code: "invalid_input",
                                 message: "connection name cannot contain ':' — reserved as the storage-key separator")
        }
        // Look up credentials from Keychain and forward inline. The
        // Node subprocess never sees the Keychain — Swift decrypts.
        var credential: Any = NSNull()
        if let cred = try? OpenClickyConnectorCredentialStore.load(providerId: service,
                                                                    connectionId: connection) {
            credential = cred
        }
        let body: [String: Any] = [
            "service": service,
            "name": name,
            "arguments": parsedArgs,
            "connection": connection as Any,
            "credential": credential
        ]
        do {
            let response = try await OpenClickyConnectorSubprocess.shared.requestJSON(
                path: "/run", method: "POST", body: body
            )
            var result = response
            if result["schema_version"] == nil { result["schema_version"] = "1" }
            if result["service"] == nil { result["service"] = service }
            if result["name"] == nil { result["name"] = name }
            if result["ok"] == nil { result["ok"] = false }
            return (textEnvelope(from: result), (result["ok"] as? Bool) == false ? true : false)
        } catch {
            return errorEnvelope(service: service, name: name,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    private static func handleConnect(args: [String: Any]) async -> ([String: Any], Bool) {
        guard let service = args["service"] as? String, !service.isEmpty else {
            return errorEnvelope(service: nil, name: nil,
                                 code: "invalid_input",
                                 message: "connector_connect requires 'service'")
        }
        let apiKey = (args["api_key"] as? String) ?? ""
        let displayName = args["display_name"] as? String
        let rawConnection = args["connection"] as? String

        let connection: String?
        do {
            connection = try OpenClickyConnectorCredentialStore.normalizeConnection(rawConnection)
        } catch {
            return errorEnvelope(service: service, name: nil,
                                 code: "invalid_input",
                                 message: "connection name cannot contain ':' — reserved as the storage-key separator")
        }

        // API-key path: store directly, no subprocess round-trip.
        if !apiKey.isEmpty {
            var cred: [String: Any] = [
                "auth_type": "api_key",
                "api_key": apiKey
            ]
            if let displayName {
                cred["display_name"] = displayName
            }
            do {
                try OpenClickyConnectorCredentialStore.save(providerId: service,
                                                            connectionId: connection,
                                                            credentialJson: cred)
            } catch {
                return errorEnvelope(service: service, name: nil,
                                     code: "RUNTIME_HOST_ERROR",
                                     message: error.localizedDescription)
            }
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "service": service,
                "connection": connection as Any,
                "auth_type": "api_key",
                "display_name": displayName as Any
            ]
            return (textEnvelope(from: body), false)
        }

        // OAuth path: subprocess mints the state + URL, Swift registers
        // the pending state.
        let running = await MainActor.run { OpenClickyConnectorSubprocess.shared.isRunning }
        guard running else {
            return errorEnvelope(service: service, name: nil,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: "OAuth connect requires the connector runtime to be running.")
        }
        let requestBody: [String: Any] = [
            "service": service,
            "connection": connection as Any,
            "display_name": displayName as Any
        ]
        do {
            let response = try await OpenClickyConnectorSubprocess.shared.requestJSON(
                path: "/oauth_authorize", method: "POST", body: requestBody
            )
            if let state = response["state"] as? String, !state.isEmpty {
                await MainActor.run {
                    OpenClickyConnectorOAuthCallback.shared.registerPendingState(
                        state, providerId: service, connectionId: connection
                    )
                }
            }
            var result = response
            if result["schema_version"] == nil { result["schema_version"] = "1" }
            if result["ok"] == nil { result["ok"] = true }
            if result["service"] == nil { result["service"] = service }
            return (textEnvelope(from: result), (result["ok"] as? Bool) == false ? true : false)
        } catch {
            return errorEnvelope(service: service, name: nil,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    private static func handleDisconnect(args: [String: Any]) async -> ([String: Any], Bool) {
        guard let service = args["service"] as? String, !service.isEmpty else {
            return errorEnvelope(service: nil, name: nil,
                                 code: "invalid_input",
                                 message: "connector_disconnect requires 'service'")
        }
        let rawConnection = args["connection"] as? String
        let connection: String?
        do {
            connection = try OpenClickyConnectorCredentialStore.normalizeConnection(rawConnection)
        } catch {
            return errorEnvelope(service: service, name: nil,
                                 code: "invalid_input",
                                 message: "connection name cannot contain ':' — reserved as the storage-key separator")
        }
        let removed: Bool
        do {
            removed = try OpenClickyConnectorCredentialStore.delete(providerId: service,
                                                                     connectionId: connection)
        } catch {
            return errorEnvelope(service: service, name: nil,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
        let body: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "service": service,
            "connection": connection as Any,
            "removed": removed
        ]
        return (textEnvelope(from: body), false)
    }

    private static func handleListConnections(args: [String: Any]) async -> ([String: Any], Bool) {
        let providerFilter = args["provider"] as? String
        let summaries: [OpenClickyConnectorConnectionSummary]
        do {
            summaries = try OpenClickyConnectorCredentialStore.listConnections(providerId: providerFilter)
        } catch {
            return errorEnvelope(service: nil, name: nil,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
        let arr: [[String: Any]] = summaries.map { s in
            [
                "service": s.providerId,
                "connection": s.connectionId as Any,
                "auth_type": s.authType as Any,
                "display_name": s.displayName as Any,
                "account_id": s.accountId as Any
            ]
        }
        let body: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "connections": arr,
            "total": arr.count
        ]
        return (textEnvelope(from: body), false)
    }

    // MARK: - Envelope helpers

    /// Wrap a JSON dictionary in an MCP `content` text envelope.
    static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    static func errorEnvelope(service: String?, name: String?, code: String, message: String) -> ([String: Any], Bool) {
        var body: [String: Any] = [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "error": message
        ]
        if let service { body["service"] = service }
        if let name { body["name"] = name }
        return (textEnvelope(from: body), true)
    }
}
