// OpenClicky-unique capability. See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 28.
//
// Enumerates recent OpenClicky Codex agent sessions from the on-disk
// state the running app already writes. The dialog / intent-classifier
// layer uses this to disambiguate "继续之前的 …" style voice prompts and
// to fire the `long_task_existing` branch of the task taxonomy
// (docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md row "recent_agent_session").
//
// Storage discovered by grep of the openclicky app:
//   * `ChatWorkspaceArchiveStore` (`cursor-buddy/MiniChatPanelManager.swift`)
//     writes two JSON arrays under
//       ~/Library/Application Support/OpenClicky/ChatArchive/
//         - archived-session-snapshots.json     (user-archived chats)
//         - relaunchable-session-snapshots.json (chats to resume after relaunch)
//   * Each entry is a `Snapshot` record encoded with
//     `OpenClickyJSONFileStore.defaultEncoder` (pretty-printed, sorted keys,
//     default Date encoding = seconds-since-2001 double).
//   * Snapshots today do NOT carry `projectPath` / `projectSlug`. We surface
//     both as nil and stay forward-compatible: if future openclicky versions
//     add those fields to the JSON, decoding still succeeds and the values
//     flow through unchanged.
//
// This capture is read-only. It never writes, never migrates, never touches
// the running app's state.

import Foundation

public enum RecentSessionsCapture {

    // MARK: - Public API

    /// Returns up to `limit` most-recent OpenClicky agent sessions,
    /// sorted by `lastUpdatedAt` descending.
    ///
    /// Contract:
    ///   * Never throws. Any I/O or decode error folds into a shorter
    ///     result (or `[]`) rather than propagating.
    ///   * Returns `[]` when the snapshot directory does not exist
    ///     (fresh install) or when both JSON files are missing / empty.
    ///   * Entries older than 30 days (by `lastUpdatedAt`) are skipped.
    ///   * `limit <= 0` returns `[]`.
    ///
    /// See `AgentSessionRef` in `Types/CaptureTypes.swift` for the
    /// exact fields carried per session.
    public static func recent(limit: Int = 10) -> [AgentSessionRef] {
        recent(limit: limit, baseDirectory: defaultBaseDirectory(), now: Date())
    }

    // MARK: - Test-visible core

    /// Test-visible core: same contract as `recent(limit:)` but takes
    /// an explicit `baseDirectory` (usually a `NSTemporaryDirectory()`
    /// mock) and an injectable `now` so the >30d staleness rule is
    /// deterministic under XCTest.
    internal static func recent(
        limit: Int,
        baseDirectory: URL,
        now: Date
    ) -> [AgentSessionRef] {
        guard limit > 0 else { return [] }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: baseDirectory.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }

        let archivedURL = baseDirectory.appendingPathComponent(
            "archived-session-snapshots.json", isDirectory: false
        )
        let relaunchableURL = baseDirectory.appendingPathComponent(
            "relaunchable-session-snapshots.json", isDirectory: false
        )

        // Dedupe by session id, preferring whichever variant carries the
        // fresher lastUpdatedAt. The two files can legitimately reference
        // the same session (e.g. a relaunchable session the user later
        // archives) so a simple concatenate would double-count.
        var byID: [String: AgentSessionRef] = [:]
        for snapshot in loadSnapshots(from: relaunchableURL) + loadSnapshots(from: archivedURL) {
            guard let ref = agentSessionRef(from: snapshot, now: now) else { continue }
            if let existing = byID[ref.id], existing.lastUpdatedAt >= ref.lastUpdatedAt {
                continue
            }
            byID[ref.id] = ref
        }

        return Array(
            byID.values
                .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
                .prefix(limit)
        )
    }

    // MARK: - Base directory resolution

    /// Test-visible so callers wanting to override just the base dir
    /// (without the `now` override) still get the production layout.
    internal static func defaultBaseDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("ChatArchive", isDirectory: true)
    }

    // MARK: - Decoding

    /// On-disk shape as written by
    /// `ChatWorkspaceArchiveStore.Snapshot` in the openclicky app.
    /// Only the fields RecentSessionsCapture actually consumes are
    /// modeled; all decode paths are lenient — unknown keys are ignored
    /// and missing keys fall back to nil (matches the app's own
    /// `Codable` synthesis for optional fields).
    private struct StoredSnapshot: Decodable {
        let id: String?
        let title: String?
        let entries: [StoredEntry]?
        let lastSubmittedPrompt: String?
        let createdAt: Date?
        let latestActivityAt: Date?
        let wasRelaunchResumeCandidate: Bool?
        // Forward-compat: neither field exists in today's snapshots but
        // decoding will happily pick them up if the app starts writing
        // them. `nil` on both is the current production case.
        let projectPath: String?
        let projectSlug: String?
    }

    private struct StoredEntry: Decodable {
        let role: String?
        let text: String?
        let createdAt: Date?
    }

    /// Reads and decodes one snapshot file. Missing file, empty file,
    /// bad JSON, or wrong shape all fold into `[]` — we never throw.
    private static func loadSnapshots(from url: URL) -> [StoredSnapshot] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        if let all = try? decoder.decode([StoredSnapshot].self, from: data) {
            return all
        }
        // Best-effort per-element decode. If the top-level array parses
        // as raw JSON but some entries are malformed, keep the good ones
        // instead of dropping the whole file.
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [Any] else {
            return []
        }
        return array.compactMap { element -> StoredSnapshot? in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else {
                return nil
            }
            return try? decoder.decode(StoredSnapshot.self, from: elementData)
        }
    }

    // MARK: - Mapping

    /// Maps a decoded snapshot into an `AgentSessionRef`. Returns `nil`
    /// for entries that are malformed (missing id / no timestamp at
    /// all) or stale (`lastUpdatedAt` more than 30 days before `now`).
    private static func agentSessionRef(
        from snapshot: StoredSnapshot,
        now: Date
    ) -> AgentSessionRef? {
        guard let id = snapshot.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }

        let startedAt = snapshot.createdAt
            ?? snapshot.entries?.first?.createdAt
            ?? snapshot.latestActivityAt
        let lastUpdatedAt = snapshot.latestActivityAt
            ?? snapshot.entries?.last?.createdAt
            ?? snapshot.createdAt

        guard let resolvedStartedAt = startedAt,
              let resolvedLastUpdatedAt = lastUpdatedAt else {
            return nil
        }

        // Staleness gate. 30 * 86400 seconds. `now - lastUpdatedAt` is
        // computed as a `TimeInterval` so it handles both past and
        // (unlikely) future timestamps consistently — a future
        // timestamp survives, which matches the "skip old, not
        // sanitize" contract in the doc.
        let ageSeconds = now.timeIntervalSince(resolvedLastUpdatedAt)
        if ageSeconds > 30 * 24 * 60 * 60 {
            return nil
        }

        return AgentSessionRef(
            id: id,
            projectPath: nonEmpty(snapshot.projectPath),
            projectSlug: nonEmpty(snapshot.projectSlug),
            startedAt: resolvedStartedAt,
            lastUpdatedAt: resolvedLastUpdatedAt,
            status: deriveStatus(snapshot),
            taskSummary: deriveTaskSummary(snapshot)
        )
    }

    /// Maps the openclicky app's persisted lifecycle flags to the four
    /// coarse strings documented on `AgentSessionRef.status`.
    ///
    /// Openclicky's on-disk shape doesn't carry a first-class status
    /// field, so we infer:
    ///   * `wasRelaunchResumeCandidate == true`  -> "running"
    ///     (the session was mid-flight when the app last exited)
    ///   * has an assistant reply and no resume flag              -> "completed"
    ///   * has entries but no assistant reply and no resume flag  -> "errored"
    ///   * neither flag / no entries                              -> "unknown"
    private static func deriveStatus(_ snapshot: StoredSnapshot) -> String {
        if snapshot.wasRelaunchResumeCandidate == true {
            return "running"
        }
        let entries = snapshot.entries ?? []
        guard !entries.isEmpty else {
            return "unknown"
        }
        let hasAssistantReply = entries.contains { entry in
            let role = entry.role?.lowercased() ?? ""
            let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return role == "assistant" && !text.isEmpty
        }
        return hasAssistantReply ? "completed" : "errored"
    }

    /// First 80 characters (grapheme-clustered) of the initial task
    /// prompt. Prefers the persisted `lastSubmittedPrompt` (the exact
    /// text the user asked for) and falls back to the first `user`
    /// transcript entry. Whitespace and interior newlines are collapsed
    /// so a multi-line prompt still fits on a single voice-summary
    /// line.
    private static func deriveTaskSummary(_ snapshot: StoredSnapshot) -> String? {
        let candidates: [String?] = [
            snapshot.lastSubmittedPrompt,
            snapshot.entries?.first(where: { ($0.role?.lowercased() ?? "") == "user" })?.text,
            snapshot.entries?.first?.text
        ]
        for candidate in candidates {
            guard let raw = candidate else { continue }
            let normalized = collapseWhitespace(raw)
            guard !normalized.isEmpty else { continue }
            return truncate(normalized, maxCount: 80)
        }
        return nil
    }

    // MARK: - String helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func collapseWhitespace(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Collapse runs of any whitespace (including CR/LF) into single spaces.
        var out = ""
        out.reserveCapacity(trimmed.count)
        var lastWasSpace = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func truncate(_ value: String, maxCount: Int) -> String {
        guard value.count > maxCount else { return value }
        return String(value.prefix(maxCount))
    }
}
