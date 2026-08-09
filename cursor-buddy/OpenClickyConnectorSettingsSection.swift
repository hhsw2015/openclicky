//
//  OpenClickyConnectorSettingsSection.swift
//  cursor-buddy
//
//  Phase 7.5 F29 review follow-up — SwiftUI section that exposes the
//  open-connector subprocess master toggle, live runtime status readout,
//  a Node path override text field, and provider allow/deny lists.
//  Rendered in the new "MCP subsystems" Settings tab.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  (informational — open-connector has no upstream Everywhere counterpart).
//

import SwiftUI

@MainActor
struct OpenClickyConnectorSettingsSection: View {
    // Not `@ObservedObject`: see OpenClickyOpenDiaSettingsSection for
    // rationale. The shared singleton publishes on runtime-status
    // heartbeats and stalls scroll in the MCP subsystems tab. We
    // snapshot at 1 Hz instead.
    let settings: OpenClickyConnectorSettings

    @State private var enabledSnapshot: Bool = false
    @State private var nodePathSnapshot: String = ""
    @State private var providerAllowlistSnapshot: [String] = []
    @State private var providerDisallowlistSnapshot: [String] = []
    @State private var runtimeStatusSnapshot: String = ""
    @State private var providerCountSnapshot: Int? = nil
    @State private var lastErrorSnapshot: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            enableToggleRow
            Divider().padding(.leading, 46)
            statusRow
            Divider().padding(.leading, 46)
            nodePathRow
            Divider().padding(.leading, 46)
            allowlistRow
            Divider().padding(.leading, 46)
            disallowlistRow
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
        let np = settings.nodePathOverride ?? ""
        if nodePathSnapshot != np { nodePathSnapshot = np }
        if providerAllowlistSnapshot != settings.providerAllowlist { providerAllowlistSnapshot = settings.providerAllowlist }
        if providerDisallowlistSnapshot != settings.providerDisallowlist { providerDisallowlistSnapshot = settings.providerDisallowlist }
        if runtimeStatusSnapshot != settings.runtimeStatus { runtimeStatusSnapshot = settings.runtimeStatus }
        if providerCountSnapshot != settings.providerCount { providerCountSnapshot = settings.providerCount }
        if lastErrorSnapshot != settings.lastError { lastErrorSnapshot = settings.lastError }
    }

    // MARK: - Rows

    private var enableToggleRow: some View {
        HStack(spacing: 12) {
            rowIcon("link.circle")
            VStack(alignment: .leading, spacing: 3) {
                Text("Enable open-connector providers")
                    .font(.system(size: 13, weight: .medium))
                Text("Runs a local Node subprocess exposing 831 SaaS providers (GitHub, Slack, Notion, …) through the connector_* MCP tools.")
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
                TextField("Auto-discover (leave blank)", text: Binding(
                    get: { nodePathSnapshot },
                    set: { newValue in
                        nodePathSnapshot = newValue
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.nodePathOverride = trimmed.isEmpty ? nil : trimmed
                    }
                ))
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

    private var allowlistRow: some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("checkmark.shield")
            VStack(alignment: .leading, spacing: 3) {
                Text("Provider allowlist").font(.system(size: 13, weight: .medium))
                TextField("comma-separated (empty = allow all)", text: Binding(
                    get: { providerAllowlistSnapshot.joined(separator: ", ") },
                    set: { newValue in
                        let parsed = parseList(newValue)
                        providerAllowlistSnapshot = parsed
                        settings.providerAllowlist = parsed
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                Text("e.g. github, slack, notion. Empty allows all 831 providers.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var disallowlistRow: some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("nosign")
            VStack(alignment: .leading, spacing: 3) {
                Text("Provider disallowlist").font(.system(size: 13, weight: .medium))
                TextField("comma-separated (applied after allowlist)", text: Binding(
                    get: { providerDisallowlistSnapshot.joined(separator: ", ") },
                    set: { newValue in
                        let parsed = parseList(newValue)
                        providerDisallowlistSnapshot = parsed
                        settings.providerDisallowlist = parsed
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                Text("Providers listed here are stripped after the allowlist filter runs.")
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
        if let providers = providerCountSnapshot { parts.append("\(providers) providers") }
        return parts.joined(separator: " — ")
    }

    private func statusIcon() -> String {
        if !enabledSnapshot { return "pause.circle" }
        if lastErrorSnapshot != nil { return "exclamationmark.triangle" }
        if (providerCountSnapshot ?? 0) > 0 { return "checkmark.circle" }
        return "circle.dashed"
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 22)
    }

    private func parseList(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
