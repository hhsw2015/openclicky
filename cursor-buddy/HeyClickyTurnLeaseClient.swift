//
//  HeyClickyTurnLeaseClient.swift
//  cursor-buddy
//
//  Acquire/heartbeat/complete Codex agent turn leases via the HeyClicky
//  proxy. Endpoint shapes verified against demo `AgentProxyEndpoints.swift`
//  and IDA HeyClicky-1.0.40 strings at 0x1012b3310, 0x1012b3600,
//  0x1012b0970.
//
//  Path convention (IDA + demo, both hardcoded):
//    POST /codex-thread-launch                    → { session_id | thread_id }
//    POST /agent/record-agent-launch              → HeyClickyTurnLease
//    GET  /agent/turn-lease/{lease_id}/status     → heartbeat
//    POST /agent/turn-lease/{lease_id}/complete   → { status, thread_id? }
//

import Foundation

struct HeyClickyThreadInfo: Sendable {
    let sessionID: String
}

final class HeyClickyTurnLeaseClient: @unchecked Sendable {
    static let shared = HeyClickyTurnLeaseClient()

    /// POST /codex-thread-launch. Demo body carries only `user_prompt`
    /// (see WorkerCallB / MemoryMigrator patterns). Response prefers
    /// `session_id`, falls back to `thread_id` for older workers.
    /// Pass a prior threadID to have the proxy resume the SAME
    /// conversation on the new account (post-reset). IDA HeyClicky-1.0.40
    /// at 0x1012b0a10 exposes `clicky_agent_thread_resumed` flag; combined
    /// with `thread_id` (0x1012d0038) the proxy re-hydrates the thread
    /// on the new account_id so message history stays intact.
    func launchThread(
        userPrompt: String,
        launchSource: HeyClickyLaunchSource,
        threadID: String,
        isFollowUp: Bool
    ) async throws -> HeyClickyThreadInfo {
        // IDA HeyClicky-1.0.42 sub_1007703C4 (CodexThreadLaunchRequest
        // Body.CodingKeys, 7 fields ordered):
        //   thread_id, role, content, is_follow_up, is_demo,
        //   is_proactive, proactive_suggestion_id
        // Prior versions of this call sent `user_prompt` +
        // `clicky_agent_thread_resumed` — BOTH are wrong. Proxy
        // ignores unknown keys, and `clicky_agent_thread_resumed` is
        // actually a local PostHog analytics property, not a wire
        // field. Missing `thread_id` in the body was why the proxy
        // could never hydrate the prior thread's message history and
        // every replay arrived as a blank conversation.
        //
        // IDA sub_100768E1C: `role` is the CHANNEL (text|voice), NOT
        // the message author. OpenClicky always uses text (voice
        // channel is the realtime-agent endpoint).
        //
        // The thread_id is CLIENT-GENERATED and STABLE across a
        // logical conversation. Server response
        // (CodexThreadLaunchResponseBody, sub_100770FF8) only carries
        // `{spoken_start_cue, text_start_cue, title}` — NO id echo,
        // because the client keeps the id it sent.
        // Empirical: proxy validator returns 400 "Missing user prompt."
        // when body has `content` but not `user_prompt`. So the Cloudflare
        // Worker's shape check happens BEFORE Swift Codable decoding —
        // it wants `user_prompt` as the required field, and treats
        // the IDA-visible struct fields as extensions.
        let payload: [String: Any] = [
            "user_prompt": userPrompt,
            "thread_id": threadID,
            "role": "text",
            "content": userPrompt,
            "is_follow_up": isFollowUp,
            "is_demo": false,
            "is_proactive": false,
            "proactive_suggestion_id": NSNull()
        ]
        HeyClickyLog.log("codex.thread_launch_dispatch", lane: "agent",
                         direction: "outgoing", [
            "thread_prefix": String(threadID.prefix(8)),
            "is_follow_up": isFollowUp
        ])
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await HeyClickyProxyClient.shared.postJSON(
            path: AppBundleConfiguration.heyClickyThreadLaunchPath(),
            body: body,
            includeDictationReceipt: true
        )
        _ = launchSource
        HeyClickyLog.log("codex.thread_launched", lane: "agent",
                         direction: "incoming", [
            "thread_prefix": String(threadID.prefix(8))
        ])
        return HeyClickyThreadInfo(sessionID: threadID)
    }

    /// POST /agent/record-agent-launch. Demo IDA-verified body carries
    /// SIX fields; missing any of them will get default routing on the
    /// server side (or an outright reject).
    func acquire(sessionID: String,
                 launchSource: HeyClickyLaunchSource,
                 isFollowUp: Bool) async throws -> HeyClickyTurnLease {
        let turnID = UUID().uuidString.uppercased()
        let taskID = UUID().uuidString.uppercased()
        // IDA HeyClicky-1.0.42 sub_1007A2808
        // (RecordAgentLaunchRequestBody.CodingKeys, 8 fields):
        //   supports_agent_turn_lease, thread_id, turn_id, task_id,
        //   is_follow_up, launch_source, idempotency_key,
        //   extra_usage_auto_approve
        // Adding `thread_id` here binds the lease to the same
        // conversation the proxy sees for follow-up turns, letting
        // the server carry `previous_response_id` across turns. Prior
        // code omitted `thread_id` entirely → every lease looked
        // fresh to the server → drift.
        let body = try JSONSerialization.data(withJSONObject: [
            "supports_agent_turn_lease": true,
            "thread_id": sessionID,
            "turn_id": turnID,
            "task_id": taskID,
            "is_follow_up": isFollowUp,
            "launch_source": launchSource.rawValue,
            "idempotency_key": turnID,
            // Pre-declare that we accept extra_effort_required tiers
            // automatically — no user prompt. Server treats this
            // lease as "run until you hit the hard cap, don't pause
            // to ask for permission." Combined with autoContinue's
            // {extra_usage_approval:true}, this maximizes per-turn
            // work done per quota unit consumed. IDA HeyClicky-1.0.42
            // sub_1007A2808 exposes this as a first-class field.
            "extra_usage_auto_approve": true
        ])
        let (data, _) = try await HeyClickyProxyClient.shared.postJSON(
            path: AppBundleConfiguration.heyClickyRecordAgentLaunchPath(),
            body: body,
            includeDictationReceipt: true
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leaseID = (json["lease_id"] as? String) ?? (json["leaseID"] as? String),
              !leaseID.isEmpty else {
            throw HeyClickyProxyError.malformedResponse
        }
        let returnedTurnID = (json["turn_id"] as? String) ?? turnID
        let credits = json["credits_used"] as? Int ?? 0
        let included = json["included_credits"] as? Int ?? 0
        // Cost telemetry (IDA HeyClicky-1.0.42 RecordAgentLaunch
        // ResponseBody: cost_usd, cost_limit_usd, requires_extra_effort).
        // Surface these so we can see per-turn dollar burn and know
        // when the server is about to demand extra_usage_approval.
        let costUSD = (json["cost_usd"] as? Double) ?? (json["cost_usd"] as? NSNumber)?.doubleValue ?? 0
        let costLimit = (json["cost_limit_usd"] as? Double) ?? (json["cost_limit_usd"] as? NSNumber)?.doubleValue ?? 0
        let requiresExtra = (json["requires_extra_effort"] as? Bool) ?? false
        let status = json["status"] as? String ?? "-"
        _ = sessionID
        HeyClickyLog.log("codex.lease_acquired", lane: "agent", direction: "incoming", [
            "lease_prefix": String(leaseID.prefix(8)),
            "credits_used": credits,
            "included_credits": included,
            "costUSD": String(format: "%.4f", costUSD),
            "costLimitUSD": String(format: "%.4f", costLimit),
            "requiresExtra": requiresExtra,
            "leaseStatus": status
        ])
        // Parse expires_at (ISO8601 or unix seconds — both observed).
        // Nil when the server omits it. Used so app-restart can decide
        // whether the same lease is still steerable.
        var expiresAt: Date? = nil
        if let iso = json["expires_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        } else if let seconds = (json["expires_at"] as? Double) ?? (json["expires_at"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: seconds)
        }
        return HeyClickyTurnLease(
            leaseID: leaseID,
            turnID: returnedTurnID,
            creditsUsed: credits,
            includedCredits: included,
            expiresAt: expiresAt
        )
    }

    /// GET /agent/turn-lease/{lease_id}/status — heartbeat.
    /// Also parses the body for `blocked_reason` / `status` so callers
    /// can preempt quota exhaustion between chat requests. Demo does
    /// not send `X-Clicky-Agent-Thread-Id` on this call — we mirror.
    func heartbeat(leaseID: String) async throws {
        let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
        let url = base
            .appendingPathComponent("agent/turn-lease")
            .appendingPathComponent(leaseID)
            .appendingPathComponent("status")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let token = AppBundleConfiguration.heyClickySessionAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        await HeyClickyHeaderBuilder.shared.apply(to: &req, includeAgentThreadID: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HeyClickyProxyError.malformedResponse
        }
        if http.statusCode == 401 {
            throw HeyClickyProxyError.unauthorized
        }
        if !(200..<300).contains(http.statusCode) {
            throw HeyClickyProxyError.upstreamUnavailable
        }
        // Body shape (demo-verified + IDA HeyClicky-1.0.40):
        //   { status: "active"|"paused"|"blocked"|"completed",
        //     blocked_reason?: "extra_usage_approval"|"quota_exhausted"|...,
        //     credits_used?, openai_calls?, cost_usd?, ... }
        // extra_usage_approval is the "we're about to exceed the
        // dollar-cost boundary on this turn" gate. HeyClicky.app auto
        // continues past it by default (IDA 0x1012b5610 "Keeping the
        // agent going..."). Only true quota_exhausted should trigger
        // the fallback router.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = (json["status"] as? String) ?? "active"
            let blockedReason = json["blocked_reason"] as? String
            // Cost telemetry every heartbeat so we can see running
            // dollar burn during a long turn without waiting for
            // record-agent-launch to return.
            let costUSD = (json["cost_usd"] as? Double) ?? (json["cost_usd"] as? NSNumber)?.doubleValue ?? -1
            let costLimit = (json["cost_limit_usd"] as? Double) ?? (json["cost_limit_usd"] as? NSNumber)?.doubleValue ?? -1
            let creditsUsed = (json["credits_used"] as? Int) ?? -1
            let openaiCalls = (json["openai_calls"] as? Int) ?? -1
            if costUSD >= 0 || costLimit >= 0 || creditsUsed >= 0 {
                HeyClickyLog.log("codex.heartbeat_cost", lane: "agent",
                                 direction: "internal", [
                    "lease_prefix": String(leaseID.prefix(8)),
                    "status": status,
                    "costUSD": String(format: "%.4f", costUSD),
                    "costLimitUSD": String(format: "%.4f", costLimit),
                    "creditsUsed": creditsUsed,
                    "openaiCalls": openaiCalls,
                    "blockedReason": blockedReason ?? "-"
                ])
            }
            // extra_usage_approval → auto-continue (HeyClicky.app parity)
            let needsContinue = (status == "paused" || status == "blocked")
                && (blockedReason == "extra_usage_approval" || blockedReason == nil)
            if needsContinue {
                throw HeyClickyProxyError.leaseNeedsContinue(leaseID: leaseID, reason: blockedReason ?? "")
            }
            // Only treat EXPLICIT quota reasons as quotaExhausted. Prior
            // code triggered fallback on any non-nil blocked_reason,
            // which caught transient reasons (lease_stale, needs_refresh,
            // rate_limited) and burned the auto-reset path unnecessarily.
            // The user still has plan quota (16/25 agents visible on the
            // panel), so ONLY spend the reset shot when the server
            // clearly says quota is out.
            let quotaReasons: Set<String> = [
                "quota_exhausted",
                "messages_quota_exhausted",
                "agents_quota_exhausted",
                "plan_limit_reached"
            ]
            if status == "blocked",
               let reason = blockedReason,
               quotaReasons.contains(reason) {
                throw HeyClickyProxyError.quotaExhausted
            }
            // Any other status/reason combo (e.g. transient
            // "lease_stale" or unknown) is logged and treated as still
            // running — heartbeat retries next tick.
            if let reason = blockedReason, !reason.isEmpty {
                HeyClickyLog.log("codex.heartbeat_unknown_reason", direction: "internal", [
                    "lease_prefix": String(leaseID.prefix(8)),
                    "status": status,
                    "reason": reason
                ])
            }
        }
    }

    /// POST /agent/turn-lease/{lease_id}/continue
    /// IDA HeyClicky-1.0.40 endpoint literal at 0x1012b3600 (path
    /// "/agent/turn-lease/…/continue"). Body carries a single field
    /// `extra_usage_approval: true` (0x1012b1130). HeyClicky auto
    /// continues by default — the response then returns lease status
    /// again; if still `paused` after approve, HeyClicky re-shows the
    /// cost card (IDA "still over boundary after approve — re-showing
    /// card, not …"). We just log that case for now.
    func autoContinue(leaseID: String) async throws {
        HeyClickyLog.log("codex.lease_continue_start", lane: "agent",
                         direction: "outgoing", [
            "lease_prefix": String(leaseID.prefix(8))
        ])
        let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
        let url = base
            .appendingPathComponent("agent/turn-lease")
            .appendingPathComponent(leaseID)
            .appendingPathComponent("continue")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AppBundleConfiguration.heyClickySessionAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        await HeyClickyHeaderBuilder.shared.apply(to: &req, includeAgentThreadID: false)
        let body: [String: Any] = ["extra_usage_approval": true]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HeyClickyProxyError.malformedResponse
        }
        let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
        HeyClickyLog.log("codex.lease_continue_http", lane: "agent",
                         direction: "incoming", [
            "lease_prefix": String(leaseID.prefix(8)),
            "http_status": http.statusCode,
            "body_head": String(bodyText.prefix(200))
        ])
        if http.statusCode == 401 {
            throw HeyClickyProxyError.unauthorized
        }
        // 402 on /continue means the proxy refused the extra-usage
        // approval — the account is truly out of quota, not just a
        // per-turn cost cap. Signal quotaExhausted so callers escalate
        // to attemptReset instead of retrying autoContinue in a loop.
        if http.statusCode == 402 || http.statusCode == 429 {
            HeyClickyLog.log("codex.lease_continue_quota_denied", lane: "agent",
                             direction: "error", [
                "lease_prefix": String(leaseID.prefix(8)),
                "http_status": http.statusCode
            ])
            throw HeyClickyProxyError.quotaExhausted
        }
        if !(200..<300).contains(http.statusCode) {
            throw HeyClickyProxyError.upstreamUnavailable
        }
        let bodyJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (bodyJSON?["status"] as? String) ?? "?"
        let stillBlocked = (status == "paused" || status == "blocked")
        let costUSD = (bodyJSON?["cost_usd"] as? Double) ?? (bodyJSON?["cost_usd"] as? NSNumber)?.doubleValue ?? 0
        let costLimit = (bodyJSON?["cost_limit_usd"] as? Double) ?? (bodyJSON?["cost_limit_usd"] as? NSNumber)?.doubleValue ?? 0
        let requiresExtra = (bodyJSON?["requires_extra_effort"] as? Bool) ?? false
        HeyClickyLog.log("codex.lease_continue_result", lane: "agent",
                         direction: "incoming", [
            "lease_prefix": String(leaseID.prefix(8)),
            "status": status,
            "still_blocked": stillBlocked,
            "costUSD": String(format: "%.4f", costUSD),
            "costLimitUSD": String(format: "%.4f", costLimit),
            "requiresExtra": requiresExtra
        ])
    }

    /// POST /agent/turn-lease/{lease_id}/complete
    func complete(leaseID: String, status: HeyClickyLeaseStatus, threadID: String?) async throws {
        HeyClickyLog.log("codex.lease_complete", lane: "agent", direction: "outgoing", [
            "lease_prefix": String(leaseID.prefix(8)),
            "status": status.rawValue,
            "has_thread": threadID != nil
        ])
        let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
        let url = base
            .appendingPathComponent("agent/turn-lease")
            .appendingPathComponent(leaseID)
            .appendingPathComponent("complete")

        // Demo status enum is completed/failed; downgrade cancelled → failed
        // so the proxy accepts the value.
        let wireStatus: String = {
            switch status {
            case .completed: return "completed"
            case .failed, .cancelled: return "failed"
            }
        }()
        var payload: [String: Any] = ["status": wireStatus]
        if let threadID { payload["thread_id"] = threadID }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        if let token = AppBundleConfiguration.heyClickySessionAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        await HeyClickyHeaderBuilder.shared.apply(to: &req)
        _ = try await URLSession.shared.data(for: req)
    }
}
