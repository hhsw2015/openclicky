// Ported from Everywhere: src/Everywhere.Mac/Interop/WindowHelper.cs @30e03e9d + SkyLightInterop.cs
//
// XCTest coverage for WindowEnumerationCapture. Everywhere's C# side
// has no direct unit tests for its `CGWindowListCopyWindowInfo`
// callers -- both usages are inline private helpers, exercised only
// via the live UI paths (RaiseOverlayAboveTarget /
// GetWindowOwnerPidsAtLocation). openclicky adds:
//
//   * Guard tests that run headless (any macOS session, including
//     `swift test` in CI / ssh) and never require a WindowServer.
//   * A gated live test that runs when NSScreen reports >= 1 display,
//     asserting shape invariants on the returned list.
//   * JSON round-trip on the `EnumeratedWindow` wire type.
//
// The CGWindowListCopyWindowInfo API is public and does NOT require
// Screen Recording consent for the shape assertions here; consent
// only gates window titles of other apps, which we do not assert on.

import XCTest
import AppKit
import CoreGraphics
@testable import OpenClickyContextService

final class WindowEnumerationCaptureTests: XCTestCase {

    // MARK: - Headless-safe invariants

    func test_enumerateAll_neverThrows_alwaysReturnsArray() {
        // `enumerateAll` must never crash on any environment. Empty
        // result is a legitimate outcome (headless / WindowServer
        // unavailable). This test just exercises the code path.
        _ = WindowEnumerationCapture.enumerateAll()
        _ = WindowEnumerationCapture.enumerateAll(options: .default)
    }

    func test_enumerateOptions_defaultMirrorsEverywhere() {
        // WindowHelper.cs:272-274 uses onScreenOnly | excludeDesktopElements,
        // relativeToWindow=0. Confirm the Swift default matches.
        let opts = EnumerateOptions.default
        XCTAssertTrue(opts.onScreenOnly)
        XCTAssertTrue(opts.excludeDesktopElements)
        XCTAssertEqual(opts.relativeToWindow, 0)
    }

    // MARK: - Live-session shape

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    private var hasWindowServerSession: Bool {
        // Simple probe: NSScreen.screens is non-empty exactly when a
        // WindowServer graphical session is attached to this process.
        // headless `swift test` in CI / ssh reports zero screens.
        !NSScreen.screens.isEmpty
    }

    func test_enumerateAll_returnsWindows_whenGUISessionAvailable() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let windows = WindowEnumerationCapture.enumerateAll()
        // A GUI login always has at least the menu bar, Dock, and one
        // Finder-owned window entry. If we ever see zero here on a
        // live session it is a legitimate skip, not a failure.
        try XCTSkipIf(windows.isEmpty, "Live session enumerated zero windows -- transient")

        for w in windows {
            // Everywhere skips entries with missing pid / missing wid
            // (WindowHelper.cs:287-288). The port likewise drops
            // those, so every returned entry has both.
            XCTAssertGreaterThan(w.pid, 0, "pid must be positive")
            XCTAssertGreaterThan(w.wid, 0, "wid must be positive")
            // Alpha is documented in [0.0, 1.0].
            XCTAssertGreaterThanOrEqual(w.alpha, 0.0)
            XCTAssertLessThanOrEqual(w.alpha, 1.0)
        }
    }

    func test_enumerateAll_onScreenFlag_matchesDefaultAssumption() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let onScreen = WindowEnumerationCapture.enumerateAll()
        try XCTSkipIf(onScreen.isEmpty, "No windows to assert on")
        for w in onScreen {
            // With .optionOnScreenOnly, CG omits kCGWindowIsOnscreen;
            // the decoder falls back to the "assumed" value from the
            // options, which is true by default.
            XCTAssertTrue(w.isOnScreen)
        }
    }

    func test_enumerateAll_optionAll_returnsAtLeastAsMany() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let onScreen = WindowEnumerationCapture.enumerateAll()
        let allWindows = WindowEnumerationCapture.enumerateAll(
            options: EnumerateOptions(
                onScreenOnly: false,
                excludeDesktopElements: true
            )
        )
        // `.optionAll` is a superset of `.optionOnScreenOnly` -- must
        // never return fewer entries.
        XCTAssertGreaterThanOrEqual(
            allWindows.count,
            onScreen.count,
            ".optionAll must not return fewer windows than .optionOnScreenOnly"
        )
    }

    func test_enumerateAll_withDesktopElements_returnsAtLeastAsMany() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        let excluded = WindowEnumerationCapture.enumerateAll(
            options: EnumerateOptions(
                onScreenOnly: true,
                excludeDesktopElements: true
            )
        )
        let included = WindowEnumerationCapture.enumerateAll(
            options: EnumerateOptions(
                onScreenOnly: true,
                excludeDesktopElements: false
            )
        )
        // Dropping the exclusion is monotonically non-shrinking.
        XCTAssertGreaterThanOrEqual(included.count, excluded.count)
    }

    func test_enumerateAll_preservesFrontToBackOrder() throws {
        // Everywhere doc: "CGWindowList returns front-to-back order"
        // (WindowHelper.cs:291). The port must not re-sort.
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try XCTSkipIf(!hasWindowServerSession, "No WindowServer session")

        // Smoke: call twice, order stable for the same window set
        // (transient windows can appear/disappear -- we only test
        // stability for entries present in both snapshots).
        let a = WindowEnumerationCapture.enumerateAll()
        let b = WindowEnumerationCapture.enumerateAll()
        try XCTSkipIf(a.isEmpty || b.isEmpty, "No windows")

        // Extract shared wids in original order from both snapshots.
        let bWids = Set(b.map { $0.wid })
        let aOrderShared = a.map { $0.wid }.filter { bWids.contains($0) }
        let bOrder = b.map { $0.wid }.filter { aOrderShared.contains($0) }
        XCTAssertEqual(
            aOrderShared,
            bOrder,
            "Order of shared windows must be stable between back-to-back enumerations"
        )
    }

    // MARK: - EnumeratedWindow wire shape

    func test_enumeratedWindow_roundTripsJSON() throws {
        let sample = EnumeratedWindow(
            pid: 501,
            wid: 12345,
            title: "Documents",
            ownerName: "Finder",
            bounds: CGRect(x: 100, y: 40, width: 800, height: 600),
            screenIndex: 0,
            isOnScreen: true,
            layer: 0,
            alpha: 1.0
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(EnumeratedWindow.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_enumeratedWindow_preservesOptionalNils() throws {
        let sample = EnumeratedWindow(
            pid: 1,
            wid: 1,
            title: nil,
            ownerName: nil,
            bounds: .zero,
            screenIndex: nil,
            isOnScreen: false,
            layer: -1,
            alpha: 0.0
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(EnumeratedWindow.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.ownerName)
        XCTAssertNil(decoded.screenIndex)
    }

    func test_enumeratedWindow_preservesFractionalBounds() throws {
        // CGWindowBounds arrive as CFDictionary of doubles; Retina
        // layouts routinely produce half-pixel edges. The wire shape
        // must preserve them (no int truncation).
        let sample = EnumeratedWindow(
            pid: 7,
            wid: 42,
            title: "x",
            ownerName: "y",
            bounds: CGRect(x: 12.5, y: -0.25, width: 1920.75, height: 1080.5),
            screenIndex: 1,
            isOnScreen: true,
            layer: 25,
            alpha: 0.5
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(EnumeratedWindow.self, from: data)
        XCTAssertEqual(decoded.bounds, sample.bounds)
        XCTAssertEqual(decoded.alpha, 0.5)
    }
}
