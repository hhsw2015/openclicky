//
//  HeyClickyLog.swift
//  cursor-buddy
//
//  Thin wrapper around OpenClickyMessageLogStore for HeyClicky Free
//  events, so every touchpoint uses a consistent lane + provider tag
//  and adding a new event is a single-line call.
//
//  Events are visible in Settings → Logs.
//

import Foundation

enum HeyClickyLog {
    /// Compile-time flag: when TRUE, `log(verbose: true, ...)` calls
    /// still write to the log store; when FALSE, they short-circuit
    /// before any allocation or JSON encoding.
    ///
    /// Debug builds → verbose ON, so developers see everything.
    /// Release builds → verbose OFF, so users don't pay the write
    /// queue + fsync cost for per-frame / per-chunk diagnostic events.
    /// Errors and per-turn state changes are logged unconditionally
    /// (call `log(...)` without `verbose:`).
    #if DEBUG
    static let verboseEnabled = true
    #else
    static let verboseEnabled = false
    #endif

    /// Emit a HeyClicky event. Merges `provider=heyclicky_free` into
    /// fields automatically. `direction`:
    ///   - "internal" for state changes (default)
    ///   - "outgoing" for requests we send
    ///   - "incoming" for responses/events we receive
    ///   - "error" for failures
    ///
    /// `verbose`: mark high-frequency / diagnostic events. When true
    /// AND the build is Release, this call is a no-op. Use for
    /// per-frame / per-chunk / per-audio-buffer signals. Keep errors
    /// and turn-level state changes at `verbose: false`.
    static func log(
        _ event: String,
        lane: String = "system",
        direction: String = "internal",
        verbose: Bool = false,
        _ fields: [String: Any] = [:]
    ) {
        if verbose && !verboseEnabled { return }
        var merged: [String: Any] = fields
        merged["provider"] = "heyclicky_free"
        OpenClickyMessageLogStore.shared.append(
            lane: lane,
            direction: direction,
            event: event,
            fields: merged
        )
    }
}

/// Same compile-time gate for the underlying store. Callers not on the
/// HeyClickyLog wrapper (e.g. `OpenClickyMessageLogStore.shared.append`
/// directly from OpenRewind/Capture) can go through this helper to
/// short-circuit high-frequency events in Release without threading
/// booleans through every call site.
enum OpenClickyLog {
    #if DEBUG
    static let verboseEnabled = true
    #else
    static let verboseEnabled = false
    #endif

    /// Verbose event pipe — no-op in Release. Use for per-frame /
    /// per-chunk / per-audio-buffer diagnostics.
    static func verbose(
        lane: String,
        direction: String = "internal",
        event: String,
        fields: [String: Any] = [:]
    ) {
        if !verboseEnabled { return }
        OpenClickyMessageLogStore.shared.append(
            lane: lane, direction: direction, event: event, fields: fields
        )
    }
}
