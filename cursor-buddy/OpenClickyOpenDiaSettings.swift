//
//  OpenClickyOpenDiaSettings.swift
//  cursor-buddy
//
//  Phase 7.6b F31 — UserDefaults-backed configuration for the OpenDia
//  Node subprocess and MCP tool surface.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
//  All settings default to opt-in / disabled so a fresh install ships
//  with the OpenDia runtime idle. Env var `OPENCLICKY_MCP_OPENDIA=1`
//  forces on for automation tests.
//

import Foundation
import Combine

@MainActor
final class OpenClickyOpenDiaSettings: ObservableObject {
    static let shared = OpenClickyOpenDiaSettings()

    // MARK: - Defaults keys

    static let enabledKey = "openclicky.opendia.enabled"
    static let nodePathOverrideKey = "openclicky.opendia.nodePathOverride"

    /// Master enable. Env var override lets headless CI force-on.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task { @MainActor in await self.applyEnabledChange() }
        }
    }

    /// Optional absolute path to a `node` executable. Empty == auto-discover.
    @Published var nodePathOverride: String? {
        didSet {
            if let v = nodePathOverride, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: Self.nodePathOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nodePathOverrideKey)
            }
        }
    }

    // MARK: - Init

    init() {
        let envForce = ProcessInfo.processInfo.environment["OPENCLICKY_MCP_OPENDIA"] == "1"
        // Default-on: if the key has never been written, treat as enabled.
        // Users can still toggle off via Settings and the choice persists.
        let stored: Bool = {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }()
        self.enabled = envForce || stored
        let override = UserDefaults.standard.string(forKey: Self.nodePathOverrideKey)
        self.nodePathOverride = (override?.isEmpty ?? true) ? nil : override
    }

    // MARK: - Runtime status (published for UI)

    @Published private(set) var runtimeStatus: String = "idle"
    @Published private(set) var extensionConnected: Bool? = nil
    @Published private(set) var availableToolCount: Int? = nil
    @Published private(set) var lastError: String? = nil

    /// Called by the subprocess after every lifecycle transition.
    func syncRuntimeSnapshot() {
        runtimeStatus = OpenClickyOpenDiaSubprocess.shared.lastStatusMessage
        extensionConnected = OpenClickyOpenDiaSubprocess.shared.extensionConnected
        availableToolCount = OpenClickyOpenDiaSubprocess.shared.availableToolCount
    }

    // MARK: - Actions

    private func applyEnabledChange() async {
        if enabled {
            do {
                try await OpenClickyOpenDiaSubprocess.shared.start()
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
            }
        } else {
            OpenClickyOpenDiaSubprocess.shared.stop()
            self.lastError = nil
        }
        syncRuntimeSnapshot()
    }

    /// One-shot startup called from `AppDelegate` / `cursor_buddyApp`.
    /// No-op unless the user has already opted in.
    static func autostartIfEnabled() {
        Task { @MainActor in
            let s = OpenClickyOpenDiaSettings.shared
            guard s.enabled else { return }
            await s.applyEnabledChange()
        }
    }
}
