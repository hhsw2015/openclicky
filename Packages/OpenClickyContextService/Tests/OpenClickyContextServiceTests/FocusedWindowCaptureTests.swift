// Ported from Everywhere: src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for FocusedWindowCapture. Everywhere's C# side has no
// direct unit tests for `FreshFocusedWindowOf` — it's a P/Invoke around
// live AX APIs that require a WindowServer session and Accessibility
// consent. openclicky provides:
//   * Pure-guard tests that never hit the AX API (safe on headless CI).
//   * A gated live-Finder test that runs when a user session is
//     available AND `OPENCLICKY_SKIP_UI_TESTS` is unset.
//   * JSON round-trip tests to pin the wire shape of FocusedWindowInfo.
//
// Per project rules: no `xcodebuild`. `AXUIElementCopyAttributeValue`
// on a non-consented pid returns `.apiDisabled` / `.notImplemented`;
// the wrapper surfaces those as nil, which is what the guard tests
// assert.

import XCTest
import AppKit
import CoreGraphics
@testable import OpenClickyContextService

final class FocusedWindowCaptureTests: XCTestCase {

    // MARK: - Guard behaviour (headless-safe)

    func test_capture_returnsNil_forZeroPid() {
        XCTAssertNil(FocusedWindowCapture.capture(processId: 0),
                     "pid == 0 must short-circuit to nil (matches C# `pid <= 0` guard)")
    }

    func test_capture_returnsNil_forNegativePid() {
        XCTAssertNil(FocusedWindowCapture.capture(processId: -1))
        XCTAssertNil(FocusedWindowCapture.capture(processId: Int32.min))
    }

    func test_capture_returnsNil_forBogusPid() {
        // Astronomically-unlikely pid. AXUIElementCreateApplication
        // returns a ref anyway (private API doesn't validate), but the
        // subsequent attribute reads all fail so both AXFocusedWindow
        // and AXMainWindow miss -> nil.
        XCTAssertNil(FocusedWindowCapture.capture(processId: Int32.max))
    }

    func test_capture_returnsNil_forCurrentTestHost() {
        // Swift test host is a headless executable; it has no windows.
        // Both AXFocusedWindow and AXMainWindow must miss -> nil.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertNil(FocusedWindowCapture.capture(processId: pid),
                     "windowless test host must yield nil, not crash")
    }

    // MARK: - Live capture (gated)

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    func test_capture_returnsFocusedWindow_forFinder() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")

        // Needs a live user WindowServer session with Accessibility
        // consent for the test host binary. `swift test` under CI /
        // ssh does not satisfy this — detect the absence of a
        // frontmost app and skip.
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw XCTSkip("No frontmost app — no WindowServer session")
        }
        if frontmost.bundleIdentifier == "com.apple.loginwindow" {
            throw XCTSkip("Login window frontmost — no user session")
        }

        // Try to nudge Finder to the front. If it doesn't take (perm
        // denied / osascript missing), skip rather than fail.
        let script = "tell application \"Finder\" to activate"
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
        proc.waitUntilExit()

        let deadline = Date().addingTimeInterval(2.0)
        var finderPid: Int32?
        while Date() < deadline {
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier == "com.apple.finder" {
                finderPid = app.processIdentifier
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try XCTSkipIf(finderPid == nil, "Finder did not come to front")

        guard let info = FocusedWindowCapture.capture(processId: finderPid!) else {
            // Finder can be frontmost with zero windows open (all closed).
            // That's a legitimate nil, not a test failure.
            throw XCTSkip("Finder has no focused window")
        }

        XCTAssertEqual(info.processId, finderPid!)
        // Title may be nil for a fresh Finder session, but frame should
        // be a real window when we do get a hit.
        XCTAssertGreaterThan(info.frame.width, 0)
        XCTAssertGreaterThan(info.frame.height, 0)
        XCTAssertNotNil(info.displayIndex,
                        "focused Finder window should intersect some screen")
    }

    // MARK: - FocusedWindowInfo shape

    func test_focusedWindowInfo_roundTripsJSON() throws {
        let sample = FocusedWindowInfo(
            processId: 4242,
            title: "Documents",
            frame: CGRect(x: 100, y: 40, width: 800, height: 600),
            displayIndex: 0,
            isMinimized: false,
            isMainWindow: true
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FocusedWindowInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_focusedWindowInfo_preservesNilTitleAndDisplay() throws {
        // Windows without titles / off-screen windows are legitimate.
        let sample = FocusedWindowInfo(
            processId: 1,
            title: nil,
            frame: .zero,
            displayIndex: nil,
            isMinimized: true,
            isMainWindow: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FocusedWindowInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.displayIndex)
        XCTAssertTrue(decoded.isMinimized)
        XCTAssertFalse(decoded.isMainWindow)
    }

    func test_focusedWindowInfo_frameSurvivesFractionalCoords() throws {
        // AXPosition/AXSize are CGFloat, and AXWindow rects can come back
        // with fractional edges on Retina displays. The wire shape must
        // preserve them verbatim (no int truncation).
        let sample = FocusedWindowInfo(
            processId: 7,
            title: "x",
            frame: CGRect(x: 12.5, y: -0.25, width: 1920.75, height: 1080.5),
            displayIndex: 1,
            isMinimized: false,
            isMainWindow: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FocusedWindowInfo.self, from: data)
        XCTAssertEqual(decoded.frame, sample.frame)
    }
}
