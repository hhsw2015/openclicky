# WorkdirProbe implementation report

Date: 2026-07-22
Doc references:
- `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 27 (WorkdirProbe struct + probe function signature)
- `docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md` (consumer of workdir signals for intent classification)

## Summary

OpenClicky-unique capability. No Everywhere source to port. Adds a total,
never-throwing filesystem probe used before Codex / agent runs to decide
whether a folder is worth entering and how to bias the task-type router.

## Files touched

- Added: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/WorkdirProbe.swift`
  - Public API: `enum WorkdirProbe { static func probe(_ url: URL) -> WorkdirProbeResult }`
  - Header carries the required OpenClicky-unique banner pointing at doc 01 row 27.
- Appended (no deletions / renames) in
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`:
  - `enum ProjectType: String, Codable, Sendable` — `rust | nodejs | python | go | swift | xcode | unknown`
  - `struct WorkdirProbeResult: Codable, Sendable, Equatable` matching the doc row 27 shape.
- Added: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/WorkdirProbeTests.swift`
  - 20 XCTest cases, all fs fixtures under `NSTemporaryDirectory()` with `tearDown` cleanup.

## Detection precedence (implemented)

Row 27 spec normalised into a single top-level pass, no recursion:
1. `*.xcodeproj` or `*.xcworkspace` at top level → `.xcode` (wins even when
   `Package.swift` is also present).
2. `Package.swift` → `.swift`.
3. `Cargo.toml` → `.rust`.
4. `go.mod` → `.go`.
5. `package.json` → `.nodejs`.
6. `pyproject.toml` OR `requirements.txt` OR `setup.py` → `.python`.
7. Otherwise → `.unknown`.

## Edge-case handling (implemented)

- Non-existent path: `exists = false`, everything else false / zero /
  `.unknown`.
- Existing regular file: `exists = true`, `isDirectory = false`,
  `isEmpty = false`, `fileCount = 0`, no project-type detection attempted.
- Symlinks: followed via `FileManager.fileExists` (Foundation resolves the
  target); broken symlinks surface as `exists = false`.
- Permission-denied listing a directory: `exists = true`,
  `isDirectory = true`, `isEmpty = true`, `fileCount = 0`. Foundation still
  reports the directory as existing, so we do not lie about that.
- `.DS_Store` is excluded from both `fileCount` and the `isEmpty` check.
- Dot-files (`.env`, `.git`, `.openclicky`, ...) count towards `fileCount`.
- `hasGit` / `hasOpenClickyState` additionally require the entry to be a
  directory; `hasAgentsMd` additionally requires it to be a regular file.

## Verification

- `cd Packages/OpenClickyContextService && swift test` — 87 tests total,
  0 failures, 1 skipped (unrelated pre-existing skip). The 20 new
  `WorkdirProbeTests` all pass.
- `cd /Users/wowdd1/Dev/openclicky && bash scripts/sign-and-install.sh` —
  builds, signs (`OpenClicky Dev Sign`), installs to
  `/Applications/OpenClicky.app`, and launches (pid captured). No errors.

## Notes for downstream

- `WorkdirProbeResult.detectedProjectType` is non-optional (`.unknown` is a
  first-class value). The doc row 27 sketch shows `ProjectType?`, but the
  intent-classifier at doc 07 always needs a concrete value; encoding
  "no marker" as `.unknown` keeps the JSON envelope compact and removes a
  `nil` branch from consumers.
- `path` is `URL.path` (absolute POSIX). Callers should not construct
  `WorkdirProbeResult` from a relative URL and expect a portable path
  string.
- Probe is O(entries) with one `contentsOfDirectory` call plus at most
  three follow-up `fileExists` calls (for `.git`, `.openclicky`,
  `AGENTS.md`). Safe on the classifier hot path.
