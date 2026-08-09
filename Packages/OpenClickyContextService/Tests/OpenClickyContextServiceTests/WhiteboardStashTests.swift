// Ported from Everywhere: src/Everywhere.Core/Interop/Whiteboard/WhiteboardStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for WhiteboardStash. Uses the injectable-clock ctor
// to exercise TTL semantics without wall-clock sleeps.

import XCTest
import Foundation
@testable import OpenClickyContextService

final class WhiteboardStashTests: XCTestCase {

    /// Mutable clock reference so a test can advance simulated time.
    private final class MockClock {
        var now: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.now = start
        }
    }

    // MARK: helpers

    private func makeStash(
        ttl: TimeInterval = WhiteboardStash.defaultTtl,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (stash: WhiteboardStash, clock: MockClock, center: NotificationCenter) {
        let clock = MockClock()
        let center = notificationCenter
        let stash = WhiteboardStash(
            clock: { clock.now },
            ttl: ttl,
            notificationCenter: center
        )
        return (stash, clock, center)
    }

    private func region(_ label: String = "r") -> WhiteboardRegion {
        WhiteboardRegion(
            bboxScreen: CGRect(x: 10, y: 20, width: 30, height: 40),
            gestureKind: "circle",
            ocrText: label,
            capturedAtUnix: 1_700_000_000
        )
    }

    // MARK: static contract

    func test_defaultTtl_isFiveMinutes() {
        // Verbatim from WhiteboardStash.cs:14 (TimeSpan.FromMinutes(5)).
        XCTAssertEqual(WhiteboardStash.defaultTtl, 300)
    }

    // MARK: set / peek

    func test_set_thenPeek_returnsRegions() {
        let (stash, _, _) = makeStash()
        let r = region("circle-a")
        stash.set(regions: [r], imageBytesById: [:])
        let peeked = stash.peek()
        XCTAssertEqual(peeked?.count, 1)
        XCTAssertEqual(peeked?.first?.id, r.id)
        XCTAssertEqual(peeked?.first?.gestureKind, "circle")
    }

    func test_peek_isNonConsuming() {
        let (stash, _, _) = makeStash()
        stash.set(regions: [region()], imageBytesById: [:])
        _ = stash.peek()
        XCTAssertNotNil(stash.peek())
        XCTAssertTrue(stash.hasPending)
    }

    func test_set_replacesPreviousSession() {
        let (stash, _, _) = makeStash()
        let first = region("first")
        let second = region("second")
        stash.set(regions: [first], imageBytesById: [:])
        stash.set(regions: [second], imageBytesById: [:])
        XCTAssertEqual(stash.peek()?.first?.id, second.id)
    }

    // MARK: take

    func test_take_returnsRegionsAndClearsSlot() {
        let (stash, _, _) = makeStash()
        stash.set(regions: [region()], imageBytesById: [:])
        XCTAssertNotNil(stash.take())
        XCTAssertNil(stash.peek())
        XCTAssertNil(stash.take())
        XCTAssertFalse(stash.hasPending)
    }

    // MARK: imageBytes side-table — the important detail

    func test_imageBytes_survivesTake() {
        // Everywhere WhiteboardStash.cs:19-24 — read_whiteboard() consumes
        // regions, then read_whiteboard_image(id) still needs bytes. The
        // side-table MUST outlive Take().
        let (stash, _, _) = makeStash()
        let id = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        stash.set(regions: [region()], imageBytesById: [id: png])
        _ = stash.take()
        XCTAssertEqual(stash.imageBytes(for: id), png,
                       "imageBytes side-table must survive take()")
    }

    func test_imageBytes_returnsNilForUnknownId() {
        let (stash, _, _) = makeStash()
        stash.set(regions: [region()], imageBytesById: [UUID(): Data([0x01])])
        XCTAssertNil(stash.imageBytes(for: UUID()))
    }

    func test_imageBytes_returnsNilBeforeAnySet() {
        let (stash, _, _) = makeStash()
        XCTAssertNil(stash.imageBytes(for: UUID()))
    }

    // MARK: TTL expiry

    func test_peek_returnsNil_afterTtlExpiry() {
        let (stash, clock, _) = makeStash(ttl: 300)
        stash.set(regions: [region()], imageBytesById: [:])
        clock.now = clock.now.addingTimeInterval(301)
        XCTAssertNil(stash.peek())
        XCTAssertFalse(stash.hasPending)
    }

    func test_take_returnsNil_afterTtlExpiry() {
        let (stash, clock, _) = makeStash(ttl: 300)
        stash.set(regions: [region()], imageBytesById: [:])
        clock.now = clock.now.addingTimeInterval(301)
        XCTAssertNil(stash.take())
    }

    func test_imageBytes_returnsNil_afterTtlExpiry() {
        let (stash, clock, _) = makeStash(ttl: 300)
        let id = UUID()
        stash.set(regions: [region()], imageBytesById: [id: Data([0x01, 0x02])])
        clock.now = clock.now.addingTimeInterval(301)
        XCTAssertNil(stash.imageBytes(for: id))
    }

    func test_peek_stillReturnsBeforeExpiry() {
        let (stash, clock, _) = makeStash(ttl: 300)
        stash.set(regions: [region()], imageBytesById: [:])
        clock.now = clock.now.addingTimeInterval(299)
        XCTAssertNotNil(stash.peek())
    }

    // MARK: clearWithEvent

    func test_clearWithEvent_dropsBothSlots() {
        let (stash, _, _) = makeStash()
        let id = UUID()
        stash.set(regions: [region()], imageBytesById: [id: Data([0x00])])
        stash.clearWithEvent()
        XCTAssertNil(stash.peek())
        XCTAssertNil(stash.imageBytes(for: id))
        XCTAssertFalse(stash.hasPending)
    }

    func test_clearWithEvent_postsNotification_whenPending() {
        let center = NotificationCenter()
        let (stash, _, _) = makeStash(notificationCenter: center)
        stash.set(regions: [region()], imageBytesById: [:])
        let received = expectation(description: "notification")
        let obs = center.addObserver(
            forName: .openClickyWhiteboardStashCleared,
            object: stash,
            queue: nil
        ) { _ in received.fulfill() }
        stash.clearWithEvent()
        wait(for: [received], timeout: 1.0)
        center.removeObserver(obs)
    }

    func test_clearWithEvent_isSilent_whenEmpty() {
        let center = NotificationCenter()
        let (stash, _, _) = makeStash(notificationCenter: center)
        var fired = 0
        let obs = center.addObserver(
            forName: .openClickyWhiteboardStashCleared,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        stash.clearWithEvent()
        XCTAssertEqual(fired, 0)
        center.removeObserver(obs)
    }

    func test_clearWithEvent_isSilent_whenOnlyImages() {
        // Regression for F14 review: Everywhere's `ClearWithEvent`
        // gates on `_current is not null` only (`WhiteboardStash.cs:222`).
        // A stash that only ever loaded image bytes (empty regions
        // batch) has no pending whiteboard and must not notify.
        let center = NotificationCenter()
        let (stash, _, _) = makeStash(notificationCenter: center)
        let id = UUID()
        stash.set(regions: [], imageBytesById: [id: Data([0x01])])
        var fired = 0
        let obs = center.addObserver(
            forName: .openClickyWhiteboardStashCleared,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        stash.clearWithEvent()
        XCTAssertEqual(fired, 0)
        // Image bytes are still dropped even though we did not notify.
        XCTAssertNil(stash.imageBytes(for: id))
        center.removeObserver(obs)
    }

    func test_clear_isSilent_evenWithPendingRegions() {
        // `clear()` is the silent variant, matching Everywhere's
        // `WhiteboardStash.cs:203-210`. Fires no notification even
        // when there was a pending session.
        let center = NotificationCenter()
        let (stash, _, _) = makeStash(notificationCenter: center)
        let id = UUID()
        stash.set(regions: [region()], imageBytesById: [id: Data([0x02])])
        var fired = 0
        let obs = center.addObserver(
            forName: .openClickyWhiteboardStashCleared,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        stash.clear()
        XCTAssertEqual(fired, 0)
        XCTAssertNil(stash.peek())
        XCTAssertNil(stash.imageBytes(for: id))
        XCTAssertFalse(stash.hasPending)
        center.removeObserver(obs)
    }

    // MARK: hasPending

    func test_hasPending_reflectsLifecycle() {
        let (stash, clock, _) = makeStash(ttl: 300)
        XCTAssertFalse(stash.hasPending)
        stash.set(regions: [region()], imageBytesById: [:])
        XCTAssertTrue(stash.hasPending)
        clock.now = clock.now.addingTimeInterval(301)
        XCTAssertFalse(stash.hasPending)
    }

    // MARK: WhiteboardRegion round-trip (defensive — struct is Codable)

    func test_whiteboardRegion_codableRoundTrip() throws {
        let r = WhiteboardRegion(
            bboxScreen: CGRect(x: 1, y: 2, width: 3, height: 4),
            gestureKind: "arrow",
            ocrText: "hello",
            capturedAtUnix: 12345.0
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(WhiteboardRegion.self, from: data)
        XCTAssertEqual(decoded, r)
    }
}
