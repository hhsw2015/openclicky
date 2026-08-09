// LinkRectStash.swift
// OpenClickyContextService
//
// Multi-batch stash for Alt+L LinkRect harvest results.
//
// Divergence from Everywhere: Everywhere's LinkRect flow is a direct-
// ship — Alt+L drag → CaptureLinks() → writes stash file + fires
// launch phrase immediately (`LinkRectHotkeyInitializer.OnHotkey` +
// `ContextStashWriter.CaptureLinks`). OpenClicky UNIFIES all capture
// gestures under Shift+Space:
//
//   - Alt+L → LinkRectStash.set(...)  (no immediate flush)
//   - Alt+D → WhiteboardStash.set(...)
//   - Alt+S → PickStash.set(...) (multi-slot)
//   - Shift+Space → captureCoreAsync merges all stashes into ONE
//     envelope, ONE flush, ONE consumer (cmux by default, voice model
//     when Ctrl+Option is held).
//
// This makes context injection consistent across text-agent (cmux)
// and voice-agent (realtime) — both receive the same accumulated
// context bundle.

import Foundation

@MainActor
public final class LinkRectStash {
    public static let shared = LinkRectStash()

    private var pending: [OpenClickyPickedLink] = []
    private var updatedAt: Date?

    /// TTL after which the batch is considered stale. Matches
    /// PickStash / WhiteboardStash conventions.
    public static let ttlSeconds: TimeInterval = 300

    /// Notification fired after `set` / `clearWithEvent`.
    public static let didChange = Notification.Name("openclicky.linkRectStashDidChange")

    private init() {}

    /// Merge `links` into the current batch, deduping by URL. If the
    /// stash is stale (past TTL) the merge resets to `links` only.
    /// Fires `linkRectStashDidChange`.
    public func set(_ links: [OpenClickyPickedLink]) {
        // If prior batch is stale, discard it and start fresh — same
        // TTL guard as `peek`.
        if let ts = updatedAt, Date().timeIntervalSince(ts) > Self.ttlSeconds {
            pending = []
        }
        var seen = Set(pending.map { $0.url.lowercased() })
        for link in links {
            let key = link.url.lowercased()
            if seen.insert(key).inserted {
                pending.append(link)
            }
        }
        updatedAt = Date()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Snapshot without consuming. Returns nil when empty or stale.
    public func peek() -> [OpenClickyPickedLink]? {
        guard let updatedAt else { return nil }
        if Date().timeIntervalSince(updatedAt) > Self.ttlSeconds { return nil }
        return pending.isEmpty ? nil : pending
    }

    /// Atomic drain — returns current batch and clears.
    public func take() -> [OpenClickyPickedLink]? {
        let out = peek()
        pending = []
        updatedAt = nil
        return out
    }

    /// True if a non-stale batch is queued.
    public var hasPending: Bool {
        peek() != nil
    }

    /// Clear + fire notification.
    public func clearWithEvent() {
        let had = !pending.isEmpty
        pending = []
        updatedAt = nil
        if had {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Silent clear (shutdown / tests).
    public func clear() {
        pending = []
        updatedAt = nil
    }
}
