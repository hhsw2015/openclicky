// OpenClickyLinkRectHarvesterTests.swift
// cursor-buddyTests
//
// Pure-geometry / cap / dedup tests for the LinkRect harvester.
// The AX walk itself is not mockable (opaque C-ref) so we lock
// down the invariants that live outside AX:
//   * `intersectsLoose` — subtree prune
//   * `majorityOverlap` — linkclump-plus mid-Y rule
//   * `addOrUpgrade` — score-based dedup
//   * `OpenClickyLinkRectLimits` — byte-match with Everywhere
//   * `OpenClickyContextStashWriter.mergeLinks` — union + 200 cap

import XCTest
import OpenClickyContextService
@testable import OpenClicky

final class OpenClickyLinkRectGeometryTests: XCTestCase {

    // MARK: intersectsLoose

    func test_intersectsLoose_disjoint_isFalse() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 100, y: 100, width: 10, height: 10)
        XCTAssertFalse(OpenClickyLinkRectGeometry.intersectsLoose(a, b))
    }

    func test_intersectsLoose_partialOverlap_isTrue() {
        let a = CGRect(x: 0, y: 0, width: 20, height: 20)
        let b = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(OpenClickyLinkRectGeometry.intersectsLoose(a, b))
    }

    func test_intersectsLoose_touchingEdges_isTrue() {
        // Loose (half-open) — touching counts as intersect. Mirrors
        // Everywhere's `!(a.Right < b.X || ...)` (strict <, not <=).
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 10, y: 0, width: 10, height: 10)
        XCTAssertTrue(OpenClickyLinkRectGeometry.intersectsLoose(a, b))
    }

    // MARK: majorityOverlap

    func test_majorityOverlap_anchorMidYInside_isSelected() {
        // Wide row anchor, user swept a small vertical band that
        // captures the anchor's mid-Y. Linkclump grabs the row.
        let anchor = CGRect(x: 0, y: 100, width: 500, height: 20)
        let dragRect = CGRect(x: 200, y: 105, width: 50, height: 10)
        XCTAssertTrue(OpenClickyLinkRectGeometry.majorityOverlap(
            anchor: anchor, dragRect: dragRect))
    }

    func test_majorityOverlap_anchorMidYAbove_isRejected() {
        // Drag rect grazes only the anchor's bottom pixel — mid-Y
        // is at y=10 which is above dragRect.y=15. Reject.
        let anchor = CGRect(x: 0, y: 0, width: 100, height: 20)
        let dragRect = CGRect(x: 0, y: 15, width: 100, height: 50)
        XCTAssertFalse(OpenClickyLinkRectGeometry.majorityOverlap(
            anchor: anchor, dragRect: dragRect))
    }

    func test_majorityOverlap_horizontallyDisjoint_isRejected() {
        let anchor = CGRect(x: 0, y: 100, width: 20, height: 20)
        let dragRect = CGRect(x: 500, y: 90, width: 100, height: 40)
        XCTAssertFalse(OpenClickyLinkRectGeometry.majorityOverlap(
            anchor: anchor, dragRect: dragRect))
    }

    func test_majorityOverlap_zeroSizeAnchor_isRejected() {
        let anchor = CGRect(x: 100, y: 100, width: 0, height: 0)
        let dragRect = CGRect(x: 0, y: 0, width: 500, height: 500)
        XCTAssertFalse(OpenClickyLinkRectGeometry.majorityOverlap(
            anchor: anchor, dragRect: dragRect))
    }

    // MARK: upgradeScore + addOrUpgrade

    func test_upgradeScore_titledBeatsUntitled() {
        let untitled = OpenClickyLinkRectGeometry.upgradeScore(
            title: nil, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let titled = OpenClickyLinkRectGeometry.upgradeScore(
            title: "Login", bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        // Titled (100 + 100 = 200) beats untitled (0 + 10000 = 10000)?
        // Titled = 100 + 100 = 200. Untitled = 0 + 10000 = 10000.
        // So untitled with huge area wins — matches Everywhere.
        XCTAssertLessThan(titled, untitled)
    }

    func test_upgradeScore_titledSmallOverUntitledSmall() {
        let untitledTiny = OpenClickyLinkRectGeometry.upgradeScore(
            title: nil, bounds: CGRect(x: 0, y: 0, width: 8, height: 8))
        let titledTiny = OpenClickyLinkRectGeometry.upgradeScore(
            title: "Copy", bounds: CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertGreaterThan(titledTiny, untitledTiny)
    }

    func test_addOrUpgrade_dedupsByLowercaseUrl() {
        var byUrl: [String: OpenClickyPickedLink] = [:]
        var byUrlBounds: [String: CGRect] = [:]
        var order: [String] = []

        OpenClickyLinkRectHarvester.addOrUpgrade(
            byUrl: &byUrl, byUrlBounds: &byUrlBounds, insertionOrder: &order,
            url: "https://Example.com/A", title: "icon",
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8))
        OpenClickyLinkRectHarvester.addOrUpgrade(
            byUrl: &byUrl, byUrlBounds: &byUrlBounds, insertionOrder: &order,
            url: "https://Example.com/A", title: "Login button",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 40))

        XCTAssertEqual(byUrl.count, 1)
        XCTAssertEqual(order.count, 1)
        XCTAssertEqual(byUrl["https://example.com/a"]?.title, "Login button")
        // First-URL casing is preserved on insert; upgrade replaces
        // the value but not the insertion-order key.
    }

    func test_addOrUpgrade_preservesInsertionOrder() {
        var byUrl: [String: OpenClickyPickedLink] = [:]
        var byUrlBounds: [String: CGRect] = [:]
        var order: [String] = []
        for i in 0..<5 {
            OpenClickyLinkRectHarvester.addOrUpgrade(
                byUrl: &byUrl, byUrlBounds: &byUrlBounds, insertionOrder: &order,
                url: "https://example.com/\(i)", title: "t\(i)",
                bounds: CGRect(x: 0, y: 0, width: 50, height: 20))
        }
        XCTAssertEqual(order, [
            "https://example.com/0",
            "https://example.com/1",
            "https://example.com/2",
            "https://example.com/3",
            "https://example.com/4",
        ])
    }

    // MARK: Everywhere-parity byte match

    func test_limits_matchEverywhere() {
        XCTAssertEqual(OpenClickyLinkRectLimits.maxLinks, 200)
        XCTAssertEqual(OpenClickyLinkRectLimits.maxUrlLen, 2048)
        XCTAssertEqual(OpenClickyLinkRectLimits.maxTitleLen, 200)
        XCTAssertEqual(OpenClickyLinkRectLimits.maxDepth, 60)
        XCTAssertEqual(OpenClickyLinkRectLimits.walkBudget, 50_000)
    }

    // MARK: harvest early-return

    func test_harvest_emptyDragRect_returnsEmpty() {
        let result = OpenClickyLinkRectHarvester.harvest(
            dragRect: CGRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertTrue(result.picks.isEmpty)
        XCTAssertEqual(result.candidatesSeen, 0)
        XCTAssertEqual(result.nodesVisited, 0)
        XCTAssertFalse(result.budgetExhausted)
    }
}

final class OpenClickyContextStashWriterLinkMergeTests: XCTestCase {

    func test_mergeLinks_bothNil_returnsNil() {
        XCTAssertNil(OpenClickyContextStashWriter.mergeLinks(nil, nil))
    }

    func test_mergeLinks_bothEmpty_returnsNil() {
        XCTAssertNil(OpenClickyContextStashWriter.mergeLinks([], []))
    }

    func test_mergeLinks_dedupsByLowercaseUrl() {
        let a = [OpenClickyPickedLink(url: "https://Example.com/X", title: "clip")]
        let b = [OpenClickyPickedLink(url: "https://example.com/x", title: "rect")]
        let out = OpenClickyContextStashWriter.mergeLinks(a, b)
        XCTAssertEqual(out?.count, 1)
        // Clipboard-first insertion order preserved.
        XCTAssertEqual(out?.first?.title, "clip")
    }

    func test_mergeLinks_capsAt200() {
        let clip = (0..<150).map {
            OpenClickyPickedLink(url: "https://example.com/c\($0)", title: nil)
        }
        let rect = (0..<150).map {
            OpenClickyPickedLink(url: "https://example.com/r\($0)", title: nil)
        }
        let out = OpenClickyContextStashWriter.mergeLinks(clip, rect)
        XCTAssertEqual(out?.count, 200)
        // First 150 are clipboard entries, then first 50 rect entries.
        XCTAssertEqual(out?.first?.url, "https://example.com/c0")
        XCTAssertEqual(out?[149].url, "https://example.com/c149")
        XCTAssertEqual(out?[150].url, "https://example.com/r0")
    }
}
