//
//  AssistAgentPlanner.swift
//  cursor-buddy
//
//  OpenSpec bundle fabricator + validator. Port of
//  heyclicky_agent/planner.py.
//
//  Used by the assist agent for structured task decomposition when
//  the model wants to plan multi-step work before executing. Also
//  usable by the app for `/plan`-style slash commands.
//
//  Emits three files (proposal.md / tasks.md / PROGRESS.md) matching
//  the OpenSpec + Codex-self-drive convention.
//

import Foundation

public enum AssistAgentPlanner {

    public static let fileSeparator = "---FILE-SEPARATOR---"

    /// System prompt the model should be given when asked to fabricate
    /// a plan bundle. Mirrors Python `PLAN_SYSTEM` verbatim so the
    /// same schema is enforced both from CLI and from the App.
    public static let planSystemPrompt = """
    You are a planning assistant for a self-driving code agent. The \
    user supplies a goal — which may be a single sentence OR a longer \
    artefact (design doc, PRD, issue writeup, OpenSpec proposal dump).

    Output THREE markdown files in one reply, separated by the exact \
    line `\(fileSeparator)` on its own. Use the OpenSpec change \
    conventions for the first two, and the Codex self-drive convention \
    for the third. All three must be internally consistent:

    === proposal.md ===
    ## Why
    <one paragraph — the motivation, in the user's terms>

    ## What Changes
    <one paragraph — the high-level plan>

    ## Impact
    <one paragraph — capabilities / files this touches>

    \(fileSeparator)

    === tasks.md ===
    ## 1. <group name>
    - [ ] 1.1 <verifiable action>
    - [ ] 1.2 <verifiable action>

    ## 2. <group name>
    - [ ] 2.1 <verifiable action>

    \(fileSeparator)

    === PROGRESS.md ===
    # Task
    <one-paragraph goal summary>

    ## Steps
    - [ ] 1.1 <same wording as in tasks.md, flattened, in order>
    - [ ] 1.2 ...

    LAST_COMPLETED: START

    Rules:
    - 5-15 tasks total, grouped meaningfully in tasks.md.
    - Each task actionable in one small burst with observable end state \
      (file exists / test passes / command exits 0 / output matches).
    - End with a verification group (build / test / lint) in tasks.md.
    - PROGRESS.md Steps are the flattened tasks.md checklist in ORDER, \
      same wording — the two views must never drift.
    - Do NOT wrap in code fences. Do NOT emit any preamble. Emit ONLY \
      the three file bodies + the two separators.
    """

    // MARK: - Task-dir + input classification

    /// `<cwd>/.openclicky/task/`. Created on demand.
    public static func codexTaskDir(cwd: String? = nil) -> URL {
        let base = URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath)
        let dir = base.appendingPathComponent(".openclicky/task", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func looksLikeOpenSpecChange(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        let proposal = url.appendingPathComponent("proposal.md")
        guard FileManager.default.fileExists(atPath: proposal.path) else { return false }
        let tasks = url.appendingPathComponent("tasks.md")
        if FileManager.default.fileExists(atPath: tasks.path) { return true }
        let specs = url.appendingPathComponent("specs")
        var specsIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: specs.path, isDirectory: &specsIsDir),
           specsIsDir.boolValue {
            return true
        }
        return false
    }

    // MARK: - Bundle IO helpers

    public static func stripBundleHeader(body raw: String, filename: String) -> String {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            var lines = body.components(separatedBy: "\n")
            if let first = lines.first, first.hasPrefix("```") {
                lines.removeFirst()
            }
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headerPrefix = "=== \(filename)"
        if body.hasPrefix(headerPrefix), let nl = body.firstIndex(of: "\n") {
            body = String(body[body.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    public struct Bundle: Sendable {
        public let proposal: String
        public let tasks: String
        public let progress: String
    }

    /// Split a bundled reply on the separator line. Returns nil when
    /// the reply doesn't carry the three sections.
    public static func splitBundle(_ raw: String) -> Bundle? {
        let parts = raw.components(separatedBy: fileSeparator)
        guard parts.count >= 3 else { return nil }
        return Bundle(
            proposal: stripBundleHeader(body: parts[0], filename: "proposal.md"),
            tasks: stripBundleHeader(body: parts[1], filename: "tasks.md"),
            progress: stripBundleHeader(body: parts[2], filename: "PROGRESS.md"))
    }

    // MARK: - Validator

    private static let taskNumberRegex: NSRegularExpression =
        try! NSRegularExpression(pattern: "-\\s*\\[\\s\\]\\s*(\\d+(?:\\.\\d+)*)",
                                 options: [])

    private static func matches(_ re: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            out.append(ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    /// Human-readable list of spec violations. Empty list = valid bundle.
    public static func validate(_ bundle: Bundle) -> [String] {
        var errs: [String] = []

        for section in ["## Why", "## What Changes", "## Impact"] {
            if !bundle.proposal.contains(section) {
                errs.append("proposal.md missing '\(section)' section")
            }
        }

        if !("\n" + bundle.tasks).contains("\n## ") {
            errs.append("tasks.md has no `## <group>` heading")
        }
        let tasksNumbers = matches(taskNumberRegex, in: bundle.tasks)
        let tasksBoxes = bundle.tasks.components(separatedBy: "- [ ]").count - 1
        if tasksBoxes < 3 {
            errs.append("tasks.md has only \(tasksBoxes) checkboxes (need ≥3)")
        }
        if tasksNumbers.count != tasksBoxes {
            errs.append("tasks.md has \(tasksBoxes) checkboxes but " +
                        "\(tasksNumbers.count) of them carry a `N.M` prefix — every " +
                        "checkbox must be numbered")
        }

        if !bundle.progress.contains("# Task") { errs.append("PROGRESS.md missing `# Task` heading") }
        if !bundle.progress.contains("## Steps") { errs.append("PROGRESS.md missing `## Steps` heading") }
        if !bundle.progress.contains("LAST_COMPLETED") {
            errs.append("PROGRESS.md missing `LAST_COMPLETED:` line")
        }
        let progressNumbers = matches(taskNumberRegex, in: bundle.progress)
        let progressBoxes = bundle.progress.components(separatedBy: "- [ ]").count - 1
        if progressBoxes < 3 {
            errs.append("PROGRESS.md has only \(progressBoxes) checkboxes (need ≥3)")
        }
        if progressNumbers.count != progressBoxes {
            errs.append("PROGRESS.md has \(progressBoxes) checkboxes but " +
                        "\(progressNumbers.count) carry a `N.M` prefix")
        }
        if !tasksNumbers.isEmpty && !progressNumbers.isEmpty && tasksNumbers != progressNumbers {
            let missing = tasksNumbers.filter { !progressNumbers.contains($0) }
            let extra = progressNumbers.filter { !tasksNumbers.contains($0) }
            errs.append("PROGRESS.md steps do not match tasks.md numbering " +
                        "(missing in progress: \(missing); extra in progress: \(extra))")
        }
        return errs
    }

    /// A "we tried and failed" bundle the loop can drive when the
    /// planner reply is unusable. Mirrors Python `fallback_bundle`.
    public static func fallback(from payload: String) -> Bundle {
        let head = payload
            .prefix(400)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let effectiveHead = head.isEmpty ? "(no goal supplied)" : String(head)
        let proposal = """
        ## Why
        \(effectiveHead)

        ## What Changes
        See tasks.md for the coarse plan; refine as the agent runs.

        ## Impact
        Unknown — assess by reading the workspace.
        """
        let tasks = """
        ## 1. Understand
        - [ ] 1.1 Read proposal.md and the user input in full.
        - [ ] 1.2 Read the workspace to identify affected files.

        ## 2. Execute
        - [ ] 2.1 Break the goal into concrete edits.
        - [ ] 2.2 Apply the edits.

        ## 3. Verify
        - [ ] 3.1 Run tests / build; capture exit codes and outputs.
        """
        let progress = """
        # Task
        \(effectiveHead)

        ## Steps
        - [ ] 1.1 Read proposal.md and the user input in full.
        - [ ] 1.2 Read the workspace to identify affected files.
        - [ ] 2.1 Break the goal into concrete edits.
        - [ ] 2.2 Apply the edits.
        - [ ] 3.1 Run tests / build; capture exit codes and outputs.

        LAST_COMPLETED: START
        """
        return Bundle(proposal: proposal, tasks: tasks, progress: progress)
    }

    // MARK: - Persist

    /// Write the bundle to `taskDir` (creating it if needed).
    @discardableResult
    public static func write(_ bundle: Bundle, to taskDir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("proposal.md", bundle.proposal),
            ("tasks.md",    bundle.tasks),
            ("PROGRESS.md", bundle.progress)
        ]
        var urls: [URL] = []
        for (name, body) in files {
            let url = taskDir.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        return urls
    }
}
