// Ported from Everywhere: src/Everywhere.Core/Interop/AnnotationStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for AnnotationStash. Exercises append/peek/consume/
// drain, TTL expiry via an injectable clock, defensive size caps
// (body / anchor_label / anchor_ref / queue depth) and the
// `annotationStashDidChange` NotificationCenter event.

import XCTest
@testable import OpenClickyContextService

final class AnnotationStashTests: XCTestCase {

    private var currentTime: Date!
    private var center: NotificationCenter!
    private var stash: AnnotationStash!

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 2_000_000)
        center = NotificationCenter()
        stash = AnnotationStash(
            clock: { self.currentTime },
            ttl: AnnotationStash.defaultTtl,
            notificationCenter: center
        )
    }

    override func tearDown() {
        stash = nil
        center = nil
        currentTime = nil
        super.tearDown()
    }

    // MARK: - constants

    func test_defaultTtl_matchesEverywhereTenMinutes() {
        XCTAssertEqual(AnnotationStash.defaultTtl, 10 * 60)
    }

    func test_capsMatchEverywhereConstants() {
        XCTAssertEqual(AnnotationStash.maxBodyLength, 8_000)
        XCTAssertEqual(AnnotationStash.maxAnchorLabelLength, 400)
        XCTAssertEqual(AnnotationStash.maxAnchorRefLength, 200)
        XCTAssertEqual(AnnotationStash.maxQueueDepth, 200)
    }

    // MARK: - append / peek / consume

    func test_append3_peek3_consume2_peek1() throws {
        let a = makeItem(body: "one")
        let b = makeItem(body: "two")
        let c = makeItem(body: "three")

        XCTAssertEqual(try stash.append(a), 1)
        XCTAssertEqual(try stash.append(b), 2)
        XCTAssertEqual(try stash.append(c), 3)

        let peeked = stash.peek()
        XCTAssertEqual(peeked, [a, b, c])
        XCTAssertEqual(stash.count, 3)

        stash.consume([a, b])
        let remaining = stash.peek()
        XCTAssertEqual(remaining, [c])
        XCTAssertEqual(stash.count, 1)
    }

    func test_consume_emptyBatch_isNoOp() throws {
        _ = try stash.append(makeItem(body: "keep"))
        stash.consume([])
        XCTAssertEqual(stash.count, 1)
    }

    func test_consume_unknownItems_leavesStashIntact() throws {
        let real = makeItem(body: "real")
        _ = try stash.append(real)
        let unknown = makeItem(body: "not-in-queue")
        stash.consume([unknown])
        XCTAssertEqual(stash.peek(), [real])
    }

    // MARK: - TTL

    func test_peek_dropsExpiredEntries() throws {
        _ = try stash.append(makeItem(body: "stale"))
        currentTime = currentTime.addingTimeInterval(AnnotationStash.defaultTtl + 1)
        XCTAssertEqual(stash.peek(), [])
        XCTAssertEqual(stash.count, 0)
    }

    func test_append_afterExpiry_pruneMakesRoomButDoesNotOverflowCap() throws {
        // A rolling 10-minute window means stale items should be
        // pruned lazily by subsequent appends, matching Everywhere's
        // `PruneExpired(_clock.GetUtcNow())` inside `Add`.
        _ = try stash.append(makeItem(body: "old"))
        currentTime = currentTime.addingTimeInterval(AnnotationStash.defaultTtl + 1)
        let fresh = makeItem(body: "fresh")
        let count = try stash.append(fresh)
        XCTAssertEqual(count, 1, "prune must run before the depth check")
        XCTAssertEqual(stash.peek(), [fresh])
    }

    // MARK: - Size caps

    func test_append_rejectsOversizeBody() {
        let overlong = String(repeating: "a", count: AnnotationStash.maxBodyLength + 1)
        let item = makeItem(body: overlong)
        XCTAssertThrowsError(try stash.append(item)) { error in
            XCTAssertEqual(
                error as? AnnotationStashError,
                .bodyTooLong(limit: AnnotationStash.maxBodyLength)
            )
        }
    }

    func test_append_rejectsOversizeAnchorLabel() {
        let overlong = String(repeating: "l", count: AnnotationStash.maxAnchorLabelLength + 1)
        let item = makeItem(body: "note", anchorLabel: overlong)
        XCTAssertThrowsError(try stash.append(item)) { error in
            XCTAssertEqual(
                error as? AnnotationStashError,
                .anchorLabelTooLong(limit: AnnotationStash.maxAnchorLabelLength)
            )
        }
    }

    func test_append_rejectsOversizeAnchorRef() {
        let overlong = String(repeating: "r", count: AnnotationStash.maxAnchorRefLength + 1)
        let item = makeItem(body: "note", anchorRef: overlong)
        XCTAssertThrowsError(try stash.append(item)) { error in
            XCTAssertEqual(
                error as? AnnotationStashError,
                .anchorRefTooLong(limit: AnnotationStash.maxAnchorRefLength)
            )
        }
    }

    func test_append_rejectsBeyondQueueDepth() throws {
        for i in 0 ..< AnnotationStash.maxQueueDepth {
            _ = try stash.append(makeItem(body: "note-\(i)"))
        }
        XCTAssertThrowsError(try stash.append(makeItem(body: "overflow"))) { error in
            XCTAssertEqual(
                error as? AnnotationStashError,
                .queueDepthExceeded(limit: AnnotationStash.maxQueueDepth)
            )
        }
    }

    // MARK: - clearWithEvent / drain

    func test_clearWithEvent_emptiesAndFiresNotification() throws {
        _ = try stash.append(makeItem(body: "one"))
        _ = try stash.append(makeItem(body: "two"))

        let expect = expectation(forNotification: .annotationStashDidChange, object: stash, notificationCenter: center)
        stash.clearWithEvent()
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(stash.peek(), [])
        XCTAssertEqual(stash.count, 0)
    }

    func test_clearWithEvent_onEmptyStash_isSilent() {
        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.clearWithEvent()
        XCTAssertEqual(fired, 0)
    }

    func test_drain_returnsAllAndClears() throws {
        let a = makeItem(body: "one")
        let b = makeItem(body: "two")
        _ = try stash.append(a)
        _ = try stash.append(b)

        let drained = stash.drain()
        XCTAssertEqual(drained, [a, b])
        XCTAssertEqual(stash.count, 0)
    }

    // MARK: - Notification observer lifecycle

    func test_append_fires_didChange_perAppend() throws {
        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        _ = try stash.append(makeItem(body: "a"))
        _ = try stash.append(makeItem(body: "b"))
        XCTAssertEqual(fired, 2)
    }

    func test_consume_fires_didChange_whenSomethingRemoved() throws {
        let a = makeItem(body: "a")
        _ = try stash.append(a)

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.consume([a])
        XCTAssertEqual(fired, 1)
    }

    func test_consume_firesEven_whenNothingMatches() throws {
        // Regression for F14 review: `AnnotationStash.cs:232` posts
        // `Changed?.Invoke()` unconditionally when the input batch is
        // non-empty. The pre-fix Swift port only fired when at least
        // one entry was actually removed; this test locks in the
        // aligned behaviour.
        let a = makeItem(body: "a")
        _ = try stash.append(a)

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.consume([makeItem(body: "ghost")])
        XCTAssertEqual(fired, 1)
        // The stash contents are untouched — only the notification is
        // eager. Everywhere's `Consume` behaves the same way.
        XCTAssertEqual(stash.peek(), [a])
    }

    func test_consume_emptyBatch_doesNotFire() throws {
        let a = makeItem(body: "a")
        _ = try stash.append(a)

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.consume([])
        XCTAssertEqual(fired, 0)
    }

    // MARK: - removeItem / remove(at:)

    func test_removeItem_removesAndFires() throws {
        let a = makeItem(body: "a")
        let b = makeItem(body: "b")
        _ = try stash.append(a)
        _ = try stash.append(b)

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        XCTAssertTrue(stash.removeItem(a))
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(stash.peek(), [b])
    }

    func test_removeItem_unknown_returnsFalseAndSilent() throws {
        let a = makeItem(body: "a")
        _ = try stash.append(a)
        let ghost = makeItem(body: "ghost")

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        XCTAssertFalse(stash.removeItem(ghost))
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(stash.peek(), [a])
    }

    func test_remove_atIndex_removesAndFires() throws {
        let a = makeItem(body: "a")
        let b = makeItem(body: "b")
        let c = makeItem(body: "c")
        _ = try stash.append(a)
        _ = try stash.append(b)
        _ = try stash.append(c)

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        XCTAssertTrue(stash.remove(at: 1))
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(stash.peek(), [a, c])
    }

    func test_remove_atIndex_outOfRange_returnsFalseAndSilent() throws {
        _ = try stash.append(makeItem(body: "only"))

        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        XCTAssertFalse(stash.remove(at: -1))
        XCTAssertFalse(stash.remove(at: 5))
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(stash.count, 1)
    }

    func test_removedObserver_doesNotFireAfterRemoval() throws {
        var fired = 0
        let observer = center.addObserver(
            forName: .annotationStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }

        _ = try stash.append(makeItem(body: "first"))
        XCTAssertEqual(fired, 1)

        center.removeObserver(observer)
        _ = try stash.append(makeItem(body: "second"))
        XCTAssertEqual(fired, 1)
    }

    // MARK: - helpers

    private func makeItem(
        body: String,
        source: AnnotationSource = .pin,
        anchorRef: String? = nil,
        anchorLabel: String = "AXButton \"Submit\""
    ) -> AnnotationItem {
        // Each item gets a unique capturedAt so value equality is
        // stable across appends but never falsely collapses two
        // distinct notes that happen to share the same body.
        let stamp = currentTime.addingTimeInterval(Double.random(in: 0 ..< 0.001))
        return AnnotationItem(
            source: source,
            body: body,
            anchorRef: anchorRef,
            anchorLabel: anchorLabel,
            capturedAt: stamp
        )
    }
}
