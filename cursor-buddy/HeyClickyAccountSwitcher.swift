//
//  HeyClickyAccountSwitcher.swift
//  cursor-buddy
//
//  Multi-account pool used ONLY by the assist agent for parallel
//  dispatch. The primary session (the account the main dialog runs
//  as) is unchanged — this file only exposes read/list/re-auth for
//  the SECONDARY pool exported to disk via
//  HeyClickyOAuthHandler.exportAccountToDisk(...).
//
//  Callers:
//    · AssistAgentAccounts (Swift) — Swift-side account picker for
//      dispatch_parallel sub-agents
//    · OpenClickySettingsWindowManager — "Add another account" UI
//

import Foundation

public struct HeyClickyStoredAccount: Identifiable, Sendable {
    public let id: String        // email
    public let email: String
    /// Approximate remaining lifetime of the stored refresh token,
    /// derived from `exportedAt`. Real refresh happens on next use;
    /// this is a UX cue for the settings row.
    public var refreshExpired: Bool
}

public enum HeyClickyAccountSwitcher {

    /// Enumerate every non-primary account exported to disk.
    /// Enriched with a rough "refresh token likely expired" flag so
    /// the settings UI can highlight ones needing re-auth.
    public static func loadAll() -> [HeyClickyStoredAccount] {
        AssistAgentAccounts.loadAll().map { acc in
            let ageDays = (Date().timeIntervalSince1970 - acc.exportedAt) / 86_400
            // Supabase refresh tokens expire ~7 days idle. Flag > 6 days
            // as suspect. The user can still hit "Switch" — the next
            // refresh call is what confirms it.
            return HeyClickyStoredAccount(
                id: acc.email, email: acc.email,
                refreshExpired: acc.exportedAt > 0 && ageDays > 6)
        }
    }

    /// Kick off a re-authenticate flow for `account`. Same primary
    /// OAuth flow — after callback, exports get refreshed for this
    /// email again.
    @MainActor
    public static func reauthenticate(_ account: HeyClickyStoredAccount) {
        try? HeyClickyOAuthHandler.shared.startSignIn(mode: .additive,
                                                     loginHint: account.email)
    }

    /// Adopt `account`'s tokens as the primary session — the main
    /// dialog will then run as this account. Fires the standard
    /// credentials-refreshed notification so observers rebuild state.
    @MainActor
    public static func applyAccount(_ account: HeyClickyStoredAccount) {
        guard let stored = AssistAgentAccounts.loadAll()
            .first(where: { $0.email == account.email }) else { return }
        _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(
            stored.accessToken,
            forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey)
        _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(
            stored.refreshToken,
            forKey: AppBundleConfiguration.heyClickySessionRefreshTokenDefaultsKey)
        _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(
            stored.email,
            forKey: AppBundleConfiguration.heyClickySessionUserEmailDefaultsKey)
        NotificationCenter.default.post(
            name: Notification.Name("com.jkneen.openclicky.heyclicky.credentialsRefreshed"),
            object: nil,
            userInfo: ["email": stored.email])
    }
}
