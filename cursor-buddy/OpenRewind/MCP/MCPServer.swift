// MCPServer.swift — actor that owns the tool registry + reader.
//
// The server exposes four MCP methods:
//   • initialize    — negotiate protocol version, return capabilities.
//   • tools/list    — enumerate registered tools with their JSON schemas.
//   • tools/call    — dispatch to one tool impl.
//   • shutdown      — graceful stop (the client is expected to close
//                     stdin afterwards; the reader loop exits on EOF).
//
// The router is an actor so concurrent `tools/call` handlers can read
// the descriptors dictionary without racing — actor isolation makes
// that access serialised for free. Tool handlers themselves are pure
// free functions (see Tools.swift) so they run outside the actor and
// don't serialise Kit access. If Kit later requires actor isolation
// itself, `OpenRewindKitReader` can be its own actor; the protocol
// stays the same.
//
// Protocol version pinned to 2024-11-05 (the MCP spec revision at
// time of writing). Later revisions should bump this constant.

import Foundation

/// Public wrapper struct passed back to `main.swift`. Kept small so we
/// don't leak actor references.
public struct RPCReply: Sendable {
    public let id: RPCID
    public let payload: Data     // already framed? no — main frames it.
    public let isError: Bool
}

public actor MCPServer {

    // MARK: - Config

    public static let protocolVersion = "2024-11-05"
    public static let serverName = "openrewind-mcp"
    public static let serverVersion = "0.4.0"

    // MARK: - State

    private let reader: OpenRewindReading
    private let tools: [String: MCPToolDescriptor]
    private var didInitialize = false
    private var didShutdown = false

    public init(reader: OpenRewindReading) {
        self.reader = reader
        var t: [String: MCPToolDescriptor] = [:]
        for descriptor in Self.builtinTools() {
            t[descriptor.name] = descriptor
        }
        self.tools = t
    }

    /// FIX(embed-2026-07-29): public so a host that embeds the MCP
    /// module without the stdio harness (main.swift, JSONRPC.swift)
    /// can register these tools in its own transport, e.g.
    /// `for d in OpenRewindMCPServer.builtinTools() { register(d) }`
    /// Returns the 9 read-only tool descriptors and their JSON schemas.
    public static func builtinTools() -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                name: "openrewind.search",
                title: "Search captured screen memory",
                description: "Full-text search over OCR + AX text captured by OpenRewind. Returns frame hits with a text snippet around the match. NOTE FOR MODELS: The snippet is stitched from TILE-BASED OCR (each screen split into rectangular regions, order does not match reading order). Use snippets to CONFIRM a match and identify the app/window, but ALWAYS synthesise a plain-language answer for the user — never paste the raw snippet verbatim.",
                inputSchema: OpenRewindToolSchemas.search),
            MCPToolDescriptor(
                name: "openrewind.timeline",
                title: "Time-ordered frame slice",
                description: "Return frames captured between `from` and `to`.",
                inputSchema: OpenRewindToolSchemas.timeline),
            MCPToolDescriptor(
                name: "openrewind.aiContext",
                title: "AI-friendly context around a moment",
                description: "Anchor frame + neighbours + recent app usage.",
                inputSchema: OpenRewindToolSchemas.aiContext),
            MCPToolDescriptor(
                name: "openrewind.frame",
                title: "Full frame detail",
                description: "OCR text, bounding boxes, and optional thumbnail for one frame. NOTE FOR MODELS: `ocrText` is the concatenation of tile-based OCR pieces (space-order, not reading-order) — treat it as a bag of terms describing what was on screen (apps, paths, error messages, code snippets, chat), NOT as literal transcript. Do not paste raw ocrText to the user; synthesise a natural-language description of what the frame showed.",
                inputSchema: OpenRewindToolSchemas.frame),
            MCPToolDescriptor(
                name: "openrewind.summary",
                title: "Daily recap",
                description: "App minutes, keywords, and meetings for one calendar day.",
                inputSchema: OpenRewindToolSchemas.summary),
            MCPToolDescriptor(
                name: "openrewind.currentContext",
                title: "Context for the frame the user is looking at now",
                description: "Full AI-context bundle for whatever the Browser's playhead is currently on.",
                inputSchema: OpenRewindToolSchemas.currentContext),
            MCPToolDescriptor(
                name: "openrewind.resolveCitation",
                title: "Resolve [FRAME#nn] citation",
                description: "Turn a frame id from an LLM response into deep-link + snippet + thumbnail.",
                inputSchema: OpenRewindToolSchemas.resolveCitation),
            MCPToolDescriptor(
                name: "openrewind.recap",
                title: "Raw daily signals for host recap generator",
                description: "Machine-readable arrays (apps, keywords, meetings, top snippets) — host's LLM turns these into prose.",
                inputSchema: OpenRewindToolSchemas.recap),
            MCPToolDescriptor(
                name: "openrewind.retentionInfo",
                title: "Retention policy + effective cutoff",
                description: "Lets callers warn users when a query targets data outside the retention window.",
                inputSchema: OpenRewindToolSchemas.retentionInfo)
        ]
    }

    // MARK: - Router

    /// Handle a single JSON-RPC request. Returns nil for notifications
    /// (no response expected on the wire).
    public func handle(_ request: RPCRequest) async -> RPCReply? {
        // Notifications: JSON-RPC forbids a response.
        if request.isNotification {
            // Most notifications are lifecycle hints. Currently ignored.
            return nil
        }
        // Guaranteed by isNotification check.
        let id = request.id!

        do {
            let result: Any
            switch request.method {
            case "initialize":
                result = try handleInitialize(params: request.params)
            case "tools/list":
                result = try handleToolsList()
            case "tools/call":
                result = try await handleToolsCall(params: request.params)
            case "shutdown":
                didShutdown = true
                result = NSNull()
            case "ping":
                result = [:] as [String: Any]
            default:
                throw RPCError.methodNotFound(request.method)
            }
            let data = try JSONRPC.encodeResult(id: id, result: result)
            return RPCReply(id: id, payload: data, isError: false)
        } catch let rpcErr as RPCError {
            let data = (try? JSONRPC.encodeError(id: id, error: rpcErr)) ?? Data()
            return RPCReply(id: id, payload: data, isError: true)
        } catch let toolErr as ToolError {
            let msg: String
            switch toolErr {
            case .badParam(let m): msg = m
            }
            let data = (try? JSONRPC.encodeError(
                id: id, error: .invalidParams(msg))) ?? Data()
            return RPCReply(id: id, payload: data, isError: true)
        } catch {
            let data = (try? JSONRPC.encodeError(
                id: id,
                error: .internalError(String(describing: error)))) ?? Data()
            return RPCReply(id: id, payload: data, isError: true)
        }
    }

    public var isShutdown: Bool { didShutdown }

    // MARK: - Handlers

    private func handleInitialize(params: [String: Any]) throws -> [String: Any] {
        didInitialize = true
        return [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [
                "tools": ["listChanged": false]
            ] as [String: Any],
            "serverInfo": [
                "name": Self.serverName,
                "version": Self.serverVersion
            ]
        ]
    }

    private func handleToolsList() throws -> [String: Any] {
        let sorted = tools.values.sorted { $0.name < $1.name }
        return ["tools": sorted.map { $0.toWire() }]
    }

    /// FIX(embed-2026-07-29): public raw dispatch — a host that owns
    /// its own MCP transport (or wants to expose the tools via a
    /// different RPC) calls this directly instead of running the
    /// stdio server. Returns the tool's raw JSON payload (before the
    /// MCP `content`/`structuredContent` envelope). Throws
    /// `RPCError.methodNotFound` for unknown names.
    public static func handle(name: String,
                              params: [String: Any],
                              reader: OpenRewindReading) async throws -> [String: Any] {
        switch name {
        case "openrewind.search":          return try await Tools.search(params: params, reader: reader)
        case "openrewind.timeline":        return try await Tools.timeline(params: params, reader: reader)
        case "openrewind.aiContext":       return try await Tools.aiContext(params: params, reader: reader)
        case "openrewind.frame":           return try await Tools.frame(params: params, reader: reader)
        case "openrewind.summary":         return try await Tools.summary(params: params, reader: reader)
        case "openrewind.currentContext":  return try await Tools.currentContext(params: params, reader: reader)
        case "openrewind.resolveCitation": return try await Tools.resolveCitation(params: params, reader: reader)
        case "openrewind.recap":           return try await Tools.recap(params: params, reader: reader)
        case "openrewind.retentionInfo":   return try await Tools.retentionInfo(params: params, reader: reader)
        default:
            throw RPCError.methodNotFound("tool '\(name)' has no handler")
        }
    }

    private func handleToolsCall(params: [String: Any]) async throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw RPCError.invalidParams("tools/call missing 'name'")
        }
        guard tools[name] != nil else {
            throw RPCError.methodNotFound("tool '\(name)' not registered")
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        let payload: [String: Any] = try await Self.handle(name: name, params: args, reader: reader)
        // MCP tool results are wrapped in a `content` array with typed
        // parts. We emit one JSON part; clients that only understand
        // text can look at the `structuredContent` shortcut too.
        let json = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.sortedKeys])
        let jsonString = String(data: json, encoding: .utf8) ?? "{}"
        return [
            "content": [
                ["type": "text", "text": jsonString] as [String: Any]
            ],
            "structuredContent": payload,
            "isError": false
        ]
    }
}
