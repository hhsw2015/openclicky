//
//  OpenClickyChromeBridgeSettingsSection.swift
//  cursor-buddy
//
//  Settings pane readout for the local HeyClickyChromeBridgeServer.
//  Distinct from the OpenDia settings section: this surface reports on
//  the account-reset auto-clicker bridge (Swift HTTP listener on
//  127.0.0.1:3011, polled by the merged OpenDia Chrome extension), not
//  on the Node-based OpenDia MCP subprocess.
//
//  Shows:
//    - Whether the local listener is bound and on which port
//    - Whether the Chrome extension is currently polling (`extAlive`
//      from `/health`, falling back to the server's own timestamp)
//    - A manual Refresh button; the pane also auto-polls every 4s
//      while visible.
//

import SwiftUI
import Foundation

@MainActor
struct OpenClickyChromeBridgeSettingsSection: View {
    @State private var isRefreshing: Bool = false
    @State private var serverRunning: Bool = false
    @State private var activePort: UInt16? = nil
    @State private var extensionConnected: Bool? = nil
    @State private var lastCheckedAt: Date? = nil
    @State private var lastError: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serverStatusRow
            Divider().padding(.leading, 46)
            extensionStatusRow
            Divider().padding(.leading, 46)
            refreshRow
            Divider().padding(.leading, 46)
            explanationRow
        }
        .onAppear {
            // One-shot refresh on appear. No polling — user hits
            // Refresh row to re-check. Polling caused SwiftUI body
            // to re-render every 4s in the scrollview, stalling
            // scroll performance and racing @MainActor accessors.
            refresh()
        }
    }

    // MARK: - Rows

    private var serverStatusRow: some View {
        HStack(spacing: 12) {
            rowIcon(serverIconName())
            VStack(alignment: .leading, spacing: 3) {
                Text("Server status").font(.system(size: 13, weight: .medium))
                Text(serverStatusText())
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

    private var extensionStatusRow: some View {
        HStack(spacing: 12) {
            rowIcon(extensionIconName())
            VStack(alignment: .leading, spacing: 3) {
                Text("Extension status").font(.system(size: 13, weight: .medium))
                Text(extensionStatusText())
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

    private var refreshRow: some View {
        Button {
            refresh(force: true)
        } label: {
            HStack(spacing: 12) {
                rowIcon(isRefreshing ? "hourglass" : "arrow.clockwise")
                Text(isRefreshing ? "Refreshing..." : "Refresh")
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
        .disabled(isRefreshing)
    }

    private var explanationRow: some View {
        HStack(spacing: 12) {
            rowIcon("info.circle")
            VStack(alignment: .leading, spacing: 3) {
                Text("About").font(.system(size: 13, weight: .medium))
                Text("The merged OpenDia Chrome extension polls this bridge to handle account reset flows. If not connected, load the extension in Chrome from ~/Dev/opendia/opendia-extension/dist/chrome/ (via chrome://extensions/, Load unpacked).")
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

    private func serverStatusText() -> String {
        if let port = activePort, serverRunning {
            return "Listening on 127.0.0.1:\(port)"
        }
        return "Not running"
    }

    private func serverIconName() -> String {
        if serverRunning { return "checkmark.circle" }
        return "pause.circle"
    }

    private func extensionStatusText() -> String {
        if let error = lastError, !error.isEmpty {
            return "Health check failed: \(error)"
        }
        guard let extensionConnected else {
            return "Waiting for first check..."
        }
        if extensionConnected {
            if let stamp = lastCheckedAt {
                let elapsed = Int(max(0, Date().timeIntervalSince(stamp)))
                return "Connected (checked \(elapsed)s ago)"
            }
            return "Connected"
        }
        return "Not connected — extension is not polling the bridge."
    }

    private func extensionIconName() -> String {
        if let extensionConnected {
            return extensionConnected ? "checkmark.circle" : "exclamationmark.triangle"
        }
        return "circle.dashed"
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 22)
    }

    // MARK: - Refresh

    private func refresh(force: Bool = false) {
        if isRefreshing && !force { return }
        isRefreshing = true

        // Snapshot bridge state on the MainActor before jumping to a
        // detached task for the network probe. The bridge is
        // @MainActor-isolated, so we cannot read it from a background
        // task.
        let bridge = HeyClickyChromeBridgeServer.shared
        let running = bridge.isRunning
        let port = bridge.activePort
        // `isExtensionAlive` is the server's own liveness view. We use
        // it as a starting point; if the port is reachable we also try
        // `/health` to confirm the extension is actively polling.
        let localAlive = bridge.isExtensionAlive

        serverRunning = running
        activePort = port

        Task {
            let result = await probeHealth(port: port)
            await MainActor.run {
                switch result {
                case .success(let extAlive):
                    self.extensionConnected = extAlive
                    self.lastError = nil
                case .failure(let message):
                    // Fall back to the server-tracked timestamp when the
                    // curl fails (e.g. transient close) so the UI does
                    // not blink to "unknown" on every retry.
                    self.extensionConnected = localAlive
                    self.lastError = message
                }
                self.lastCheckedAt = Date()
                self.isRefreshing = false
            }
        }
    }

    private enum HealthResult {
        case success(Bool)
        case failure(String)
    }

    private func probeHealth(port: UInt16?) async -> HealthResult {
        guard let port else {
            return .failure("bridge not bound")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return .failure("bad URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.5
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("bad JSON")
            }
            let alive = (obj["extAlive"] as? Bool) ?? false
            return .success(alive)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
