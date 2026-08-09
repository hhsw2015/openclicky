// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacIdleTimeReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for IdleTimeCapture. These tests are non-interactive
// and safe to run under `swift test` on a login shell / CI runner - no
// WindowServer or user session required. CoreGraphics's
// `CGEventSourceSecondsSinceLastEventType` returns a reading even when
// no GUI session is attached; the reading may be 0 on very fresh
// sessions but is never negative in practice.

import XCTest
@testable import OpenClickyContextService

final class IdleTimeCaptureTests: XCTestCase {

    func test_capture_returnsNonNilReading() {
        let info = IdleTimeCapture.capture()
        XCTAssertNotNil(info, "CoreGraphics should always return a non-negative idle-time reading")
    }

    func test_capture_returnsNonNegativeSeconds() throws {
        guard let info = IdleTimeCapture.capture() else {
            XCTFail("Expected a non-nil idle-time reading")
            return
        }
        XCTAssertGreaterThanOrEqual(info.seconds, 0,
            "Idle-time reading must be >= 0; got \(info.seconds)")
    }

    func test_capture_monotonicallyIncreasesWithoutInput() throws {
        // Two calls separated by a short sleep. Because the test process
        // does not inject input events, the second reading must be >=
        // the first (idle time only resets when input arrives).
        guard let first = IdleTimeCapture.capture() else {
            XCTFail("Expected a non-nil first reading")
            return
        }
        let sleepSeconds: TimeInterval = 0.25
        Thread.sleep(forTimeInterval: sleepSeconds)
        guard let second = IdleTimeCapture.capture() else {
            XCTFail("Expected a non-nil second reading")
            return
        }
        // Allow a tiny tolerance in case another process (e.g. the test
        // harness itself) posts a stray event during the sleep. In
        // practice `second` should be roughly `first + sleepSeconds`.
        XCTAssertGreaterThanOrEqual(second.seconds, first.seconds - 0.05,
            "Idle time should not go backwards without input (first=\(first.seconds), second=\(second.seconds))")
    }

    func test_capture_doesNotCrashOnColdCall() {
        // Regression guard: the very first call in a fresh process must
        // not require any prior setup. XCTest's harness has already
        // spun up before this test runs, but the assertion is still
        // meaningful because IdleTimeCapture holds no state.
        _ = IdleTimeCapture.capture()
    }

    func test_idleTimeInfo_roundTripsJSON() throws {
        let sample = IdleTimeInfo(seconds: 12.5)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(IdleTimeInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_idleTimeInfo_zeroSecondsIsValid() throws {
        // Everywhere returns 0.0 both for "user just typed" and for its
        // catch-all error path. Ensure the type accepts 0 without any
        // special handling.
        let sample = IdleTimeInfo(seconds: 0)
        XCTAssertEqual(sample.seconds, 0)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(IdleTimeInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }
}
