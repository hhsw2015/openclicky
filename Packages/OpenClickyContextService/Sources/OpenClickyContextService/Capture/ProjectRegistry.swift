// OpenClicky-unique capability. See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 29.
//
// Fuzzy-match known project names from voice transcripts. Feeds the
// intent classifier's `long_task_existing` branch: when the user says
// "resume clicky mac" or "open klicky", we need to map that utterance
// back to a real on-disk workdir before spawning Codex.
//
// The registry ships with a hardcoded seed list of projects known to
// live on the maintainer's machine. To extend it, add entries to
// `seed` below — see docs/ROADMAP/.impl-notes/ for the accompanying
// notes on how the seed was chosen. A future revision may load
// entries from `~/.openclicky/projects.json`; that is out of scope
// for the phase-1 tracer-bullet.
//
// The matching algorithm is intentionally simple (four strategies,
// unweighted max) so that behaviour is easy to reason about and unit
// test. It is not a search engine; the input space is tens of
// entries, not thousands.

import Foundation

/// Read-only registry of known projects on this machine.
///
/// Use `ProjectRegistry.shared.lookup(_:)` to fuzzy-match a query
/// (typically a fragment of a voice transcript) against the registry.
/// Matches are returned sorted by descending confidence, filtered to
/// `score >= 0.5`, capped at `limit`.
public struct ProjectRegistry {

    // MARK: - Public API

    public static let shared: ProjectRegistry = ProjectRegistry(entries: Self.seed)

    /// The full set of registered project entries, in the order they
    /// were registered. Exposed for callers that need to enumerate
    /// (e.g. a "which project?" prompt UI).
    public func all() -> [ProjectEntry] {
        return entries
    }

    /// Fuzzy-match `query` against every registered project.
    ///
    /// Returns matches with `score >= 0.5`, sorted descending, capped
    /// at `limit`. Empty / whitespace-only queries return `[]`.
    public func lookup(_ query: String, limit: Int = 5) -> [ProjectMatch] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        guard limit > 0 else { return [] }

        var scored: [ProjectMatch] = []
        for entry in entries {
            if let match = Self.bestMatch(for: normalizedQuery, in: entry) {
                scored.append(match)
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Stable secondary key: alphabetical slug, so callers get a
            // predictable order when two entries tie.
            return lhs.entry.slug < rhs.entry.slug
        }

        if scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }

    // MARK: - Internals

    /// Injectable init for testing. Public API always uses `.shared`.
    internal init(entries: [ProjectEntry]) {
        self.entries = entries
    }

    private let entries: [ProjectEntry]

    /// Minimum confidence required to be returned by `lookup`. Values
    /// below this floor are treated as no-match so a mistyped project
    /// name doesn't accidentally route the user to an unrelated
    /// workdir.
    private static let scoreThreshold: Double = 0.5

    /// Normalise a query or candidate term for comparison:
    /// lowercase, strip anything that isn't a letter or digit
    /// (collapsing to a single space), then trim + collapse runs of
    /// whitespace.
    internal static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasSpace = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Break a normalised string into whitespace-separated tokens.
    /// Empty string yields `[]`.
    private static func tokens(_ normalized: String) -> [String] {
        if normalized.isEmpty { return [] }
        return normalized.split(separator: " ").map(String.init)
    }

    /// Best match for `query` against a single entry, comparing
    /// against the entry's slug and each alias. Returns nil when no
    /// candidate term clears `scoreThreshold`.
    private static func bestMatch(
        for query: String,
        in entry: ProjectEntry
    ) -> ProjectMatch? {
        var candidates: [String] = [entry.slug]
        candidates.append(contentsOf: entry.aliases)

        var best: (score: Double, term: String)? = nil
        for candidate in candidates {
            let normalizedCandidate = normalize(candidate)
            guard !normalizedCandidate.isEmpty else { continue }
            let score = similarity(query: query, candidate: normalizedCandidate)
            if score >= scoreThreshold {
                if best == nil || score > best!.score {
                    best = (score, candidate)
                }
            }
        }

        guard let best = best else { return nil }
        return ProjectMatch(entry: entry, score: best.score, matchedTerm: best.term)
    }

    /// Compute a 0.0-1.0 similarity score between a normalised query
    /// and a normalised candidate term using the strategies described
    /// in row 29 of the roadmap:
    ///
    ///   * Exact match       -> 1.0
    ///   * Prefix match      -> 0.9
    ///   * Substring         -> 0.7
    ///   * Word-token overlap-> 0.85 (multi-word query fully contained
    ///                         in candidate as tokens, or vice versa)
    ///   * Levenshtein       -> similarity ratio, kept only when >= 0.7
    ///
    /// The strategies are combined by taking the maximum score. Below
    /// `scoreThreshold` the candidate is treated as no-match.
    private static func similarity(query: String, candidate: String) -> Double {
        if query == candidate { return 1.0 }

        var score = 0.0

        if candidate.hasPrefix(query) || query.hasPrefix(candidate) {
            score = max(score, 0.9)
        }

        // Token overlap: check if query tokens all appear in candidate
        // tokens, or vice versa. Handles "clicky mac" -> "clicky-mac"
        // which after normalisation is "clicky mac" both sides.
        let queryTokens = Set(tokens(query))
        let candidateTokens = Set(tokens(candidate))
        if !queryTokens.isEmpty, !candidateTokens.isEmpty {
            if queryTokens.isSubset(of: candidateTokens)
                || candidateTokens.isSubset(of: queryTokens)
            {
                score = max(score, 0.85)
            }
        }

        if candidate.contains(query) || query.contains(candidate) {
            score = max(score, 0.7)
        }

        let lev = levenshteinSimilarity(query, candidate)
        if lev >= 0.7 {
            score = max(score, lev)
        }

        return score
    }

    /// Levenshtein-based similarity in [0.0, 1.0]:
    ///   1 - distance / max(len(a), len(b))
    /// Returns 1.0 for two empty strings.
    internal static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let lhs = Array(a)
        let rhs = Array(b)
        let n = lhs.count
        let m = rhs.count
        if n == 0 && m == 0 { return 1.0 }
        if n == 0 || m == 0 { return 0.0 }

        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                let deletion = prev[j] + 1
                let insertion = curr[j - 1] + 1
                let substitution = prev[j - 1] + cost
                curr[j] = min(deletion, insertion, substitution)
            }
            swap(&prev, &curr)
        }
        let distance = prev[m]
        let maxLen = max(n, m)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    // MARK: - Seed data
    //
    // Extend this list to teach OpenClicky about additional projects.
    // Keep `slug` lowercase and single-token; put spelled-out or
    // hyphenated variants into `aliases`. `path` should be the
    // canonical absolute POSIX path — no ~/ expansion.

    private static let seed: [ProjectEntry] = [
        ProjectEntry(
            slug: "openclicky",
            path: "/Users/wowdd1/Dev/openclicky",
            aliases: ["open clicky", "clicky"],
            projectType: .swift
        ),
        ProjectEntry(
            slug: "ccline",
            path: "/Users/wowdd1/Dev/ccline",
            aliases: [],
            projectType: .unknown
        ),
        ProjectEntry(
            slug: "clicky-mac",
            path: "/Users/wowdd1/Dev/clicky-mac",
            aliases: ["clicky mac"],
            projectType: .swift
        ),
        ProjectEntry(
            slug: "everywhere",
            path: "/Users/wowdd1/Dev/Everywhere",
            aliases: [],
            projectType: .unknown
        ),
        ProjectEntry(
            slug: "xlinkbook",
            path: "/Users/wowdd1/.xlb-env/xlinkBook",
            aliases: ["xlb"],
            projectType: .python
        ),
    ]
}
