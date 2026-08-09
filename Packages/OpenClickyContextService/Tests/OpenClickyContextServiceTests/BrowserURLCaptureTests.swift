// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacBrowserUrlReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for BrowserURLCapture. Everywhere's C# unit tests do
// not exercise `MacBrowserUrlReader` directly (it is P/Invoke to the
// live AX API and can only be run on a macOS session with Accessibility
// consent). openclicky provides:
//   * Pure-guard tests that do not depend on any running browser and
//     are safe to run under `swift test` on a headless CI runner.
//   * A gated live-Safari test that only runs when Safari is already
//     open and `OPENCLICKY_SKIP_UI_TESTS` is not set; skipped otherwise.
//   * Round-trip JSON tests for `BrowserURLInfo`.
//
// Per project rules: no `xcodebuild`, no test that requires a fresh
// TCC prompt. `AXUIElementCopyAttributeValue` on a non-consented pid
// returns `.apiDisabled` / `.noValue` and the capture surfaces that
// as `nil`, which is exactly what the guard tests assert.

import XCTest
import AppKit
@testable import OpenClickyContextService

final class BrowserURLCaptureTests: XCTestCase {

    // MARK: - Guard behaviour (headless-safe)

    func test_capture_returnsNil_forNilPid() async {
        let result = await BrowserURLCapture.capture(processId: nil)
        XCTAssertNil(result, "nil pid must short-circuit to nil (matches C# `pid <= 0` guard)")
    }

    func test_capture_returnsNil_forZeroPid() async {
        let result = await BrowserURLCapture.capture(processId: 0)
        XCTAssertNil(result, "pid == 0 must return nil per Everywhere's guard")
    }

    func test_capture_returnsNil_forNegativePid() async {
        let result = await BrowserURLCapture.capture(processId: -1)
        XCTAssertNil(result, "pid < 0 must return nil per Everywhere's guard")
    }

    func test_capture_returnsNil_forBogusPid() async {
        // Deliberately-large pid that is astronomically unlikely to map
        // to a running process. Everywhere's C# path returns nil when
        // the AX app element has no focused UI; ours does too.
        let result = await BrowserURLCapture.capture(processId: Int32.max)
        XCTAssertNil(result, "bogus pid must return nil, not crash")
    }

    func test_capture_returnsNil_forCurrentTestHost() async {
        // The Swift test harness is a plain executable; it has no
        // browser web area focused, so AXURL walk must yield nil.
        // This test verifies the walk terminates cleanly (does not
        // crash / does not spin) even when the target pid is a real
        // running non-browser process.
        let pid = ProcessInfo.processInfo.processIdentifier
        let result = await BrowserURLCapture.capture(processId: pid)
        XCTAssertNil(result, "non-browser process must not surface a URL")
    }

    // MARK: - Optional live browser test

    func test_capture_returnsURL_whenSafariIsFrontmostWithPage() async throws {
        // Skip when the test runner opts out of UI-touching tests, or
        // when Safari is not running. This test is best-effort — it is
        // valuable when a developer runs it locally with Safari open
        // to a real page, and harmless (skipped) otherwise.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil,
            "OPENCLICKY_SKIP_UI_TESTS set; skipping live-browser probe"
        )

        let safari = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.Safari" }
        try XCTSkipIf(safari == nil, "Safari not running; skipping live-browser probe")
        try XCTSkipIf(
            !NSWorkspace.shared.isFrontmostApp(bundleId: "com.apple.Safari"),
            "Safari not frontmost; AX focused-element walk would target a different app"
        )

        guard let pid = safari?.processIdentifier else {
            XCTFail("Safari pid missing after skip guard")
            return
        }

        // Best-effort: if the user's frontmost Safari window has no
        // page focused (e.g. bookmarks manager) the walk may still
        // return nil. Assert only the shape when we do get a hit.
        if let info = await BrowserURLCapture.capture(processId: pid) {
            XCTAssertEqual(info.processId, pid)
            XCTAssertFalse(info.url.isEmpty, "captured URL must be non-empty")
        }
    }

    // MARK: - BrowserURLInfo shape

    func test_browserURLInfo_roundTripsJSON() throws {
        let sample = BrowserURLInfo(processId: 4242, url: "https://example.com/path?q=1#frag")
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(BrowserURLInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_browserURLInfo_preservesSchemeAndFragmentVerbatim() throws {
        // Everywhere returns AXURL as-is, without normalisation. Any
        // scheme (including `chrome://newtab/` / `favorites://`) must
        // round-trip untouched.
        let quirks = [
            "chrome://newtab/",
            "favorites://",
            "https://user:pass@example.com/",
            "file:///Users/me/index.html#section",
        ]
        for raw in quirks {
            let sample = BrowserURLInfo(processId: 1, url: raw)
            let data = try JSONEncoder().encode(sample)
            let decoded = try JSONDecoder().decode(BrowserURLInfo.self, from: data)
            XCTAssertEqual(decoded.url, raw, "URL must round-trip verbatim: \(raw)")
        }
    }
}

// MARK: - NSWorkspace test helper

private extension NSWorkspace {
    /// Small helper so the live-Safari test can gate on "Safari is
    /// frontmost" without pulling in the FrontmostAppCapture struct
    /// (different capture, don't want a cross-test dependency).
    func isFrontmostApp(bundleId: String) -> Bool {
        frontmostApplication?.bundleIdentifier == bundleId
    }
}
