// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for `CursorCapture` and `ElementUnderCursorCapture`.
// Everywhere's C# side has no direct tests for `ElementFromPointer` /
// `ElementFromPoint` — both wrap live AppKit + AX calls that need a
// WindowServer session and Accessibility consent. openclicky provides:
//   * Coordinate + JSON round-trip tests (headless-safe).
//   * Hit-test guards that never crash on bogus coords.
//   * A gated live smoke test that runs when the harness has a real
//     mouse (AppKit reports non-zero location).

import XCTest
import AppKit
import CoreGraphics
@testable import OpenClickyContextService

final class CursorCaptureTests: XCTestCase {

    // MARK: - CursorCapture

    func test_capture_returnsNonNil() {
        // AppKit always reports a location — even without a live cursor
        // it emits (0,0). Struct must be non-nil.
        let cursor = CursorCapture.capture()
        XCTAssertNotNil(cursor)
    }

    func test_capture_pointIsFinite() throws {
        let cursor = try XCTUnwrap(CursorCapture.capture())
        XCTAssertTrue(cursor.point.x.isFinite)
        XCTAssertTrue(cursor.point.y.isFinite)
    }

    func test_capture_displayIndexIsSaneWhenScreensPresent() throws {
        // On any macOS test host with at least one display, displayIndex
        // must be either -1 (cursor off every display, legal for hidden
        // remote sessions) or a valid index into NSScreen.screens.
        let cursor = try XCTUnwrap(CursorCapture.capture())
        let screens = NSScreen.screens
        if screens.isEmpty {
            XCTAssertEqual(cursor.displayIndex, -1,
                           "no screens must yield displayIndex == -1")
        } else {
            XCTAssertTrue(cursor.displayIndex == -1 ||
                          (0..<screens.count).contains(cursor.displayIndex),
                          "displayIndex \(cursor.displayIndex) must be -1 or in 0..<\(screens.count)")
        }
    }

    func test_capture_displayIndexNonNegativeWhenOnScreen() throws {
        // If AppKit reports a mouseLocation inside at least one screen,
        // displayIndex must be >= 0. Skips on the (rare) headless CI
        // path where the location is (0,0) and screens list is empty.
        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "headless test host — no display map")

        let cursor = try XCTUnwrap(CursorCapture.capture())
        // Convert back to Cocoa to check containment against NSScreen.frame.
        let primaryHeight = screens[0].frame.height
        let cocoaPoint = CGPoint(x: cursor.point.x,
                                 y: primaryHeight - cursor.point.y)
        let onScreen = screens.contains { $0.frame.contains(cocoaPoint) }
        if onScreen {
            XCTAssertGreaterThanOrEqual(cursor.displayIndex, 0)
        }
    }

    func test_capture_capturedAtIsRecent() throws {
        let before = Date().timeIntervalSince1970
        let cursor = try XCTUnwrap(CursorCapture.capture())
        let after = Date().timeIntervalSince1970
        XCTAssertGreaterThanOrEqual(cursor.capturedAtUnix, before - 0.5)
        XCTAssertLessThanOrEqual(cursor.capturedAtUnix, after + 0.5)
    }

    // MARK: - CursorPosition wire shape

    func test_cursorPosition_roundTripsJSON() throws {
        let sample = CursorPosition(
            point: CGPoint(x: 512.25, y: 384.75),
            displayIndex: 1,
            capturedAtUnix: 1_753_000_000.5
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(CursorPosition.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_cursorPosition_survivesNegativeCoords() throws {
        // Multi-display: a display to the left/above primary produces
        // negative Quartz coords. Must round-trip verbatim.
        let sample = CursorPosition(
            point: CGPoint(x: -1920.0, y: -100.0),
            displayIndex: 2,
            capturedAtUnix: 0
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(CursorPosition.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    // MARK: - ElementUnderCursorCapture

    func test_elementUnderCursor_atBogusPoint_doesNotCrash() {
        // Astronomically off-screen coord. macOS behaviour varies by
        // version: some return `.cannotComplete`, some return
        // `.success` with a screen-level element (e.g. AXApplication
        // for `com.apple.WindowManager`). Both are legal — we just
        // assert we don't crash.
        _ = ElementUnderCursorCapture.capture(
            at: CGPoint(x: -1_000_000, y: -1_000_000)
        )
    }

    func test_elementUnderCursor_returnsNilOrScreenLevel_forBogusPoint() throws {
        // No AX consent in `swift test` -> AXUIElementCopyElementAtPosition
        // returns .apiDisabled -> wrapper returns nil. On a consented host
        // we may get a screen-level element back — accept either.
        let info = ElementUnderCursorCapture.capture(
            at: CGPoint(x: -1_000_000, y: -1_000_000)
        )
        if let hit = info {
            // If we got something back, pid must be >= 0 and bounds must
            // be a real (possibly zero) rect. Role may still be nil for
            // some systemwide sentinels.
            XCTAssertGreaterThanOrEqual(hit.pid, 0)
            XCTAssertTrue(hit.bounds.origin.x.isFinite)
            XCTAssertTrue(hit.bounds.origin.y.isFinite)
        }
    }

    func test_elementUnderCursor_defaultsToCurrentCursor() {
        // Should not crash regardless of AX consent state. When AX
        // consent is missing the call is expected to return nil; when
        // present, the returned info is a valid struct.
        _ = ElementUnderCursorCapture.capture()
    }

    // MARK: - ElementUnderCursorInfo wire shape

    func test_elementUnderCursorInfo_roundTripsJSON() throws {
        let sample = ElementUnderCursorInfo(
            pid: 4242,
            role: "AXButton",
            subrole: "AXCloseButton",
            title: "Close",
            value: nil,
            bounds: CGRect(x: 12.5, y: 40.25, width: 48, height: 24),
            bundleId: "com.apple.finder"
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ElementUnderCursorInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_elementUnderCursorInfo_preservesAllNilFields() throws {
        // The AX element may omit every attribute except pid + bounds.
        // Wire shape must round-trip nil verbatim.
        let sample = ElementUnderCursorInfo(
            pid: 1,
            role: nil,
            subrole: nil,
            title: nil,
            value: nil,
            bounds: .zero,
            bundleId: nil
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ElementUnderCursorInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertNil(decoded.role)
        XCTAssertNil(decoded.subrole)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.value)
        XCTAssertNil(decoded.bundleId)
    }
}
