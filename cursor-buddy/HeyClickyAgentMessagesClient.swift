//
//  HeyClickyAgentMessagesClient.swift
//  cursor-buddy
//
//  Metadata-only logger for the /agent-messages endpoint. Per the
//  reference implementation (clicky-mac AgentProxyEndpoints.swift
//  `AgentMessageLogger.log`) this endpoint is a POST-only turn log
//  that carries session/role/tokens/status/timestamp — NOT chat
//  content and NOT a pull inbox.
//
//  Earlier openclicky code treated it as a bidirectional inbox
//  (GET long-poll + POST prompt content). That was wrong: chat
//  content flows through the local Codex process stdout, and the
//  metadata endpoint would never carry prompt bodies. This module
//  now matches the reference schema.
//
//  API kept `HeyClickyAgentMessagesClient.shared` so callers don't
//  have to change file-wide; `start`/`stop` are no-ops that log a
//  breadcrumb so any residual caller shows up in the log store.
//

import Foundation

/// Thin metadata row published back to callers who used the old
/// inbox API. Content is intentionally empty — this endpoint does
/// not carry content in the reference impl.
public struct HeyClickyAgentMessage: Sendable, Hashable {
    public let id: String
    public let role: String
    public let content: String
    public let createdAt: Date?
    public let sessionID: String?
}

public final class HeyClickyAgentMessagesClient: @unchecked Sendable {
    public static let shared = HeyClickyAgentMessagesClient()

    private init() {}

    /// Historical no-op. The old contract polled /agent-messages for
    /// inbound chat rows; that endpoint doesn't carry content. Local
    /// Codex stdout streams straight into `CodexAgentSession.entries`,
    /// so the HUD gets remote turns without any HTTP poller.
    public func start(onIncoming: @escaping @Sendable (HeyClickyAgentMessage) -> Void) {
        HeyClickyLog.log("agent_messages.poller_start_ignored", lane: "agent",
                         direction: "internal", [
            "stage": "S4_message_ingress",
            "reason": "endpoint_is_metadata_only",
            "note": "local_codex_stdout_carries_content"
        ])
    }

    public func stop() {
        HeyClickyLog.log("agent_messages.poller_stop_ignored", lane: "agent",
                         direction: "internal", ["stage": "S4_message_ingress"])
    }

    /// Post a per-turn metadata log row so proxy usage counters and
    /// /me/plan stay accurate. Schema matches
    /// clicky-mac AgentMessageLogger.log.
    @discardableResult
    public func logTurnMetadata(
        sessionID: String,
        threadID: String? = nil,
        role: String,
        tokens: Int,
        status: String
    ) async -> Bool {
        var body: [String: Any] = [
            "session_id": sessionID,
            "role": role,
            "tokens": tokens,
            "status": status,
            "timestamp": Int(Date().timeIntervalSince1970)
        ]
        if let threadID { body["thread_id"] = threadID }
        HeyClickyLog.log("agent_messages.meta_post_start", lane: "agent",
                         direction: "outgoing", [
            "stage": "S5_message_egress",
            "role": role,
            "tokens": tokens,
            "status": status
        ])
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            HeyClickyLog.log("agent_messages.meta_post_failed", lane: "agent",
                             direction: "error", [
                "stage": "S5_message_egress", "reason": "encode_failed"
            ])
            return false
        }
        do {
            let (_, resp) = try await HeyClickyProxyClient.shared.postJSON(
                path: AppBundleConfiguration.heyClickyAgentMessagesPath(),
                body: payload,
                includeDictationReceipt: false
            )
            let ok = (200...299).contains(resp.statusCode)
            HeyClickyLog.log("agent_messages.meta_post_result", lane: "agent",
                             direction: ok ? "incoming" : "error", [
                "stage": "S5_message_egress",
                "status": resp.statusCode,
                "ok": ok
            ])
            return ok
        } catch {
            HeyClickyLog.log("agent_messages.meta_post_failed", lane: "agent",
                             direction: "error", [
                "stage": "S5_message_egress", "error": "\(error)"
            ])
            return false
        }
    }

    /// Compat shim so any residual caller of the old `postUserMessage`
    /// API doesn't crash. Content is intentionally NOT posted — this
    /// endpoint carries metadata only.
    @discardableResult
    public func postUserMessage(_ text: String, sessionID: String? = nil) async -> Bool {
        return await logTurnMetadata(
            sessionID: sessionID ?? "",
            role: "user",
            tokens: text.count,
            status: "submitted"
        )
    }
}
