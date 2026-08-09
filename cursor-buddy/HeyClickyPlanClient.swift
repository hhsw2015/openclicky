//
//  HeyClickyPlanClient.swift
//  cursor-buddy
//
//  GET /me/plan — returns the signed-in user's current quota state.
//  IDA-verified endpoint (HeyClicky-1.0.40 @ 0x1012a2436) with the
//  two IDA-verified fields at 0x1012b10d0/0x1012b10e1:
//      { credits_used: Int, included_credits: Int, ... }
//

import Foundation
import Combine

struct HeyClickyPlanSnapshot: Sendable {
    let tier: String
    let messagesUsed: Int
    let messagesCap: Int
    let agentsUsed: Int
    let agentsCap: Int
    let dictationUsed: Int
    let dictationCap: Int
    let windowResetsAt: Date?

    var remainingText: String {
        // Notch detail row is `lineLimit(1)` and prefixed with the
        // user's email — anything past ~30 chars truncates. Show the
        // quota that's actually being spent this session (agents on
        // spawn, messages on chat-tool-call) with the higher-remaining
        // one implicit. Prefer the *used* number so the counter moves
        // as work is done — remaining stays flat between refreshes.
        if agentsCap > 0 && agentsUsed > 0 {
            return "\(agentsUsed)/\(agentsCap) agents · \(messagesUsed)/\(messagesCap) msg"
        }
        if messagesCap > 0 || agentsCap > 0 {
            return "\(messagesUsed)/\(messagesCap) msg · \(agentsUsed)/\(agentsCap) agents"
        }
        return "Free tier"
    }

    var detailedText: String {
        [
            "messages \(messagesUsed)/\(messagesCap)",
            "agents \(agentsUsed)/\(agentsCap)",
            "dictation \(dictationUsed)/\(dictationCap)"
        ].joined(separator: " · ")
    }
}

@MainActor
final class HeyClickyPlanClient: ObservableObject {
    static let shared = HeyClickyPlanClient()

    @Published private(set) var latest: HeyClickyPlanSnapshot?
    @Published private(set) var isRefreshing: Bool = false

    private var periodicRefreshTask: Task<Void, Never>?

    /// Poll /me/plan every `intervalSeconds` so Settings + Notch quota
    /// row never lags behind the server. Idempotent — safe to call
    /// multiple times.
    func startPeriodicRefresh(intervalSeconds: UInt64 = 45) {
        if periodicRefreshTask != nil { return }
        HeyClickyLog.log("plan.periodic_refresh_started", lane: "system",
                         direction: "internal",
                         ["interval_s": intervalSeconds])
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.refresh()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stopPeriodicRefresh() {
        if periodicRefreshTask == nil { return }
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        HeyClickyLog.log("plan.periodic_refresh_stopped", lane: "system",
                         direction: "internal", [:])
    }

    /// Fetch the current plan snapshot. Silent on failure — a nil
    /// `latest` means "unknown" to the UI, not "quota exhausted".
    @discardableResult
    func refresh() async -> HeyClickyPlanSnapshot? {
        guard AppBundleConfiguration.heyClickySignedIn() else {
            latest = nil
            return nil
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
            // /me/plan is a cheap read; cap the wait short so a cold
            // Cloudflare Worker doesn't make the UI sit on "Loading…"
            // for a full minute.
            // 8s was too tight — Cloudflare Worker cold-start can eat
            // 15+s on the first request. Timeouts here were showing up
            // as `plan.refresh_error` every poll cycle. 15s is still
            // fast enough that a genuinely-hung request gets abandoned
            // before the next 45s tick fires.
            var req = URLRequest(url: base.appendingPathComponent("me/plan"),
                                 timeoutInterval: 15)
            req.httpMethod = "GET"
            if let token = AppBundleConfiguration.heyClickySessionAccessToken() {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            await HeyClickyHeaderBuilder.shared.apply(to: &req, includeAgentThreadID: false)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                HeyClickyLog.log("plan.refresh_failed", direction: "error")
                return latest
            }
            let usage = (json["usage"] as? [String: Any]) ?? [:]
            let messages = (usage["messages"] as? [String: Any]) ?? [:]
            let agents = (usage["agents"] as? [String: Any]) ?? [:]
            let dictation = (usage["dictation"] as? [String: Any]) ?? [:]
            let resetIso = usage["window_resets_at"] as? String

            let snap = HeyClickyPlanSnapshot(
                // Demo authoritative field: `plan` (AgentProxyEndpoints.swift:263).
                // `tier` is only present as a duplicate marketing label; fall
                // through so we survive either shape.
                tier: (json["plan"] as? String) ?? (json["tier"] as? String) ?? "free",
                messagesUsed: (messages["used"] as? Int) ?? 0,
                messagesCap: (messages["cap"] as? Int) ?? 0,
                agentsUsed: (agents["used"] as? Int) ?? 0,
                agentsCap: (agents["cap"] as? Int) ?? 0,
                dictationUsed: (dictation["used"] as? Int) ?? 0,
                dictationCap: (dictation["cap"] as? Int) ?? 0,
                windowResetsAt: resetIso.flatMap { ISO8601DateFormatter().date(from: $0) }
            )
            latest = snap
            HeyClickyLog.log("plan.refresh_ok", lane: "system", direction: "incoming", [
                "tier": snap.tier,
                "msgs": "\(snap.messagesUsed)/\(snap.messagesCap)",
                "agents": "\(snap.agentsUsed)/\(snap.agentsCap)"
            ])
            // Single source of truth: broadcast so the quota watcher /
            // any other consumer can react without firing its own poll.
            NotificationCenter.default.post(name: .heyClickyPlanSnapshotChanged, object: nil)
            return snap
        } catch {
            HeyClickyLog.log("plan.refresh_error", direction: "error", ["error": "\(error)"])
            return latest
        }
    }
}
