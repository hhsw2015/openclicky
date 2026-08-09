// Ported from Everywhere: src/Everywhere.Core/Interop/PickStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Single-slot cross-call buffer holding the element a user just
// "pinned" for an AI agent via the Agent Pick hotkey. The MCP
// `read_pick` tool consumes the slot (Take semantics) so the next
// call sees an empty stash again, mirroring the user mental model
// "I pinned this for that one question".
//
// Pins expire after `defaultTtl` so a forgotten pin does not leak
// into a future agent conversation. Replacing an unread pin is fine
// -- the new one wins.
//
// Design fidelity notes vs Everywhere:
//   * TTL constant `TimeSpan.FromMinutes(5)` (PickStash.cs:14) ->
//     `defaultTtl: TimeInterval = 300`.
//   * Everywhere's `object lock` (PickStash.cs:16) becomes `NSLock`.
//   * Everywhere raises `Pinned` on Set and `Cleared` on Take / Clear
//     with a value transition. Swift port funnels both through a
//     single `NotificationCenter` event (`pickStashDidChange`),
//     matching the roadmap contract for "fire didChange on write".
//     The stash itself is passed as `object:` so observers can query
//     `hasFreshPin` / `peek()` synchronously.
//   * Injectable clock (`TimeProvider _clock`, PickStash.cs:17) is
//     preserved so tests can fast-forward past the 5-minute TTL
//     without waiting in real time.

import Foundation

/// NotificationCenter event names emitted by Layer 4 UX stashes.
/// Kept side-by-side so overlay code can subscribe to both without
/// juggling separate declarations.
public extension Notification.Name {
    /// Posted after `PickStash.set`, `PickStash.take` (when a value
    /// was consumed) or `PickStash.clearWithEvent`. The `object` is
    /// the `PickStash` instance itself.
    static let pickStashDidChange = Notification.Name("com.openclicky.contextservice.PickStashDidChange")

    /// Posted after `AnnotationStash.append`, `.consume(_:)` or
    /// `.clearWithEvent()` when the visible entry set changed. The
    /// `object` is the `AnnotationStash` instance itself.
    static let annotationStashDidChange = Notification.Name("com.openclicky.contextservice.AnnotationStashDidChange")
}

/// Process-wide pin buffer.
///
/// Reference: `src/Everywhere.Core/Interop/PickStash.cs`
/// (`Set`, `Take`, `HasFreshPin`, `ClearWithEvent`, `DefaultTtl`).
public final class PickStash: @unchecked Sendable {

    /// Default pin TTL: 5 minutes. Verbatim from PickStash.cs:14
    /// (`TimeSpan.FromMinutes(5)`).
    public static let defaultTtl: TimeInterval = 5 * 60

    /// Process-wide default instance. Callers that need isolation
    /// (tests, per-user profile experiments) construct their own.
    public static let shared = PickStash()

    private let clock: () -> Date
    private let ttl: TimeInterval
    private let gate = NSLock()
    private let notificationCenter: NotificationCenter

    private struct Entry {
        let element: PickedElement
        let expiresAt: Date
    }

    /// Multi-slot pin storage. Divergence from Everywhere
    /// (`PickStash.cs:18 _current` is single-slot) — OpenClicky
    /// supports accumulating multiple pins across Alt+S presses so
    /// agents see the full set the user selected. Ordered by
    /// insertion; latest at end.
    private var entries: [Entry] = []

    /// Max concurrent pins to prevent runaway growth. Successive
    /// `set()` past this cap drops the oldest entry.
    public static let maxEntries: Int = 32

    /// Identity key used to dedupe re-selection of the SAME element.
    /// Mirrors the anchor id `AnnotationBadgeOverlayClassifier.pinAnchorID`
    /// uses so the overlay and stash agree on "is this the same pin".
    private static func identityKey(for e: PickedElement) -> String {
        let bx = Int(e.bounds.origin.x)
        let by = Int(e.bounds.origin.y)
        let bw = Int(e.bounds.width)
        let bh = Int(e.bounds.height)
        return "\(e.pid)|\(e.role ?? "?")|\(bx),\(by),\(bw),\(bh)"
    }

    public init(
        clock: @escaping () -> Date = { Date() },
        ttl: TimeInterval = PickStash.defaultTtl,
        notificationCenter: NotificationCenter = .default
    ) {
        self.clock = clock
        self.ttl = ttl
        self.notificationCenter = notificationCenter
    }

    /// Append `element` to the multi-slot store. If the stash is
    /// already at `maxEntries`, the oldest entry is dropped.
    /// Divergence from Everywhere `PickStash.Set` (PickStash.cs:42-51,
    /// single-slot replace) — accumulates so agents can act on the
    /// full set of user-pinned elements.
    public func set(_ element: PickedElement, ttl: TimeInterval? = nil) {
        let effectiveTtl = ttl ?? self.ttl
        let expiry = clock().addingTimeInterval(effectiveTtl)
        gate.lock()
        let prevCount = entries.count
        // Dedup: if an identical element is already in the stash,
        // refresh its expiry instead of appending. Identity = same
        // (pid, role, bounds) triple — mirrors the anchor id the
        // overlay uses to dedupe badges.
        let key = Self.identityKey(for: element)
        var replaced = false
        for i in 0 ..< entries.count {
            if Self.identityKey(for: entries[i].element) == key {
                entries[i] = Entry(element: element, expiresAt: expiry)
                replaced = true
                break
            }
        }
        if !replaced {
            entries.append(Entry(element: element, expiresAt: expiry))
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
        }
        let newCount = entries.count
        gate.unlock()
        CaptureLog.log(
            "openclicky.stash.pick.set",
            lane: "pick",
            [
                "role": element.role ?? "?",
                "title": element.title ?? "",
                "pid": String(element.pid),
                "prev_count": String(prevCount),
                "new_count": String(newCount),
                "dedup_replaced": replaced ? "true" : "false",
                "ttl_seconds": String(Int(effectiveTtl)),
            ]
        )
        notificationCenter.post(name: .pickStashDidChange, object: self)
    }

    /// Atomically drain ALL entries and clear the stash. Returns
    /// non-expired entries only, in insertion order.
    public func takeAll() -> [PickedElement] {
        let now = clock()
        gate.lock()
        let all = entries
        let hadEntries = !entries.isEmpty
        entries = []
        gate.unlock()

        let fresh = all.filter { $0.expiresAt > now }.map { $0.element }
        CaptureLog.log(
            "openclicky.stash.pick.take",
            lane: "pick",
            [
                "was_empty": hadEntries ? "false" : "true",
                "drained_count": String(all.count),
                "fresh_count": String(fresh.count),
            ]
        )
        if hadEntries {
            notificationCenter.post(name: .pickStashDidChange, object: self)
        }
        return fresh
    }

    /// Legacy single-value take (drains everything, returns latest
    /// non-expired). Kept so existing byte-parity call sites
    /// (`OpenClickyStashTools`) don't break.
    public func take() -> PickedElement? {
        return takeAll().last
    }

    /// Snapshot ALL non-expired entries without consuming.
    public func peekAll() -> [PickedElement] {
        let now = clock()
        gate.lock()
        defer { gate.unlock() }
        return entries.filter { $0.expiresAt > now }.map { $0.element }
    }

    /// Legacy single-value peek (returns latest non-expired) — kept
    /// so `ContextStashWriter.captureCoreAsync` and other legacy
    /// consumers work unchanged.
    public func peek() -> PickedElement? {
        return peekAll().last
    }

    /// True if any non-expired entry is in the stash.
    public var hasFreshPin: Bool {
        let now = clock()
        gate.lock()
        defer { gate.unlock() }
        return entries.contains { $0.expiresAt > now }
    }

    /// Fresh entry count for observers that need the raw count.
    public var freshCount: Int {
        let now = clock()
        gate.lock()
        defer { gate.unlock() }
        return entries.filter { $0.expiresAt > now }.count
    }

    /// Drop everything and fire `pickStashDidChange` if we discarded
    /// anything.
    public func clearWithEvent() {
        gate.lock()
        let hadEntries = !entries.isEmpty
        entries = []
        gate.unlock()
        if hadEntries {
            CaptureLog.log(
                "openclicky.stash.pick.cleared",
                lane: "pick",
                ["reason": "clear_with_event"]
            )
            notificationCenter.post(name: .pickStashDidChange, object: self)
        }
    }

    /// Silent clear (no event) — shutdown / test reset.
    public func clear() {
        gate.lock()
        entries = []
        gate.unlock()
    }
}
