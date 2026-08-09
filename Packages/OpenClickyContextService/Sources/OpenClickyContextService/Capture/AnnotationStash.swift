// Ported from Everywhere: src/Everywhere.Core/Interop/AnnotationStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Multi-entry append-and-drain buffer holding user annotations
// queued for the next SnapshotContext send. Unlike `PickStash`'s
// single slot that the agent Takes, the annotation flow is
// "user accumulates N notes across pins/whiteboard/selection, then
// ships all of them in the next SnapshotContext".
//
// TTL prevents long-forgotten notes from leaking into a future
// conversation; queue-depth + per-field caps prevent a buggy or
// malicious MCP client from unbounded growth.
//
// Design fidelity notes vs Everywhere:
//   * `DefaultTtl = TimeSpan.FromMinutes(10)` (AnnotationStash.cs:57)
//     -> `defaultTtl: TimeInterval = 600`.
//   * Defensive caps `MaxBodyLength = 8_000`, `MaxAnchorLabelLength
//     = 400`, `MaxAnchorRefLength = 200`, `MaxQueueDepth = 200`
//     (AnnotationStash.cs:63-66) mirrored verbatim.
//   * Everywhere's `object lock` (line 68) becomes `NSLock`.
//   * Peek returns a snapshot of live entries WITHOUT clearing;
//     Consume drops exactly the batch previously handed out (identity
//     compare of values) so a failed downstream write leaves the
//     queue intact for the next attempt.
//   * Change notification: Everywhere raises `Changed` on every
//     visible-count transition and additionally `Added` per item on
//     append (AnnotationStash.cs:83-89, 123-124). Swift port funnels
//     both into `annotationStashDidChange`, matching the roadmap
//     contract for a single `didChange` write event. Observers can
//     pull the current entry set via `peek()`.
//   * `AnnotationSource` / `AnnotationItem` value types live in
//     `Types/CaptureTypes.swift` for reuse across capture + UI.

import Foundation

/// Errors raised by `AnnotationStash.append` when the caller's input
/// violates the defensive size caps. Mapped from Everywhere's
/// `ArgumentException` (AnnotationStash.cs:101-115) so the callers
/// upstream can produce parity error strings.
public enum AnnotationStashError: Error, Equatable {
    case bodyTooLong(limit: Int)
    case anchorLabelTooLong(limit: Int)
    case anchorRefTooLong(limit: Int)
    case queueDepthExceeded(limit: Int)
}

/// Process-wide annotation queue.
///
/// Reference: `src/Everywhere.Core/Interop/AnnotationStash.cs`
/// (`Add`, `Peek`, `Drain`, `Consume`, `Clear`, `DefaultTtl`,
/// `MaxBodyLength`, ...).
public final class AnnotationStash: @unchecked Sendable {

    /// Default annotation TTL: 10 minutes. Verbatim from
    /// AnnotationStash.cs:57 (`TimeSpan.FromMinutes(10)`).
    public static let defaultTtl: TimeInterval = 10 * 60

    /// Max characters for `AnnotationItem.body`. Verbatim from
    /// AnnotationStash.cs:63.
    public static let maxBodyLength = 8_000
    /// Max characters for `AnnotationItem.anchorLabel`. Verbatim
    /// from AnnotationStash.cs:64.
    public static let maxAnchorLabelLength = 400
    /// Max characters for `AnnotationItem.anchorRef`. Verbatim from
    /// AnnotationStash.cs:65.
    public static let maxAnchorRefLength = 200
    /// Max queue depth. Verbatim from AnnotationStash.cs:66.
    public static let maxQueueDepth = 200

    /// Process-wide default instance. Callers that need isolation
    /// (tests, per-user profile experiments) construct their own.
    public static let shared = AnnotationStash()

    private struct Entry {
        let item: AnnotationItem
        let expiresAt: Date
    }

    private let clock: () -> Date
    private let ttl: TimeInterval
    private let gate = NSLock()
    private let notificationCenter: NotificationCenter
    private var entries: [Entry] = []

    public init(
        clock: @escaping () -> Date = { Date() },
        ttl: TimeInterval = AnnotationStash.defaultTtl,
        notificationCenter: NotificationCenter = .default
    ) {
        self.clock = clock
        self.ttl = ttl
        self.notificationCenter = notificationCenter
    }

    /// Queue an annotation. Returns the post-insert live count so
    /// callers can echo it back to the MCP client, matching
    /// `AnnotationStash.Add` (AnnotationStash.cs:97-126).
    ///
    /// Throws `AnnotationStashError` on oversize fields or when the
    /// queue would exceed `maxQueueDepth`. Both mirror Everywhere's
    /// `ArgumentException` guard rail.
    @discardableResult
    public func append(_ item: AnnotationItem, ttl: TimeInterval? = nil) throws -> Int {
        if item.body.count > AnnotationStash.maxBodyLength {
            throw AnnotationStashError.bodyTooLong(limit: AnnotationStash.maxBodyLength)
        }
        if item.anchorLabel.count > AnnotationStash.maxAnchorLabelLength {
            throw AnnotationStashError.anchorLabelTooLong(limit: AnnotationStash.maxAnchorLabelLength)
        }
        if let ref = item.anchorRef, ref.count > AnnotationStash.maxAnchorRefLength {
            throw AnnotationStashError.anchorRefTooLong(limit: AnnotationStash.maxAnchorRefLength)
        }

        let now = clock()
        let effectiveTtl = ttl ?? self.ttl
        let expiry = now.addingTimeInterval(effectiveTtl)

        let newCount: Int
        let countBefore: Int
        gate.lock()
        pruneExpiredLocked(now: now)
        countBefore = entries.count
        if entries.count >= AnnotationStash.maxQueueDepth {
            gate.unlock()
            throw AnnotationStashError.queueDepthExceeded(limit: AnnotationStash.maxQueueDepth)
        }
        entries.append(Entry(item: item, expiresAt: expiry))
        newCount = entries.count
        gate.unlock()

        CaptureLog.log(
            "openclicky.stash.annotation.push",
            lane: "system",
            [
                "source": String(describing: item.source),
                "count_before": String(countBefore),
                "count_after": String(newCount),
            ]
        )
        notificationCenter.post(name: .annotationStashDidChange, object: self)
        return newCount
    }

    /// Snapshot the live (non-expired) entries without consuming.
    /// Materialised so callers can iterate without holding the lock.
    ///
    /// 1:1 with `AnnotationStash.Peek` (AnnotationStash.cs:133-144).
    public func peek() -> [AnnotationItem] {
        let now = clock()
        gate.lock()
        defer { gate.unlock() }
        pruneExpiredLocked(now: now)
        return entries.map(\.item)
    }

    /// Atomically read all live entries and clear the stash.
    /// Fires `annotationStashDidChange` when the queue had entries.
    ///
    /// 1:1 with `AnnotationStash.Drain` (AnnotationStash.cs:151-168).
    /// Retained for parity with Everywhere's SnapshotContext capture
    /// path even though the current OpenClicky pipeline prefers
    /// `peek()` + `consume(_:)` so a failed write leaves the queue
    /// intact for the next attempt.
    @discardableResult
    public func drain() -> [AnnotationItem] {
        let now = clock()
        gate.lock()
        pruneExpiredLocked(now: now)
        let snapshot = entries.map(\.item)
        let hadEntries = !entries.isEmpty
        entries.removeAll()
        gate.unlock()
        if hadEntries {
            notificationCenter.post(name: .annotationStashDidChange, object: self)
        }
        return snapshot
    }

    /// Drop exactly the items previously returned by `peek()`. Used
    /// by the snapshot pipeline so annotations are only removed
    /// AFTER the on-disk stash file has been written successfully; a
    /// transient I/O failure leaves the queued notes available for
    /// the user's next attempt. Anything appended since the peek (or
    /// that has expired) stays.
    ///
    /// 1:1 with `AnnotationStash.Consume`
    /// (AnnotationStash.cs:219-233). Everywhere identity-matches by
    /// `ReferenceEquals` on the underlying record; the Swift port
    /// value-matches on the immutable `AnnotationItem` (safe because
    /// `capturedAt` gives each item a de-facto unique key). Fires
    /// `annotationStashDidChange` unconditionally for a non-empty
    /// input batch, mirroring `AnnotationStash.cs:232` which invokes
    /// `Changed?.Invoke()` outside the match loop regardless of how
    /// many entries were actually removed.
    public func consume(_ items: [AnnotationItem]) {
        if items.isEmpty { return }
        // Track "already consumed" per position so a duplicate value
        // in `items` only removes one entry per occurrence, matching
        // Everywhere's descending-index single-remove per hit.
        gate.lock()
        let countBefore = entries.count
        var kept = 0
        for target in items {
            if let idx = entries.firstIndex(where: { $0.item == target }) {
                entries.remove(at: idx)
                kept += 1
            }
        }
        let countAfter = entries.count
        gate.unlock()
        CaptureLog.log(
            "openclicky.stash.annotation.consume",
            lane: "system",
            [
                "input_batch": String(items.count),
                "kept": String(kept),
                "drained": String(countBefore - countAfter),
            ]
        )
        // Unconditional post — matches AnnotationStash.cs:232.
        notificationCenter.post(name: .annotationStashDidChange, object: self)
    }

    /// Remove the first live entry whose value equals `item`. Fires
    /// `annotationStashDidChange` when an entry was removed.
    ///
    /// 1:1 with `AnnotationStash.RemoveItem`
    /// (AnnotationStash.cs:179-193). Everywhere identity-matches via
    /// `ReferenceEquals` because `AnnotationItem` is a C# `record`
    /// (heap-boxed); the Swift port is a value struct so `==` is the
    /// only sensible match. `capturedAt` gives each item a de-facto
    /// unique key when the caller round-trips the exact instance it
    /// received from `peek`.
    @discardableResult
    public func removeItem(_ item: AnnotationItem) -> Bool {
        let now = clock()
        gate.lock()
        pruneExpiredLocked(now: now)
        let idx = entries.firstIndex(where: { $0.item == item })
        if let idx {
            entries.remove(at: idx)
        }
        gate.unlock()
        if idx != nil {
            notificationCenter.post(name: .annotationStashDidChange, object: self)
            return true
        }
        return false
    }

    /// Remove the live entry at `index`, matching the current `peek()`
    /// ordering. Returns `false` when `index` is out of range.
    ///
    /// 1:1 with `AnnotationStash.Remove(int)`
    /// (AnnotationStash.cs:195-209). Prunes expired entries before the
    /// bounds check so callers see the same view `peek()` returned.
    @discardableResult
    public func remove(at index: Int) -> Bool {
        let now = clock()
        gate.lock()
        pruneExpiredLocked(now: now)
        guard index >= 0, index < entries.count else {
            gate.unlock()
            return false
        }
        entries.remove(at: index)
        gate.unlock()
        notificationCenter.post(name: .annotationStashDidChange, object: self)
        return true
    }

    /// Drop every queued annotation. Fires
    /// `annotationStashDidChange` if the queue was non-empty.
    ///
    /// Semantic equivalent of Everywhere's `Clear`
    /// (AnnotationStash.cs:235-244) merged with `Changed?.Invoke()`.
    /// Name aligns with `PickStash.clearWithEvent` for a consistent
    /// Layer 4 API surface.
    public func clearWithEvent() {
        gate.lock()
        let hadEntries = !entries.isEmpty
        entries.removeAll()
        gate.unlock()
        if hadEntries {
            notificationCenter.post(name: .annotationStashDidChange, object: self)
        }
    }

    /// Silent clear (no event). Reserved for shutdown / test-reset
    /// paths where observers do not need to know.
    public func clear() {
        gate.lock()
        entries.removeAll()
        gate.unlock()
    }

    /// Live entry count (expired entries pruned first). Matches
    /// `AnnotationStash.Count` (AnnotationStash.cs:246-...).
    public var count: Int {
        let now = clock()
        gate.lock()
        defer { gate.unlock() }
        pruneExpiredLocked(now: now)
        return entries.count
    }

    // MARK: - private

    /// Drop expired entries. Caller must hold `gate`. Silent -- does
    /// not fire `annotationStashDidChange`; TTL expiry is a passive
    /// housekeeping event and observers only care about explicit
    /// user-driven changes.
    private func pruneExpiredLocked(now: Date) {
        entries.removeAll { $0.expiresAt <= now }
    }
}
