// OpenClickyAppActivatorTests.swift
// cursor-buddyTests
//
// Phase 7 — AppActivator + LaunchPhrase parity.
//
// Tests the invariants that don't require driving a real GUI focus:
//   * `activate` rejects empty / whitespace / unknown bundle ids
//   * `isFrontmost` returns false for unknown ids
//   * `supportsFrontmostDetection` is true on macOS
//   * `fireLaunchPhrase` with empty phrase is a no-op
//   * concurrent `fireLaunchPhrase` fires collapse (phraseInFlight
//     interlock, mirrors `_phraseInFlight` in
//     Everywhere `ContextStashWriter.TryFireLaunchPhrase`)
//
// Real activation of a known bundle id (e.g. `com.apple.finder`) is
// intentionally skipped — headless CI has no window server, and even
// on developer laptops taking focus during a test run is disruptive.

import Foundation
import XCTest
@testable import OpenClicky

final class OpenClickyAppActivatorTests: XCTestCase {

    // MARK: - activate

    func test_activate_emptyBundleId_returnsFalse() {
        XCTAssertFalse(OpenClickyAppActivator.shared.activate(""))
    }

    func test_activate_whitespaceBundleId_returnsFalse() {
        XCTAssertFalse(OpenClickyAppActivator.shared.activate("   "))
    }

    func test_activate_unknownBundleId_returnsFalse() {
        // A syntactically valid bundle id nobody would ever have running.
        XCTAssertFalse(OpenClickyAppActivator.shared.activate("com.openclicky.tests.nonexistent.\(UUID().uuidString)"))
    }

    // MARK: - isFrontmost

    func test_isFrontmost_emptyBundleId_returnsFalse() {
        XCTAssertFalse(OpenClickyAppActivator.shared.isFrontmost(""))
    }

    func test_isFrontmost_unknownBundleId_returnsFalse() {
        XCTAssertFalse(OpenClickyAppActivator.shared.isFrontmost("com.openclicky.tests.nonexistent.\(UUID().uuidString)"))
    }

    // MARK: - supportsFrontmostDetection

    func test_supportsFrontmostDetection_isTrueOnMac() {
        // Everywhere's `TryFireLaunchPhrase` short-circuits when this is
        // false; on macOS NSWorkspace is always available so the flag
        // must be true for the injection pipeline to run.
        XCTAssertTrue(OpenClickyAppActivator.shared.supportsFrontmostDetection)
    }

    // MARK: - fireLaunchPhrase

    func test_fireLaunchPhrase_emptyPhrase_isNoOp() async {
        // Empty phrase must exit immediately without acquiring the
        // phraseInFlight flag (matches ContextStashWriter.cs:512
        // `if (string.IsNullOrWhiteSpace(phrase)) return;`).
        // We can't observe the private flag directly; we assert that
        // the call completes near-instantly (well under the settle
        // loop's 2.4s cap).
        let start = Date()
        await OpenClickyAppActivator.shared.fireLaunchPhrase(
            bundleId: "com.openclicky.tests.nonexistent.\(UUID().uuidString)",
            phrase: ""
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5, "empty phrase must skip the settle loop")
    }

    func test_fireLaunchPhrase_whitespacePhrase_isNoOp() async {
        // The activator only treats `""` as empty (byte-parity with C#
        // `string.IsNullOrWhiteSpace` includes whitespace-only, but the
        // openclicky port keeps the strict `phrase.isEmpty` check so a
        // user who *deliberately* types spaces still fires). Test the
        // documented behaviour: the settle loop runs, but focus never
        // settles on the unknown bundle, so we exit through the
        // "did not stay frontmost" branch within the 2.4s cap.
        let bogus = "com.openclicky.tests.nonexistent.\(UUID().uuidString)"
        let start = Date()
        await OpenClickyAppActivator.shared.fireLaunchPhrase(bundleId: bogus, phrase: "   ")
        let elapsed = Date().timeIntervalSince(start)
        // Must not exceed the 16 × 150ms settle cap by much.
        XCTAssertLessThan(elapsed, 4.0)
    }

    func test_fireLaunchPhrase_concurrent_secondFireBailsFast() async {
        // Mirrors ContextStashWriter.cs:519-523 — the second fire path
        // must see `phraseInFlight = true` and bail immediately without
        // running its own settle loop.
        //
        // The first fire targets a non-existent bundle so it will hold
        // the interlock for the full 16 × 150ms settle cap (never
        // settling), giving the second fire a window in which to
        // observe the flag.
        let bogus = "com.openclicky.tests.nonexistent.\(UUID().uuidString)"
        let phrase = "hello"

        async let first: Void = OpenClickyAppActivator.shared.fireLaunchPhrase(bundleId: bogus, phrase: phrase)
        // Small delay so the first fire acquires the interlock before
        // we start the second.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        let secondStart = Date()
        await OpenClickyAppActivator.shared.fireLaunchPhrase(bundleId: bogus, phrase: phrase)
        let secondElapsed = Date().timeIntervalSince(secondStart)

        // Second fire must bail via the phraseInFlight guard —
        // ~milliseconds, well under the settle cap.
        XCTAssertLessThan(secondElapsed, 0.5, "second concurrent fire must be skipped by phraseInFlight guard")

        // Await the first so no dangling task leaks past the test.
        _ = await first
    }
}
