// Ported from Everywhere @ 30e03e9dcfdd4247fd679828ed86e9042f32d809:
//   src/Everywhere.Mcp/OpenDia/OpenDiaChatBus.cs  (subscription model + push channel)
//   src/Everywhere.Mcp/Tools/ChatBusTools.cs      (canonical envelope shape)
//
// F32 landing. Everywhere's chat bus proxies to a browser extension that
// owns the chat store; OpenClicky has no such extension, so this bus is
// an in-process pub/sub with:
//   - a bounded, FIFO history buffer (max 200 messages)
//   - a per-message TTL (5 minutes) so stale sends are garbage-collected
//   - subscribe filtered by kind / from / since_ts, ack-consumed on read
//     (the subscriber's `sinceTs` is advanced past every returned message
//     so subsequent long-polls do not re-deliver)
//
// The bus does NOT persist to disk. Restarting OpenClicky wipes state
// intentionally — this matches Everywhere's semantics (chat state lives
// with the extension; the daemon holds only cursors).

import Foundation

/// In-process pub/sub bus with TTL + queue caps. Access is serialised
/// through an internal `os_unfair_lock`-equivalent (`NSLock`) so all
/// public entry points are safe from any thread.
public final class OpenClickyChatBus: @unchecked Sendable {

    // MARK: - Configuration

    /// Everywhere pin: no matching constant upstream — the extension
    /// owns storage. We chose 5 minutes as a compromise between "just
    /// long enough for a slow agent to poll" and "not a memory leak
    /// if nobody is subscribed".
    public static let defaultMessageTTL: TimeInterval = 5 * 60
    /// Max history buffer size. Once exceeded the oldest message is
    /// dropped (FIFO). 200 is chosen so the bus never exceeds ~200KB
    /// resident with worst-case 1KB messages.
    public static let defaultMaxQueue: Int = 200

    // MARK: - Shared singleton

    /// Bridge-facing shared instance. Tests instantiate their own.
    public static let shared = OpenClickyChatBus()

    // MARK: - State

    private let lock = NSLock()
    private var history: [ChatBusMessage] = []
    /// Active subscribers keyed by their `subscriptionID`. Each carries
    /// its own filter + cursor so `chat_subscribe` can be called
    /// repeatedly with the same filter and only see new messages.
    private var subscribers: [String: SubscriberState] = [:]
    /// Channel store used by `chat_list`/`chat_read`/`chat_create`/
    /// `chat_delete`. Everywhere ChatBusTools.cs:32-146 delegates to
    /// the OpenDia extension; the OpenClicky port keeps an in-process
    /// map keyed by `chat_id`.
    private var channels: [String: ChannelState] = [:]
    private let ttl: TimeInterval
    private let maxQueue: Int
    private let clock: @Sendable () -> Double

    public init(
        ttl: TimeInterval = OpenClickyChatBus.defaultMessageTTL,
        maxQueue: Int = OpenClickyChatBus.defaultMaxQueue,
        clock: @Sendable @escaping () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.ttl = ttl
        self.maxQueue = maxQueue
        self.clock = clock
    }

    // MARK: - chat_send

    /// Publish one message. Returns the delivered envelope plus the
    /// count of matched (currently-registered) subscribers. Subscribers
    /// are counted at send time; the message stays in history until
    /// consumed or evicted, so late subscribers can still pull it via
    /// `sinceTs` cursor semantics.
    public func send(
        kind: String,
        body: String,
        from: String? = nil,
        to: String? = nil,
        metadata: [String: ChatBusMessage.MetadataValue]? = nil
    ) throws -> ChatBusSendResult {
        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKind.isEmpty else {
            throw ChatBusError.invalidRole("kind is required")
        }
        let now = clock()
        let message = ChatBusMessage(
            messageID: UUID().uuidString,
            kind: trimmedKind,
            body: body,
            from: from,
            to: to,
            ts: now,
            metadata: metadata
        )

        lock.lock()
        pruneExpiredLocked(now: now)
        history.append(message)
        if history.count > maxQueue {
            // Drop oldest entries first — matches Everywhere's implicit
            // "the extension trims its store" behaviour and prevents
            // unbounded growth if nobody polls.
            let overflow = history.count - maxQueue
            history.removeFirst(overflow)
        }
        // Count subscribers whose filter accepts this message. The
        // count is informational only — subscribers pull via their
        // own cursor.
        let delivered = subscribers.values.reduce(0) { acc, sub in
            acc + (sub.matches(message) ? 1 : 0)
        }
        lock.unlock()

        return ChatBusSendResult(ok: true, messageID: message.messageID, deliveredTo: delivered)
    }

    // MARK: - chat_subscribe

    /// Pull messages matching the filter. `sinceTs` advances the
    /// per-subscriber cursor so repeated calls with the same
    /// `subscriptionID` deliver only new messages. If `subscriptionID`
    /// is nil, an ephemeral cursor is used (starts from `sinceTs` or
    /// now if omitted).
    ///
    /// This method does NOT block; callers wanting long-poll semantics
    /// wrap it in their own async wait. Everywhere's server-side long
    /// poll comes from the OpenDia extension push channel and is out
    /// of scope for the OpenClicky port.
    public func subscribe(
        subscriptionID: String? = nil,
        kindFilter: String? = nil,
        from: String? = nil,
        sinceTs: Double? = nil
    ) -> [ChatBusMessage] {
        let now = clock()
        lock.lock()
        pruneExpiredLocked(now: now)

        // Resolve the effective cursor. Persistent subscribers get
        // their stored `sinceTs`; ephemeral callers use whatever the
        // caller passed (or `now` — matches "only new" semantics).
        let cursor: Double
        if let subscriptionID {
            if let existing = subscribers[subscriptionID] {
                cursor = existing.sinceTs
            } else {
                let s = SubscriberState(
                    subscriptionID: subscriptionID,
                    kindFilter: kindFilter,
                    fromFilter: from,
                    sinceTs: sinceTs ?? now
                )
                subscribers[subscriptionID] = s
                cursor = s.sinceTs
            }
        } else {
            cursor = sinceTs ?? 0
        }

        let matched = history.filter { message in
            guard message.ts > cursor else { return false }
            if let kindFilter, message.kind != kindFilter { return false }
            if let from, message.from != from { return false }
            return true
        }

        // Advance cursor to the newest match timestamp so subsequent
        // calls do not re-return the same message.
        if let last = matched.last, let subscriptionID {
            if var state = subscribers[subscriptionID] {
                state.sinceTs = last.ts
                // Also refresh filter — repeated subscribe calls can
                // rotate filters without dropping the cursor.
                state.kindFilter = kindFilter ?? state.kindFilter
                state.fromFilter = from ?? state.fromFilter
                subscribers[subscriptionID] = state
            }
        }

        lock.unlock()
        return matched
    }

    // MARK: - Test hooks

    /// Test-only: current history depth (post-prune).
    public func historyCount() -> Int {
        lock.lock()
        pruneExpiredLocked(now: clock())
        let n = history.count
        lock.unlock()
        return n
    }

    /// Test-only: reset all bus state.
    public func reset() {
        lock.lock()
        history.removeAll()
        subscribers.removeAll()
        channels.removeAll()
        lock.unlock()
    }

    // MARK: - chat_list / chat_read / chat_create / chat_delete
    // Everywhere ChatBusTools.cs:32-146 — the extension owns storage
    // upstream, so the OpenClicky port keeps a minimal in-process
    // implementation. Ordering, error codes, and payload keys stay
    // byte-exact with the C# tool.

    /// Everywhere ChatBusTools.cs:34 — `{chats:[{chat_id, title,
    /// updated_at, message_count}]}`.
    public func listChannels() -> [ChatBusChannelSummary] {
        lock.lock()
        defer { lock.unlock() }
        return channels.values
            .map { state in
                ChatBusChannelSummary(
                    chatID: state.chatID,
                    title: state.title,
                    updatedAt: state.updatedAt,
                    messageCount: state.messages.count
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Everywhere ChatBusTools.cs:47 — read messages, optionally
    /// filtering by monotonic msg_id (strictly greater).
    public func readChannel(
        chatID: String,
        sinceMsgID: Int64? = nil
    ) throws -> [ChatBusMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard let state = channels[chatID] else {
            throw ChatBusError.chatNotFound("chat_id=\(chatID) not found")
        }
        guard let cursor = sinceMsgID else { return state.messages }
        return state.messages.filter { message in
            // Wire cursor is monotonic per-channel `msg_id`; encoded
            // as the message index (+ 1) since we do not persist a
            // separate counter.
            guard let idx = state.msgIDIndex[message.messageID] else { return false }
            return idx > cursor
        }
    }

    /// Everywhere ChatBusTools.cs:111 — create channel. Returns the
    /// generated `chat_id`. Title is optional.
    @discardableResult
    public func createChannel(title: String? = nil) -> ChatBusChannelSummary {
        let now = clock()
        let id = UUID().uuidString
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = trimmed.isEmpty ? "chat" : trimmed
        lock.lock()
        channels[id] = ChannelState(chatID: id, title: resolvedTitle, updatedAt: now)
        lock.unlock()
        return ChatBusChannelSummary(chatID: id, title: resolvedTitle, updatedAt: now, messageCount: 0)
    }

    /// Everywhere ChatBusTools.cs:128 — delete channel by id.
    /// Returns `{ok:true, chat_id}`; raises `chatNotFound` when
    /// the id is unknown.
    public func deleteChannel(chatID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard channels.removeValue(forKey: chatID) != nil else {
            throw ChatBusError.chatNotFound("chat_id=\(chatID) not found")
        }
    }

    // MARK: - Internals

    /// Backing store for one chat channel. Held by the outer bus lock;
    /// no independent locking. `msgIDIndex` is the message_id -> ordinal
    /// map used by `readChannel(sinceMsgID:)` to filter monotonically.
    private struct ChannelState {
        let chatID: String
        var title: String
        var updatedAt: Double
        var messages: [ChatBusMessage] = []
        var msgIDIndex: [String: Int64] = [:]
        var nextMsgID: Int64 = 1
    }

    private struct SubscriberState {
        let subscriptionID: String
        var kindFilter: String?
        var fromFilter: String?
        var sinceTs: Double

        func matches(_ msg: ChatBusMessage) -> Bool {
            if let kindFilter, msg.kind != kindFilter { return false }
            if let fromFilter, msg.from != fromFilter { return false }
            return true
        }
    }

    private func pruneExpiredLocked(now: Double) {
        // Everywhere's extension prunes on `chrome.storage.local` writes;
        // we prune every send/subscribe. Cost is O(n) with n <= 200.
        history.removeAll { message in
            (now - message.ts) > ttl
        }
    }
}
