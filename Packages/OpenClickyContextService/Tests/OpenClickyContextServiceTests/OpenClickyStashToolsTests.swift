// Ported from Everywhere: src/Everywhere.Mcp/Tools/ReadPickTool.cs + AddAnnotationTool.cs + ReadAnnotationsTool.cs + ClearAnnotationsTool.cs + ReadWhiteboardTool.cs + ReadWhiteboardImageTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for `OpenClickyStashTools`. Each test builds fresh
// stash instances (never touches the process-wide `.shared` singletons)
// so runs are order-independent.

import XCTest
import CoreGraphics
@testable import OpenClickyContextService

final class OpenClickyStashToolsTests: XCTestCase {

    private var currentTime: Date!
    private var center: NotificationCenter!

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 3_000_000)
        center = NotificationCenter()
    }

    override func tearDown() {
        center = nil
        currentTime = nil
        super.tearDown()
    }

    // MARK: - read_pick

    func test_readPick_emptyStash_returnsPinnedFalse() {
        let pick = PickStash(
            clock: { self.currentTime },
            ttl: PickStash.defaultTtl,
            notificationCenter: center
        )
        let result = OpenClickyStashTools.readPick(stash: pick)
        XCTAssertFalse(result.pinned)
        XCTAssertFalse(result.consumedPin)
        XCTAssertNil(result.pickedIndex)
        XCTAssertNil(result.app)
        XCTAssertNil(result.element)
        XCTAssertNil(result.treeJson)
    }

    func test_setPick_thenReadPickAuto_returnsElement_andConsumes() {
        let pick = PickStash(
            clock: { self.currentTime },
            ttl: PickStash.defaultTtl,
            notificationCenter: center
        )
        let picked = PickedElement(
            pid: 4242,
            role: "AXButton",
            title: "Submit",
            value: nil,
            bounds: CGRect(x: 10, y: 20, width: 100, height: 30),
            bundleId: "com.example.app",
            capturedAt: currentTime
        )
        pick.set(picked)
        XCTAssertTrue(pick.hasFreshPin)

        let result = OpenClickyStashTools.readPick(mode: "auto", stash: pick)
        XCTAssertTrue(result.pinned)
        XCTAssertTrue(result.consumedPin)
        // auto → full for the Swift snapshot (no tree walk).
        XCTAssertEqual(result.pickedIndex, "full")
        XCTAssertEqual(result.app, "com.example.app")
        XCTAssertEqual(result.element?["role"], "AXButton")
        XCTAssertEqual(result.element?["title"], "Submit")
        XCTAssertEqual(result.element?["pid"], "4242")
        XCTAssertEqual(result.element?["bounds"], "10,20 100x30")
        XCTAssertEqual(result.element?["mode"], "full")
        XCTAssertNil(result.treeJson)

        // Consumed — a follow-up read reports empty.
        XCTAssertFalse(pick.hasFreshPin)
        let followup = OpenClickyStashTools.readPick(stash: pick)
        XCTAssertFalse(followup.pinned)
        XCTAssertFalse(followup.consumedPin)
    }

    func test_readPick_includeTreeJson_populatesTreeJson() {
        let pick = PickStash(
            clock: { self.currentTime },
            ttl: PickStash.defaultTtl,
            notificationCenter: center
        )
        let picked = PickedElement(
            pid: 1,
            role: "AXWindow",
            title: "Doc",
            value: nil,
            bounds: .zero,
            bundleId: "com.example.app",
            capturedAt: currentTime
        )
        pick.set(picked)
        let result = OpenClickyStashTools.readPick(
            includeTreeJson: true,
            stash: pick
        )
        XCTAssertNotNil(result.treeJson)
        XCTAssertTrue(result.treeJson?.contains("AXWindow") == true)
    }

    // MARK: - add_annotation / read_annotations / clear_annotations

    func test_addAnnotation_appendsOne_readAnnotationsReturnsOne() {
        let annotations = AnnotationStash(
            clock: { self.currentTime },
            ttl: AnnotationStash.defaultTtl,
            notificationCenter: center
        )
        let result = OpenClickyStashTools.addAnnotation(
            source: "pin",
            body: "Note about this button",
            anchorLabel: "Submit button",
            anchorRef: "elem-42",
            stash: annotations
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.count, 1)

        let listed = OpenClickyStashTools.readAnnotations(stash: annotations)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.source, .pin)
        XCTAssertEqual(listed.first?.body, "Note about this button")
        XCTAssertEqual(listed.first?.anchorLabel, "Submit button")
        XCTAssertEqual(listed.first?.anchorRef, "elem-42")

        // Peek does NOT consume.
        let again = OpenClickyStashTools.readAnnotations(stash: annotations)
        XCTAssertEqual(again.count, 1)
    }

    func test_addAnnotation_invalidSource_returnsOkFalse() {
        let annotations = AnnotationStash(
            clock: { self.currentTime },
            ttl: AnnotationStash.defaultTtl,
            notificationCenter: center
        )
        let result = OpenClickyStashTools.addAnnotation(
            source: "not-a-real-source",
            body: "text",
            anchorLabel: "label",
            anchorRef: nil,
            stash: annotations
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(annotations.count, 0)
    }

    func test_addAnnotation_emptyBody_returnsOkFalse() {
        let annotations = AnnotationStash(
            clock: { self.currentTime },
            ttl: AnnotationStash.defaultTtl,
            notificationCenter: center
        )
        let result = OpenClickyStashTools.addAnnotation(
            source: "whiteboard",
            body: "   ",
            anchorLabel: "label",
            anchorRef: nil,
            stash: annotations
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(annotations.count, 0)
    }

    func test_clearAnnotations_dropsAll() throws {
        let annotations = AnnotationStash(
            clock: { self.currentTime },
            ttl: AnnotationStash.defaultTtl,
            notificationCenter: center
        )
        _ = OpenClickyStashTools.addAnnotation(
            source: "pin",
            body: "a",
            anchorLabel: "x",
            anchorRef: nil,
            stash: annotations
        )
        _ = OpenClickyStashTools.addAnnotation(
            source: "selected",
            body: "b",
            anchorLabel: "y",
            anchorRef: nil,
            stash: annotations
        )
        XCTAssertEqual(annotations.count, 2)

        let cleared = OpenClickyStashTools.clearAnnotations(stash: annotations)
        XCTAssertTrue(cleared.ok)
        XCTAssertEqual(cleared.count, 2)
        XCTAssertEqual(annotations.count, 0)
        XCTAssertEqual(OpenClickyStashTools.readAnnotations(stash: annotations).count, 0)
    }

    // MARK: - read_whiteboard / read_whiteboard_image

    func test_readWhiteboard_emptyStash_returnsDrawnFalse() {
        let wb = WhiteboardStash(
            clock: { self.currentTime },
            ttl: WhiteboardStash.defaultTtl,
            notificationCenter: center
        )
        let r = OpenClickyStashTools.readWhiteboard(stash: wb)
        XCTAssertFalse(r.drawn)
        XCTAssertEqual(r.regionCount, 0)
        XCTAssertFalse(r.consumed)
        XCTAssertTrue(r.markdown.isEmpty)
    }

    func test_readWhiteboard_threeRegions_returnsThreeMarkdownBlocks_andConsumes() {
        let wb = WhiteboardStash(
            clock: { self.currentTime },
            ttl: WhiteboardStash.defaultTtl,
            notificationCenter: center
        )
        let regions = [
            WhiteboardRegion(
                id: UUID(),
                bboxScreen: CGRect(x: 0, y: 0, width: 100, height: 20),
                gestureKind: "circle",
                ocrText: "First region text",
                capturedAtUnix: currentTime.timeIntervalSince1970
            ),
            WhiteboardRegion(
                id: UUID(),
                bboxScreen: CGRect(x: 0, y: 40, width: 200, height: 30),
                gestureKind: "underline",
                ocrText: "Second region text",
                capturedAtUnix: currentTime.timeIntervalSince1970
            ),
            WhiteboardRegion(
                id: UUID(),
                bboxScreen: CGRect(x: 0, y: 80, width: 300, height: 40),
                gestureKind: "arrow",
                ocrText: nil,
                capturedAtUnix: currentTime.timeIntervalSince1970
            ),
        ]
        wb.set(regions: regions, imageBytesById: [:])
        XCTAssertTrue(wb.hasPending)

        let r = OpenClickyStashTools.readWhiteboard(stash: wb)
        XCTAssertTrue(r.drawn)
        XCTAssertEqual(r.regionCount, 3)
        XCTAssertTrue(r.consumed)

        // One header per region.
        let headerCount = r.markdown
            .components(separatedBy: "## Region ")
            .count - 1
        XCTAssertEqual(headerCount, 3)
        XCTAssertTrue(r.markdown.contains("circle = emphasis"))
        XCTAssertTrue(r.markdown.contains("underline = focus on a single line"))
        XCTAssertTrue(r.markdown.contains("arrow = pointing at this leaf"))
        XCTAssertTrue(r.markdown.contains("First region text"))
        XCTAssertTrue(r.markdown.contains("Second region text"))
        // Third region had nil OCR — emit empty-text marker.
        XCTAssertTrue(r.markdown.contains("(empty-text leaf at 0,80 300x40)"))

        // Consumed — follow-up read reports empty.
        XCTAssertFalse(wb.hasPending)
        let again = OpenClickyStashTools.readWhiteboard(stash: wb)
        XCTAssertFalse(again.drawn)
        XCTAssertFalse(again.consumed)
    }

    func test_readWhiteboardImage_unknownId_returnsNil() {
        let wb = WhiteboardStash(
            clock: { self.currentTime },
            ttl: WhiteboardStash.defaultTtl,
            notificationCenter: center
        )
        // Non-UUID string → nil.
        XCTAssertNil(OpenClickyStashTools.readWhiteboardImage(
            imageId: "not-a-uuid",
            stash: wb
        ))
        // Valid UUID, empty stash → nil.
        XCTAssertNil(OpenClickyStashTools.readWhiteboardImage(
            imageId: UUID().uuidString,
            stash: wb
        ))
    }

    func test_readWhiteboardImage_knownId_returnsBytes_survivesRegionTake() {
        let wb = WhiteboardStash(
            clock: { self.currentTime },
            ttl: WhiteboardStash.defaultTtl,
            notificationCenter: center
        )
        let imgId = UUID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let region = WhiteboardRegion(
            id: UUID(),
            bboxScreen: CGRect(x: 0, y: 0, width: 10, height: 10),
            gestureKind: "circle",
            ocrText: "hi",
            capturedAtUnix: currentTime.timeIntervalSince1970
        )
        wb.set(regions: [region], imageBytesById: [imgId: bytes])

        // Consuming regions must not drop image bytes (see WhiteboardStash header).
        _ = OpenClickyStashTools.readWhiteboard(stash: wb)
        let fetched = OpenClickyStashTools.readWhiteboardImage(
            imageId: imgId.uuidString,
            stash: wb
        )
        XCTAssertEqual(fetched, bytes)
    }
}
