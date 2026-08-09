//
//  OpenClickyAnnotationBadgeOverlayTests.swift
//  cursor-buddyTests
//
//  Phase 7.1: unit coverage for the pure classifier that drives the
//  annotation badge overlay. Tests exercise the ➕ / ✓ label transitions
//  against a private PickStash + AnnotationStash so we don't need
//  NSPanels or AX permissions in the test target.
//

import XCTest
import Foundation
import OpenClickyContextService
@testable import OpenClicky

final class OpenClickyAnnotationBadgeOverlayTests: XCTestCase {

    private func makePicked(bounds: CGRect = CGRect(x: 100, y: 200, width: 60, height: 40)) -> PickedElement {
        PickedElement(
            pid: 4242,
            role: "AXButton",
            title: "Submit",
            value: nil,
            bounds: bounds,
            bundleId: "com.example.app",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    // MARK: - Classifier

    func testEmptyStashProducesNoAnchors() {
        let classifier = AnnotationBadgeOverlayClassifier(
            pick: nil,
            annotations: [],
            whiteboardPending: false
        )
        XCTAssertTrue(classifier.anchors().isEmpty)
    }

    func testPickWithoutAnnotationRendersPlus() {
        let picked = makePicked()
        let classifier = AnnotationBadgeOverlayClassifier(
            pick: picked,
            annotations: [],
            whiteboardPending: false
        )
        let anchors = classifier.anchors()
        XCTAssertEqual(anchors.count, 1)

        let (anchor, state) = anchors[0]
        XCTAssertEqual(anchor.source, .pin)
        XCTAssertEqual(anchor.label, "Button \"Submit\"")
        XCTAssertEqual(state.noteCount, 0)
        XCTAssertFalse(state.isAnnotated)
    }

    func testMatchingAnnotationSwitchesToCheckmark() {
        let picked = makePicked()
        let id = AnnotationBadgeOverlayClassifier.pinAnchorID(for: picked)
        let annotation = AnnotationItem(
            source: .pin,
            body: "focus on this",
            anchorRef: id,
            anchorLabel: "Button \"Submit\""
        )
        let classifier = AnnotationBadgeOverlayClassifier(
            pick: picked,
            annotations: [annotation],
            whiteboardPending: false
        )
        let anchors = classifier.anchors()
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors[0].state.noteCount, 1)
        XCTAssertTrue(anchors[0].state.isAnnotated)
        XCTAssertEqual(anchors[0].state.lastBody, "focus on this")
    }

    func testMultipleAnnotationsCount() {
        let picked = makePicked()
        let id = AnnotationBadgeOverlayClassifier.pinAnchorID(for: picked)
        let items: [AnnotationItem] = (0..<3).map { i in
            AnnotationItem(
                source: .pin,
                body: "note \(i)",
                anchorRef: id,
                anchorLabel: "Button \"Submit\""
            )
        }
        let classifier = AnnotationBadgeOverlayClassifier(
            pick: picked,
            annotations: items,
            whiteboardPending: false
        )
        let anchors = classifier.anchors()
        XCTAssertEqual(anchors[0].state.noteCount, 3)
        XCTAssertEqual(anchors[0].state.lastBody, "note 2")
    }

    func testUnrelatedAnnotationsAreIgnored() {
        let picked = makePicked()
        let stranger = AnnotationItem(
            source: .pin,
            body: "not this one",
            anchorRef: "pin:9999:AXTextField:-:0,0,0,0",
            anchorLabel: "TextField"
        )
        let classifier = AnnotationBadgeOverlayClassifier(
            pick: picked,
            annotations: [stranger],
            whiteboardPending: false
        )
        XCTAssertEqual(classifier.anchors()[0].state.noteCount, 0)
    }

    func testAnchorIDStableAcrossReadsButBoundsSensitive() {
        let a = makePicked(bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
        let b = makePicked(bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
        let c = makePicked(bounds: CGRect(x: 11, y: 20, width: 30, height: 40))
        XCTAssertEqual(
            AnnotationBadgeOverlayClassifier.pinAnchorID(for: a),
            AnnotationBadgeOverlayClassifier.pinAnchorID(for: b)
        )
        XCTAssertNotEqual(
            AnnotationBadgeOverlayClassifier.pinAnchorID(for: a),
            AnnotationBadgeOverlayClassifier.pinAnchorID(for: c)
        )
    }

    // MARK: - Stash <-> classifier end-to-end (no UI)

    func testPickStashSetProducesLiveAnchor() throws {
        let center = NotificationCenter()
        let pickStash = PickStash(notificationCenter: center)
        let annotationStash = AnnotationStash(notificationCenter: center)

        pickStash.set(makePicked())

        let classifier = AnnotationBadgeOverlayClassifier(
            pick: pickStash.peek(),
            annotations: annotationStash.peek(),
            whiteboardPending: false
        )
        XCTAssertEqual(classifier.anchors().count, 1)
        XCTAssertEqual(classifier.anchors()[0].state.badgeLabel, "＋")
    }

    func testAnnotationAppendFlipsBadgeLabel() throws {
        let center = NotificationCenter()
        let pickStash = PickStash(notificationCenter: center)
        let annotationStash = AnnotationStash(notificationCenter: center)

        let picked = makePicked()
        pickStash.set(picked)
        let id = AnnotationBadgeOverlayClassifier.pinAnchorID(for: picked)
        _ = try annotationStash.append(
            AnnotationItem(source: .pin, body: "hi", anchorRef: id, anchorLabel: "Button \"Submit\"")
        )

        let classifier = AnnotationBadgeOverlayClassifier(
            pick: pickStash.peek(),
            annotations: annotationStash.peek(),
            whiteboardPending: false
        )
        XCTAssertEqual(classifier.anchors()[0].state.badgeLabel, "✓")
    }

    func testClearWithEventRemovesAnchor() {
        let center = NotificationCenter()
        let pickStash = PickStash(notificationCenter: center)
        let annotationStash = AnnotationStash(notificationCenter: center)

        pickStash.set(makePicked())
        pickStash.clearWithEvent()

        let classifier = AnnotationBadgeOverlayClassifier(
            pick: pickStash.peek(),
            annotations: annotationStash.peek(),
            whiteboardPending: false
        )
        XCTAssertTrue(classifier.anchors().isEmpty)
    }
}

// MARK: - BadgeState convenience for tests

private extension AnnotationBadgeState {
    var badgeLabel: String {
        if noteCount == 0 { return "＋" }
        if noteCount == 1 { return "✓" }
        return "✓ \(noteCount)"
    }
}
