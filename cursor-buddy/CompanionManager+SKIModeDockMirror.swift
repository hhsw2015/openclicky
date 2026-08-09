//
//  CompanionManager+SKIModeDockMirror.swift
//  cursor-buddy
//
//  Mirrors every active SKI Mode session into the existing
//  `codexAgentSessions` array as a lightweight shim, then populates
//  `agentDockItems` pointing at the shim's UUID. This lets the standard
//  Codex chat / mini-chat panels open, hover, stop, etc. work on SKI
//  sessions with ZERO UI forks — the panels see a normal
//  CodexAgentSession, only the transcript source and submit target are
//  redirected via `session.skiBridge`.
//

import Foundation
import Combine

@MainActor
final class SKIModeDockMirror {
    static let shared = SKIModeDockMirror()

    /// SKI session id (String) -> CodexAgentSession UUID (the shim).
    private var idMap: [String: UUID] = [:]
    /// SKI session id -> the shim instance (kept for entry updates).
    private var shims: [String: CodexAgentSession] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private weak var manager: CompanionManager?
    private var pruneTimer: Timer?

    private init() {}

    func attach(companionManager: CompanionManager) {
        self.manager = companionManager
        SKIModeConversationStore.shared.$allSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.reconcile(with: sessions)
            }
            .store(in: &cancellables)
        // Re-run reconcile every 30 s so inactive sessions age out
        // even when no new SKI events arrive.
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reconcile(with: SKIModeConversationStore.shared.allSessions)
            }
        }
    }

    /// Auto-drop dock items for SKI sessions that have been inactive
    /// (UDS peer closed) for more than this many seconds. Short window
    /// so a killed CLI's ghost bubble disappears quickly. Reconnects
    /// within this window will collapse to a single fresh bubble via
    /// the store's evict-on-beginSession path.
    private static let inactiveGraceSeconds: TimeInterval = 10

    private func reconcile(with sessions: [SKISession]) {
        guard let cm = manager else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "openclicky.ski.dock_mirror_no_manager",
                fields: ["sessionsCount": "\(sessions.count)"]
            )
            return
        }

        let now = Date()
        let visibleSessions = sessions.filter { session in
            if session.isActive { return true }
            // Keep the last message timestamp (or startedAt) as the
            // "last seen" anchor. Drop when it's older than the grace.
            let lastActivity = session.messages.last?.ts ?? session.startedAt
            return now.timeIntervalSince(lastActivity) < Self.inactiveGraceSeconds
        }

        for session in visibleSessions {
            let shimUUID: UUID
            let shim: CodexAgentSession
            if let existingUUID = idMap[session.id], let existing = shims[session.id] {
                shimUUID = existingUUID
                shim = existing
            } else {
                shimUUID = UUID()
                idMap[session.id] = shimUUID
                let dir = (session.workspace as NSString).lastPathComponent
                let title = dir.isEmpty ? "SKI" : dir
                let accent = Self.accentTheme(forIndex: idMap.count)
                shim = CodexAgentSession(id: shimUUID, title: title, accentTheme: accent)
                shim.skiBridge = (workspace: session.workspace, skiSessionID: session.id)
                // Force visible-in-list status so the main panel Agents
                // tab shows the shim even before the first turn.
                shim.forceVisibleForSKIShim()
                shims[session.id] = shim
                cm.registerSKIShimAgentSession(shim)
            }

            // Mirror SKIMessages -> CodexTranscriptEntry.
            let entries = session.messages.compactMap(Self.mapMessageToEntry)
            shim.setEntriesForSKIShim(entries)

            // Derive Codex-facing session state from the last message.
            // - user message pending / thinking / tool_call → .running / .composing
            // - agent final reply → .ready / .idle
            // Session.isActive=false + inactive → mark completed
            // so it settles into "Completed" filter just like Codex.
            let (statusValue, stage, activity) = Self.deriveShimState(from: session)
            shim.updateSKIShimState(status: statusValue, progressStage: stage, activityStatus: activity)

            // Dock item — points at the shim's real UUID so Chat/Mini
            // buttons find it in codexAgentSessions.
            let lastAgent = session.messages.last(where: { $0.role == .agent })?.text
            let caption = lastAgent.map { String($0.prefix(120)) }
            let status: ClickyAgentDockStatus = session.isActive ? .running : .done
            let progressLabel = session.isActive ? "SKI · listening" : "SKI · ended"
            let dir = (session.workspace as NSString).lastPathComponent
            let title = dir.isEmpty ? "SKI" : dir
            let item = ClickyAgentDockItem(
                id: shimUUID,
                sessionID: shimUUID,        // <-- points at shim CodexAgentSession
                title: title,
                userInstruction: session.messages.first(where: { $0.role == .user })?.text ?? "",
                accentTheme: shim.accentTheme,
                status: status,
                progressStageLabel: progressLabel,
                progressStepText: nil,
                activityStatusLines: shim.activityStatusLines,
                caption: caption,
                suggestedNextActions: [],
                createdAt: session.startedAt
            )
            cm.upsertSKIModeDockItem(item)
        }

        let liveIDs = Set(visibleSessions.map { $0.id })
        for (skiID, shimUUID) in idMap where !liveIDs.contains(skiID) {
            cm.removeSKIModeDockItem(id: shimUUID)
            cm.removeSKIShimAgentSession(id: shimUUID)
            idMap.removeValue(forKey: skiID)
            shims.removeValue(forKey: skiID)
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "openclicky.ski.dock_upsert",
            fields: [
                "sessions": "\(sessions.count)",
                "total_dock_items": "\(cm.agentDockItems.count)",
                "ski_tracked": "\(idMap.count)"
            ]
        )

        if !sessions.isEmpty {
            cm.presentAgentDockWindowForSKI()
        }
    }

    /// Cycle through Codex's accent-theme palette so multi-session
    /// SKI dock bubbles look distinct — same set/order as
    /// `CompanionManager.nextAgentDockAccentTheme`.
    private static let accentPalette: [ClickyAccentTheme] = [.blue, .mint, .rose, .amber, .white]
    private static func accentTheme(forIndex index: Int) -> ClickyAccentTheme {
        accentPalette[index % accentPalette.count]
    }

    /// Map the tail of a SKISession's message list to the same status
    /// / progressStage / activity triple that a real Codex session
    /// would carry.
    private static func deriveShimState(from session: SKISession)
        -> (CodexAgentSessionStatus?, CodexAgentProgressStage?, String?)
    {
        guard let last = session.messages.last else {
            return (.ready, .idle, nil)
        }
        // Session peer closed → completed if we've seen any assistant
        // reply, else stopped.
        if !session.isActive {
            let hadReply = session.messages.contains { $0.role == .agent && $0.kind == .final }
            return (hadReply ? .ready : .stopped, hadReply ? .completed : .idle, nil)
        }
        switch last.kind {
        case .toolCall:
            let activity = last.text.hasPrefix("→")
                ? "Working: " + last.text.dropFirst().trimmingCharacters(in: .whitespaces)
                : last.text
            return (.running, .composing, String(activity))
        case .toolResult:
            return (.running, .composing, nil)
        case .final, .ack:
            return (.ready, last.kind == .final ? .idle : .composing, nil)
        case .text, .notice:
            return (.ready, .idle, nil)
        }
    }

    private static func mapMessageToEntry(_ message: SKIMessage) -> CodexTranscriptEntry? {
        let role: CodexTranscriptEntry.Role
        switch message.role {
        case .user: role = .user
        case .agent:
            switch message.kind {
            case .toolCall, .toolResult: role = .command
            case .notice: role = .system
            default: role = .assistant
            }
        case .system: role = .system
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return CodexTranscriptEntry(role: role, text: text, createdAt: message.ts)
    }

    func skiSessionID(forDockItemID dockID: UUID) -> String? {
        idMap.first(where: { $0.value == dockID })?.key
    }
}
