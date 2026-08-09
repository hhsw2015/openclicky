//
//  MirageSecrets.swift
//
//  Empty-by-default template. The public git tree ships this file with an
//  empty upstream URL — a fresh clone compiles but the Peeky Free lane
//  self-disables at runtime (MirageBackendClient.send throws
//  MirageError.notConfigured on every request, and the .peekyFree profile
//  refuses to activate).
//
//  Personal builds fill the value in and hide the change from git:
//
//      git update-index --skip-worktree \
//          cursor-buddy/MirageSecrets.swift
//
//  Undo before pulling / committing shared refactors:
//
//      git update-index --no-skip-worktree \
//          cursor-buddy/MirageSecrets.swift
//
//  This mirrors the pattern used for HeyClickySecrets.swift.

import Foundation

enum MirageSecrets {
    /// Cloudflare Worker endpoint that fronts the free-tier Claude /
    /// Deepgram / Cartesia lanes via the mirage protocol (rotating
    /// anonymous UUID header, no login). Empty string in the public tree so
    /// nobody accidentally hammers someone else's account by building from a
    /// fresh clone. When empty at runtime, MirageBackendClient.isConfigured
    /// returns false and every profile check refuses to route.
    static let upstreamBaseURL: String = ""

    /// True when the upstream is configured. Callers should short-circuit
    /// early and surface a helpful "not configured" message rather than
    /// silently falling back to a paid provider — the whole point of the
    /// peekyFree profile is that it never touches billed paths.
    static var isConfigured: Bool {
        !upstreamBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Full endpoint for the Messages API. Nil when not configured.
    static var anthropicMessagesURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: upstreamBaseURL + "/v1/anthropic/messages")
    }

    /// Endpoint for minting a Deepgram STT session token. Nil when not
    /// configured.
    static var deepgramTokenURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: upstreamBaseURL + "/v1/deepgram/token")
    }

    /// Endpoint for minting a Cartesia TTS session token. Nil when not
    /// configured.
    static var cartesiaTokenURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: upstreamBaseURL + "/v1/cartesia/token")
    }
}
