//
//  OpenClickyOpenDiaSettingsSection.swift
//  cursor-buddy
//
//  Phase 7.6b F31 review follow-up — SwiftUI section that exposes the
//  OpenDia master toggle, live status readout, and a test-connection
//  action. Rendered inside the "System & Logs" settings tab so users
//  no longer have to hand-write the `openclicky.opendia.enabled`
//  UserDefaults key documented in the extension README.
//

import SwiftUI

@MainActor
struct OpenClickyOpenDiaSettingsSection: View {
    // Not `@ObservedObject` any more: the shared singleton fires
    // objectWillChange on every `@Published` write (enabled toggle,
    // lastError update, runtimeStatus sync from autostart or health
    // probes). While the MCP subsystems tab is scrolling, those
    // publishes trigger repeated VStack invalidations and stall the
    // scrollview. Instead we snapshot into local @State at 1 Hz.
    let settings: OpenClickyOpenDiaSettings

    @State private var isTesting: Bool = false
    @State private var testResult: String? = nil

    // Snapshot mirrors — refreshed at 1 Hz max from the shared
    // singleton via `.task`. Kept in sync with user-driven writes so
    // toggles/textfields feel immediate.
    @State private var enabledSnapshot: Bool = false
    @State private var nodePathSnapshot: String = ""
    @State private var runtimeStatusSnapshot: String = ""
    @State private var extensionConnectedSnapshot: Bool? = nil
    @State private var availableToolCountSnapshot: Int? = nil
    @State private var lastErrorSnapshot: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            enableToggleRow
            Divider().padding(.leading, 46)
            statusRow
            Divider().padding(.leading, 46)
            endpointRow
            Divider().padding(.leading, 46)
            testConnectionRow
            if let error = lastErrorSnapshot, !error.isEmpty {
                Divider().padding(.leading, 46)
                errorRow(error)
            }
            if let result = testResult, !result.isEmpty {
                Divider().padding(.leading, 46)
                resultRow(result)
            }
        }
        .task(id: ObjectIdentifier(settings)) {
            // Sample the singleton once immediately, then poll at 1 Hz
            // while the section is visible. Cancels automatically when
            // the view goes away (Task lifecycle owned by SwiftUI).
            refreshSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() {
        // Only write @State when the value actually changed — SwiftUI
        // still diffs, but this skips even the diff cost for identical
        // snapshots and keeps the render->publish loop broken.
        if enabledSnapshot != settings.enabled { enabledSnapshot = settings.enabled }
        let np = settings.nodePathOverride ?? ""
        if nodePathSnapshot != np { nodePathSnapshot = np }
        if runtimeStatusSnapshot != settings.runtimeStatus { runtimeStatusSnapshot = settings.runtimeStatus }
        if extensionConnectedSnapshot != settings.extensionConnected { extensionConnectedSnapshot = settings.extensionConnected }
        if availableToolCountSnapshot != settings.availableToolCount { availableToolCountSnapshot = settings.availableToolCount }
        if lastErrorSnapshot != settings.lastError { lastErrorSnapshot = settings.lastError }
    }

    // MARK: - Rows

    private var enableToggleRow: some View {
        HStack(spacing: 12) {
            rowIcon("globe")
            VStack(alignment: .leading, spacing: 3) {
                Text("Enable OpenDia browser automation")
                    .font(.system(size: 13, weight: .medium))
                Text("Runs a local Node bridge on 127.0.0.1 for the sideloaded OpenDia browser extension. 120 browser_* MCP tools become available to agents.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { enabledSnapshot },
                set: { newValue in
                    // Optimistic snapshot update so the toggle feels
                    // instant; the singleton didSet chain kicks off
                    // the real start/stop.
                    enabledSnapshot = newValue
                    settings.enabled = newValue
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusRow: some View {
        let text = describeStatus()
        return HStack(spacing: 12) {
            rowIcon(statusIcon())
            VStack(alignment: .leading, spacing: 3) {
                Text("Status").font(.system(size: 13, weight: .medium))
                Text(LocalizedStringKey(text))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var endpointRow: some View {
        let subprocess = OpenClickyOpenDiaSubprocess.shared
        let endpoint: String
        if let url = subprocess.localhostURL {
            endpoint = "\(url.absoluteString) (WS on same port)"
        } else {
            endpoint = "Not bound — enable OpenDia to allocate a port."
        }
        return HStack(spacing: 12) {
            rowIcon("network")
            VStack(alignment: .leading, spacing: 3) {
                Text("Endpoint").font(.system(size: 13, weight: .medium))
                Text(endpoint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var testConnectionRow: some View {
        Button {
            runTest()
        } label: {
            HStack(spacing: 12) {
                rowIcon(isTesting ? "hourglass" : "bolt.horizontal")
                Text(isTesting ? "Testing connection..." : "Test connection")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTesting || !enabledSnapshot)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 12) {
            rowIcon("exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 3) {
                Text("Error").font(.system(size: 13, weight: .medium))
                Text(LocalizedStringKey(message))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func resultRow(_ message: String) -> some View {
        HStack(spacing: 12) {
            rowIcon("checkmark.seal")
            VStack(alignment: .leading, spacing: 3) {
                Text("Last test").font(.system(size: 13, weight: .medium))
                Text(LocalizedStringKey(message))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Helpers

    private func describeStatus() -> String {
        if !enabledSnapshot { return "Stopped" }
        let base = runtimeStatusSnapshot.isEmpty ? "starting..." : runtimeStatusSnapshot
        if let connected = extensionConnectedSnapshot {
            let tail = connected
                ? "Extension connected."
                : "Waiting for browser extension to connect."
            return "\(base) — \(tail)"
        }
        return base
    }

    private func statusIcon() -> String {
        if !enabledSnapshot { return "pause.circle" }
        if let connected = extensionConnectedSnapshot, connected { return "checkmark.circle" }
        if lastErrorSnapshot != nil { return "exclamationmark.triangle" }
        return "circle.dashed"
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 22)
    }

    private func runTest() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        Task { @MainActor in
            let message = await OpenClickyOpenDiaSubprocess.shared.testConnection()
            self.testResult = message
            self.isTesting = false
            self.settings.syncRuntimeSnapshot()
        }
    }
}
