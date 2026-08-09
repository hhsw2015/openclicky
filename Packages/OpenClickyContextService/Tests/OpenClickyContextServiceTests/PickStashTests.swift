// Ported from Everywhere: src/Everywhere.Core/Interop/PickStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for PickStash. Exercises the set/take/peek/clear
// semantics, TTL expiry via an injectable clock, and the
// `pickStashDidChange` NotificationCenter event so the Layer 4 UX
// overlay's subscription surface stays honest.

import XCTest
import CoreGraphics
@testable import OpenClickyContextService

final class PickStashTests: XCTestCase {

    // Fresh clock / center per test so state does not bleed between
    // cases and observers do not fire against a prior instance.
    //
    // NOTE: `stash` is intentionally NOT declared as `PickStash!`
    // because `Optional<T>` has a `take()` method in the Swift
    // standard library that shadows any `take()` on the wrapped
    // type when called through the implicitly-unwrapped optional.
    // The IUO variant would silently invoke `Optional.take()` on
    // every `stash.take()` call and return the PickStash instance
    // itself (setting the ivar to nil). Keeping the ivar non-
    // optional via a lazy-init pattern avoids the footgun.
    private var currentTime: Date = Date(timeIntervalSince1970: 1_000_000)
    private var center: NotificationCenter = NotificationCenter()
    private lazy var stash: PickStash = PickStash(
        clock: { self.currentTime },
        ttl: PickStash.defaultTtl,
        notificationCenter: center
    )

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_000_000)
        center = NotificationCenter()
        stash = PickStash(
            clock: { self.currentTime },
            ttl: PickStash.defaultTtl,
            notificationCenter: center
        )
    }

    // MARK: - constants

    func test_defaultTtl_matchesEverywhereFiveMinutes() {
        // Everywhere: `PickStash.DefaultTtl = TimeSpan.FromMinutes(5)`.
        XCTAssertEqual(PickStash.defaultTtl, 5 * 60)
    }

    // MARK: - set / peek / take basics

    func test_set_thenHasFreshPin_thenPeek_thenTake() {
        let element = Self.makeElement(pid: 1234, title: "Submit")

        XCTAssertFalse(stash.hasFreshPin, "empty stash must not be fresh")
        stash.set(element)

        XCTAssertTrue(stash.hasFreshPin, "set must produce a fresh pin")
        XCTAssertEqual(stash.peek(), element, "peek must return the same element")
        XCTAssertTrue(stash.hasFreshPin, "peek must not consume the slot")

        XCTAssertEqual(stash.take(), element, "take must return the pinned element")
        XCTAssertFalse(stash.hasFreshPin, "take must clear the slot")
        XCTAssertNil(stash.take(), "second take on empty slot must be nil")
    }

    func test_set_overwritesPreviousUnreadPin() {
        // Everywhere docstring: "Replacing an unread pin is fine — the new one wins."
        let first = Self.makeElement(pid: 1, title: "old")
        let second = Self.makeElement(pid: 2, title: "new")
        stash.set(first)
        stash.set(second)
        XCTAssertEqual(stash.peek(), second)
        XCTAssertEqual(stash.take(), second)
    }

    // MARK: - TTL

    func test_peek_returnsNilAfterTtlExpires() {
        let element = Self.makeElement(pid: 42, title: "expiring")
        stash.set(element)
        // Fast-forward past the 5-minute TTL.
        currentTime = currentTime.addingTimeInterval(PickStash.defaultTtl + 1)
        XCTAssertNil(stash.peek(), "peek must return nil once the pin has expired")
        XCTAssertFalse(stash.hasFreshPin, "hasFreshPin must be false once the pin has expired")
    }

    func test_take_returnsNilAfterTtlExpires() {
        let element = Self.makeElement(pid: 42, title: "expiring")
        stash.set(element)
        currentTime = currentTime.addingTimeInterval(PickStash.defaultTtl + 1)
        XCTAssertNil(stash.take(), "take must return nil once the pin has expired")
        XCTAssertFalse(stash.hasFreshPin, "expired take must still leave the slot cleared")
    }

    func test_customTtlOverride_isRespected() {
        let element = Self.makeElement(pid: 7, title: "short")
        stash.set(element, ttl: 1)
        currentTime = currentTime.addingTimeInterval(2)
        XCTAssertNil(stash.peek())
    }

    // MARK: - clearWithEvent

    func test_clearWithEvent_firesNotificationAndEmpties() {
        let element = Self.makeElement(pid: 1, title: "x")
        stash.set(element)

        let expect = expectation(forNotification: .pickStashDidChange, object: stash, notificationCenter: center)
        stash.clearWithEvent()
        wait(for: [expect], timeout: 1.0)

        XCTAssertFalse(stash.hasFreshPin)
        XCTAssertNil(stash.peek())
    }

    func test_clearWithEvent_onEmptyStash_doesNotFireNotification() {
        // Everywhere fires only when `_current is not null`, so an
        // already-empty stash must stay silent.
        var fired = 0
        let observer = center.addObserver(
            forName: .pickStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.clearWithEvent()
        XCTAssertEqual(fired, 0, "clearWithEvent on an empty stash must be silent")
    }

    func test_clear_silent_doesNotFireNotification() {
        stash.set(Self.makeElement(pid: 1, title: "x"))

        var fired = 0
        let observer = center.addObserver(
            forName: .pickStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.clear()
        XCTAssertEqual(fired, 0, "silent clear must not fire didChange")
        XCTAssertFalse(stash.hasFreshPin)
    }

    // MARK: - Notification observer lifecycle

    func test_set_and_take_fire_didChange_observer() {
        var fired = 0
        let observer = center.addObserver(
            forName: .pickStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        stash.set(Self.makeElement(pid: 1, title: "a"))
        XCTAssertEqual(fired, 1, "set must fire didChange once")

        _ = stash.take()
        XCTAssertEqual(fired, 2, "take on a filled slot must fire didChange once")
    }

    func test_take_onEmptyStash_isSilent() {
        var fired = 0
        let observer = center.addObserver(
            forName: .pickStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }
        defer { center.removeObserver(observer) }

        _ = stash.take()
        XCTAssertEqual(fired, 0, "take on an already-empty slot must not fire didChange")
    }

    func test_removedObserver_doesNotFireAfterRemoval() {
        var fired = 0
        let observer = center.addObserver(
            forName: .pickStashDidChange,
            object: stash,
            queue: nil
        ) { _ in fired += 1 }

        stash.set(Self.makeElement(pid: 1, title: "a"))
        XCTAssertEqual(fired, 1)

        center.removeObserver(observer)
        stash.set(Self.makeElement(pid: 2, title: "b"))
        XCTAssertEqual(fired, 1, "removed observer must not receive further didChange events")
    }

    // MARK: - helpers

    private static func makeElement(pid: Int32, title: String) -> PickedElement {
        PickedElement(
            pid: pid,
            role: "AXButton",
            title: title,
            value: nil,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 30),
            bundleId: "com.example.testapp",
            capturedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }
}
