//
//  CompanionManager+SelfDrivingCodexDispatch.swift
//  cursor-buddy
//
//  Pre-routing hook for the self-driving Codex lane. Fires before
//  the upstream jasonkneen/openclicky 13-layer keyword chain in
//  `routeFinalVoiceTranscriptActionIfNeeded` when the transcript
//  looks like an agent-intent utterance AND PickStash has a folder
//  selected — routes to RouteDispatcher.spawnCodex so Codex runs
//  self-driving inside that folder (resuming PROGRESS.md or
//  fabricating one via OpenClickyPlanningLoop).
//
//  Utterances without a folder fall through to upstream (single-shot
//  Codex or chat with context injection).
//

import AppKit
import Foundation
import OpenClickyContextService

extension CompanionManager {

    /// Try self-driving Codex routing. Returns true when the
    /// transcript was fully handled here; false to let upstream
    /// take over.
    func trySelfDrivingCodexDispatch(from transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        guard Self.implicitAgentTaskInstruction(from: normalized) != nil else {
            return false
        }

        guard let folder = Self.peekSelectedFolderFromStash() else {
            return false
        }

        Task { @MainActor in
            self.dispatchSelfDrivingCodex(userTask: normalized, workdir: folder)
        }
        return true
    }

    private func dispatchSelfDrivingCodex(userTask: String, workdir: String) {
        let slug = RouteDispatcher.shared.makeSlug(from: userTask)
        let probe = WorkdirProbe.probe(URL(fileURLWithPath: workdir))
        let kind: String
        let projectRef: String?
        if probe.exists && probe.isDirectory && probe.isEmpty {
            kind = "long_task_new"
            projectRef = nil
        } else {
            kind = "long_task_existing"
            projectRef = URL(fileURLWithPath: workdir).lastPathComponent
        }

        let route = HeyClickyChatToolCallClient.RouteParseResult(
            kind: kind,
            projectRef: projectRef,
            slug: slug,
            workdir: workdir,
            confidence: 0.75
        )

        HeyClickyLog.log(
            "companion.self_driving_codex_dispatch",
            lane: "agent",
            direction: "internal",
            ["kind": kind, "workdir": workdir, "slug": slug]
        )

        // spawnCodex fabricates PROGRESS.md via OpenClickyPlanningLoop
        // when missing, then dispatches to CompanionManager with
        // progressDriven=true. Preflight nil is fine — spawnCodex
        // rebuilds what it needs.
        RouteDispatcher.shared.spawnCodex(
            route: route,
            userTranscript: userTask,
            preflight: nil
        )
    }

    /// Sync peek at whatever the last PickStash entry looks like.
    /// Returns an expanded absolute directory path when the stash
    /// entry points at one, nil otherwise. Cheap, never blocks.
    static func peekSelectedFolderFromStash() -> String? {
        guard let picked = PickStash.shared.peekAll().last,
              let raw = picked.value else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
           isDir.boolValue {
            return expanded
        }
        return nil
    }
}
