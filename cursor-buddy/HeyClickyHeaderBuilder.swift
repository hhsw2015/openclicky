//
//  HeyClickyHeaderBuilder.swift
//  cursor-buddy
//
//  Builds the six `x-clicky-*` headers described in
//  docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §5.6.
//

import Foundation

final class HeyClickyHeaderBuilder: @unchecked Sendable {
    static let shared = HeyClickyHeaderBuilder()

    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.headers")
    private let sessionUUID: String = UUID().uuidString
    private var cachedDistinctID: String?
    private var agentThreadID: String?

    private init() {}

    /// Adds every relevant `x-clicky-*` header to the request. Callers
    /// still set `Authorization` themselves so refresh flows can pin a
    /// specific token.
    /// Attach the six `x-clicky-*` headers to `request`. Callers that
    /// speak to lane-scoped endpoints (heartbeat, etc.) can suppress
    /// the `X-Clicky-Agent-Thread-Id` header by passing
    /// `includeAgentThreadID: false` — demo's heartbeat call omits it.
    func apply(
        to request: inout URLRequest,
        includeDictationReceipt: Bool = false,
        includeAgentThreadID: Bool = true
    ) async {
        let prefix = AppBundleConfiguration.heyClickyHeaderPrefix()
        // Prefix already includes the trailing dash (X-Clicky-) per
        // IDA-verified authoritative binary.
        request.setValue(sessionUUID, forHTTPHeaderField: "\(prefix)Session-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "\(prefix)Trace-Id")
        request.setValue("normal", forHTTPHeaderField: "\(prefix)Mode")

        if let distinct = distinctID() {
            request.setValue(distinct, forHTTPHeaderField: "\(prefix)Distinct-Id")
        }
        if includeAgentThreadID, let threadID = currentAgentThreadID() {
            request.setValue(threadID, forHTTPHeaderField: "\(prefix)Agent-Thread-Id")
        }
        if includeDictationReceipt,
           let receipt = try? await HeyClickySessionTokenClient.shared.mintDictationReceipt() {
            request.setValue(receipt, forHTTPHeaderField: "\(prefix)Dictation-Receipt")
        }
    }

    func setAgentThreadID(_ id: String?) {
        stateQueue.sync { agentThreadID = id }
    }

    func currentAgentThreadID() -> String? {
        stateQueue.sync { agentThreadID }
    }

    /// Session UUID stable across the whole app-launch lifetime.
    func chatSessionID() -> String { sessionUUID }

    /// Decodes the JWT `sub` claim from the current access token. Returns
    /// nil when no token or malformed. Cached until sign-out.
    func distinctID() -> String? {
        stateQueue.sync {
            if let cached = cachedDistinctID { return cached }
            // Prefer the persisted user id (survives cold start with no
            // JWT decode). Fall back to JWT `sub` only when the store
            // is empty (older session before we added persistence).
            if let stored = AppBundleConfiguration.heyClickySessionUserID(), !stored.isEmpty {
                cachedDistinctID = stored
                return stored
            }
            guard let token = AppBundleConfiguration.heyClickySessionAccessToken() else { return nil }
            let sub = Self.decodeJWTSub(token: token)
            cachedDistinctID = sub
            return sub
        }
    }

    func invalidateDistinctID() {
        stateQueue.sync { cachedDistinctID = nil }
    }

    private static func decodeJWTSub(token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        // Base64URL → Base64
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: paddingCount)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["sub"] as? String
    }
}
