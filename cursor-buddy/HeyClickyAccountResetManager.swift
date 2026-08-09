//
//  HeyClickyAccountResetManager.swift
//  cursor-buddy
//
//  Single-account quota reset. HeyClicky Free's proxy gives each
//  account a rolling 25-turn window; when it hits 25/25 the proxy
//  returns 402/429. Signing OUT and back IN on the SAME account
//  opens a fresh window, so this manager drives that flow through
//  the Chrome extension without user interaction.
//
//  This is deliberately a single-account operation:
//    · wipe the local session (keychain + cookies)
//    · relaunch the OAuth flow with `login_hint=<current_email>`
//    · the Chrome ext auto-clicks the account chooser row for that
//      email (no user picks) and rides through the consent page
//    · on `clicky://auth-callback` the new tokens are persisted and
//      the app carries on.
//
//  Callers:
//    · `HeyClickyChatToolCallClient` — on 402/429 for chat lane
//    · `HeyClickyProxyTranscriptionProvider` — on 402/429 for STT
//    · `CodexAgentSession+HeyClicky` — on 402/429 for agent lane
//    · Manual "Reset free quota now" button in Settings
//    · Notch quota badge tap
//    · Automation bridge (`/heyclicky/account/reset`)
//
//  Guarded by:
//    · 3-min cooldown per instance so a rapid burst of 402s doesn't
//      trigger three overlapping resets
//    · `isResetInProgress` flag so session-expired observers know to
//      skip their own wipe (letting this flow finish its own wipe +
//      re-sign)
//

import AppKit
import Foundation

@MainActor
final class HeyClickyAccountResetManager {
    static let shared = HeyClickyAccountResetManager()
    private init() {}

    private var lastAttemptAt: Date = .distantPast
    private static let cooldownSec: TimeInterval = 180

    /// True while a reset is running end-to-end (from wipe through
    /// Chrome-ext-driven callback). Observers on
    /// `.heyClickySessionExpired` check this before doing their own
    /// wipe so this flow can finish uninterrupted.
    private(set) var isResetInProgress: Bool = false

    /// Kick off a reset. Non-blocking — returns whether the attempt
    /// was accepted. Actual completion fires
    /// `.heyClickyCredentialsRefreshed` (or fails silently after ~90s).
    ///
    /// Returns false when:
    ///   · already in progress (dedup)
    ///   · in cooldown window (<3min since last attempt)
    ///   · not signed in (nothing to reset)
    ///   · authorize URL not configured
    @discardableResult
    func attemptReset(reason: String) -> Bool {
        guard !isResetInProgress else {
            HeyClickyLog.log("heyclicky.reset.dedup", lane: "system",
                             direction: "internal", ["reason": reason])
            return false
        }
        let sinceLast = Date().timeIntervalSince(lastAttemptAt)
        guard sinceLast >= Self.cooldownSec else {
            HeyClickyLog.log("heyclicky.reset.cooldown", lane: "system",
                             direction: "internal", [
                "reason": reason,
                "sec_until_ok": "\(Int(Self.cooldownSec - sinceLast))"
            ])
            return false
        }
        guard AppBundleConfiguration.heyClickySignedIn() else {
            HeyClickyLog.log("heyclicky.reset.not_signed_in", lane: "system",
                             direction: "internal", ["reason": reason])
            return false
        }
        guard let email = AppBundleConfiguration.heyClickyReadKeychainSecret(
            forKey: AppBundleConfiguration.heyClickySessionUserEmailDefaultsKey
        ), !email.isEmpty else {
            HeyClickyLog.log("heyclicky.reset.no_email", lane: "system",
                             direction: "internal", ["reason": reason])
            return false
        }
        guard HeyClickyChromeBridgeServer.shared.isExtensionAlive else {
            HeyClickyLog.log("heyclicky.reset.no_chrome_ext", lane: "system",
                             direction: "error", ["reason": reason])
            return false
        }

        lastAttemptAt = Date()
        isResetInProgress = true

        HeyClickyLog.log("heyclicky.reset.begin", lane: "system",
                         direction: "internal",
                         ["reason": reason, "email": email])

        Task { [weak self] in
            await self?.driveResetViaExtension(email: email, reason: reason)
        }
        return true
    }

    /// Wait until the currently-running reset completes, or return
    /// immediately if there isn't one. Bounded by a 90s hard timeout
    /// so callers never wedge forever if Chrome ext hangs.
    func awaitBarrier() async {
        guard isResetInProgress else { return }
        let deadline = Date().addingTimeInterval(90)
        while isResetInProgress && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Best-effort watcher: polls plan client every 30s; when the
    /// user hits 25/25 auto-fires reset so they don't have to sit
    /// there and wait for a hard failure.
    func startBackgroundQuotaWatcher() {
        // Deliberately no-op for now. The synchronous chat/agent/STT
        // lanes already fire attemptReset on 402/429, which is when
        // the reset actually matters. A background poll would just
        // burn API quota. Keep the entry point for API compatibility.
        HeyClickyLog.log("heyclicky.reset.bg_watcher_noop", lane: "system",
                         direction: "internal", [:])
    }

    // MARK: - Reset drive (private)

    private func driveResetViaExtension(email: String, reason: String) async {
        defer {
            isResetInProgress = false
            HeyClickyLog.log("heyclicky.reset.end", lane: "system",
                             direction: "internal", ["reason": reason])
        }

        // 1) Wipe local session so the callback overwrites with fresh
        //    tokens instead of merging.
        AppBundleConfiguration.heyClickyWipeSession()
        HeyClickySessionTokenClient.shared.invalidateAll()

        // 2) Build the authorize URL with login_hint so Google skips
        //    the account chooser when only one account is signed in.
        let authorizeURL: URL
        do {
            let base = try AppBundleConfiguration.heyClickyOAuthAuthorizeURL()
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            var items = comps.queryItems ?? []
            if !items.contains(where: { $0.name == "prompt" }) {
                items.append(URLQueryItem(name: "prompt", value: "select_account"))
            }
            if !items.contains(where: { $0.name == "login_hint" }) {
                items.append(URLQueryItem(name: "login_hint", value: email))
            }
            if !items.contains(where: { $0.name == "clicky_auto" }) {
                items.append(URLQueryItem(name: "clicky_auto", value: "1"))
            }
            comps.queryItems = items
            guard let url = comps.url else {
                HeyClickyLog.log("heyclicky.reset.authorize_url_build_failed",
                                 lane: "system", direction: "error", [:])
                return
            }
            authorizeURL = url
        } catch {
            HeyClickyLog.log("heyclicky.reset.authorize_url_missing",
                             lane: "system", direction: "error",
                             ["err": "\(error)"])
            return
        }

        // 3) Drive Chrome ext: open tab → click the chooser row for
        //    this email → ride consent → wait for callback.
        let bridge = HeyClickyChromeBridgeServer.shared
        guard let tabId = await bridge.openTab(
            url: authorizeURL.absoluteString, active: false
        ) else {
            HeyClickyLog.log("heyclicky.reset.open_tab_failed",
                             lane: "system", direction: "error", [:])
            return
        }

        _ = await bridge.waitForNavigation(
            matching: "accounts.google.com", timeout: 15
        )
        try? await Task.sleep(nanoseconds: 700_000_000)

        var clicked = false
        let selectors = [
            "[data-identifier=\"\(email)\"][role=\"link\"]",
            "[data-identifier=\"\(email)\"]",
            "[data-email=\"\(email)\"]",
            "li[data-identifier]",
            "div[data-identifier][role=\"link\"]",
            "div[data-identifier]",
            "[role=\"link\"][aria-label*=\"\(email)\"]",
            "[jsname][data-identifier]"
        ]
        for sel in selectors {
            if await bridge.click(
                tabId: tabId, selector: sel, textMatch: email, timeout: 3
            ) {
                clicked = true
                break
            }
        }

        // consent page
        if await bridge.waitForNavigation(
            matching: "signin/oauth/consent", timeout: 3
        ) != nil {
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = await bridge.click(
                tabId: tabId,
                selector: "#submit_approve_access, button[jsname=\"LgbsSe\"]",
                textMatch: "Continue|Allow|继续|允许",
                timeout: 4
            )
        }

        // wait for our custom scheme callback
        let nav = await bridge.waitForNavigation(
            matching: "clicky://auth-callback", timeout: 60
        )
        await bridge.closeTab(tabId: tabId)

        HeyClickyLog.log(
            "heyclicky.reset.drive_done",
            lane: "system",
            direction: "internal",
            [
                "clicked": clicked ? "1" : "0",
                "callback_seen": nav != nil ? "1" : "0",
                "signed_in_after": AppBundleConfiguration.heyClickySignedIn() ? "1" : "0"
            ]
        )
    }
}
