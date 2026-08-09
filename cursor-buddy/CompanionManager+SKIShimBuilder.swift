//
//  CompanionManager+SKIShimBuilder.swift
//  cursor-buddy
//
//  One place to build a per-turn CodexAgentSession shim + matching dock
//  bubble. Peeky Free's mirage pipeline calls this when a voice turn
//  routes into an agent branch; SKI's dock mirror uses a very similar
//  recipe inline (see CompanionManager+SKIModeDockMirror.swift:80-129)
//  and can adopt this once its per-session bookkeeping is refactored.
//
//  Why not push into SKIModeDockMirror wholesale: SKI's version threads
//  workspace metadata + persistent id map + skiBridge coupling that is
//  irrelevant for a one-shot mirage turn. Keeping mirage's simpler path
//  distinct avoids dragging that complexity into every call site.
//
//  The returned shim is already registered via `registerSKIShimAgentSession`
//  so Chat / MiniChat can look it up, and the initial dock item points
//  its `sessionID` at the shim's UUID. Callers advance the shim via the
//  usual `updateSKIShimState` / `appendRemoteTranscriptEntry` API.

import Foundation

@MainActor
extension CompanionManager {
    /// Advance a per-turn dock bubble's status + stage label while its
    /// underlying agent is still working. Used by Peeky Free's mirage
    /// pipeline to reflect each streamed Claude Code CLI event as
    /// "🔧 tool_name" / "💭 Thinking…" / "Composing reply" on the dock,
    /// matching the way Codex agent bubbles update.
    ///
    /// Idempotent per event — safe to call rapidly. `activityLine` is
    /// appended to the shim's rolling activity buffer (rendered under
    /// the bubble title in the notch panel).
    func advanceMiragePeekyDock(
        dockID: UUID,
        shim: CodexAgentSession,
        title: String,
        userInstruction: String,
        stageLabel: String,
        activityLine: String?,
        dockStatus: ClickyAgentDockStatus
    ) {
        // Nudge the shim's own view of "still running" so the shared
        // Codex overlay treats it as active. Empty string means "keep
        // whatever activity buffer we already have".
        shim.updateSKIShimState(
            status: .running,
            progressStage: .composing,
            activityStatus: activityLine ?? "")
        // Republish dock item with updated fields; upsert is keyed on
        // `id` so the existing bubble mutates in place.
        upsertSKIModeDockItem(ClickyAgentDockItem(
            id: dockID,
            sessionID: dockID,
            title: title,
            userInstruction: userInstruction,
            accentTheme: .rose,
            status: dockStatus,
            progressStageLabel: stageLabel,
            progressStepText: nil,
            activityStatusLines: shim.activityStatusLines,
            caption: nil,
            suggestedNextActions: [],
            createdAt: Date()
        ))
    }

    /// Build + register a per-turn shim for a dock bubble. Returns the
    /// shim and the dock item's UUID (same value as `shim.id`) so callers
    /// can wire the two lifetimes together.
    func makeShimForTurn(
        title: String,
        userInstruction: String,
        accentTheme: ClickyAccentTheme,
        initialStageLabel: String
    ) -> (shim: CodexAgentSession, dockID: UUID) {
        let dockID = UUID()
        let shim = CodexAgentSession(id: dockID, title: title, accentTheme: accentTheme)
        shim.forceVisibleForSKIShim()
        registerSKIShimAgentSession(shim)
        upsertSKIModeDockItem(ClickyAgentDockItem(
            id: dockID,
            sessionID: dockID,
            title: title,
            userInstruction: userInstruction,
            accentTheme: accentTheme,
            status: .starting,
            progressStageLabel: initialStageLabel,
            progressStepText: nil,
            activityStatusLines: [],
            caption: nil,
            suggestedNextActions: [],
            createdAt: Date()
        ))
        return (shim, dockID)
    }
}
