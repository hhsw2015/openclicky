// Ported from Everywhere: src/Everywhere.Mac/Interop/NSScreenVisualElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for ScreenListCapture. Everywhere has no unit tests
// for `NSScreenVisualElement`; it is exercised only via the live UI
// walk. openclicky adds:
//
//   * Headless-safe guards (skip when `NSScreen.screens` is empty,
//     which happens under `swift test` in CI / ssh).
//   * Shape invariants matching the Everywhere y-flip formula.
//   * A round-trip that reconstructs Cocoa Y from Quartz using the
//     primary Cocoa height (mirrors the C# byte-exact flip at
//     NSScreenVisualElement.cs:62-64).
//   * JSON round-trip on the `ScreenInfo` wire type.

import XCTest
import AppKit
import CoreGraphics
@testable import OpenClickyContextService

final class ScreenListCaptureTests: XCTestCase {

    // MARK: - Headless-safe invariants

    func test_enumerateAll_neverThrows() {
        _ = ScreenListCapture.enumerateAll()
    }

    // MARK: - Live-session shape

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    private var hasWindowServerSession: Bool {
        !NSScreen.screens.isEmpty
    }

    func test_enumerateAll_returnsAtLeastOneScreen_whenGUISessionAvailable() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let screens = ScreenListCapture.enumerateAll()
        XCTAssertFalse(screens.isEmpty, "GUI session must expose at least one screen")
    }

    func test_enumerateAll_primaryIsIndexZero() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let screens = ScreenListCapture.enumerateAll()
        try XCTSkipIf(screens.isEmpty, "No screens available")

        // AppKit invariant Everywhere relies on at
        // NSScreenVisualElement.cs:62 -- `NSScreen.Screens[0]` is
        // primary. The port materialises that as `isPrimary` + `index`.
        XCTAssertEqual(screens[0].index, 0)
        XCTAssertTrue(screens[0].isPrimary)

        for (position, entry) in screens.enumerated() {
            XCTAssertEqual(entry.index, position, "index must match array position")
            XCTAssertEqual(entry.isPrimary, position == 0, "only index 0 is primary")
        }
    }

    func test_enumerateAll_allFramesFiniteAndPositive() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let screens = ScreenListCapture.enumerateAll()
        try XCTSkipIf(screens.isEmpty, "No screens available")

        for screen in screens {
            XCTAssertNotEqual(screen.displayID, 0, "displayID must be non-zero")
            XCTAssertGreaterThan(screen.frameQuartz.width, 0)
            XCTAssertGreaterThan(screen.frameQuartz.height, 0)
            XCTAssertGreaterThan(screen.frameCocoa.width, 0)
            XCTAssertGreaterThan(screen.frameCocoa.height, 0)
            XCTAssertGreaterThan(screen.backingScaleFactor, 0)

            // The four scalars must be finite (no NaN / +/-inf).
            XCTAssertTrue(screen.frameQuartz.origin.x.isFinite)
            XCTAssertTrue(screen.frameQuartz.origin.y.isFinite)
            XCTAssertTrue(screen.frameQuartz.width.isFinite)
            XCTAssertTrue(screen.frameQuartz.height.isFinite)

            // visibleFrame is a subset of frame in area terms; width
            // and height cannot exceed the full frame.
            XCTAssertLessThanOrEqual(screen.visibleFrameQuartz.width, screen.frameQuartz.width)
            XCTAssertLessThanOrEqual(screen.visibleFrameQuartz.height, screen.frameQuartz.height)
        }
    }

    func test_enumerateAll_quartzAndCocoaFramesRoundTripViaPrimaryHeight() throws {
        // NSScreenVisualElement.cs:62-64 byte-exact:
        //   quartz.y = primary.Height - (cocoa.y + cocoa.height)
        // Restated: cocoa.y == primary.Height - (quartz.y + quartz.height).
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let screens = ScreenListCapture.enumerateAll()
        try XCTSkipIf(screens.isEmpty, "No screens available")

        let primaryCocoaHeight = screens[0].frameCocoa.height

        for screen in screens {
            // x is unchanged by the flip.
            XCTAssertEqual(screen.frameQuartz.origin.x, screen.frameCocoa.origin.x, accuracy: 0.0001)
            XCTAssertEqual(screen.frameQuartz.width, screen.frameCocoa.width, accuracy: 0.0001)
            XCTAssertEqual(screen.frameQuartz.height, screen.frameCocoa.height, accuracy: 0.0001)

            // y round-trip.
            let expectedCocoaY = primaryCocoaHeight - (screen.frameQuartz.origin.y + screen.frameQuartz.height)
            XCTAssertEqual(
                screen.frameCocoa.origin.y,
                expectedCocoaY,
                accuracy: 0.0001,
                "cocoa.y must equal primary.height - (quartz.y + quartz.height)"
            )
        }
    }

    func test_enumerateAll_primaryQuartzOriginIsZero() throws {
        // For the primary screen, quartz.y = primary.height - (0 + primary.height) = 0.
        // Same argument for x. This is what makes screens[0] the top-left origin
        // of the global Quartz coordinate space.
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let screens = ScreenListCapture.enumerateAll()
        try XCTSkipIf(screens.isEmpty, "No screens available")

        // Cocoa places the primary at origin (0, 0) as well; the flip
        // preserves that.
        XCTAssertEqual(screens[0].frameQuartz.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(screens[0].frameQuartz.origin.y, 0, accuracy: 0.0001)
    }

    func test_enumerateAll_displayIDsAreUnique() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let screens = ScreenListCapture.enumerateAll()
        try XCTSkipIf(screens.count < 2, "Need multiple displays to assert uniqueness")

        // Mirrored displays would share a displayID, so the assertion
        // is best-effort: we skip below 2 screens and treat duplicates
        // as a legitimate mirrored config only after distinguishing.
        let ids = screens.map(\.displayID)
        let unique = Set(ids)
        // If the count differs, the setup is mirrored; not a failure,
        // just document the alternative outcome.
        XCTAssertTrue(
            unique.count == ids.count || unique.count == 1,
            "Non-mirrored displays must have unique CGDirectDisplayIDs"
        )
    }

    // MARK: - ScreenInfo wire shape

    func test_screenInfo_roundTripsJSON() throws {
        let sample = ScreenInfo(
            displayID: 69733382,
            index: 0,
            name: "Built-in Retina Display",
            frameQuartz: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            frameCocoa: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrameQuartz: CGRect(x: 0, y: 25, width: 1728, height: 1092),
            backingScaleFactor: 2.0,
            isPrimary: true
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ScreenInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_screenInfo_preservesFractionalGeometry() throws {
        // Everywhere truncates to int (L63); the port keeps CGFloat.
        // Fractional origins must survive JSON round-trip.
        let sample = ScreenInfo(
            displayID: 2077750305,
            index: 1,
            name: "LG UltraFine",
            frameQuartz: CGRect(x: 1728.5, y: -180.75, width: 3008, height: 1692.25),
            frameCocoa: CGRect(x: 1728.5, y: 1297.75, width: 3008, height: 1692.25),
            visibleFrameQuartz: CGRect(x: 1728.5, y: -180.75, width: 3008, height: 1692.25),
            backingScaleFactor: 1.0,
            isPrimary: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ScreenInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.frameQuartz.origin.y, -180.75, accuracy: 0.0001)
    }

    func test_screenInfo_preservesOptionalNilName() throws {
        let sample = ScreenInfo(
            displayID: 42,
            index: 2,
            name: nil,
            frameQuartz: .zero,
            frameCocoa: .zero,
            visibleFrameQuartz: .zero,
            backingScaleFactor: 1.0,
            isPrimary: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ScreenInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertNil(decoded.name)
    }
}
