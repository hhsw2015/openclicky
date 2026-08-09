//
//  MirageTokenCache.swift
//  cursor-buddy
//
//  Per-provider bearer/JWT cache used by MirageDeepgramClient and
//  MirageCartesiaClient. Both providers give aegis-proxy → short-lived
//  tokens (Deepgram JWT + Cartesia bearer, ~3600s TTL) that then let the
//  client open a direct WSS/SSE with the actual STT/TTS service. We hold
//  the token in memory, refresh at 90% of TTL, and drop it when the
//  upstream returns 429 (quota exhausted for the current device-id — the
//  Backend Client's UUID pool will rotate on its own, and the next
//  `token(...)` call mints under the new identity).
//
//  Direct Swift port of Peeky `peeky/src/providers/token_cache.rs` (51
//  lines). Behaviour parity kept deliberately narrow: no persistence, no
//  cross-provider sharing — each provider instantiates its own cache so
//  the two lanes' identities and refresh cadences do not interfere.

import Foundation

/// Serialized state for one provider's short-lived token. Actor because
/// concurrent turns (streaming STT + streaming TTS) share the same cache
/// and must not double-mint.
actor MirageTokenCache {
    /// Absolute expiry time — mint runs `Date() + ttl` to derive this.
    private var expiresAt: Date?
    /// The active token string. Nil = never minted or force-invalidated.
    private var token: String?
    /// Refresh margin. When the token has less than this remaining, the
    /// next `token()` call re-mints. Matches Peeky Rust
    /// `tuning.rs:PROXY_TOKEN_REFRESH_MARGIN_SECS = 120` (2 minutes).
    /// The proxy already returns generous TTLs; a 120s margin is enough
    /// to survive a single voice turn without forcing a mid-turn mint.
    private let refreshMargin: TimeInterval

    init(refreshMargin: TimeInterval = 120) {
        self.refreshMargin = refreshMargin
    }

    /// Return a valid token, minting a fresh one via `mint` if the cache
    /// is cold or the current token is about to expire. Multiple
    /// concurrent callers are serialized via the actor; only one mint
    /// runs even under contention.
    ///
    /// - Parameter mint: closure that produces `(token, ttl)` seconds.
    ///                   Called at most once per refresh cycle.
    func token(mint: () async throws -> (token: String, ttl: TimeInterval)) async throws -> String {
        if let t = token, let e = expiresAt, e.timeIntervalSinceNow > refreshMargin {
            return t
        }
        let (t, ttl) = try await mint()
        self.token = t
        self.expiresAt = Date().addingTimeInterval(ttl)
        return t
    }

    /// Drop the cached token immediately. Called after upstream 429 so
    /// the next request mints a fresh one. Idempotent.
    func invalidate() {
        token = nil
        expiresAt = nil
    }

    /// Snapshot for logging / diagnostics. Not part of the request path.
    func snapshot() -> (hasToken: Bool, expiresAt: Date?) {
        (token != nil, expiresAt)
    }
}
