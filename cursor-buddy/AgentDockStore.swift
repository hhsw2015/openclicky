//
//  AgentDockStore.swift
//  cursor-buddy
//
//  Narrow ObservableObject that mirrors the agent-dock / handoff-queue
//  fields on CompanionManager. Any view that only wants dock changes
//  (ClickyAgentDockStackView, the agent menu-bar icon) observes this
//  store instead of the whole CompanionManager, so per-frame agent
//  progress updates don't invalidate BlueCursorView / notch / chat.
//
//  CompanionManager keeps the original @Published fields (public API
//  is preserved); this class is written to via `didSet` mirrors.
//

import Foundation
import Combine

@MainActor
final class AgentDockStore: ObservableObject {
    /// Mirror of `CompanionManager.agentDockItems`.
    @Published var agentDockItems: [ClickyAgentDockItem] = []

    /// Mirror of `CompanionManager.codexAgentSessions`.
    @Published var codexAgentSessions: [CodexAgentSession] = []

    /// Mirror of `CompanionManager.handoffQueue`.
    @Published var handoffQueue: [HandoffQueuedRegionScreenshot] = []
}
