// OpenClicky-unique capability. See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 29.
//
// XCTest coverage for ProjectRegistry. The seed list ships with the
// package so we exercise `.shared` directly rather than injecting
// fixtures; all assertions are pinned to entries that are part of the
// permanent seed so the suite stays stable as the maintainer adds new
// projects.

import XCTest
@testable import OpenClickyContextService

final class ProjectRegistryTests: XCTestCase {

    // MARK: - Exact and alias matches

    func testExactSlugMatchScoresOne() {
        let matches = ProjectRegistry.shared.lookup("openclicky")
        XCTAssertFalse(matches.isEmpty, "expected at least one match for 'openclicky'")
        let top = matches[0]
        XCTAssertEqual(top.entry.slug, "openclicky")
        XCTAssertEqual(top.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(top.matchedTerm, "openclicky")
    }

    func testAliasExactMatchRoutesToOwningEntry() {
        // "clicky" is an alias of "openclicky". It should surface
        // openclicky as the top hit even though "clicky-mac" also
        // contains the substring.
        let matches = ProjectRegistry.shared.lookup("clicky")
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches[0].entry.slug, "openclicky")
        XCTAssertEqual(matches[0].score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(matches[0].matchedTerm, "clicky")
    }

    func testMultiWordAliasNormalisesAcrossPunctuation() {
        // Registry stores "clicky mac" as an alias of clicky-mac and
        // the slug itself normalises to "clicky mac". Either exact
        // hit is acceptable — but we should get a very high score.
        let matches = ProjectRegistry.shared.lookup("clicky mac")
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches[0].entry.slug, "clicky-mac")
        XCTAssertGreaterThanOrEqual(matches[0].score, 0.85)
    }

    // MARK: - Prefix / substring / typo strategies

    func testPrefixMatchScoresHigh() {
        // "open" is a prefix of "openclicky".
        let matches = ProjectRegistry.shared.lookup("open")
        XCTAssertFalse(matches.isEmpty)
        let openclicky = matches.first(where: { $0.entry.slug == "openclicky" })
        XCTAssertNotNil(openclicky, "expected openclicky in matches for 'open'")
        XCTAssertGreaterThanOrEqual(openclicky!.score, 0.9)
    }

    func testSubstringMatchesMultipleEntries() {
        // "click" is a substring of both openclicky (via slug + alias)
        // and clicky-mac.
        let matches = ProjectRegistry.shared.lookup("click", limit: 10)
        let slugs = Set(matches.map { $0.entry.slug })
        XCTAssertTrue(slugs.contains("openclicky"))
        XCTAssertTrue(slugs.contains("clicky-mac"))
        for m in matches {
            XCTAssertGreaterThanOrEqual(m.score, 0.5)
        }
    }

    func testLevenshteinTolerantOfSingleCharTypo() {
        // "openklicky" -> "openclicky" is one substitution; on len 10
        // that yields similarity 0.9, well above the 0.7 Levenshtein
        // floor.
        let matches = ProjectRegistry.shared.lookup("openklicky")
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches[0].entry.slug, "openclicky")
        XCTAssertGreaterThanOrEqual(matches[0].score, 0.7)
    }

    // MARK: - Negative cases

    func testEmptyQueryReturnsEmpty() {
        XCTAssertTrue(ProjectRegistry.shared.lookup("").isEmpty)
        XCTAssertTrue(ProjectRegistry.shared.lookup("   ").isEmpty)
        XCTAssertTrue(ProjectRegistry.shared.lookup("!!!").isEmpty)
    }

    func testUnrelatedQueryReturnsEmpty() {
        // No seed entry is anywhere near "xyz" / "quokka" — all
        // strategies must drop below the 0.5 threshold.
        XCTAssertTrue(ProjectRegistry.shared.lookup("xyz").isEmpty)
        XCTAssertTrue(ProjectRegistry.shared.lookup("quokka").isEmpty)
    }

    // MARK: - Limit + ordering

    func testLimitIsRespected() {
        let one = ProjectRegistry.shared.lookup("click", limit: 1)
        XCTAssertEqual(one.count, 1)
        let two = ProjectRegistry.shared.lookup("click", limit: 2)
        XCTAssertLessThanOrEqual(two.count, 2)
    }

    func testLimitZeroReturnsEmpty() {
        XCTAssertTrue(ProjectRegistry.shared.lookup("openclicky", limit: 0).isEmpty)
    }

    func testMatchesAreSortedByDescendingScore() {
        let matches = ProjectRegistry.shared.lookup("click", limit: 10)
        guard matches.count >= 2 else {
            XCTFail("expected multiple matches for 'click'")
            return
        }
        for i in 0..<(matches.count - 1) {
            XCTAssertGreaterThanOrEqual(
                matches[i].score,
                matches[i + 1].score,
                "matches must be sorted by descending score"
            )
        }
    }

    // MARK: - all()

    func testAllReturnsSeedEntries() {
        let all = ProjectRegistry.shared.all()
        let slugs = Set(all.map { $0.slug })
        XCTAssertTrue(slugs.contains("openclicky"))
        XCTAssertTrue(slugs.contains("clicky-mac"))
    }

    // MARK: - Internal helpers

    func testNormalizeLowercasesAndStripsPunctuation() {
        XCTAssertEqual(ProjectRegistry.normalize("Open-Clicky!"), "open clicky")
        XCTAssertEqual(ProjectRegistry.normalize("  Clicky   MAC  "), "clicky mac")
        XCTAssertEqual(ProjectRegistry.normalize(""), "")
        XCTAssertEqual(ProjectRegistry.normalize("!!!"), "")
    }

    func testLevenshteinSimilarityBoundaries() {
        XCTAssertEqual(ProjectRegistry.levenshteinSimilarity("", ""), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ProjectRegistry.levenshteinSimilarity("abc", ""), 0.0, accuracy: 0.0001)
        XCTAssertEqual(ProjectRegistry.levenshteinSimilarity("abc", "abc"), 1.0, accuracy: 0.0001)
        // One substitution on length 3 -> 1 - 1/3 = 0.666...
        XCTAssertEqual(
            ProjectRegistry.levenshteinSimilarity("abc", "abd"),
            2.0 / 3.0,
            accuracy: 0.0001
        )
    }

    // MARK: - Custom registry via internal init

    func testCustomRegistryScoresAndFilters() {
        let entries: [ProjectEntry] = [
            ProjectEntry(slug: "alpha", path: "/tmp/alpha", aliases: ["ay"], projectType: .rust),
            ProjectEntry(slug: "beta",  path: "/tmp/beta",  aliases: [],     projectType: .go),
        ]
        let registry = ProjectRegistry(entries: entries)
        let hits = registry.lookup("alpha")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].entry.slug, "alpha")
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 0.0001)

        XCTAssertTrue(registry.lookup("zzz").isEmpty)
    }
}
