//
//  OpenClickyPlanningLoop.swift
//  cursor-buddy
//
//  OpenClicky planning loop: fabricate PROGRESS.md via dialog-model API
//  when no external planning skill has pre-provided one. Runs 3 rounds
//  against the free HeyClicky planning channel (msgs-quota lane) so
//  paid agent credit is preserved.
//
//  This is a background loop invoked by OpenClickyRouteDispatcher between
//  user turn N (assistant already voice-replied "开始了") and codex spawn.
//  The user does not see the API rounds.
//
//  Openclicky-native. No Everywhere counterpart.
//

import Foundation

@MainActor
public enum OpenClickyPlanningLoop {

    public struct Context: Sendable {
        public let taskIntent: String        // user's transcribed voice request
        public let workdir: String?          // resolved workdir (nil for ~/OpenClicky variant)
        public let layer0Digest: String      // frontmost app / window / selection digest

        public init(taskIntent: String, workdir: String?, layer0Digest: String) {
            self.taskIntent = taskIntent
            self.workdir = workdir
            self.layer0Digest = layer0Digest
        }
    }

    /// Runs a 3-round loop against the free HeyClicky planning channel.
    /// Returns the final PROGRESS.md content verbatim (round-3 output).
    ///
    /// Provider preference (money-rule): HeyClicky free msgs channel is the
    /// only lane exercised here on purpose — it consumes the msgs quota,
    /// never agent credit, and never a raw paid API key. If the free lane
    /// is unavailable / fails, callers fall back to a minimal PROGRESS.md
    /// stub (this function itself never throws; it returns the minimal
    /// fallback on any failure).
    public static func generate(context: Context) async -> String {
        let sessionName = "openclicky.planning.\(UUID().uuidString.prefix(8))"
        defer { HeyClickyFreePlanningClient.shared.clearSession(name: String(sessionName)) }

        let systemContext = buildSystemContext(context)

        // Round 1 — brainstorm concrete executable steps from intent + context.
        let round1Query = """
        You are helping OpenClicky plan a task the user just requested by voice.

        User's request (verbatim transcript):
        \(context.taskIntent.isEmpty ? "(empty transcript)" : context.taskIntent)

        Break this request into 5-12 concrete, independently-verifiable
        execution steps. Each step must be:
        - Actionable (an agent can do it in one tool call or a small burst)
        - Verifiable (there is an observable end state — a file exists, a
          command exits 0, output matches a pattern)
        - Ordered so dependencies come before dependents

        Do NOT emit markdown yet. Just number the steps 1..N with a single
        sentence each. No preamble, no summary.
        """
        let round1 = await runRound(
            query: round1Query,
            systemContext: systemContext,
            sessionName: String(sessionName)
        )

        // Round 2 — critique + refine.
        let round2Query = """
        Review the checklist you just produced. For each step:
        - Is it truly verifiable? If not, rewrite it so it is.
        - Are dependencies obvious? If step B needs step A's output, note it.
        - Are any steps missing (setup, teardown, validation)?
        - Is any step actually two steps? Split it.

        Emit the revised checklist as the same numbered list, no other prose.
        """
        _ = await runRound(
            query: round2Query,
            systemContext: nil,
            sessionName: String(sessionName)
        )

        // Round 3 — format as final PROGRESS.md.
        let round3Query = """
        Now emit the final PROGRESS.md file content. Rules — follow exactly:

        1. Start with the literal heading `## Checklist` on its own line.
        2. One checkbox per step: `- [ ] <step description>` — plain markdown,
           lowercase `x` is reserved for later completion.
        3. Blank line after the checklist.
        4. End with the literal line `LAST_COMPLETED:` (empty marker, no value).
        5. No preamble, no closing prose, no code fences. Output ONLY the
           PROGRESS.md content — the raw bytes are written to disk verbatim.
        """
        let round3 = await runRound(
            query: round3Query,
            systemContext: nil,
            sessionName: String(sessionName)
        )

        let cleaned = stripCodeFences(round3.trimmingCharacters(in: .whitespacesAndNewlines))
        if isValidProgressMarkdown(cleaned) {
            return ensureTrailingNewline(cleaned)
        }
        // Round-3 output was unusable; fall back to a minimal but valid
        // PROGRESS.md so the codex spawn is not blocked.
        return fallbackProgress(for: context)
    }

    // MARK: - Internals

    /// One planning round. Returns the assistant text; empty string on any
    /// failure so the caller can decide fallback behaviour.
    private static func runRound(
        query: String,
        systemContext: String?,
        sessionName: String
    ) async -> String {
        var request = HeyClickyFreePlanningClient.PlanRequest(
            query: query,
            systemContext: systemContext,
            sessionName: sessionName,
            timeoutSeconds: 60
        )
        request.capabilities = []
        do {
            let result = try await HeyClickyFreePlanningClient.shared.generatePlan(request)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            HeyClickyLog.log(
                "openclicky.planning.round",
                lane: "voice",
                direction: "internal",
                [
                    "session": sessionName,
                    "chars": text.count
                ]
            )
            return text
        } catch {
            HeyClickyLog.log(
                "openclicky.planning.round_failed",
                lane: "voice",
                direction: "error",
                [
                    "session": sessionName,
                    "error": String(describing: error)
                ]
            )
            return ""
        }
    }

    private static func buildSystemContext(_ context: Context) -> String {
        var lines: [String] = []
        lines.append("[openclicky-planning-context]")
        if let workdir = context.workdir, !workdir.isEmpty {
            lines.append("workdir: \(workdir)")
        } else {
            lines.append("workdir: (none — task will run under ~/OpenClicky/<slug>/)")
        }
        if !context.layer0Digest.isEmpty {
            lines.append("layer0:")
            lines.append(context.layer0Digest)
        }
        lines.append("[/openclicky-planning-context]")
        return lines.joined(separator: "\n")
    }

    /// Strip triple-backtick fences if the model wrapped the output despite
    /// being told not to.
    private static func stripCodeFences(_ text: String) -> String {
        var s = text
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanity check the round-3 output before we commit it to disk. Must at
    /// minimum contain one checkbox line and the LAST_COMPLETED: marker.
    private static func isValidProgressMarkdown(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let hasCheckbox = text.contains("- [ ]")
        let hasMarker = text.range(
            of: #"^\s*LAST_COMPLETED:\s*$"#,
            options: [.regularExpression, .anchored]
        ) != nil || text.contains("LAST_COMPLETED:")
        return hasCheckbox && hasMarker
    }

    private static func ensureTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }

    private static func fallbackProgress(for context: Context) -> String {
        let intent = context.taskIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = intent.isEmpty ? "task" : intent
        return "## Checklist\n- [ ] \(line)\n\nLAST_COMPLETED:\n"
    }
}
