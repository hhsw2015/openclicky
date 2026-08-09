//
//  OpenClickyRouteDispatcher.swift
//  cursor-buddy
//
//  Phase 4 Step 2: Dispatch the [ROUTE] JSON parsed from a Fable reply
//  into the codex spawn path, or fall back to a pure-context-signal
//  classifier when Fable forgot to emit [ROUTE]. Wired from
//  HeyClickyChatToolCallClient.analyzeVoiceResponse after decode.
//
//  Contract:
//   - kind == chat / ambiguous  -> no codex spawn (TTS reply is enough).
//   - kind == short_task / long_task_new / long_task_existing -> spawn.
//   - Fallback classifier NEVER uses utterance keyword tables. It only
//     consults preflight context signals (WorkdirProbe.probe on
//     preflight.selectedFolder + ProjectRegistry fuzzy match on the
//     transcript / window title).
//
//  See docs/ROADMAP/02_LAYER_1_INTENT_ROUTER.md and
//  docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md.
//

import AppKit
import Foundation
import OpenClickyContextService

@MainActor
final class RouteDispatcher {

    static let shared = RouteDispatcher()

    /// Wired from CompanionManager.init so the dispatcher can reach the
    /// codex spawn primitives without a static import cycle.
    weak var companionManager: CompanionManager?

    private init() {}

    // MARK: - Public entry points

    /// Spawn a self-driving Codex run. Callers construct the route
    /// bundle themselves (Layer 0 fills workdir/slug/progressDriven
    /// from folder probe + agent intent detection). No confidence
    /// gate or [ROUTE] JSON parsing here — that lived on the chat
    /// path and has been removed.
    func spawnCodex(
        route: HeyClickyChatToolCallClient.RouteParseResult,
        userTranscript: String,
        preflight: HeyClickyChatToolCallClient.FablePreflightContext?
    ) {
        guard let companion = companionManager else {
            HeyClickyLog.log("openclicky.route_dispatch_no_companion", lane: "voice", direction: "warn", [
                "kind": route.kind
            ])
            return
        }

        // Resolve workdir: explicit route > project_ref lookup >
        // preflight selected folder > nil (standalone ~/OpenClicky/<slug>/).
        var workdir: String? = nil
        if let raw = route.workdir?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // F26 HIGH #2 — tilde-expand before the validator downstream
            // sees the path; `FileManager.fileExists` does not expand `~`.
            workdir = (raw as NSString).expandingTildeInPath
        } else if let projectRef = route.projectRef?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !projectRef.isEmpty,
                  let match = ProjectRegistry.shared.lookup(projectRef, limit: 1).first,
                  match.score >= 0.75 {
            // F26 LOW #2 — resolve project_ref via ProjectRegistry when
            // the model named a project but did not supply a workdir.
            HeyClickyLog.log("openclicky.route_project_ref_resolved", lane: "voice", direction: "internal", [
                "project_ref": projectRef,
                "resolved_slug": match.entry.slug,
                "score": String(format: "%.2f", match.score)
            ])
            workdir = match.entry.path
        } else if let folder = preflight?.selectedFolder, !folder.isEmpty {
            workdir = folder
        }

        // Openclicky task-planning contract (docs/OPENCLICKY_TASK_SPEC.md):
        //   - Workdir-anchored: <workdir>/.openclicky/task/
        //   - Standalone:       ~/OpenClicky/<slug>/
        let resolution = OpenClickyTaskDirectoryResolver.resolve(
            workdir: workdir,
            slug: route.slug
        )

        let prompt = composeAgentPrompt(
            userTranscript: userTranscript,
            preflight: preflight,
            route: route
        )

        HeyClickyLog.log("openclicky.route_spawn_codex", lane: "voice", direction: "outgoing", [
            "kind": route.kind,
            "workdir": workdir ?? "",
            "task_dir": resolution.taskDir,
            "task_dir_anchor": resolution.anchor.rawValue,
            "progress_exists": resolution.progressExists ? "true" : "false",
            "slug": route.slug ?? "",
            "project_ref": route.projectRef ?? "",
            "progress_driven": route.progressDriven ? "true" : "false",
            "completion_marker": route.effectiveCompletionMarker ?? "",
            "prompt_len": prompt.count
        ])

        // If no PROGRESS.md was pre-provided at the resolved task dir,
        // fabricate one via the 3-round background planning loop and
        // then spawn codex. Otherwise spawn immediately.
        if !resolution.progressExists {
            let planningContext = OpenClickyPlanningLoop.Context(
                taskIntent: userTranscript,
                workdir: workdir,
                layer0Digest: preflightDigest(preflight)
            )
            Task { @MainActor in
                let progressMd = await OpenClickyPlanningLoop.generate(context: planningContext)
                let progressURL = URL(fileURLWithPath: resolution.progressPath)
                try? progressMd.write(to: progressURL, atomically: true, encoding: .utf8)
                HeyClickyLog.log("openclicky.planning.fabricated", lane: "voice", direction: "internal", [
                    "taskDir": resolution.taskDir,
                    "anchor": resolution.anchor.rawValue,
                    "lines": String(progressMd.split(separator: "\n").count),
                    "bytes": String(progressMd.utf8.count)
                ])
                self.performSpawn(
                    companion: companion,
                    prompt: prompt,
                    workdir: workdir,
                    resolution: resolution,
                    route: route,
                    userTranscript: userTranscript
                )
            }
            return
        }

        performSpawn(
            companion: companion,
            prompt: prompt,
            workdir: workdir,
            resolution: resolution,
            route: route,
            userTranscript: userTranscript
        )
    }

    /// Final spawn step shared by the "PROGRESS.md pre-provided" and
    /// "PROGRESS.md fabricated" branches.
    private func performSpawn(
        companion: CompanionManager,
        prompt: String,
        workdir: String?,
        resolution: OpenClickyTaskDirectoryResolver.Resolution,
        route: HeyClickyChatToolCallClient.RouteParseResult,
        userTranscript: String
    ) {
        // Working-directory override for codex: keep the resolved workdir
        // where the user actually is (variant A), or use the standalone
        // task dir itself (variant B) so the agent lands inside its
        // sandbox rather than $HOME.
        let workingDirectoryOverride: String = workdir ?? resolution.taskDir
        companion.dispatchRoutedAgentTask(
            instruction: prompt,
            workingDirectoryOverride: workingDirectoryOverride,
            projectRef: route.projectRef,
            slug: route.slug,
            progressDriven: true,
            completionMarker: route.effectiveCompletionMarker
                ?? OpenClickyRouterSettings.shared.effectiveDefaultCompletionMarker,
            taskDir: resolution.taskDir,
            taskProgressPath: resolution.progressPath,
            voiceContextUserTranscript: userTranscript
        )
    }

    /// Short digest of Layer-0 context to seed the planning loop with the
    /// scene the user is in. Kept < ~2 KB to stay well inside any prompt
    /// window; PII / long selections are truncated.
    private func preflightDigest(_ preflight: HeyClickyChatToolCallClient.FablePreflightContext?) -> String {
        guard let p = preflight else { return "" }
        var lines: [String] = []
        if let name = p.frontmostName, !name.isEmpty {
            lines.append("frontmost_app: \(name)")
        } else if let bundle = p.frontmostBundle, !bundle.isEmpty {
            lines.append("frontmost_app: \(bundle)")
        }
        if let title = p.windowTitle, !title.isEmpty {
            let head = title.count > 200 ? String(title.prefix(200)) + "…" : title
            lines.append("window_title: \"\(head)\"")
        }
        if let url = p.browserURL, !url.isEmpty {
            lines.append("url: \(url)")
        }
        if let folder = p.selectedFolder, !folder.isEmpty {
            lines.append("selected_folder: \(folder)")
        }
        if !p.selectedFileNames.isEmpty {
            let joined = p.selectedFileNames.prefix(20).joined(separator: ", ")
            lines.append("selected_files: [\(joined)]")
        }
        if let sel = p.selectedText, !sel.isEmpty {
            let head = sel.count > 400 ? String(sel.prefix(400)) + "…" : sel
            let escaped = head
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
            lines.append("selected_text: \"\(escaped)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Prepend the scene context and route hint so the codex agent sees
    /// what Fable saw at classification time. Deeper reads happen via the
    /// MCP sensor tools that codex already has in its config.
    private func composeAgentPrompt(
        userTranscript: String,
        preflight: HeyClickyChatToolCallClient.FablePreflightContext?,
        route: HeyClickyChatToolCallClient.RouteParseResult
    ) -> String {
        var lines: [String] = []
        lines.append("USER REQUEST (from voice):")
        lines.append(userTranscript)
        lines.append("")
        lines.append("INITIAL SCENE CONTEXT:")
        if let name = preflight?.frontmostName, !name.isEmpty {
            lines.append("frontmost_app: \(name)")
        } else if let bundle = preflight?.frontmostBundle, !bundle.isEmpty {
            lines.append("frontmost_app: \(bundle)")
        }
        if let title = preflight?.windowTitle, !title.isEmpty {
            lines.append("window_title: \"\(title)\"")
        }
        if let url = preflight?.browserURL, !url.isEmpty {
            lines.append("url: \(url)")
        }
        if let folder = preflight?.selectedFolder, !folder.isEmpty {
            lines.append("selected_folder: \(folder)")
        }
        if let files = preflight?.selectedFileNames, !files.isEmpty {
            lines.append("selected_files: [\(files.joined(separator: ", "))]")
        }
        if let sel = preflight?.selectedText, !sel.isEmpty {
            let head = sel.count > 400 ? String(sel.prefix(400)) + "…" : sel
            let escaped = head
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("selected_text: \"\(escaped)\"")
        }
        lines.append("")
        let confStr = String(format: "%.2f", route.confidence)
        lines.append("INTENT (Fable classifier): \(route.kind), confidence \(confStr)")
        if let projectRef = route.projectRef, !projectRef.isEmpty {
            lines.append("project_ref: \(projectRef)")
        }
        if let slug = route.slug, !slug.isEmpty {
            lines.append("slug: \(slug)")
        }
        if route.progressDriven {
            lines.append("progress_driven: true")
            if let marker = route.effectiveCompletionMarker {
                lines.append("completion_marker: \(marker)")
            }
        }
        lines.append("")
        lines.append(
            "You have MCP sensor tools available (get_focused_context, get_selected_text, probe_workdir, etc). Use them as needed for fresh state — the scene context above is a snapshot from the voice-hotkey moment."
        )
        return lines.joined(separator: "\n")
    }

    /// Slug-ify a transcript head. Not a keyword classifier — just a
    /// filesystem-safe identifier used when we have to invent an
    /// ephemeral task dir. Never inspects semantics.
    /// Slug-ify a transcript head. Callable from Layer 0 to build a
    /// RouteParseResult on the fly.
    func makeSlug(from transcript: String) -> String {
        sanitizedSlug(from: transcript)
    }

    private func sanitizedSlug(from transcript: String) -> String {
        let head = String(transcript.prefix(40)).lowercased()
        let cleaned = head.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.isEmpty {
            return "task-\(Int(Date().timeIntervalSince1970))"
        }
        return String(trimmed.prefix(30))
    }
}
