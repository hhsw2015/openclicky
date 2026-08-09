// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs + src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for FocusedElementCapture. Everywhere has no direct
// unit tests here — `SnapshotRenderer` + `AXUIElement` are P/Invoke
// wrappers over live AX APIs. openclicky provides:
//   * Pure-guard tests that never hit the AX API (safe on headless CI).
//   * A gated live-Finder test that runs when a user session is
//     available AND `OPENCLICKY_SKIP_UI_TESTS` is unset.
//   * JSON round-trip tests to pin the wire shape of FocusedElementInfo.

import XCTest
import AppKit
import CoreGraphics
@testable import OpenClickyContextService

final class FocusedElementCaptureTests: XCTestCase {

    // MARK: - Guard behaviour (headless-safe)

    func test_capture_returnsNil_forZeroPid() {
        XCTAssertNil(FocusedElementCapture.capture(pid: 0),
                     "pid == 0 must short-circuit to nil")
    }

    func test_capture_returnsNil_forNegativePid() {
        XCTAssertNil(FocusedElementCapture.capture(pid: -1))
        XCTAssertNil(FocusedElementCapture.capture(pid: Int32.min))
    }

    func test_capture_returnsNil_forBogusPid() {
        // AXUIElementCreateApplication accepts any int; the subsequent
        // AXFocusedUIElement lookup returns an AX error -> nil.
        XCTAssertNil(FocusedElementCapture.capture(pid: Int32.max))
    }

    func test_capture_returnsNil_forCurrentTestHost() {
        // Swift test host is a headless executable; it has no focused
        // UI element even under a WindowServer session.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertNil(FocusedElementCapture.capture(pid: pid),
                     "windowless test host must yield nil, not crash")
    }

    // MARK: - Live capture (gated)

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    func test_capture_returnsElement_forFinder() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw XCTSkip("No frontmost app — no WindowServer session")
        }
        if frontmost.bundleIdentifier == "com.apple.loginwindow" {
            throw XCTSkip("Login window frontmost — no user session")
        }

        // Nudge Finder to the front; skip if the nudge doesn't take.
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

        guard let info = FocusedElementCapture.capture(pid: finderPid!) else {
            // Finder without a focused element is legitimate (all windows
            // closed / no keyboard focus).
            throw XCTSkip("Finder has no focused UI element")
        }
        XCTAssertEqual(info.pid, finderPid!)
        XCTAssertFalse(info.role.isEmpty,
                       "role must always be present on a returned element")
        XCTAssertFalse(info.isSecure,
                       "Finder should never expose a secure text field as its focus")
    }

    // MARK: - Secure-field contract

    func test_focusedElementInfo_isSecureImpliesNilValue() {
        // Contract check: if callers ever construct an isSecure=true
        // instance, they MUST leave value nil. This is enforced by
        // FocusedElementCapture.capture but the struct is public — pin
        // the invariant so downstream stash writers can rely on it.
        let sample = FocusedElementInfo(
            pid: 100,
            role: "AXTextField",
            subrole: "AXSecureTextField",
            title: nil,
            name: "Password",
            value: nil,
            placeholder: "Enter password",
            help: nil,
            description: nil,
            states: ["password"],
            actions: [],
            bounds: CGRect(x: 0, y: 0, width: 200, height: 24),
            isSecure: true
        )
        XCTAssertTrue(sample.isSecure)
        XCTAssertNil(sample.value)
        XCTAssertTrue(sample.states.contains("password"))
    }

    // MARK: - FocusedElementInfo shape

    func test_focusedElementInfo_roundTripsJSON() throws {
        let sample = FocusedElementInfo(
            pid: 4242,
            role: "AXButton",
            subrole: nil,
            title: "Submit",
            name: "Submit",
            value: nil,
            placeholder: nil,
            help: "Send the form",
            description: nil,
            states: ["focused"],
            actions: ["Press"],
            bounds: CGRect(x: 100, y: 200, width: 80, height: 30),
            isSecure: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FocusedElementInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_focusedElementInfo_preservesFractionalBounds() throws {
        let sample = FocusedElementInfo(
            pid: 7,
            role: "AXTextField",
            subrole: "AXSearchField",
            title: nil,
            name: nil,
            value: "hello",
            placeholder: "Search",
            help: nil,
            description: nil,
            states: [],
            actions: [],
            bounds: CGRect(x: 12.5, y: -0.25, width: 320.75, height: 24.5),
            isSecure: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FocusedElementInfo.self, from: data)
        XCTAssertEqual(decoded.bounds, sample.bounds)
    }

    func test_focusedElementInfo_preservesEmptyCollections() throws {
        let sample = FocusedElementInfo(
            pid: 1,
            role: "AXUnknown",
            subrole: nil,
            title: nil,
            name: nil,
            value: nil,
            placeholder: nil,
            help: nil,
            description: nil,
            states: [],
            actions: [],
            bounds: .zero,
            isSecure: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FocusedElementInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertTrue(decoded.states.isEmpty)
        XCTAssertTrue(decoded.actions.isEmpty)
        XCTAssertEqual(decoded.bounds, .zero)
    }
}
