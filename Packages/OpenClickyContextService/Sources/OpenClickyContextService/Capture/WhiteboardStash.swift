// Ported from Everywhere: src/Everywhere.Core/Interop/Whiteboard/WhiteboardStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Cross-call buffer for whiteboard regions the user just drew.
//
// Design fidelity vs Everywhere:
//   * Single-slot most-recent-wins for `pendingRegions` — replacing an
//     unread session is fine, the new whiteboard wins
//     (`WhiteboardStash.cs:9-11`).
//   * `take()` is atomic read + clear of the regions slot only, matching
//     `Take()` (lines 169-178). Expired entries return nil.
//   * `peek()` snapshots without consuming, expired entries return nil
//     (lines 183-190).
//   * `_imageBytesById` side-table — critical detail per doc 05 line 27
//     and the comment at `WhiteboardStash.cs:19-24`. The stash keeps PNG
//     bytes alive through a Take() so the two-tool flow works:
//         read_whiteboard()        → consumes regions, exposes image_ids
//         read_whiteboard_image(id) → still finds bytes, until TTL
//     Both slots share the same TTL clock, set at `set()` call time.
//     `take()` does NOT clear the image cache; only `clearWithEvent()` /
//     TTL expiry / a subsequent `set()` replace it.
//   * `clearWithEvent()` posts a Notification when there was something
//     to clear — Swift substitute for the C# `event Action? Cleared`
//     that `WhiteboardOverlayHost` listens on.
//   * Injectable clock — Everywhere takes a `TimeProvider` in ctor. The
//     public `shared` uses the wall clock; tests build private instances
//     with a mocked clock (mirrors `SelectionCache`).
//
// Divergences (documented in the phase5 impl notes):
//   * The public Swift API is the slim contract Phase 5 requires: no
//     `Append`, no `Drawn` event, no MergeImageBytes helper. The Phase 7
//     overlay does its own region assembly and calls `set()` once per
//     commit; there is no partial-append workflow in openclicky.
//   * `WhiteboardRegion` here is the wire-format record (id, bbox,
//     gesture, ocrText, capturedAt) not the Everywhere AXR-heavy record
//     — see comment in `Types/CaptureTypes.swift`.
//   * Image bytes are keyed by `UUID` rather than the C# `string`
//     `image_id`. The JSON boundary in Phase 6 stringifies at the
//     `context-stash.json` serialisation step.

import Foundation
import CoreGraphics

public extension Notification.Name {
    /// Posted by `WhiteboardStash.clearWithEvent()` when there was a
    /// pending session that got cleared. Swift-native substitute for
    /// Everywhere's `event Action? Cleared` (WhiteboardStash.cs:44).
    /// Object is the stash instance; userInfo is empty.
    static let openClickyWhiteboardStashCleared = Notification.Name(
        "com.jkneen.openclicky.WhiteboardStash.Cleared"
    )
}

/// In-memory whiteboard region buffer with 5-minute TTL and a paired
/// image-bytes side-table.
///
/// See file header for design fidelity notes vs Everywhere's
/// `WhiteboardStash.cs`.
public final class WhiteboardStash: @unchecked Sendable {

    /// TTL for both region and image slots. Verbatim from
    /// `WhiteboardStash.cs:14` (`TimeSpan.FromMinutes(5)` = 300s).
    public static let defaultTtl: TimeInterval = 300

    /// Process-wide default. Tests construct their own instance so they
    /// can inject a clock and TTL.
    public static let shared = WhiteboardStash()

    private let lock = NSLock()
    private let clock: () -> Date
    private let ttl: TimeInterval
    private let notificationCenter: NotificationCenter

    // Region slot — single most-recent-wins entry. Expires with the
    // stash-level TTL captured at `set()` time.
    private var pendingRegions: [WhiteboardRegion]?
    private var pendingExpiresAtUnix: Double = 0

    // Image bytes side-table. Independent field so `take()` can drop the
    // regions slot without affecting these entries. `WhiteboardStash.cs:23`.
    private var imageBytesById: [UUID: WhiteboardImageEntry] = [:]

    public convenience init() {
        self.init(
            clock: { Date() },
            ttl: WhiteboardStash.defaultTtl,
            notificationCenter: .default
        )
    }

    /// Designated test initialiser. Mirrors the injectable-clock pattern
    /// used by `SelectionCache` so TTL tests can advance time without
    /// blocking on wall-clock waits.
    public init(
        clock: @escaping () -> Date,
        ttl: TimeInterval = WhiteboardStash.defaultTtl,
        notificationCenter: NotificationCenter = .default
    ) {
        self.clock = clock
        self.ttl = ttl
        self.notificationCenter = notificationCenter
    }

    /// Overwrite the region slot with `regions` and refresh the image
    /// bytes side-table with the supplied `imageBytesById`. Both slots
    /// share the expiry timestamp derived from the current clock + TTL.
    ///
    /// Empty `regions` are permitted — the Everywhere source throws in
    /// that case, but the Swift port callers (Phase 7 overlay) filter
    /// upstream and the stash treats empty simply as "no session".
    /// A caller that supplies an empty region list gets `hasPending ==
    /// false`; image bytes still get replaced (may be an explicit "no
    /// regions, only inline images" scenario in future).
    public func set(regions: [WhiteboardRegion], imageBytesById: [UUID: Data]) {
        let now = clock()
        let expiresAt = now.timeIntervalSince1970 + ttl
        var newImageMap: [UUID: WhiteboardImageEntry] = [:]
        newImageMap.reserveCapacity(imageBytesById.count)
        for (id, bytes) in imageBytesById {
            newImageMap[id] = WhiteboardImageEntry(
                id: id,
                pngBytes: bytes,
                expiresAtUnix: expiresAt
            )
        }
        lock.lock()
        if regions.isEmpty {
            self.pendingRegions = nil
            self.pendingExpiresAtUnix = 0
        } else {
            self.pendingRegions = regions
            self.pendingExpiresAtUnix = expiresAt
        }
        // Replace the image side-table wholesale — the new session's
        // image_ids may or may not overlap with the previous one, and
        // Everywhere's `set()` also replaces `_imageBytesById` outright
        // (WhiteboardStash.cs:61).
        self.imageBytesById = newImageMap
        lock.unlock()
        CaptureLog.log(
            "openclicky.stash.whiteboard.set",
            lane: "whiteboard",
            [
                "region_count": String(regions.count),
                "has_image_bytes": imageBytesById.isEmpty ? "false" : "true",
            ]
        )
    }

    /// Snapshot without consuming. Returns nil when empty or expired.
    public func peek() -> [WhiteboardRegion]? {
        let nowUnix = clock().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let regions = pendingRegions else { return nil }
        if pendingExpiresAtUnix <= nowUnix { return nil }
        return regions
    }

    /// Atomically read and clear the regions slot. Image bytes side-table
    /// is intentionally untouched — the two-tool flow depends on it
    /// surviving region consumption (`WhiteboardStash.cs:19-24`).
    /// Returns nil when empty or expired.
    public func take() -> [WhiteboardRegion]? {
        let nowUnix = clock().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        let regions = pendingRegions
        let expiry = pendingExpiresAtUnix
        pendingRegions = nil
        pendingExpiresAtUnix = 0
        guard let regions else { return nil }
        return expiry <= nowUnix ? nil : regions
    }

    /// Look up PNG bytes by image id. Returns nil when the id is unknown
    /// or the shared TTL has expired.
    ///
    /// Mirrors `PeekImageBytes` (`WhiteboardStash.cs:145-164`): TTL is
    /// checked per entry and expired entries are lazily removed so a
    /// long-idle stash doesn't retain stale image bytes forever.
    public func imageBytes(for id: UUID) -> Data? {
        let nowUnix = clock().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let entry = imageBytesById[id] else { return nil }
        if entry.expiresAtUnix <= nowUnix {
            // Lazy cleanup — mirrors the C# path that sets
            // `_imageBytesById = null` when the shared expiry has
            // passed (line 159). We're keyed per-entry so drop only the
            // expired one; a future `set()` will replace whatever else
            // is left.
            imageBytesById.removeValue(forKey: id)
            return nil
        }
        return entry.pngBytes
    }

    /// Drop both slots and, when there was a pending regions session,
    /// post `openClickyWhiteboardStashCleared` on the injected
    /// notification centre. Mirrors `ClearWithEvent`
    /// (`WhiteboardStash.cs:217-227`).
    ///
    /// The gate matches Everywhere byte-for-byte: `fire = _current is
    /// not null` (`WhiteboardStash.cs:222`) — the image bytes side-
    /// table is deliberately NOT part of the signal. A caller that
    /// only ever loaded image bytes (e.g. via a `set()` with empty
    /// regions) does not have a "pending whiteboard" and observers
    /// should stay quiet.
    public func clearWithEvent() {
        lock.lock()
        let hadPending = pendingRegions != nil
        let regionsGated = pendingRegions?.count ?? 0
        let imagesGated = imageBytesById.count
        pendingRegions = nil
        pendingExpiresAtUnix = 0
        imageBytesById.removeAll(keepingCapacity: false)
        lock.unlock()
        CaptureLog.log(
            "openclicky.stash.whiteboard.clear_with_event",
            lane: "whiteboard",
            [
                "regions_gated": String(regionsGated),
                "images_gated": String(imagesGated),
                "had_pending": hadPending ? "true" : "false",
            ]
        )
        if hadPending {
            notificationCenter.post(
                name: .openClickyWhiteboardStashCleared,
                object: self
            )
        }
    }

    /// Silent variant of `clearWithEvent()`. Drops both the regions
    /// slot and the image bytes side-table without posting any
    /// notification. Reserved for shutdown / test-reset paths.
    ///
    /// 1:1 with `Clear()` (`WhiteboardStash.cs:203-210`).
    public func clear() {
        lock.lock()
        pendingRegions = nil
        pendingExpiresAtUnix = 0
        imageBytesById.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// True when a non-expired regions slot exists. Corresponds to
    /// `HasFreshWhiteboard` (`WhiteboardStash.cs:192-201`).
    public var hasPending: Bool {
        let nowUnix = clock().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard pendingRegions != nil else { return false }
        return pendingExpiresAtUnix > nowUnix
    }
}
