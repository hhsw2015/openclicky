//
//  AppBundleConfiguration+HeyClicky.swift
//  cursor-buddy
//
//  HeyClicky Free Tier configuration accessors. See
//  docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §6.
//

import Foundation

extension AppBundleConfiguration {
    // MARK: Defaults keys

    static let heyClickyProxyBaseURLDefaultsKey = "openClickyHeyClickyProxyBaseURL"
    static let heyClickyOAuthAuthorizeURLDefaultsKey = "openClickyHeyClickyOAuthAuthorizeURL"
    static let heyClickySupabaseURLDefaultsKey = "openClickyHeyClickySupabaseURL"
    static let heyClickySupabaseAnonKeyDefaultsKey = "openClickyHeyClickySupabaseAnonKey"
    static let heyClickyHeaderPrefixDefaultsKey = "openClickyHeyClickyHeaderPrefix"
    static let heyClickyChatToolCallPathDefaultsKey = "openClickyHeyClickyChatToolCallPath"
    static let heyClickyTranscriptionPathDefaultsKey = "openClickyHeyClickyTranscriptionPath"
    static let heyClickyRealtimeEphemeralPathDefaultsKey = "openClickyHeyClickyRealtimeEphemeralPath"
    static let heyClickyCodexEphemeralPathDefaultsKey = "openClickyHeyClickyCodexEphemeralPath"
    static let heyClickyDictationReceiptPathDefaultsKey = "openClickyHeyClickyDictationReceiptPath"
    static let heyClickyThreadLaunchPathDefaultsKey = "openClickyHeyClickyThreadLaunchPath"
    static let heyClickyRecordAgentLaunchPathDefaultsKey = "openClickyHeyClickyRecordAgentLaunchPath"
    static let heyClickyFallbackChatProviderDefaultsKey = "openClickyHeyClickyFallbackChatProvider"
    static let heyClickyFallbackSTTProviderDefaultsKey = "openClickyHeyClickyFallbackSTTProvider"
    static let heyClickyFallbackAgentProviderDefaultsKey = "openClickyHeyClickyFallbackAgentProvider"
    static let heyClickyClientCapabilitiesDefaultsKey = "openClickyHeyClickyClientCapabilities"
    /// Toggle for the in-App assist agent (research tool + multi-round
    /// tool loop). Off → main dialog only sees the everywhere-context
    /// injection. On (default) → same everywhere-context PLUS the
    /// assist-agent tool surface (research/multi-round/dispatch).
    static let assistAgentEnabledDefaultsKey = "openClickyAssistAgentEnabled"
    static let heyClickyBridgePortMinDefaultsKey = "openClickyHeyClickyBridgePortMin"
    static let heyClickyBridgePortMaxDefaultsKey = "openClickyHeyClickyBridgePortMax"
    static let heyClickyPreviousAgentBaseURLDefaultsKey = "openClickyHeyClickyPreviousAgentBaseURL"
    /// Sentinel bool: true iff a snapshot exists. Distinguishes
    /// "user had no URL set" from "no snapshot taken yet".
    static let heyClickyHasPreviousAgentBaseURLDefaultsKey = "openClickyHeyClickyHasPreviousAgentBaseURL"
    static let heyClickyHasPreviousCodexAPIKeyDefaultsKey = "openClickyHeyClickyHasPreviousCodexAPIKey"
    static let heyClickyPendingSignInStartedAtDefaultsKey = "openClickyHeyClickyPendingSignInStartedAt"

    // Keychain-backed
    static let heyClickySessionAccessTokenDefaultsKey = "openClickyHeyClickySessionAccessToken"
    static let heyClickySessionRefreshTokenDefaultsKey = "openClickyHeyClickySessionRefreshToken"
    /// Keychain-backed snapshot of the user's prior Codex API key,
    /// held only while a HeyClicky Free agent lease is active.
    static let heyClickyPreviousCodexAPIKeyDefaultsKey = "openClickyHeyClickyPreviousCodexAPIKey"
    /// IDA-verified names (0x1012ce438 / 0x1012ce400): supabaseUserId /
    /// supabaseUserEmail. Persisted per-session so distinct-id headers
    /// and login_hint reset flow survive app restart without another
    /// JWT decode.
    static let heyClickySessionUserIDDefaultsKey = "openClickyHeyClickySessionUserID"
    static let heyClickySessionUserEmailDefaultsKey = "openClickyHeyClickySessionUserEmail"
    static let heyClickySessionExpiresAtDefaultsKey = "openClickyHeyClickySessionExpiresAt"

    // MARK: Required URLs (throw when missing → feature auto-disables §6.1)

    // Defaults come from `HeyClickySecrets` — that file is
    // gitignored. `HeyClickySecrets.example.swift` in the repo has
    // empty strings; whoever wants a working build fills in the real
    // values locally and copies to `HeyClickySecrets.swift`.

    static func heyClickyProxyBaseURL() throws -> URL {
        let raw = UserDefaults.standard.string(forKey: heyClickyProxyBaseURLDefaultsKey)
            ?? stringValue(
                forKey: "HeyClickyProxyBaseURL",
                environmentKeys: ["HEYCLICKY_PROXY_BASE_URL"]
            )
            ?? HeyClickySecrets.proxyBaseURL
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil,
              (url.host?.isEmpty == false) else {
            throw HeyClickyConfigError.proxyBaseURLMissing
        }
        return url
    }

    /// Supabase project base URL used for /auth/v1/token refresh
    /// and /auth/v1/user identity checks.
    static func heyClickySupabaseURL() throws -> URL {
        let raw = UserDefaults.standard.string(forKey: heyClickySupabaseURLDefaultsKey)
            ?? stringValue(
                forKey: "HeyClickySupabaseURL",
                environmentKeys: ["HEYCLICKY_SUPABASE_URL"]
            )
            ?? HeyClickySecrets.supabaseURL
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil,
              (url.host?.isEmpty == false) else {
            throw HeyClickyConfigError.proxyBaseURLMissing
        }
        return url
    }

    /// Supabase anon JWT — sent as `apikey` header on all
    /// /auth/v1/* Supabase calls. Not secret (short-lived,
    /// row-level-security scoped) so may live in Info.plist.
    static func heyClickySupabaseAnonKey() -> String? {
        UserDefaults.standard.string(forKey: heyClickySupabaseAnonKeyDefaultsKey)
            ?? stringValue(
                forKey: "HeyClickySupabaseAnonKey",
                environmentKeys: ["HEYCLICKY_SUPABASE_ANON_KEY"]
            )
            ?? HeyClickySecrets.supabaseAnonKey
    }

    static func heyClickyOAuthAuthorizeURL() throws -> URL {
        let raw = UserDefaults.standard.string(forKey: heyClickyOAuthAuthorizeURLDefaultsKey)
            ?? stringValue(
                forKey: "HeyClickyOAuthAuthorizeURL",
                environmentKeys: ["HEYCLICKY_OAUTH_AUTHORIZE_URL"]
            )
            ?? HeyClickySecrets.oauthAuthorizeURL
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil,
              (url.host?.isEmpty == false) else {
            throw HeyClickyConfigError.oauthURLMissing
        }
        return url
    }

    // MARK: Path/prefix defaults

    /// Header namespace. Authoritative value confirmed from HeyClicky-1.0.40
    /// IDA strings at 0x1012a3640..0x1012c0140 (X-Clicky-Distinct-Id,
    /// X-Clicky-Session-Id, X-Clicky-Trace-Id, X-Clicky-Mode,
    /// X-Clicky-Agent-Thread-Id, X-Clicky-Dictation-Receipt).
    static func heyClickyHeaderPrefix() -> String {
        UserDefaults.standard.string(forKey: heyClickyHeaderPrefixDefaultsKey)
            ?? stringValue(forKey: "HeyClickyHeaderPrefix", environmentKeys: ["HEYCLICKY_HEADER_PREFIX"])
            ?? "X-Clicky-"
    }

    /// IDA-verified endpoint (0x1012b0dac) used by the agent-messages
    /// long-poll: server pushes agent turns, client posts user replies.
    static func heyClickyAgentMessagesPath() -> String {
        UserDefaults.standard.string(forKey: "openClickyHeyClickyAgentMessagesPath")
            ?? "/agent-messages"
    }
    /// IDA-verified endpoints for the Agent notifications inbox.
    static func heyClickyAgentNotificationsPath() -> String {
        UserDefaults.standard.string(forKey: "openClickyHeyClickyAgentNotificationsPath")
            ?? "/agent/notifications"
    }
    static func heyClickyAgentNotificationsReadAllPath() -> String {
        UserDefaults.standard.string(forKey: "openClickyHeyClickyAgentNotificationsReadAllPath")
            ?? "/agent/notifications/read-all"
    }
    /// Composio + integrations (Phase 4 hooks — used opportunistically).
    static func heyClickyAgentComposioSessionPath() -> String { "/agent/composio/session" }
    static func heyClickyAgentIntegrationsPath() -> String { "/agent/integrations" }
    static func heyClickyAgentCronListPath() -> String { "/agent/cron/list" }
    static func heyClickyAgentRealtimeGCalCreatePath() -> String { "/agent/realtime/google-calendar/events/create" }
    static func heyClickyAgentRealtimeGCalEventsPath() -> String { "/agent/realtime/google-calendar/events" }
    static func heyClickyAgentRealtimeSpotifySearchPath() -> String { "/agent/realtime/spotify/search" }
    static func heyClickyAgentRealtimeTurnPath() -> String { "/agent/realtime/turn" }

    static func heyClickyChatToolCallPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyChatToolCallPathDefaultsKey) ?? "/chat-tool-call"
    }

    static func heyClickyTranscriptionPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyTranscriptionPathDefaultsKey) ?? "/audio/transcriptions"
    }

    /// IDA-verified: /agent/realtime/session (0x1012cc5c0),
    /// not /agent/realtime/ephemeral. Config key retained for override.
    static func heyClickyRealtimeEphemeralPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyRealtimeEphemeralPathDefaultsKey) ?? "/agent/realtime/session"
    }

    /// Demo `ProviderConfig.swift:104` — Codex ephemeral shares the
    /// generic session-token endpoint. `/agent/codex-ephemeral` was a
    /// speculative name; keep it as an override slot but default to
    /// the demo-verified path.
    static func heyClickyCodexEphemeralPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyCodexEphemeralPathDefaultsKey) ?? "/agent/session-token"
    }

    static func heyClickyDictationReceiptPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyDictationReceiptPathDefaultsKey) ?? "/agent/session-token"
    }

    static func heyClickyThreadLaunchPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyThreadLaunchPathDefaultsKey) ?? "/codex-thread-launch"
    }

    static func heyClickyRecordAgentLaunchPath() -> String {
        UserDefaults.standard.string(forKey: heyClickyRecordAgentLaunchPathDefaultsKey) ?? "/agent/record-agent-launch"
    }

    /// Demo default is ["clipboard_copy"]. Override via UserDefault
    /// (comma-separated) or Info.plist array.
    static func heyClickyClientCapabilities() -> [String] {
        if let raw = UserDefaults.standard.string(forKey: heyClickyClientCapabilitiesDefaultsKey),
           !raw.isEmpty {
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let array = Bundle.main.object(forInfoDictionaryKey: "HeyClickyClientCapabilities") as? [String],
           !array.isEmpty {
            return array
        }
        return ["clipboard_copy"]
    }

    // MARK: Fallback providers per lane

    static func heyClickyFallbackChatProvider() -> String? {
        let value = UserDefaults.standard.string(forKey: heyClickyFallbackChatProviderDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func heyClickyFallbackSTTProvider() -> String? {
        let value = UserDefaults.standard.string(forKey: heyClickyFallbackSTTProviderDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func heyClickyFallbackAgentProvider() -> String? {
        let value = UserDefaults.standard.string(forKey: heyClickyFallbackAgentProviderDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    // MARK: Bridge port range

    static func heyClickyBridgePortRange() -> ClosedRange<Int> {
        let defaults = UserDefaults.standard
        let minPort: Int = {
            let stored = defaults.integer(forKey: heyClickyBridgePortMinDefaultsKey)
            return stored > 0 ? stored : 3011
        }()
        let maxPort: Int = {
            let stored = defaults.integer(forKey: heyClickyBridgePortMaxDefaultsKey)
            return stored > 0 ? stored : 3021
        }()
        return min(minPort, maxPort)...max(minPort, maxPort)
    }

    // MARK: Sign-in state (Keychain-backed via heyClickyReadKeychainSecret)

    static func heyClickySignedIn() -> Bool {
        heyClickySessionAccessToken()?.isEmpty == false
    }

    static func heyClickySessionAccessToken() -> String? {
        heyClickyReadKeychainSecret(forKey: heyClickySessionAccessTokenDefaultsKey)
    }

    static func heyClickySessionRefreshToken() -> String? {
        heyClickyReadKeychainSecret(forKey: heyClickySessionRefreshTokenDefaultsKey)
    }

    static func heyClickySessionUserID() -> String? {
        heyClickyReadKeychainSecret(forKey: heyClickySessionUserIDDefaultsKey)
    }

    static func heyClickySessionUserEmail() -> String? {
        heyClickyReadKeychainSecret(forKey: heyClickySessionUserEmailDefaultsKey)
    }

    static func heyClickySessionExpiresAt() -> Date? {
        let raw = UserDefaults.standard.double(forKey: heyClickySessionExpiresAtDefaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    static func setHeyClickySessionExpiresAt(_ date: Date?) {
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: heyClickySessionExpiresAtDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: heyClickySessionExpiresAtDefaultsKey)
        }
    }

    // MARK: Restore state

    /// Three-state snapshot: nil = no snapshot taken; .some("") = user
    /// had no base URL set; .some("http…") = user had this URL set.
    static func heyClickyPreviousAgentBaseURLSnapshot() -> String?? {
        guard UserDefaults.standard.bool(forKey: heyClickyHasPreviousAgentBaseURLDefaultsKey) else {
            return nil
        }
        let raw = UserDefaults.standard.string(forKey: heyClickyPreviousAgentBaseURLDefaultsKey) ?? ""
        return .some(raw)
    }

    /// Captures the current base URL exactly (including "empty" =
    /// user had none). Passing nil clears the snapshot record.
    static func setHeyClickyPreviousAgentBaseURLSnapshot(_ value: String?) {
        if let value {
            UserDefaults.standard.set(value, forKey: heyClickyPreviousAgentBaseURLDefaultsKey)
            UserDefaults.standard.set(true, forKey: heyClickyHasPreviousAgentBaseURLDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: heyClickyPreviousAgentBaseURLDefaultsKey)
            UserDefaults.standard.removeObject(forKey: heyClickyHasPreviousAgentBaseURLDefaultsKey)
        }
    }

    /// Legacy shape kept for callers that only need to know "any
    /// non-empty prior URL." Prefer the Snapshot variant above for
    /// activate/deactivate correctness.
    static func heyClickyPreviousAgentBaseURL() -> String? {
        guard let inner = heyClickyPreviousAgentBaseURLSnapshot() else { return nil }
        let trimmed = (inner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func setHeyClickyPreviousAgentBaseURL(_ value: String?) {
        setHeyClickyPreviousAgentBaseURLSnapshot(value)
    }

    // MARK: - Codex API key snapshot (Keychain-backed)

    static func hasHeyClickyPreviousCodexAPIKey() -> Bool {
        UserDefaults.standard.bool(forKey: heyClickyHasPreviousCodexAPIKeyDefaultsKey)
    }

    static func heyClickyPreviousCodexAPIKey() -> String? {
        heyClickyReadKeychainSecret(forKey: heyClickyPreviousCodexAPIKeyDefaultsKey)
    }

    /// nil = no snapshot exists; .some("") = user had no key; .some("sk-…") = user had this key.
    static func setHeyClickyPreviousCodexAPIKeySnapshot(_ value: String?) {
        if let value {
            _ = heyClickyWriteKeychainSecret(value, forKey: heyClickyPreviousCodexAPIKeyDefaultsKey)
            UserDefaults.standard.set(true, forKey: heyClickyHasPreviousCodexAPIKeyDefaultsKey)
        } else {
            _ = heyClickyWriteKeychainSecret(nil, forKey: heyClickyPreviousCodexAPIKeyDefaultsKey)
            UserDefaults.standard.removeObject(forKey: heyClickyHasPreviousCodexAPIKeyDefaultsKey)
        }
    }

    /// Reads the current persisted Codex API key exactly as `persistSecret`
    /// wrote it, so the snapshot round-trips.
    static func currentCodexAPIKeySnapshot() -> String {
        // `openAIAPIKey()` blends env/plist fallbacks; we need the exact
        // persisted value so restore is faithful. Direct Keychain read:
        heyClickyReadKeychainSecret(forKey: userCodexAgentAPIKeyDefaultsKey) ?? ""
    }

    static func heyClickyPendingSignInStartedAt() -> Date? {
        let value = UserDefaults.standard.double(forKey: heyClickyPendingSignInStartedAtDefaultsKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    static func setHeyClickyPendingSignInStartedAt(_ value: Date?) {
        if let value {
            UserDefaults.standard.set(value.timeIntervalSince1970, forKey: heyClickyPendingSignInStartedAtDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: heyClickyPendingSignInStartedAtDefaultsKey)
        }
    }

    // MARK: Keychain access (own-namespace read/write for tokens)

    /// File-backed session store. Sits in Application Support so tokens
    /// survive app relaunch without touching the login Keychain — that
    /// avoided a bunch of "OpenClicky wants to use your keychain" prompts
    /// every time the dev signing identity fingerprint drifted.
    ///
    /// Trade-off: access/refresh tokens live in a mode-600 file instead
    /// of the Keychain. Access tokens are short-TTL (1h) and refresh
    /// tokens are already scoped per-Supabase-project, so file-mode
    /// protection is enough for this use case.
    private static var heyClickySessionStoreURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("OpenClicky", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("heyclicky-session.json")
    }

    private static func heyClickyLoadStore() -> [String: String] {
        guard let data = try? Data(contentsOf: heyClickySessionStoreURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private static func heyClickySaveStore(_ dict: [String: String]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            try data.write(to: heyClickySessionStoreURL, options: [.atomic])
            // 600: owner read/write only.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: heyClickySessionStoreURL.path
            )
        } catch {
            // Best-effort — swallow so a disk-full at write time can't
            // brick the auth path. Read side already tolerates empty file.
        }
    }

    static func heyClickyReadKeychainSecret(forKey key: String) -> String? {
        let store = heyClickyLoadStore()
        let raw = store[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    @discardableResult
    static func heyClickyWriteKeychainSecret(_ value: String?, forKey key: String) -> Bool {
        var store = heyClickyLoadStore()
        if let value, !value.isEmpty {
            store[key] = value
        } else {
            store.removeValue(forKey: key)
        }
        heyClickySaveStore(store)
        return true
    }

    /// Assist agent toggle. Defaults to true (opt-out).
    /// See `assistAgentEnabledDefaultsKey`.
    static func assistAgentEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: assistAgentEnabledDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: assistAgentEnabledDefaultsKey)
        }
        return true
    }
    static func setAssistAgentEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: assistAgentEnabledDefaultsKey)
    }

    /// Wipe both access + refresh in one shot. Atomic-ish (Keychain has no
    /// multi-item transactions; wipe both or fail loudly).
    static func heyClickyWipeSession() {
        _ = heyClickyWriteKeychainSecret(nil, forKey: heyClickySessionAccessTokenDefaultsKey)
        _ = heyClickyWriteKeychainSecret(nil, forKey: heyClickySessionRefreshTokenDefaultsKey)
        _ = heyClickyWriteKeychainSecret(nil, forKey: heyClickySessionUserIDDefaultsKey)
        _ = heyClickyWriteKeychainSecret(nil, forKey: heyClickySessionUserEmailDefaultsKey)
        setHeyClickySessionExpiresAt(nil)
    }
}
