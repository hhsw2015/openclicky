//
//  HeyClickyFreeTierAgentHook.swift
//  cursor-buddy
//
//  Snapshot / restore `clickyAgentBaseURL` when Codex is routed through
//  the HeyClicky Free proxy. See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §3.4.
//

import Foundation

@MainActor
enum HeyClickyFreeTierAgentHook {
    private static let agentBaseURLKey = "clickyAgentBaseURL"

    /// Snapshot the user's current agent base URL + Codex API key,
    /// write the proxy URL, install the minted ephemeral. All three
    /// snapshot operations complete before any mutation so a mid-flight
    /// crash still leaves a restorable trail.
    ///
    /// Idempotent: repeat activations keep the ORIGINAL snapshot so
    /// deactivate always restores the user's real values, never our
    /// own intermediate proxy state.
    static func activate(ephemeral: String) {
        // Snapshot phase — capture BOTH original values first.
        if AppBundleConfiguration.heyClickyPreviousAgentBaseURLSnapshot() == nil {
            let currentURL = UserDefaults.standard.string(forKey: agentBaseURLKey) ?? ""
            AppBundleConfiguration.setHeyClickyPreviousAgentBaseURLSnapshot(currentURL)
        }
        if !AppBundleConfiguration.hasHeyClickyPreviousCodexAPIKey() {
            let currentKey = AppBundleConfiguration.currentCodexAPIKeySnapshot()
            AppBundleConfiguration.setHeyClickyPreviousCodexAPIKeySnapshot(currentKey)
        }

        // Mutate phase — only after both snapshots exist.
        guard let base = try? AppBundleConfiguration.heyClickyProxyBaseURL() else {
            // Config missing: undo the snapshots so we never restore into
            // a partial state, then bail.
            AppBundleConfiguration.setHeyClickyPreviousAgentBaseURLSnapshot(nil)
            AppBundleConfiguration.setHeyClickyPreviousCodexAPIKeySnapshot(nil)
            return
        }
        let proxyAgentURL = base
            .appendingPathComponent("agent")
            .appendingPathComponent("openai")
            .appendingPathComponent("v1")
        UserDefaults.standard.set(proxyAgentURL.absoluteString, forKey: agentBaseURLKey)
        AppBundleConfiguration.persistSecret(ephemeral, defaultsKey: AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey)
    }

    /// Restore the snapshotted base URL AND Codex API key. Idempotent —
    /// safe to call when never activated. Never wipes the user's key.
    static func deactivate() {
        // Restore base URL from three-state snapshot.
        if let urlSnapshot = AppBundleConfiguration.heyClickyPreviousAgentBaseURLSnapshot() {
            let previous = urlSnapshot ?? ""
            if previous.isEmpty {
                UserDefaults.standard.removeObject(forKey: agentBaseURLKey)
            } else {
                UserDefaults.standard.set(previous, forKey: agentBaseURLKey)
            }
            AppBundleConfiguration.setHeyClickyPreviousAgentBaseURLSnapshot(nil)
        }
        // Restore Codex API key from snapshot. Only wipe if we know for
        // certain the user had no key before.
        if AppBundleConfiguration.hasHeyClickyPreviousCodexAPIKey() {
            let previousKey = AppBundleConfiguration.heyClickyPreviousCodexAPIKey() ?? ""
            AppBundleConfiguration.persistSecret(previousKey, defaultsKey: AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey)
            AppBundleConfiguration.setHeyClickyPreviousCodexAPIKeySnapshot(nil)
        }
        // NOTE: no snapshot → do nothing. Never wipe a key we didn't put there.
    }

    /// Called from the settings commit path to treat a user-typed BYOK
    /// URL as an opt-out from the free tier. Drops both snapshots so
    /// the new value becomes the baseline.
    static func userCommittedBaseURL(_ newValue: String) {
        AppBundleConfiguration.setHeyClickyPreviousAgentBaseURLSnapshot(nil)
        AppBundleConfiguration.setHeyClickyPreviousCodexAPIKeySnapshot(nil)
        _ = newValue
    }

    /// On boot, if any lane is `.heyclickyFree` and the snapshot exists,
    /// leave state alone (already activated). If the app crashed between
    /// activate/deactivate, no way to know — accept whatever the user
    /// currently sees as canonical.
    static func reconcile() {
        // No-op today. Placeholder for future integrity checks.
    }
}
