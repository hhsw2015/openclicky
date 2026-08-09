//
//  SKIModeWorkspacesBar.swift
//  cursor-buddy
//
//  Horizontal chip bar rendered near the top of the OpenClicky notch
//  panel. Only visible when SKI Mode is the active profile AND at
//  least one CLI agent has connected via ~/.openclicky/agents.sock.
//  Mirrors SKI's project chip UX: user picks which workspace receives
//  voice; auto = follow focused window.
//

import SwiftUI

struct SKIModeWorkspacesBar: View {
    @ObservedObject private var presence = OpenClickyAgentsPresenceStore.shared
    @State private var activeProfileID: String = OpenClickyProfileCatalog.activeProfile().id

    var body: some View {
        Group {
            if activeProfileID == "ski_mode" {
                content
            } else {
                EmptyView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            activeProfileID = OpenClickyProfileCatalog.activeProfile().id
        }
    }

    private var content: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                autoChip
                if presence.connected.isEmpty {
                    emptyStateChip
                } else {
                    ForEach(presence.connected) { agent in
                        workspaceChip(agent)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.15))
    }

    private var emptyStateChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text("No CLI connected - run \"start openclicky voice\"")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .help("Open Claude Code (or another CLI agent with openclicky-voice installed) in a git repo and say \"start openclicky voice\" to connect.")
    }

    private var autoChip: some View {
        let isAuto = presence.pinnedActiveProjectRoot == nil
        return Button {
            presence.setPinnedActiveProject(nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "location.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("Auto")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isAuto ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(isAuto ? Color.accentColor : Color.white.opacity(0.15), lineWidth: 1)
            )
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func workspaceChip(_ agent: OpenClickyAgentPresence) -> some View {
        let isActive = presence.pinnedActiveProjectRoot == agent.projectRoot
        let dirName = (agent.projectRoot as NSString).lastPathComponent
        return Button {
            presence.setPinnedActiveProject(isActive ? nil : agent.projectRoot)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(dirName.isEmpty ? agent.projectRoot : dirName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(isActive ? Color.accentColor : Color.white.opacity(0.15), lineWidth: 1)
            )
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .help(agent.projectRoot)
    }
}
