// OpenClicky-unique capability. See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 30.
//
// Runs a small handful of read-only `git` subprocesses to snapshot the state
// of a working tree: current branch, dirty flag, stash presence, upstream
// divergence, and last-commit metadata. Feeds the intent classifier so a
// "long_task_existing on a dirty branch" can prompt the user to commit
// before Codex is turned loose.
//
// Everything is best-effort and total: any spawn failure, non-zero exit,
// timeout, missing binary, or non-repo input folds into `nil`. Individual
// git calls that fail (e.g. `git rev-list --count` when no upstream is
// configured) do NOT poison the surrounding capture — only the field they
// feed becomes `nil`.
//
// A single capture invokes up to six subprocesses. Each is bounded by a
// 3-second wall-clock timeout enforced via a background monitor that
// escalates `terminate()` (SIGTERM) followed by hard drain. Total worst
// case is therefore ~18s if every call hangs, but on any repo of realistic
// size the calls return in single-digit ms.

import Foundation

/// Read-only git state probe.
///
/// Public entry point is `probe(_:)`. Never throws — see file-header note.
public enum GitAwarenessCapture {

    /// Per-subprocess wall-clock timeout.
    private static let timeoutSeconds: TimeInterval = 3.0

    /// Probes the git repo enclosing `url`.
    ///
    /// `url` may be either the repo root itself or any nested subdirectory.
    /// Returns `nil` when:
    ///   * `url` does not exist or is not inside a git working tree,
    ///   * `git` is not on `PATH`,
    ///   * the initial `rev-parse --show-toplevel` call fails or times
    ///     out.
    ///
    /// Individual downstream fields may be `nil` on partial failures
    /// (e.g. no upstream configured, empty repo) — see `GitAwarenessInfo`.
    public static func probe(_ url: URL) -> GitAwarenessInfo? {
        // Cheap pre-check: walk up looking for a `.git` sibling before
        // paying for a subprocess. Also lets us bail early on paths that
        // don't exist.
        guard let enclosingRoot = findEnclosingGitDir(startingAt: url) else {
            return nil
        }

        // Ask git to canonicalise the root — handles worktrees, symlinks,
        // and case-sensitivity questions we don't want to solve by hand.
        guard let toplevel = runGit(
            args: ["rev-parse", "--show-toplevel"],
            cwd: enclosingRoot
        )?.trimmedNonEmpty else {
            return nil
        }

        let cwd = URL(fileURLWithPath: toplevel, isDirectory: true)

        // Branch / detached HEAD.
        let symbolicRef = runGit(
            args: ["symbolic-ref", "-q", "HEAD"],
            cwd: cwd
        )?.trimmedNonEmpty
        let currentBranch = symbolicRef.flatMap { ref -> String? in
            // symbolic-ref returns e.g. "refs/heads/main". Strip the
            // prefix; if it's not a heads ref, keep the raw value.
            let prefix = "refs/heads/"
            if ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
            return ref
        }
        let detachedHead = (currentBranch == nil)

        // Working tree status.
        let statusRaw = runGit(
            args: ["status", "--porcelain=v1", "-uall"],
            cwd: cwd
        ) ?? ""
        let counts = parseStatusCounts(statusRaw)

        // Stash list — count lines. Empty output means no stashes.
        let stashRaw = runGit(args: ["stash", "list"], cwd: cwd) ?? ""
        let stashCount = stashRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count

        // Upstream divergence: `--left-right` returns "behind\tahead"
        // (from the perspective of `@{u}...HEAD`). Missing upstream
        // causes git to exit non-zero; runGit surfaces that as nil.
        var aheadOfUpstream: Int?
        var behindUpstream: Int?
        if !detachedHead {
            if let raw = runGit(
                args: ["rev-list", "--count", "--left-right", "@{u}...HEAD"],
                cwd: cwd
            )?.trimmedNonEmpty {
                let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
                if parts.count == 2,
                   let behind = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let ahead = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    behindUpstream = behind
                    aheadOfUpstream = ahead
                }
            }
        }

        // Last commit: short-sha \0 subject \0 committer-unix-timestamp.
        var lastSha: String?
        var lastSubject: String?
        var lastTimestamp: Date?
        if let raw = runGit(
            args: ["log", "-1", "--format=%h%x00%s%x00%ct"],
            cwd: cwd
        )?.trimmingCharacters(in: .newlines),
           !raw.isEmpty {
            let parts = raw.split(separator: "\0", omittingEmptySubsequences: false)
            if parts.count == 3 {
                let sha = String(parts[0])
                let subject = String(parts[1])
                let ts = String(parts[2]).trimmingCharacters(in: .whitespaces)
                if !sha.isEmpty { lastSha = sha }
                if !subject.isEmpty { lastSubject = subject }
                if let seconds = TimeInterval(ts) {
                    lastTimestamp = Date(timeIntervalSince1970: seconds)
                }
            }
        }

        let isDirty = counts.untracked + counts.modified + counts.staged > 0

        return GitAwarenessInfo(
            repoRoot: toplevel,
            currentBranch: currentBranch,
            detachedHead: detachedHead,
            isDirty: isDirty,
            untrackedCount: counts.untracked,
            modifiedCount: counts.modified,
            stagedCount: counts.staged,
            stashCount: stashCount,
            aheadOfUpstream: aheadOfUpstream,
            behindUpstream: behindUpstream,
            lastCommitSha: lastSha,
            lastCommitSubject: lastSubject,
            lastCommitTimestamp: lastTimestamp
        )
    }

    // MARK: - Repo detection

    /// Walks up from `url` looking for a `.git` entry (either a directory
    /// for a normal repo or a file for a linked worktree / submodule).
    /// Returns the first parent directory that contains one, or `nil`.
    private static func findEnclosingGitDir(startingAt url: URL) -> URL? {
        let fm = FileManager.default
        var current = url.standardizedFileURL

        // If the caller passed a file, start from its parent.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current.deleteLastPathComponent()
        } else if !fm.fileExists(atPath: current.path) {
            return nil
        }

        while true {
            let gitEntry = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitEntry.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    // MARK: - Porcelain parsing

    private struct StatusCounts {
        var untracked: Int = 0
        var modified: Int = 0
        var staged: Int = 0
    }

    /// Parses `git status --porcelain=v1 -uall` output. Each line is:
    /// `XY <path>` where X is index status, Y is worktree status.
    ///
    /// Rules per row 30 spec:
    ///   * `??`      -> untracked
    ///   * X in `[MADRC]` (and X != '?') -> staged
    ///   * Y == 'M' -> modified  (worktree change relative to index)
    ///   * Y == 'D' -> modified  (worktree deletion)
    private static func parseStatusCounts(_ raw: String) -> StatusCounts {
        var counts = StatusCounts()
        for lineSub in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(lineSub)
            guard line.count >= 2 else { continue }
            let idx = line.index(line.startIndex, offsetBy: 1)
            let x = line[line.startIndex]
            let y = line[idx]

            if x == "?" && y == "?" {
                counts.untracked += 1
                continue
            }
            if "MADRC".contains(x) {
                counts.staged += 1
            }
            if y == "M" || y == "D" {
                counts.modified += 1
            }
        }
        return counts
    }

    // MARK: - Subprocess plumbing

    /// Runs `git <args>` in `cwd`, captures stdout, and returns it on
    /// success. Returns `nil` on non-zero exit, timeout, or spawn error.
    /// stderr is discarded; we only care about textual signal.
    private static func runGit(args: [String], cwd: URL) -> String? {
        let process = Process()
        process.currentDirectoryURL = cwd
        // Rely on PATH lookup so the user's installed git wins over any
        // odd system binary. `/usr/bin/env` provides the resolution.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args

        // Strip config that would poison output (paging, colour codes,
        // localised messages, external editors triggered on error).
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Timeout monitor. Schedules a terminate() on a global queue; we
        // race it against `waitUntilExit` on the caller thread. Once we
        // know the process is done, we cancel the monitor with a flag.
        let didTimeoutLock = NSLock()
        var didTimeout = false
        let workItem = DispatchWorkItem {
            didTimeoutLock.lock()
            didTimeout = true
            didTimeoutLock.unlock()
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)

        process.waitUntilExit()
        workItem.cancel()

        didTimeoutLock.lock()
        let timedOut = didTimeout
        didTimeoutLock.unlock()

        if timedOut { return nil }
        guard process.terminationStatus == 0 else { return nil }

        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        // Drain stderr to avoid holding a pipe reference.
        _ = try? stderr.fileHandleForReading.readToEnd()

        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Local helpers

private extension String {
    /// Trims whitespace + newlines and returns `nil` if the result is
    /// empty.
    var trimmedNonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
