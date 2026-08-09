# Phase 1: GitAwarenessCapture — Implementation Report

Date: 2026-07-22
Roadmap row: `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 30
Status: OpenClicky-unique. No Everywhere source.

## Files

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/GitAwarenessCapture.swift` (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (appended `GitAwarenessInfo`)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/GitAwarenessCaptureTests.swift` (new)

## Public API

```swift
public enum GitAwarenessCapture {
    public static func probe(_ url: URL) -> GitAwarenessInfo?
}
```

`GitAwarenessInfo` fields mirror the spec exactly: `repoRoot`,
`currentBranch`, `detachedHead`, `isDirty`, `untrackedCount`,
`modifiedCount`, `stagedCount`, `stashCount`, `aheadOfUpstream`,
`behindUpstream`, `lastCommitSha` (7 char), `lastCommitSubject`,
`lastCommitTimestamp`. Codable / Sendable / Equatable.

## Git commands issued

Executed via `Process` with `/usr/bin/env git ...`, `cwd = repoRoot`,
`LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`,
`GIT_PAGER=cat`, stdin nulled, stderr drained but discarded:

1. `git rev-parse --show-toplevel` — canonicalise repo root.
2. `git symbolic-ref -q HEAD` — current branch (fails on detached HEAD; we use exit=nonzero → nil to detect detached).
3. `git status --porcelain=v1 -uall` — untracked / modified / staged counts.
4. `git stash list` — count lines to get `stashCount`.
5. `git rev-list --count --left-right @{u}...HEAD` — ahead / behind vs upstream. Skipped when detached; nonzero exit (no upstream) folds to `nil` fields.
6. `git log -1 --format=%h%x00%s%x00%ct` — short sha, subject, committer timestamp separated by NUL for safe subject parsing.

Repo detection is a pre-flight walk-up looking for a `.git` entry (dir or file, so linked worktrees / submodules match).

## Timeout

Each subprocess is bounded by a 3s wall-clock timeout enforced by a
`DispatchWorkItem` scheduled on a background queue; on fire it calls
`Process.terminate()`. `waitUntilExit` returns; a lock-guarded flag
distinguishes "we killed it" from "it exited normally". A timeout
surfaces as `nil` for the specific call; downstream fields collapse to
`nil`, they do not corrupt the whole probe. Total worst case is ~18s
across six calls; realistic p50 on any dev machine is <200ms end to end.

## Porcelain parsing rules

Per row 30 spec:

- `??` → `untracked`
- `X` in `[MADRC]` (first column) → `staged`
- `Y` == `M` or `D` (second column) → `modified`

A staged+modified file (e.g. `MM`) increments both `staged` and
`modified`. `isDirty` is the sum being non-zero.

## Test results

`swift test --filter GitAwarenessCaptureTests`:

```
Executed 11 tests, with 0 failures (0 unexpected) in 6.075 seconds
```

Full suite (`swift test`): 137 tests, 0 failures.

`bash scripts/sign-and-install.sh`: BUILD SUCCEEDED, signed, installed,
launched (pid confirmed).

Test coverage:

- non-repo path → nil
- missing path → nil
- fresh repo (init + one commit) → clean, branch=main, sha len=7
- probe from nested subdirectory → resolves to correct root
- untracked / modified / staged flavours each increment their bucket
- stash push → stashCount=1, tree returns to clean
- detached HEAD → `currentBranch==nil`, `detachedHead==true`
- Codable JSON round-trip
- 500-file repo returns within 5s budget (smoke test for the timeout path — the happy budget covers a large repo, so we know overhead is not accidentally scaling with tree size)

All tests skip themselves with `XCTSkip` when `git` is not on `PATH`.

## Known limitations

1. Linked worktrees (`git worktree add`): the `.git` entry is a file, not a directory. We detect it via `fileExists` (does not distinguish), and `git rev-parse --show-toplevel` returns the linked worktree path correctly. Untested here; the primary worktree case is exercised.
2. Submodules: same as worktrees — `.git` is a file pointing at the parent. `rev-parse` handles it. No explicit test.
3. Massive stash lists: `git stash list` output is read whole into memory. Practical stashes are <100 entries, so we did not add a `-z` + streaming parse.
4. Empty repos (initialised, no commit yet): `git log -1` exits non-zero, and `lastCommit*` fields become `nil` — matches the type contract.
5. Concurrent mutations: a rebase / another `git commit` racing with the probe can produce briefly inconsistent snapshots. The intent classifier only needs a coarse signal, so we accept this.
6. `git` older than 1.8: no. `symbolic-ref -q` and `--porcelain=v1` are both very old, but any pre-1.8 install would fail silently and the probe would return `nil` for those fields.
7. Non-UTF-8 branch names / commit subjects: decoded with `.utf8`; invalid bytes cause the specific field to become `nil`. Not exercised in tests.
8. No caching. Each call spawns six subprocesses. Callers upstream (context service router) should coalesce probes on the same repoRoot within a short window.
