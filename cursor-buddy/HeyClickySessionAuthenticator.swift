//
//  HeyClickySessionAuthenticator.swift
//  cursor-buddy
//
//  Single-flight /auth/refresh + nested OAuth handler. See
//  docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §1.1 file 3 and §5.7.
//

import Foundation
import AppKit

final class HeyClickySessionAuthenticator: @unchecked Sendable {
    static let shared = HeyClickySessionAuthenticator()

    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.auth")
    private var refreshTask: Task<Bool, Error>?
    private let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.waitsForConnectivity = true
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Coalesces concurrent callers into one `/auth/refresh` request.
    /// Returns true when a fresh access token has been stored.
    func refresh() async throws -> Bool {
        let task: Task<Bool, Error> = stateQueue.sync {
            if let existing = refreshTask { return existing }
            let created = Task<Bool, Error> { [weak self] in
                defer {
                    self?.stateQueue.sync { self?.refreshTask = nil }
                }
                return try await self?.performRefresh() ?? false
            }
            refreshTask = created
            return created
        }
        return try await task.value
    }

    /// IDA-verified: refresh goes DIRECTLY to Supabase
    /// (/auth/v1/token?grant_type=refresh_token with apikey header),
    /// not through the proxy. Matches HeyClicky-1.0.40 string at
    /// 0x1012ce520.
    private func performRefresh() async throws -> Bool {
        guard let refresh = AppBundleConfiguration.heyClickySessionRefreshToken(),
              !refresh.isEmpty else {
            HeyClickyLog.log("oauth.refresh_skipped_no_refresh_token", direction: "error")
            return false
        }
        HeyClickyLog.log("oauth.refresh_started", lane: "system", direction: "outgoing")
        let supabase = try AppBundleConfiguration.heyClickySupabaseURL()
        guard let apiKey = AppBundleConfiguration.heyClickySupabaseAnonKey(), !apiKey.isEmpty else {
            return false
        }
        var components = URLComponents(url: supabase.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components?.url else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            // Transport didn't return HTTP — treat as transient, keep
            // cached session for retry (demo R-500-003 semantics).
            return false
        }

        // 5xx / network / decode errors: leave the cached access token
        // in place and let the caller retry. Only 400/401 signal that
        // the refresh token is burned.
        if http.statusCode >= 500 {
            HeyClickyLog.log("oauth.refresh_5xx_kept", direction: "error", [
                "status": http.statusCode
            ])
            return false
        }
        if http.statusCode == 400 || http.statusCode == 401 {
            HeyClickyLog.log("oauth.refresh_burned", direction: "error", [
                "status": http.statusCode
            ])
            _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(nil, forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey)
            AppBundleConfiguration.setHeyClickySessionExpiresAt(nil)
            return false
        }
        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            return false
        }
        _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(access, forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey)
        let newRefreshOpt = json["refresh_token"] as? String
        if let newRefresh = newRefreshOpt, !newRefresh.isEmpty {
            _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(newRefresh, forKey: AppBundleConfiguration.heyClickySessionRefreshTokenDefaultsKey)
        }
        // Update side-values (userId / email / expiresAt).
        let expInParam = (json["expires_in"] as? Int).map(String.init)
            ?? (json["expires_in"] as? String)
        let expAtParam = (json["expires_at"] as? Int).map(String.init)
            ?? (json["expires_at"] as? String)
        HeyClickyOAuthHandler.persistJWTClaims(accessToken: access, expiresInParam: expInParam, expiresAtParam: expAtParam)
        // Keep the disk export in sync so the assist agent's
        // parallel-dispatch pool sees the fresh tokens, not stale ones.
        HeyClickyOAuthHandler.exportAccountToDisk(
            access: access,
            refresh: newRefreshOpt
                ?? (AppBundleConfiguration.heyClickyReadKeychainSecret(
                    forKey: AppBundleConfiguration.heyClickySessionRefreshTokenDefaultsKey
                ) ?? ""))
        HeyClickyHeaderBuilder.shared.invalidateDistinctID()
        HeyClickyLog.log("oauth.refresh_ok", lane: "system", direction: "incoming", [
            "rotated_refresh": (json["refresh_token"] as? String)?.isEmpty == false ? "yes" : "no"
        ])
        NotificationCenter.default.post(name: .clickyHeyClickyCredentialsRefreshed, object: nil)
        return true
    }
}

/// Wraps the OAuth authorize + code-exchange flow. Wired to
/// `handleWidgetDeepLink` for the `heyclicky-auth-callback` scheme.
final class HeyClickyOAuthHandler: @unchecked Sendable {
    static let shared = HeyClickyOAuthHandler()

    /// Sign-in modes:
    /// * `.primary` — overwrite the app's primary session slots. Main
    ///   dialog then runs as this account.
    /// * `.additive` — only export tokens into
    ///   heyclicky-accounts/<email>.json for the assist agent's
    ///   parallel-dispatch pool. Primary session is left untouched.
    enum SignInMode: String, Sendable { case primary, additive }

    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.oauth")
    private let urlSession: URLSession
    private var pendingMode: SignInMode = .primary

    init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Supabase authorize URL already carries provider=google and
    /// redirect_to=clicky://auth-callback. We only need to open it.
    /// (Optionally append clicky_auto=1 so browser-extension helpers
    /// can auto-select an account on account-reset flows.)
    @MainActor
    func startSignIn(mode: SignInMode = .primary, loginHint: String? = nil) throws {
        stateQueue.sync { self.pendingMode = mode }
        let authorizeURL = try AppBundleConfiguration.heyClickyOAuthAuthorizeURL()
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "clicky_auto" }) {
            queryItems.append(URLQueryItem(name: "clicky_auto", value: "1"))
        }
        if let hint = loginHint, !hint.isEmpty,
           !queryItems.contains(where: { $0.name == "login_hint" }) {
            queryItems.append(URLQueryItem(name: "login_hint", value: hint))
        }
        components?.queryItems = queryItems
        guard let finalURL = components?.url else {
            throw HeyClickyConfigError.oauthURLMissing
        }
        AppBundleConfiguration.setHeyClickyPendingSignInStartedAt(Date())
        HeyClickyLog.log("oauth.sign_in_opened", lane: "system", direction: "outgoing", [
            "host": finalURL.host ?? "",
            "has_clicky_auto": "yes",
            "mode": mode.rawValue
        ])
        NSWorkspace.shared.open(finalURL)
    }

    // Note: Supabase implicit flow does not use CSRF state; demo and
    // IDA both omit it. Any state param would be dead code, so nothing
    // is stored or verified here.

    /// Supabase implicit flow: the callback URL carries access_token +
    /// refresh_token directly in the fragment (or query, depending on
    /// PKCE). Parse both, persist atomically. No proxy round-trip.
    /// IDA-verified regex at 0x1012a6530.
    func consumeCallbackURL(_ url: URL) throws {
        var pairs: [String: String] = [:]
        let fragment = url.fragment ?? ""
        let query = url.query ?? ""
        for chunk in [fragment, query] where !chunk.isEmpty {
            for pair in chunk.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let key = String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                pairs[key] = value
            }
        }
        guard let access = pairs["access_token"], !access.isEmpty,
              let refresh = pairs["refresh_token"], !refresh.isEmpty else {
            HeyClickyLog.log("oauth.callback_malformed", direction: "error", [
                "have_access": pairs["access_token"] == nil ? "no" : "empty",
                "have_refresh": pairs["refresh_token"] == nil ? "no" : "empty"
            ])
            AppBundleConfiguration.heyClickyWipeSession()
            throw HeyClickyProxyError.malformedResponse
        }
        let mode: SignInMode = stateQueue.sync {
            let m = self.pendingMode
            self.pendingMode = .primary  // consume, reset default
            return m
        }
        HeyClickyLog.log("oauth.callback_ok", lane: "system", direction: "incoming", [
            "access_len": access.count,
            "refresh_len": refresh.count,
            "mode": mode.rawValue
        ])
        // Always export to heyclicky-accounts/<email>.json so the
        // assist agent's parallel-dispatch pool sees every account.
        Self.exportAccountToDisk(access: access, refresh: refresh)
        // Additive: DON'T touch primary session slots. Sibling account
        // for the assist agent only. Follow-on refresh loop / plan
        // reload are skipped — they belong to the primary account.
        if mode == .additive {
            AppBundleConfiguration.setHeyClickyPendingSignInStartedAt(nil)
            return
        }
        _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(access, forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey)
        _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(refresh, forKey: AppBundleConfiguration.heyClickySessionRefreshTokenDefaultsKey)
        Self.persistJWTClaims(accessToken: access, expiresInParam: pairs["expires_in"], expiresAtParam: pairs["expires_at"])
        AppBundleConfiguration.setHeyClickyPendingSignInStartedAt(nil)
        HeyClickyHeaderBuilder.shared.invalidateDistinctID()
        HeyClickySessionTokenClient.shared.startProactiveRefreshLoop()
        // Refresh the plan snapshot right after sign-in so the
        // Settings quota row lands with real numbers, not "Loading…".
        Task { @MainActor in await HeyClickyPlanClient.shared.refresh() }
        // Close the OAuth tabs the browser left spinning — Supabase's
        // final hop redirects to `clicky://auth-callback`, which macOS
        // intercepts before the tab sees a load-complete, so the page
        // stays in "loading" state forever unless we close it.
        Task { @MainActor in
            await HeyClickyChromeBridgeServer.shared.closeTabsMatching([
                "accounts.google.com",
                "/auth/v1/authorize",
                "/auth/v1/callback"
            ])
        }
        NotificationCenter.default.post(name: .clickyHeyClickyCredentialsRefreshed, object: nil)
    }

    /// Decode `sub`/`email`/`exp` from a JWT access token and persist
    /// each side-value so distinct-id/login-hint/refresh-lead work
    /// across process restarts without re-decoding on every request.
    static func persistJWTClaims(accessToken: String, expiresInParam: String? = nil, expiresAtParam: String? = nil) {
        let payload = decodeJWTPayload(accessToken)
        if let userID = payload?["sub"] as? String {
            _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(userID, forKey: AppBundleConfiguration.heyClickySessionUserIDDefaultsKey)
        }
        if let email = payload?["email"] as? String {
            _ = AppBundleConfiguration.heyClickyWriteKeychainSecret(email, forKey: AppBundleConfiguration.heyClickySessionUserEmailDefaultsKey)
        }
        // Prefer `expires_at` (Supabase absolute epoch);
        // fall back to `expires_in` (seconds from now);
        // last resort JWT `exp` claim.
        var expiresAt: Date?
        if let raw = expiresAtParam, let epoch = TimeInterval(raw) {
            expiresAt = Date(timeIntervalSince1970: epoch)
        } else if let raw = expiresInParam, let seconds = TimeInterval(raw) {
            expiresAt = Date().addingTimeInterval(seconds)
        } else if let exp = payload?["exp"] as? TimeInterval {
            expiresAt = Date(timeIntervalSince1970: exp)
        } else if let exp = payload?["exp"] as? Int {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
        }
        if let expiresAt {
            AppBundleConfiguration.setHeyClickySessionExpiresAt(expiresAt)
        }
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: paddingCount)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Called on app launch — clears stale sign-in state if callback never
    /// arrived within 10 minutes.
    func reconcilePendingSignIn() {
        guard let startedAt = AppBundleConfiguration.heyClickyPendingSignInStartedAt() else { return }
        if Date().timeIntervalSince(startedAt) > 600 {
            AppBundleConfiguration.setHeyClickyPendingSignInStartedAt(nil)
            OpenClickyMessageLogStore.shared.append(
                lane: "system",
                direction: "error",
                event: "system.heyclicky.oauth_timeout",
                fields: [
                    "provider": "heyclicky_free",
                    "started_at": ISO8601DateFormatter().string(from: startedAt)
                ]
            )
        }
    }

    /// Persist `(email, access, refresh)` into
    /// `~/Library/Application Support/OpenClicky/heyclicky-accounts/<email>.json`
    /// so the assist agent's parallel-dispatch pool can find every
    /// account the user has authorised. Silent no-op when the JWT
    /// carries no email claim — never breaks the login flow.
    static func exportAccountToDisk(access: String, refresh: String) {
        guard !access.isEmpty, let email = decodeEmailFromJWT(access) else {
            HeyClickyLog.log("oauth.export_account_no_email",
                             lane: "system", direction: "internal", [:])
            return
        }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("OpenClicky/heyclicky-accounts",
                                              isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = email.map { c -> Character in
            (c.isLetter || c.isNumber || ".-_@".contains(c)) ? c : "_"
        }
        let target = dir.appendingPathComponent("\(String(safe)).json")

        let payload: [String: Any] = [
            "openClickyHeyClickySessionUserEmail": email,
            "openClickyHeyClickySessionAccessToken": access,
            "openClickyHeyClickySessionRefreshToken": refresh,
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: target, options: .atomic)
            HeyClickyLog.log("oauth.export_account_ok",
                             lane: "system", direction: "internal",
                             ["email": email])
        } catch {
            HeyClickyLog.log("oauth.export_account_write_failed",
                             lane: "system", direction: "error",
                             ["email": email,
                              "err": error.localizedDescription])
        }
    }

    /// Pull the `email` claim off a Supabase JWT. Returns nil on any
    /// decode failure — the export path is opportunistic and never
    /// blocks the login flow.
    private static func decodeEmailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1])
        // base64url pad
        while body.count % 4 != 0 { body.append("=") }
        body = body
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = obj["email"] as? String,
              !email.isEmpty else { return nil }
        return email
    }
}
