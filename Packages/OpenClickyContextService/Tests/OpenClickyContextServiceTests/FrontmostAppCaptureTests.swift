// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/AppKey.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for FrontmostAppCapture + AppKeyResolver.
//
// These tests are written to compile & run under either XCTest bundle
// (Xcode test target) or `swift test` if a Package.swift is later added.
// They must NOT be run headlessly on a machine without a WindowServer —
// `NSWorkspace.shared.frontmostApplication` requires an active user
// session. The activation-based tests use osascript to nudge Finder to
// the front; the harness may skip them via the OPENCLICKY_SKIP_UI_TESTS
// environment variable if run in CI.
//
// Per project rules: DO NOT run xcodebuild from terminal. This file is
// authored for later manual execution inside Xcode.

import XCTest
import AppKit
@testable import OpenClickyContextService

final class AppKeyResolverTests: XCTestCase {

    // MARK: AppKeyResolver.fromProcessId — matches AppKey.cs contract

    func test_fromProcessId_returnsUnknown_forZeroPid() {
        XCTAssertEqual(AppKeyResolver.fromProcessId(0), "unknown")
    }

    func test_fromProcessId_returnsUnknown_forNegativePid() {
        XCTAssertEqual(AppKeyResolver.fromProcessId(-1), "unknown")
        XCTAssertEqual(AppKeyResolver.fromProcessId(Int32.min), "unknown")
    }

    func test_fromProcessId_returnsPidString_forNonexistentPid() {
        // Pid unlikely to exist. Everywhere: `catch { return pid.ToString() }`.
        // Even if by fluke it exists, the assertion below (length > 0) still holds.
        let key = AppKeyResolver.fromProcessId(999_999)
        XCTAssertFalse(key.isEmpty)
        // Should be either "999999" (nonexistent) or a lowercase name (unlikely collision).
        XCTAssertEqual(key, key.lowercased(), "AppKey must be all-lowercase")
    }

    func test_fromProcessId_returnsLowercase_forCurrentProcess() {
        // Our own pid always resolves — NSRunningApplication.current handles this.
        let pid = ProcessInfo.processInfo.processIdentifier
        let key = AppKeyResolver.fromProcessId(pid)
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(key, key.lowercased())
    }

    // MARK: AppKeyResolver.matchesQuery — matches AppKey.cs:31-40

    func test_matchesQuery_returnsFalse_forEmptyQuery() {
        XCTAssertFalse(AppKeyResolver.matchesQuery("finder", query: ""))
        XCTAssertFalse(AppKeyResolver.matchesQuery("finder", query: "   "))
        XCTAssertFalse(AppKeyResolver.matchesQuery("finder", query: "\n\t"))
    }

    func test_matchesQuery_caseInsensitiveEquality() {
        XCTAssertTrue(AppKeyResolver.matchesQuery("finder", query: "FINDER"))
        XCTAssertTrue(AppKeyResolver.matchesQuery("Finder", query: "finder"))
    }

    func test_matchesQuery_caseInsensitiveSubstring() {
        XCTAssertTrue(AppKeyResolver.matchesQuery("com.apple.finder", query: "apple"))
        XCTAssertTrue(AppKeyResolver.matchesQuery("com.apple.finder", query: "FINDER"))
        XCTAssertFalse(AppKeyResolver.matchesQuery("com.apple.finder", query: "chrome"))
    }
}

final class FrontmostAppCaptureTests: XCTestCase {

    // Skip UI-touching tests when running in CI / headless.
    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    /// Bring an app to the front via osascript and wait for NSWorkspace
    /// to catch up. Returns after up to `timeout` seconds.
    private func activate(bundleId: String, timeout: TimeInterval = 3.0) {
        let script = "tell application id \"\(bundleId)\" to activate"
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
        proc.waitUntilExit()

        // Poll until NSWorkspace reports the target bundle as frontmost.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func test_capture_returnsNonNil_whenAnyAppFrontmost() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        // On a live user session, some app is always frontmost.
        let info = FrontmostAppCapture.capture()
        XCTAssertNotNil(info)
    }

    func test_capture_matchesFinder_afterActivation() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        // `swift test` runs without an active WindowServer session — the
        // frontmost app is usually `loginwindow`, and `NSWorkspace.activate`
        // is a no-op. Detect that and skip; the test only makes sense when
        // run inside Xcode with a real user session.
        if let pre = FrontmostAppCapture.capture(),
           pre.bundleId == "com.apple.loginwindow" {
            throw XCTSkip("No user WindowServer session — run inside Xcode for this test")
        }
        activate(bundleId: "com.apple.finder")

        guard let info = FrontmostAppCapture.capture() else {
            XCTFail("Expected a frontmost app after activating Finder")
            return
        }
        XCTAssertEqual(info.bundleId, "com.apple.finder")
        XCTAssertGreaterThan(info.processId, 0)
        XCTAssertEqual(info.appKey, "finder")
        // Finder is a Regular app.
        XCTAssertEqual(info.activationPolicy, .regular)
    }

    func test_capture_pidAlwaysPositive() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        guard let info = FrontmostAppCapture.capture() else {
            throw XCTSkip("No frontmost application reported")
        }
        XCTAssertGreaterThan(info.processId, 0)
    }

    func test_capture_appKeyNeverEmpty() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        guard let info = FrontmostAppCapture.capture() else {
            throw XCTSkip("No frontmost application reported")
        }
        XCTAssertFalse(info.appKey.isEmpty)
        XCTAssertEqual(info.appKey, info.appKey.lowercased())
    }

    // MARK: JSON round-trip — ensures snapshot format stays stable.

    func test_frontmostAppInfo_roundTripsJSON() throws {
        let sample = FrontmostAppInfo(
            processId: 42,
            bundleId: "com.apple.finder",
            localizedName: "Finder",
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            appKey: "finder",
            activationPolicy: .regular
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FrontmostAppInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_capture_afterActivatingNonexistentApp_doesNotCrash() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        // Try to activate a bogus bundle id. osascript will error out
        // silently and the frontmost app stays whatever it was.
        activate(bundleId: "com.openclicky.definitely-not-installed", timeout: 1.0)
        let info = FrontmostAppCapture.capture()
        // Whatever the previous frontmost was, we should still get *something*
        // and it must be internally consistent.
        if let info {
            XCTAssertGreaterThan(info.processId, 0)
            XCTAssertFalse(info.appKey.isEmpty)
        }
    }
}
