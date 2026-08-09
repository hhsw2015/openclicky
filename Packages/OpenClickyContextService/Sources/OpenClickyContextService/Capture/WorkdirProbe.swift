// OpenClicky-unique capability (no Everywhere source). See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 27.
//
// Probes a candidate workdir before OpenClicky spawns a Codex / agent run on
// it. Returns a `WorkdirProbeResult` describing existence, emptiness, and a
// coarse project-type classification driven by top-level marker files.
//
// The classifier is deliberately simple: one pass over the directory's top
// level, no descent, no globbing beyond exact filename / suffix matches. It
// is called from the intent-classifier hot path (see
// docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md) and must stay cheap and total.

import Foundation

/// Read-only probe of a workdir on disk.
///
/// See `WorkdirProbeResult` for the returned shape. Never throws: any I/O
/// error is folded into an all-false / `unknown` result so callers can
/// branch on shape alone.
public enum WorkdirProbe {

    /// Filenames that must be ignored when computing `fileCount` /
    /// `isEmpty`. macOS Finder scatters `.DS_Store` into every directory
    /// the user ever opens; treating it as a real entry would mean "empty
    /// project" folders never look empty.
    private static let ignoredEntries: Set<String> = [".DS_Store"]

    /// Probes the given `url`.
    ///
    /// Behaviour summary (see `WorkdirProbeResult` doc-comments for the
    /// per-field contract):
    ///   * Non-existent path -> `exists = false`, everything else false /
    ///     zero / `.unknown`.
    ///   * Existing file (not dir) -> `exists = true`, `isDirectory = false`,
    ///     `isEmpty = false`, `fileCount = 0`. No project-type detection
    ///     is attempted.
    ///   * Symlinks are followed via `FileManager.attributesOfItem`.
    ///   * Permission-denied listing a real directory folds into
    ///     `isEmpty = true`, `fileCount = 0` — Foundation still reports the
    ///     directory as existing, so we don't lie about that.
    public static func probe(_ url: URL) -> WorkdirProbeResult {
        let fm = FileManager.default
        let path = url.path

        var isDirObjC: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirObjC)

        guard exists else {
            return WorkdirProbeResult(
                path: path,
                exists: false,
                isDirectory: false,
                isEmpty: false,
                fileCount: 0,
                detectedProjectType: .unknown,
                hasGit: false,
                hasOpenClickyState: false,
                hasAgentsMd: false
            )
        }

        let isDirectory = isDirObjC.boolValue
        guard isDirectory else {
            // Regular file (or symlink to one). Nothing to classify.
            return WorkdirProbeResult(
                path: path,
                exists: true,
                isDirectory: false,
                isEmpty: false,
                fileCount: 0,
                detectedProjectType: .unknown,
                hasGit: false,
                hasOpenClickyState: false,
                hasAgentsMd: false
            )
        }

        // List top-level entries. On permission-denied we intentionally
        // treat the directory as empty rather than throwing: callers only
        // need a shape-based branch.
        let rawEntries: [String]
        do {
            rawEntries = try fm.contentsOfDirectory(atPath: path)
        } catch {
            return WorkdirProbeResult(
                path: path,
                exists: true,
                isDirectory: true,
                isEmpty: true,
                fileCount: 0,
                detectedProjectType: .unknown,
                hasGit: false,
                hasOpenClickyState: false,
                hasAgentsMd: false
            )
        }

        let entries = rawEntries.filter { !ignoredEntries.contains($0) }
        let entrySet = Set(entries)
        let fileCount = entries.count
        let isEmpty = entries.isEmpty

        let hasGit = isTopLevelDirectory(named: ".git", in: url, when: entrySet.contains(".git"))
        let hasOpenClickyState = isTopLevelDirectory(named: ".openclicky", in: url, when: entrySet.contains(".openclicky"))
        let hasAgentsMd = isTopLevelFile(named: "AGENTS.md", in: url, when: entrySet.contains("AGENTS.md"))

        let detectedProjectType = detectProjectType(entries: entrySet, in: url)

        return WorkdirProbeResult(
            path: path,
            exists: true,
            isDirectory: true,
            isEmpty: isEmpty,
            fileCount: fileCount,
            detectedProjectType: detectedProjectType,
            hasGit: hasGit,
            hasOpenClickyState: hasOpenClickyState,
            hasAgentsMd: hasAgentsMd
        )
    }

    // MARK: - Project type detection

    /// Applies the precedence documented in row 27:
    ///   xcode (`*.xcodeproj` / `*.xcworkspace`) > swift (`Package.swift`)
    ///   > rust (`Cargo.toml`) > go (`go.mod`) > nodejs (`package.json`)
    ///   > python (`pyproject.toml` / `requirements.txt` / `setup.py`) > unknown.
    ///
    /// Only the top level is inspected — no recursion.
    private static func detectProjectType(entries: Set<String>, in url: URL) -> ProjectType {
        // xcode: any `*.xcodeproj` or `*.xcworkspace` bundle at top level
        // wins over swift, even if `Package.swift` is also present.
        for entry in entries {
            if entry.hasSuffix(".xcodeproj") || entry.hasSuffix(".xcworkspace") {
                return .xcode
            }
        }

        if entries.contains("Package.swift") {
            return .swift
        }
        if entries.contains("Cargo.toml") {
            return .rust
        }
        if entries.contains("go.mod") {
            return .go
        }
        if entries.contains("package.json") {
            return .nodejs
        }
        if entries.contains("pyproject.toml") ||
            entries.contains("requirements.txt") ||
            entries.contains("setup.py") {
            return .python
        }
        return .unknown
    }

    // MARK: - Kind helpers

    /// Confirms that the entry named `name` inside `parent` is a directory.
    /// The `when` gate avoids a stat call when the entry is not listed at
    /// all.
    private static func isTopLevelDirectory(named name: String, in parent: URL, when present: Bool) -> Bool {
        guard present else { return false }
        var isDir: ObjCBool = false
        let path = parent.appendingPathComponent(name).path
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Confirms that the entry named `name` inside `parent` is a regular
    /// file (or a symlink to one).
    private static func isTopLevelFile(named name: String, in parent: URL, when present: Bool) -> Bool {
        guard present else { return false }
        var isDir: ObjCBool = false
        let path = parent.appendingPathComponent(name).path
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }
}
