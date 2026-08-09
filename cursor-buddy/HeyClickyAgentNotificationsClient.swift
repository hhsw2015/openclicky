//
//  HeyClickyAgentNotificationsClient.swift
//  cursor-buddy
//
//  Wrapper around the two Agent notifications endpoints
//  (IDA-verified paths 0x1012ae230 and 0x1012ae270):
//    GET  /agent/notifications?limit=20  — list
//    POST /agent/notifications/read-all  — mark all read
//
//  Public API is `.refresh()` which populates `@Published unread`. UI
//  should observe that count to render a badge on the Agent HUD icon.
//

import Combine
import Foundation

public struct HeyClickyAgentNotification: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let read: Bool
    public let createdAt: Date?
}

@MainActor
public final class HeyClickyAgentNotificationsClient: ObservableObject {
    public static let shared = HeyClickyAgentNotificationsClient()

    @Published public private(set) var items: [HeyClickyAgentNotification] = []
    @Published public private(set) var unreadCount: Int = 0

    private var pollTask: Task<Void, Never>?
    /// Backoff for consecutive unauthorized responses. When the server
    /// keeps returning 401 even after the shared token was refreshed
    /// (server-side session-token binding issue), polling every 45s
    /// hammers the endpoint and floods the log. Grow the interval up
    /// to 5 min on repeated 401s so the storm stops.
    private var consecutiveUnauthorized: Int = 0
    private let maxBackoffSeconds: UInt64 = 300

    private init() {}

    /// Kick off a periodic refresh loop so agent completions surface
    /// even when the HUD is closed. Idempotent: repeat calls no-op.
    /// Interval is intentionally slow (45s) to keep request volume
    /// low; anything under a minute is user-friendly for "agent done"
    /// notifications and the /agent-messages poller catches inline
    /// turns at a faster cadence anyway.
    public func startPeriodicRefresh(intervalSeconds: UInt64 = 45) {
        if pollTask != nil { return }
        HeyClickyLog.log("agent_notifications.poller_started", lane: "agent",
                         direction: "internal", [
            "stage": "S6_notifications",
            "interval_s": intervalSeconds
        ])
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let backoff = await MainActor.run { self?.currentBackoffSeconds(base: intervalSeconds) ?? intervalSeconds }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            }
        }
    }

    /// Interval to wait before the next poll. On healthy 200s the base
    /// `intervalSeconds` (45s) is used; each consecutive `unauthorized`
    /// doubles the delay up to `maxBackoffSeconds`. Once a request
    /// succeeds the counter resets and we're back to 45s.
    private func currentBackoffSeconds(base: UInt64) -> UInt64 {
        guard consecutiveUnauthorized > 0 else { return base }
        let multiplier = min(UInt64(1) << min(consecutiveUnauthorized, 8), maxBackoffSeconds / max(base, 1))
        return min(base * max(multiplier, 1), maxBackoffSeconds)
    }

    public func stopPeriodicRefresh() {
        if pollTask == nil { return }
        pollTask?.cancel()
        pollTask = nil
        HeyClickyLog.log("agent_notifications.poller_stopped", lane: "agent",
                         direction: "internal", ["stage": "S6_notifications"])
    }

    /// Fetch the newest 20 notifications and update `items` / `unreadCount`
    /// in-place. Silent on error (leaves prior snapshot intact).
    public func refresh() async {
        let path = AppBundleConfiguration.heyClickyAgentNotificationsPath() + "?limit=20"
        do {
            let (data, resp) = try await HeyClickyProxyClient.shared.getJSON(path: path)
            guard (200...299).contains(resp.statusCode) else { return }
            consecutiveUnauthorized = 0
            let parsed = Self.decode(from: data)
            self.items = parsed
            self.unreadCount = parsed.filter { !$0.read }.count
            HeyClickyLog.log("agent_notifications.refresh_ok", lane: "agent", direction: "incoming", [
                "stage": "S6_notifications",
                "total": parsed.count,
                "unread": self.unreadCount
            ])
        } catch HeyClickyProxyError.unauthorized {
            consecutiveUnauthorized += 1
            // Log only on transitions to avoid flooding when the storm
            // is already in progress. First hit is loud, subsequent
            // ones become a periodic summary at exponential intervals.
            let isPowerOfTwo = (consecutiveUnauthorized & (consecutiveUnauthorized - 1)) == 0
            if consecutiveUnauthorized == 1 || isPowerOfTwo {
                HeyClickyLog.log("agent_notifications.refresh_failed", lane: "agent", direction: "error", [
                    "error": "unauthorized",
                    "consecutive": consecutiveUnauthorized,
                    "next_backoff_s": currentBackoffSeconds(base: 45)
                ])
            }
        } catch {
            HeyClickyLog.log("agent_notifications.refresh_failed", lane: "agent", direction: "error", [
                "error": "\(error)"
            ])
        }
    }

    /// POST /agent/notifications/read-all so the server clears the
    /// unread badge. Locally zeros `unreadCount` optimistically.
    public func markAllRead() async {
        let previousUnread = unreadCount
        unreadCount = 0
        items = items.map {
            HeyClickyAgentNotification(id: $0.id, title: $0.title, body: $0.body, read: true, createdAt: $0.createdAt)
        }
        let payload = try? JSONSerialization.data(withJSONObject: [:] as [String: Any])
        do {
            _ = try await HeyClickyProxyClient.shared.postJSON(
                path: AppBundleConfiguration.heyClickyAgentNotificationsReadAllPath(),
                body: payload ?? Data("{}".utf8),
                includeDictationReceipt: false
            )
            HeyClickyLog.log("agent_notifications.read_all_ok", lane: "agent", direction: "outgoing", [
                "cleared": previousUnread
            ])
        } catch {
            HeyClickyLog.log("agent_notifications.read_all_failed", lane: "agent", direction: "error", [
                "error": "\(error)"
            ])
        }
    }

    static func decode(from data: Data) -> [HeyClickyAgentNotification] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]]
        if let obj = root as? [String: Any] {
            items = (obj["notifications"] as? [[String: Any]])
                ?? (obj["items"] as? [[String: Any]])
                ?? []
        } else if let arr = root as? [[String: Any]] {
            items = arr
        } else {
            items = []
        }
        return items.compactMap { row in
            guard let id = (row["id"] as? String) ?? (row["notification_id"] as? String) else { return nil }
            let title = (row["title"] as? String) ?? ""
            let body = (row["body"] as? String) ?? (row["message"] as? String) ?? ""
            let read = (row["read"] as? Bool) ?? (row["read_at"] != nil)
            let createdAt = (row["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return HeyClickyAgentNotification(
                id: id, title: title, body: body, read: read, createdAt: createdAt
            )
        }
    }
}
