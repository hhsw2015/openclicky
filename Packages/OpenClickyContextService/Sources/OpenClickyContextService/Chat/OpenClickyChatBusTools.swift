// Ported from Everywhere @ 30e03e9dcfdd4247fd679828ed86e9042f32d809:
//   src/Everywhere.Mcp/Tools/ChatBusTools.cs
//
// F32 landing — MCP descriptor blobs + dispatch helpers for the two
// chat_bus tools (`chat_send`, `chat_subscribe`). The Swift bus is
// in-process, so unlike Everywhere we do not gate on an extension
// connection; every call succeeds or fails purely on argument
// validity.
//
// Wire contract:
//   chat_send(kind, body, from?, to?, metadata?)
//       -> {ok, message_id, delivered_to}
//   chat_subscribe(kind_filter?, from?, since?, subscription_id?)
//       -> {messages: [ChatBusMessage...]}
//
// Envelope byte-shape matches Everywhere's `{ok:true, ...}` /
// `{ok:false, code, message}` split. Callers on the main bridge wrap
// these dicts into the MCP `{type:"text", text:"<json>"}` content
// envelope.

import Foundation

/// MCP descriptors + dispatch adapters for the two `chat_*` tools.
public enum OpenClickyChatBusTools {

    // MARK: - Tool name set

    public static let toolNames: Set<String> = [
        "chat_send",
        "chat_subscribe",
        // Everywhere ChatBusTools.cs:32-146 — channel surface added
        // for the OpenClicky port. In-process store, no OpenDia bridge.
        "chat_list",
        "chat_read",
        "chat_create",
        "chat_delete"
    ]

    // MARK: - Tool descriptors (MCP tools/list shape)

    public static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "chat_send",
                "description":
                    "Publish one message onto the OpenClicky chat bus. Any subscriber whose filter accepts (kind, from) receives it. " +
                    "Messages TTL out after 5 minutes; the bus holds at most 200 messages (oldest dropped on overflow). " +
                    "Ported from Everywhere ChatBusTools.cs (SPEC §5.1).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind": [
                            "type": "string",
                            "description": "Message kind — the primary routing key subscribers filter on (e.g. 'toast', 'agent_hint')."
                        ],
                        "body": [
                            "type": "string",
                            "description": "Message body (free-form text or JSON-serialised payload)."
                        ],
                        "from": [
                            "type": "string",
                            "description": "Optional sender identifier (agent name, tool call id, etc)."
                        ],
                        "to": [
                            "type": "string",
                            "description": "Optional recipient identifier — informational, subscribers still opt in via their filter."
                        ],
                        "metadata": [
                            "type": "object",
                            "description": "Optional flat metadata bag (values must be JSON scalars — string/number/bool/null)."
                        ]
                    ] as [String: Any],
                    "required": ["kind", "body"]
                ]
            ],
            [
                "name": "chat_subscribe",
                "description":
                    "Return all bus messages that match the filter and post-date the caller's cursor. Non-blocking: if there are no new messages, returns {messages:[]}. " +
                    "Repeat with the same subscription_id to advance the cursor and receive only new deliveries. " +
                    "Ported from Everywhere ChatBusTools.cs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind_filter": [
                            "type": "string",
                            "description": "Optional kind to filter by. Omit to receive all kinds."
                        ],
                        "from": [
                            "type": "string",
                            "description": "Optional sender identifier to filter by."
                        ],
                        "since": [
                            "type": "number",
                            "description": "Optional unix-seconds cursor. Messages with ts <= since are skipped. Ignored if subscription_id is supplied AND already advanced."
                        ],
                        "subscription_id": [
                            "type": "string",
                            "description": "Optional stable subscriber id. Reusing the same id preserves the cursor across polls."
                        ],
                        "block_ms": [
                            "type": "number",
                            "description": "Optional soft wait budget in ms. Reserved — the current implementation is non-blocking and ignores this."
                        ]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            // Everywhere ChatBusTools.cs:32 — chat_list.
            [
                "name": "chat_list",
                "description": "List chats owned by OpenDia sidepanel. Returns { chats: [{chat_id, title, updated_at, message_count}] }.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            // Everywhere ChatBusTools.cs:45 — chat_read.
            [
                "name": "chat_read",
                "description": "Read messages from chat, optionally since monotonic msg_id (strictly greater).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "chat_id": [
                            "type": "string",
                            "description": "uuid v4 chat."
                        ],
                        "since_msg_id": [
                            "type": "integer",
                            "description": "Optional monotonic watermark; only messages with msg_id > since_msg_id are returned."
                        ]
                    ] as [String: Any],
                    "required": ["chat_id"]
                ]
            ],
            // Everywhere ChatBusTools.cs:110 — chat_create.
            [
                "name": "chat_create",
                "description": "Create a new chat owned by OpenDia sidepanel. Returns { chat_id, title, updated_at }.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Optional human-readable title."
                        ]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            // Everywhere ChatBusTools.cs:128 — chat_delete.
            [
                "name": "chat_delete",
                "description": "Delete a chat by chat_id.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "chat_id": [
                            "type": "string",
                            "description": "uuid v4 chat."
                        ]
                    ] as [String: Any],
                    "required": ["chat_id"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    /// Executes one chat_* tool against the shared bus. Returns an MCP
    /// content envelope (`{type:"text", text:"<json>"}`) plus the
    /// `isError` flag — matches the shape produced by every other
    /// bridge tool family (Connector, OpenCLI, OpenDia, adapter, page,
    /// capture) so `executeSensorTool` can drop the pair into
    /// `result.content[]` without re-wrapping.
    public static func execute(name: String, arguments: [String: Any]) -> ([String: Any], Bool) {
        switch name {
        case "chat_send":
            return handleSend(arguments: arguments)
        case "chat_subscribe":
            return handleSubscribe(arguments: arguments)
        case "chat_list":
            return handleList(arguments: arguments)
        case "chat_read":
            return handleRead(arguments: arguments)
        case "chat_create":
            return handleCreate(arguments: arguments)
        case "chat_delete":
            return handleDelete(arguments: arguments)
        default:
            return (textEnvelope(from: failBody(code: "UNKNOWN_TOOL", message: "unknown chat_bus tool '\(name)'")), true)
        }
    }

    // MARK: Channel dispatch (Everywhere ChatBusTools.cs:32-146)

    public static func handleList(arguments: [String: Any], bus: OpenClickyChatBus = .shared) -> ([String: Any], Bool) {
        let summaries = bus.listChannels()
        let items: [[String: Any]] = summaries.map { s in
            [
                "chat_id": s.chatID,
                "title": s.title,
                "updated_at": s.updatedAt,
                "message_count": s.messageCount
            ]
        }
        let payload: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "chats": items
        ]
        return (textEnvelope(from: payload), false)
    }

    public static func handleRead(arguments: [String: Any], bus: OpenClickyChatBus = .shared) -> ([String: Any], Bool) {
        guard let chatID = (arguments["chat_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !chatID.isEmpty else {
            return (textEnvelope(from: failBody(code: "CHAT_NOT_FOUND", message: "chat_id required")), true)
        }
        let sinceMsgID: Int64? = {
            if let v = arguments["since_msg_id"] as? Int64 { return v }
            if let v = arguments["since_msg_id"] as? Int { return Int64(v) }
            if let v = arguments["since_msg_id"] as? Double { return Int64(v) }
            if let s = arguments["since_msg_id"] as? String, let v = Int64(s) { return v }
            return nil
        }()
        do {
            let messages = try bus.readChannel(chatID: chatID, sinceMsgID: sinceMsgID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let items: [[String: Any]] = messages.map { message in
                guard let data = try? encoder.encode(message),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return [:]
                }
                return dict
            }
            let payload: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "chat_id": chatID,
                "messages": items
            ]
            return (textEnvelope(from: payload), false)
        } catch let err as ChatBusError {
            return (textEnvelope(from: failBody(code: err.code, message: err.message)), true)
        } catch {
            return (textEnvelope(from: failBody(code: "BUS_ERROR", message: String(describing: error))), true)
        }
    }

    public static func handleCreate(arguments: [String: Any], bus: OpenClickyChatBus = .shared) -> ([String: Any], Bool) {
        let title = arguments["title"] as? String
        let summary = bus.createChannel(title: title)
        let payload: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "chat_id": summary.chatID,
            "title": summary.title,
            "updated_at": summary.updatedAt
        ]
        return (textEnvelope(from: payload), false)
    }

    public static func handleDelete(arguments: [String: Any], bus: OpenClickyChatBus = .shared) -> ([String: Any], Bool) {
        guard let chatID = (arguments["chat_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !chatID.isEmpty else {
            return (textEnvelope(from: failBody(code: "CHAT_NOT_FOUND", message: "chat_id required")), true)
        }
        do {
            try bus.deleteChannel(chatID: chatID)
            let payload: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "chat_id": chatID
            ]
            return (textEnvelope(from: payload), false)
        } catch let err as ChatBusError {
            return (textEnvelope(from: failBody(code: err.code, message: err.message)), true)
        } catch {
            return (textEnvelope(from: failBody(code: "BUS_ERROR", message: String(describing: error))), true)
        }
    }

    /// Also usable by tests or direct-in-process callers.
    public static func handleSend(arguments: [String: Any], bus: OpenClickyChatBus = .shared) -> ([String: Any], Bool) {
        guard let kind = (arguments["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty else {
            return (textEnvelope(from: failBody(code: "INVALID_ROLE", message: "kind is required")), true)
        }
        guard let body = arguments["body"] as? String else {
            return (textEnvelope(from: failBody(code: "INVALID_PAYLOAD", message: "body is required")), true)
        }
        let from = arguments["from"] as? String
        let to = arguments["to"] as? String
        let metadata = decodeMetadata(arguments["metadata"])
        do {
            let result = try bus.send(kind: kind, body: body, from: from, to: to, metadata: metadata)
            let payload: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "message_id": result.messageID,
                "delivered_to": result.deliveredTo
            ]
            return (textEnvelope(from: payload), false)
        } catch let err as ChatBusError {
            return (textEnvelope(from: failBody(code: err.code, message: err.message)), true)
        } catch {
            return (textEnvelope(from: failBody(code: "BUS_ERROR", message: String(describing: error))), true)
        }
    }

    /// Also usable by tests or direct-in-process callers.
    public static func handleSubscribe(arguments: [String: Any], bus: OpenClickyChatBus = .shared) -> ([String: Any], Bool) {
        let kindFilter = arguments["kind_filter"] as? String
        let from = arguments["from"] as? String
        let since = decodeDouble(arguments["since"])
        let subscriptionID = arguments["subscription_id"] as? String
        let messages = bus.subscribe(
            subscriptionID: subscriptionID,
            kindFilter: kindFilter,
            from: from,
            sinceTs: since
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let items: [[String: Any]] = messages.map { message in
            guard let data = try? encoder.encode(message),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return dict
        }
        let payload: [String: Any] = [
            "schema_version": "1",
            "ok": true,
            "messages": items
        ]
        return (textEnvelope(from: payload), false)
    }

    // MARK: - Helpers

    private static func failBody(code: String, message: String) -> [String: Any] {
        return [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "message": message
        ]
    }

    /// Wrap a JSON-serialisable dict into the MCP content text envelope
    /// (`{type:"text", text:"<json>"}`). Mirrors the pattern used by
    /// every other bridge tool family so `executeSensorTool` can
    /// splice the return straight into `result.content[]`.
    private static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    private static func decodeDouble(_ value: Any?) -> Double? {
        if let v = value as? Double { return v.isFinite ? v : nil }
        if let v = value as? Int { return Double(v) }
        if let s = value as? String, let v = Double(s) { return v.isFinite ? v : nil }
        return nil
    }

    private static func decodeMetadata(_ value: Any?) -> [String: ChatBusMessage.MetadataValue]? {
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: ChatBusMessage.MetadataValue] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = .string(s); continue }
            if let b = v as? Bool { out[k] = .bool(b); continue }
            if let n = v as? Double { out[k] = .number(n); continue }
            if let n = v as? Int { out[k] = .number(Double(n)); continue }
            if v is NSNull { out[k] = .null; continue }
            // Skip non-scalar values (arrays, dicts). Everywhere's
            // extension mirror does the same — nested payloads are
            // opaque to the bus.
        }
        return out.isEmpty ? nil : out
    }
}
