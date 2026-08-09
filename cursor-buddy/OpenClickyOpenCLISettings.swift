//
//  OpenClickyOpenCLISettings.swift
//  cursor-buddy
//
//  Phase 7.6a F30 — UserDefaults-backed configuration for the OpenCLI
//  Node subprocess and the three `opencli_*` MCP tools.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
//  Defaults to disabled so a fresh install ships with the OpenCLI
//  runtime idle. The subprocess is spawned only when the user flips
//  `enabled` in Settings (or when `OPENCLICKY_MCP_OPENCLI=1` forces it
//  on for automation tests).
//

import Foundation
import Combine

@MainActor
final class OpenClickyOpenCLISettings: ObservableObject {
    static let shared = OpenClickyOpenCLISettings()

    // MARK: - Defaults keys

    static let enabledKey = "openclicky.opencli.enabled"

    /// Master enable. Reads env var override so headless CI can force-on.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task { @MainActor in await self.applyEnabledChange() }
        }
    }

    // MARK: - Init

    init() {
        let envForce = ProcessInfo.processInfo.environment["OPENCLICKY_MCP_OPENCLI"] == "1"
        // Default-on: if the key has never been written, treat as enabled.
        let stored: Bool = {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }()
        self.enabled = envForce || stored
    }

    // MARK: - Runtime status (read-only, published for UI)

    @Published private(set) var runtimeStatus: String = "idle"
    @Published private(set) var siteCount: Int? = nil
    @Published private(set) var adapterCount: Int? = nil
    @Published private(set) var lastError: String? = nil

    /// Called after every lifecycle transition to update the UI-facing
    /// snapshot.
    func syncRuntimeSnapshot() {
        runtimeStatus = OpenClickyOpenCLISubprocess.shared.lastStatusMessage
        siteCount = OpenClickyOpenCLISubprocess.shared.siteCount
        adapterCount = OpenClickyOpenCLISubprocess.shared.adapterCount
    }

    // MARK: - Actions

    private func applyEnabledChange() async {
        if enabled {
            do {
                try await OpenClickyOpenCLISubprocess.shared.start()
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
            }
        } else {
            OpenClickyOpenCLISubprocess.shared.stop()
            self.lastError = nil
        }
        syncRuntimeSnapshot()
    }

    /// One-shot startup called from `AppDelegate` / `cursor_buddyApp`.
    /// No-op unless the user has already opted in.
    static func autostartIfEnabled() {
        Task { @MainActor in
            let s = OpenClickyOpenCLISettings.shared
            guard s.enabled else { return }
            await s.applyEnabledChange()
        }
    }
}
