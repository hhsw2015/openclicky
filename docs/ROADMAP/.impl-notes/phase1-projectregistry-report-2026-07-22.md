# Phase 1: ProjectRegistry — Implementation Report

Date: 2026-07-22
Roadmap row: `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 29
Marker: OpenClicky-unique (no Everywhere source).

## Scope

Implemented `ProjectRegistry`: fuzzy-match known project names heard in
voice transcripts against a local registry of on-disk projects. Feeds
the `long_task_existing` branch of the intent classifier.

## Files

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ProjectRegistry.swift` (new)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/ProjectRegistryTests.swift` (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (appended
  `ProjectEntry` + `ProjectMatch` types; no existing types touched)

## API

```swift
public struct ProjectRegistry {
    public static let shared: ProjectRegistry
    public func lookup(_ query: String, limit: Int = 5) -> [ProjectMatch]
    public func all() -> [ProjectEntry]
}

public struct ProjectEntry: Codable, Sendable, Equatable {
    public let slug: String
    public let path: String
    public let aliases: [String]
    public let projectType: ProjectType   // reuses existing enum
}

public struct ProjectMatch: Codable, Sendable, Equatable {
    public let entry: ProjectEntry
    public let score: Double              // 0.0-1.0
    public let matchedTerm: String
}
```

`internal init(entries:)` exists on `ProjectRegistry` to allow test
suites (and future JSON-loader wiring) to construct alternative
registries; the public API only exposes `.shared`.

## Matching algorithm

Query and each candidate term (slug + aliases) are normalised:
lowercase, non-alphanumeric characters collapsed to a single space,
edge whitespace trimmed. Score is `max` over four strategies:

- Exact match -> `1.0`
- Prefix (either direction) -> `0.9`
- Word-token subset (either direction) -> `0.85`
- Substring (either direction) -> `0.7`
- Levenshtein similarity >= `0.7` -> the similarity itself

Only candidates scoring `>= 0.5` are returned. Ties break by
alphabetical slug (stable ordering). `limit <= 0` and empty /
whitespace-only queries short-circuit to `[]`.

## Seed data

Hardcoded list of five projects present on the maintainer's machine
(all verified with `ls -d` before shipping):

| slug         | path                                | aliases            | projectType |
|--------------|-------------------------------------|--------------------|-------------|
| openclicky   | /Users/wowdd1/Dev/openclicky        | open clicky, clicky| swift       |
| ccline       | /Users/wowdd1/Dev/ccline            | -                  | unknown     |
| clicky-mac   | /Users/wowdd1/Dev/clicky-mac        | clicky mac         | swift       |
| everywhere   | /Users/wowdd1/Dev/Everywhere        | -                  | unknown     |
| xlinkbook    | /Users/wowdd1/.xlb-env/xlinkBook    | xlb                | python      |

### How to extend

Add entries to the `private static let seed` array at the bottom of
`Capture/ProjectRegistry.swift`. Keep `slug` lowercase and
single-token; put spelled-out or hyphenated variants into `aliases`.
`path` should be an absolute POSIX path (no `~/` expansion).

A future revision may load the registry from
`~/.openclicky/projects.json` — the internal `init(entries:)` gives
that path an obvious wiring point without changing the public API.

## Testing

15 XCTest cases in `ProjectRegistryTests`, covering:

- Exact slug match -> `score == 1.0`, correct slug + matchedTerm
- Alias exact match (`"clicky"` -> `openclicky`)
- Multi-word alias with punctuation (`"clicky mac"` -> `clicky-mac`)
- Prefix (`"open"` -> `openclicky`, score >= 0.9)
- Substring hits multiple entries (`"click"` -> openclicky + clicky-mac)
- Levenshtein typo tolerance (`"openklicky"` -> `openclicky`)
- Empty / whitespace-only / all-punctuation query -> `[]`
- Unrelated query (`"xyz"`, `"quokka"`) -> `[]`
- `limit` respected; `limit == 0` -> `[]`
- Ordering by descending score
- `all()` includes seed entries
- `normalize` boundary cases
- `levenshteinSimilarity` boundary cases (empty, equal, one substitution)
- Custom registry via internal `init(entries:)`

## Verification

- `cd Packages/OpenClickyContextService && swift test`:
  137 tests, 2 skipped, 0 failures. All 15 ProjectRegistryTests pass.
- `bash scripts/sign-and-install.sh`: exit 0; build + sign succeeded.

## Notes / follow-ups

- Levenshtein path is O(n*m); at seed sizes (~5 entries, single-token
  strings) this is trivial. If the registry grows past a few hundred
  entries, add an early-exit length filter before running Levenshtein.
- No file-system watching or automatic discovery of new projects — the
  seed is static. Discovery is intentionally deferred to a later phase
  (see roadmap row 29's follow-up notes).
- `ProjectRegistry.shared` is safe from any actor context because
  `ProjectEntry` and `ProjectMatch` are `Sendable` and the struct holds
  only immutable data.
