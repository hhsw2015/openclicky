//
//  OpenClickyConnectorSettings.swift
//  cursor-buddy
//
//  Phase 7.5 F29 — UserDefaults-backed configuration for the
//  open-connector Node subprocess and MCP tool surface.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
//  All settings default to "opt-in / disabled" so a fresh install ships
//  with the connector runtime idle. The subprocess is spawned only when
//  the user flips `enabled` in the Settings panel (or the environment
//  variable `OPENCLICKY_MCP_CONNECTOR=1` forces it on for automation
//  tests).
//

import Foundation
import Combine

@MainActor
final class OpenClickyConnectorSettings: ObservableObject {
    static let shared = OpenClickyConnectorSettings()

    // MARK: - Defaults keys

    static let enabledKey = "openclicky.connector.enabled"
    static let nodePathOverrideKey = "openclicky.connector.nodePathOverride"
    static let providerAllowlistKey = "openclicky.connector.providerAllowlist"
    static let providerDisallowlistKey = "openclicky.connector.providerDisallowlist"

    /// Master enable. Reads env var override so headless CI can force-on.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task { @MainActor in await self.applyEnabledChange() }
        }
    }

    /// Optional absolute path to a `node` executable. Empty string means
    /// "auto-discover" (`/opt/homebrew/bin/node` → `/usr/local/bin/node`
    /// → `~/.nvm/...` → PATH). Nil-equivalent = empty.
    @Published var nodePathOverride: String? {
        didSet {
            if let v = nodePathOverride, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: Self.nodePathOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nodePathOverrideKey)
            }
        }
    }

    /// Optional allowlist. Empty == allow all 831 providers. Matches
    /// Everywhere's Phase-1 `PROVIDERS = ["github"]` mechanism.
    @Published var providerAllowlist: [String] {
        didSet {
            UserDefaults.standard.set(providerAllowlist, forKey: Self.providerAllowlistKey)
        }
    }

    /// Optional disallowlist. Applied AFTER the allowlist filter.
    @Published var providerDisallowlist: [String] {
        didSet {
            UserDefaults.standard.set(providerDisallowlist, forKey: Self.providerDisallowlistKey)
        }
    }

    // MARK: - Init

    init() {
        // Force-on override for automation.
        let envForce = ProcessInfo.processInfo.environment["OPENCLICKY_MCP_CONNECTOR"] == "1"
        // Default-on: if the key has never been written, treat as enabled.
        let stored: Bool = {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }()
        self.enabled = envForce || stored
        let override = UserDefaults.standard.string(forKey: Self.nodePathOverrideKey)
        self.nodePathOverride = (override?.isEmpty ?? true) ? nil : override
        self.providerAllowlist = (UserDefaults.standard.array(forKey: Self.providerAllowlistKey) as? [String]) ?? []
        self.providerDisallowlist = (UserDefaults.standard.array(forKey: Self.providerDisallowlistKey) as? [String]) ?? []
    }

    // MARK: - Runtime status (read-only, published for UI)

    @Published private(set) var runtimeStatus: String = "idle"
    @Published private(set) var providerCount: Int? = nil
    @Published private(set) var lastError: String? = nil

    /// Called by `OpenClickyConnectorSubprocess` after every lifecycle
    /// transition to update the UI-facing snapshot.
    func syncRuntimeSnapshot() {
        runtimeStatus = OpenClickyConnectorSubprocess.shared.lastStatusMessage
        providerCount = OpenClickyConnectorSubprocess.shared.providerCount
    }

    // MARK: - Actions

    private func applyEnabledChange() async {
        if enabled {
            do {
                try OpenClickyConnectorOAuthCallback.shared.start()
                try await OpenClickyConnectorSubprocess.shared.start()
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
            }
        } else {
            OpenClickyConnectorSubprocess.shared.stop()
            OpenClickyConnectorOAuthCallback.shared.stop()
            self.lastError = nil
        }
        syncRuntimeSnapshot()
    }

    /// One-shot startup called from `AppDelegate` / `cursor_buddyApp`.
    /// No-op unless the user has already opted in.
    static func autostartIfEnabled() {
        Task { @MainActor in
            let s = OpenClickyConnectorSettings.shared
            guard s.enabled else { return }
            await s.applyEnabledChange()
        }
    }
}
