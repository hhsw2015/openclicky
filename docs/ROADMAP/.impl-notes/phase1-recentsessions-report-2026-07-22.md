# Phase 1 - RecentSessionsCapture (row 28) - 2026-07-22

## Files delivered

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/RecentSessionsCapture.swift` (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (appended `AgentSessionRef`; no existing types touched)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/RecentSessionsCaptureTests.swift` (new, 12 tests)

## Discovery: where openclicky stores agent-session state

Found via grep of `cursor-buddy/`. Session persistence is owned by
`ChatWorkspaceArchiveStore` in `cursor-buddy/MiniChatPanelManager.swift`.
Two JSON files under
`~/Library/Application Support/OpenClicky/ChatArchive/`:

- `archived-session-snapshots.json` - user-archived agent chats
- `relaunchable-session-snapshots.json` - sessions to auto-resume after
  the next app launch (`wasRelaunchResumeCandidate == true`)

Both files are `[Snapshot]` arrays encoded with
`OpenClickyJSONFileStore.defaultEncoder` (`.prettyPrinted, .sortedKeys`,
default `Date` policy = double seconds-since-2001).

Note: the roadmap doc references `.openclicky/tasks/<slug>/` per-project
task directories (`docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md` line 88), but
those are the *future* on-disk layout for spawned Codex work. Today's
openclicky app does NOT yet write session metadata under that path -
`.openclicky/tasks/` is only referenced as a target directory template
inside the Codex prompt itself. The only session-index persistence live
in the running app is the ChatArchive layer above.

## File format (Snapshot fields consumed)

```swift
struct Snapshot: Codable {
    let id: UUID
    let title: String
    let accentThemeRawValue: String
    let entries: [CodexTranscriptEntry]  // {id, role, text, createdAt}
    let activeThreadID: String?
    let lastSubmittedPrompt: String?
    let createdAt: Date?
    let latestActivityAt: Date?
    let wasRelaunchResumeCandidate: Bool?
    let activeTurnID: String?
    let activeLeaseID: String?
    let leaseExpiresAt: Date?
}
```

The capture models this with a private `StoredSnapshot` that only
carries the fields it uses, plus optional forward-compat `projectPath`
/ `projectSlug` (nil today; unlocked automatically when the app
starts persisting them).

## Field derivation

- `id` -> `Snapshot.id.uuidString`
- `projectPath` / `projectSlug` -> nil today (not yet on disk)
- `startedAt` -> `createdAt` or first entry's `createdAt`
- `lastUpdatedAt` -> `latestActivityAt` or last entry's `createdAt` or `createdAt`
- `status` derivation (no first-class status on disk):
  - `wasRelaunchResumeCandidate == true` -> `"running"`
  - has assistant reply -> `"completed"`
  - has entries but no assistant reply -> `"errored"`
  - no entries -> `"unknown"`
- `taskSummary` -> `lastSubmittedPrompt` (fallbacks: first `user`
  entry, then first entry). Whitespace collapsed, truncated to 80
  chars.

## Behaviour vs spec

| Requirement | Implementation |
| --- | --- |
| Missing directory -> `[]` | `FileManager.fileExists(_:isDirectory:)` gate at entry |
| Malformed JSON skipped, no crash | Two-tier decode: whole-array, then per-element via `JSONSerialization` |
| >30d stale skipped | `now.timeIntervalSince(lastUpdatedAt) > 30 * 86400` |
| Sort by `lastUpdatedAt` DESC | Explicit sort after dedupe |
| Limit respected | `prefix(limit)`; `limit <= 0` early-returns `[]` |
| Never throws | All I/O wrapped in `try?` / decode failures fold to `[]` |
| Base dir injectable for tests | `internal static func recent(limit:baseDirectory:now:)` overload; `defaultBaseDirectory(fileManager:)` also internal |

Two files can legitimately reference the same session id (relaunchable
becomes archived after the user archives it), so results are deduped
by id preferring the fresher `lastUpdatedAt`.

## Doc 01 row 28 fix / clarification suggested

The doc's API line `func recentAgentSessions(limit: Int) -> [AgentSessionRef]`
matches this capture's shape. `AgentSessionRef` was not yet defined in
the "数据模型" block on line 100-144 - only referenced from
`RouterContext`. Suggest adding a struct definition alongside
`FinderSelectionInfo` / `WorkdirProbe` to keep the doc self-contained.
No blocking issue; the field set here is the roadmap-implied minimum
(id, project ref, timestamps, status, summary).

## Verification

- `swift test` in `Packages/OpenClickyContextService`:
  149 tests, 2 skipped, 0 failures (RecentSessionsCaptureTests
  contributes 12 new tests, all green in 0.013s).
- `bash scripts/sign-and-install.sh` from repo root:
  build + codesign + install to /Applications succeeded; process
  started with `Authority=OpenClicky Dev Sign`.

## Scope discipline

- No files touched outside `Packages/OpenClickyContextService/Sources/`
  and `Tests/`.
- `Types/CaptureTypes.swift`: append-only; existing types untouched.
- No new SPM dependencies.
- Public API surface: exactly `RecentSessionsCapture.recent(limit:)`
  plus the appended `AgentSessionRef` struct.
