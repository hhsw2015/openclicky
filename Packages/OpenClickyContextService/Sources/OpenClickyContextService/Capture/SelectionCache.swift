// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/SelectionCache.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// OS-wide most-recent-selection cache. Single-slot, 2-minute TTL.
// Populated by successful `SelectedTextCapture.capture()` calls;
// queried before the AX / clipboard fallback runs so a selection made
// in another app survives focus change back to the openclicky panel.
//
// Design fidelity notes vs Everywhere:
//   * Single-slot cache — Everywhere stores exactly one `(text, appKey,
//     capturedAtUtc)` tuple, most recent write wins. NOT keyed by
//     `(app, textHash)` despite what some task briefs claim; verified
//     against `SelectionCache.cs:19-21`.
//   * TTL — `TimeSpan.FromMinutes(2)` verbatim (line 14).
//   * Cache hit criteria — non-empty text AND `now - capturedAtUtc <= Ttl`.
//   * Injectable clock — Everywhere takes `TimeProvider clock` in ctor;
//     openclicky mirrors that so tests can fast-forward without waiting
//     two real minutes.
//   * Thread-safety — Everywhere uses a `Lock` around read/write of the
//     three fields plus the emit-time app-key resolution outside the
//     lock. Swift port uses `NSLock` for the same reason and resolves the
//     app key at `store()` call sites, not inside the lock.
//
// Divergences from Everywhere (documented in phase1-selectedtext report):
//   * Everywhere subscribes to a reactive `IObserver<TextSelectionData>`
//     stream driven by a mouse-hook detector. openclicky does NOT port
//     the detector in Phase 1 — the cache is written manually by
//     `SelectedTextCapture.capture()` on successful AX/clipboard reads.
//     The observable contract of "most recent non-empty selection wins"
//     is preserved regardless of the driver.

import Foundation

/// OS-wide most-recent selected-text cache with a 2-minute TTL.
///
/// Reference: `src/Everywhere.Mcp/Snapshot/SelectionCache.cs`
/// (`GetFresh`, `OnNext`, `Ttl`).
public final class SelectionCache: @unchecked Sendable {

    /// Cache TTL: 2 minutes. Verbatim from `SelectionCache.cs:14`
    /// (`TimeSpan.FromMinutes(2)`).
    public static let ttl: TimeInterval = 120

    /// Process-wide default instance. Callers that need isolation
    /// (tests, per-user profile experiments) construct their own.
    public static let shared = SelectionCache()

    /// Injectable clock for deterministic TTL testing. Signature mirrors
    /// Everywhere's `TimeProvider _clock` field (SelectionCache.cs:17).
    private let clock: () -> Date
    private let ttl: TimeInterval
    private let gate = NSLock()

    private var text: String?
    private var appKey: String?
    private var capturedAt: Date?

    public init(
        clock: @escaping () -> Date = { Date() },
        ttl: TimeInterval = SelectionCache.ttl
    ) {
        self.clock = clock
        self.ttl = ttl
    }

    /// Cached (text, appKey) tuple if a non-empty selection was stored
    /// within the last `ttl` seconds, else `nil`.
    ///
    /// 1:1 with `SelectionCache.GetFresh` (SelectionCache.cs:31-39):
    ///   * empty stored text -> `nil`
    ///   * `now - capturedAt > ttl` -> `nil`
    ///   * otherwise -> the stored tuple
    public func getFresh() -> (text: String, appKey: String?)? {
        gate.lock()
        defer { gate.unlock() }
        guard let stored = text, !stored.isEmpty else { return nil }
        guard let captured = capturedAt else { return nil }
        if clock().timeIntervalSince(captured) > ttl { return nil }
        return (stored, appKey)
    }

    /// Write a new most-recent selection. Empty text is ignored, matching
    /// `SelectionCache.OnNext` (SelectionCache.cs:41-54, which guards on
    /// `string.IsNullOrEmpty(value.Text)`).
    public func store(text: String, appKey: String?) {
        if text.isEmpty { return }
        let now = clock()
        gate.lock()
        self.text = text
        self.appKey = appKey
        self.capturedAt = now
        gate.unlock()
    }

    /// Test-only reset — not on Everywhere's API but harmless since the
    /// C# type is `IDisposable` and testable via `TimeProvider`. Swift
    /// tests reset because the class-instance shared default persists
    /// across `-swift test` cases in the same process.
    public func reset() {
        gate.lock()
        text = nil
        appKey = nil
        capturedAt = nil
        gate.unlock()
    }
}
