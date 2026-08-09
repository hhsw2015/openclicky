//
//  OpenClickyOpenCLISettingsSection.swift
//  cursor-buddy
//
//  Phase 7.6a F30 review follow-up — SwiftUI section that exposes the
//  OpenCLI subprocess master toggle, live runtime status readout, and a
//  Node path override text field. Rendered in the new "MCP subsystems"
//  Settings tab so users no longer have to hand-write the
//  `openclicky.opencli.enabled` UserDefaults key.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  (informational — OpenCLI has no upstream Everywhere counterpart).
//

import SwiftUI

@MainActor
struct OpenClickyOpenCLISettingsSection: View {
    // Not `@ObservedObject`: see OpenClickyOpenDiaSettingsSection for
    // rationale. The shared singleton publishes on runtime-status
    // heartbeats and stalls scroll in the MCP subsystems tab. We
    // snapshot at 1 Hz instead.
    let settings: OpenClickyOpenCLISettings

    // OpenCLISettings does not currently expose a nodePathOverride
    // property, but the UI still surfaces the read-only defaults key so
    // advanced users can inspect it. We use @AppStorage against the raw
    // UserDefaults key for direct editing.
    @AppStorage("openclicky.opencli.nodePathOverride") private var nodePathOverride: String = ""

    @State private var enabledSnapshot: Bool = false
    @State private var runtimeStatusSnapshot: String = ""
    @State private var siteCountSnapshot: Int? = nil
    @State private var adapterCountSnapshot: Int? = nil
    @State private var lastErrorSnapshot: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            enableToggleRow
            Divider().padding(.leading, 46)
            statusRow
            Divider().padding(.leading, 46)
            nodePathRow
            if let error = lastErrorSnapshot, !error.isEmpty {
                Divider().padding(.leading, 46)
                errorRow(error)
            }
        }
        .task(id: ObjectIdentifier(settings)) {
            refreshSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() {
        if enabledSnapshot != settings.enabled { enabledSnapshot = settings.enabled }
        if runtimeStatusSnapshot != settings.runtimeStatus { runtimeStatusSnapshot = settings.runtimeStatus }
        if siteCountSnapshot != settings.siteCount { siteCountSnapshot = settings.siteCount }
        if adapterCountSnapshot != settings.adapterCount { adapterCountSnapshot = settings.adapterCount }
        if lastErrorSnapshot != settings.lastError { lastErrorSnapshot = settings.lastError }
    }

    // MARK: - Rows

    private var enableToggleRow: some View {
        HStack(spacing: 12) {
            rowIcon("terminal")
            VStack(alignment: .leading, spacing: 3) {
                Text("Enable OpenCLI site adapters")
                    .font(.system(size: 13, weight: .medium))
                Text("Runs a local Node subprocess that exposes site-specific CLI adapters (Twitter, Reddit, LinkedIn, etc.) through the opencli_* MCP tools.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { enabledSnapshot },
                set: { newValue in
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
        HStack(spacing: 12) {
            rowIcon(statusIcon())
            VStack(alignment: .leading, spacing: 3) {
                Text("Status").font(.system(size: 13, weight: .medium))
                Text(describeStatus())
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var nodePathRow: some View {
        HStack(spacing: 12) {
            rowIcon("chevron.left.forwardslash.chevron.right")
            VStack(alignment: .leading, spacing: 3) {
                Text("Node path override").font(.system(size: 13, weight: .medium))
                TextField("Auto-discover (leave blank)", text: $nodePathOverride)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Text("Absolute path to a `node` executable. Empty = auto-discover /opt/homebrew, /usr/local, nvm, PATH.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    // MARK: - Helpers

    private func describeStatus() -> String {
        if !enabledSnapshot { return "Stopped" }
        var parts: [String] = []
        let base = runtimeStatusSnapshot.isEmpty ? "starting..." : runtimeStatusSnapshot
        parts.append(base)
        if let sites = siteCountSnapshot { parts.append("\(sites) sites") }
        if let adapters = adapterCountSnapshot { parts.append("\(adapters) adapters") }
        return parts.joined(separator: " — ")
    }

    private func statusIcon() -> String {
        if !enabledSnapshot { return "pause.circle" }
        if lastErrorSnapshot != nil { return "exclamationmark.triangle" }
        if (siteCountSnapshot ?? 0) > 0 { return "checkmark.circle" }
        return "circle.dashed"
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 22)
    }
}
