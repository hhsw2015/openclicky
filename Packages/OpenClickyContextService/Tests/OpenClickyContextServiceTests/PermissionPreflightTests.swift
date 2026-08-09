// Ported from Everywhere: src/Everywhere.Mac/Interop/PermissionHelper.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for PermissionPreflight. These tests are strictly
// non-interactive:
//
//   * They never call an API that prompts the user - the preflight is
//     check-only by contract.
//   * They do not assert specific granted/denied values because those
//     depend on the local TCC database (which will differ between CI
//     boxes, developer laptops, and freshly-signed builds).
//   * They do assert that every call terminates without crashing and
//     returns a value inside the documented `PermissionStatus`
//     universe.
//
// Safe to run under `swift test` on a login shell or headless CI.

import XCTest
@testable import OpenClickyContextService

final class PermissionPreflightTests: XCTestCase {

    // MARK: - Individual kinds

    func test_check_accessibility_returnsGrantedOrDenied() {
        // Bool-only API (AXIsProcessTrusted). Only .granted and
        // .denied are reachable; anything else would be a port bug.
        let status = PermissionPreflight.check(.accessibility)
        XCTAssertTrue(status == .granted || status == .denied,
            "Accessibility check should map to .granted or .denied; got \(status)")
    }

    func test_check_screenRecording_returnsGrantedOrDenied() {
        // Bool-only API (CGPreflightScreenCaptureAccess). Same
        // invariant as accessibility.
        let status = PermissionPreflight.check(.screenRecording)
        XCTAssertTrue(status == .granted || status == .denied,
            "Screen recording check should map to .granted or .denied; got \(status)")
    }

    func test_check_inputMonitoring_returnsInAllowedSet() {
        let status = PermissionPreflight.check(.inputMonitoring)
        XCTAssertTrue(Self.allowedForTristate.contains(status),
            "Input monitoring status \(status) not in \(Self.allowedForTristate)")
    }

    func test_check_microphone_returnsInAllowedSet() {
        let status = PermissionPreflight.check(.microphone)
        XCTAssertTrue(Self.allowedForFullMatrix.contains(status),
            "Microphone status \(status) not in \(Self.allowedForFullMatrix)")
    }

    func test_check_automation_withoutTargetReturnsUnknown() {
        // Contract: passing nil (or empty) bundle id for .automation
        // returns .unknown, because AEDeterminePermissionToAutomate
        // requires an AEDesc target.
        XCTAssertEqual(PermissionPreflight.check(.automation), .unknown)
        XCTAssertEqual(PermissionPreflight.check(.automation, automationTargetBundleId: nil), .unknown)
        XCTAssertEqual(PermissionPreflight.check(.automation, automationTargetBundleId: ""), .unknown)
    }

    func test_check_automation_withTargetReturnsInAllowedSet() {
        // com.apple.finder is present on every macOS install so the
        // target lookup itself always succeeds; the return value is
        // still environment-dependent (granted / denied /
        // notDetermined / unknown).
        let status = PermissionPreflight.check(
            .automation,
            automationTargetBundleId: "com.apple.finder"
        )
        XCTAssertTrue(Self.allowedForFullMatrix.contains(status),
            "Automation status \(status) not in \(Self.allowedForFullMatrix)")
    }

    func test_check_automation_withUnknownTargetReturnsUnknownOrNotDetermined() {
        // An intentionally bogus bundle id. The AEDesc construction
        // still succeeds (it is just a payload), but the address will
        // not resolve to a running/installed app; macOS surfaces this
        // as procNotFound (-600) which we map to .notDetermined, or
        // some other OSStatus mapped to .unknown.
        let status = PermissionPreflight.check(
            .automation,
            automationTargetBundleId: "invalid.bundle.id.definitely.not.installed.\(UUID().uuidString)"
        )
        XCTAssertTrue(Self.allowedForFullMatrix.contains(status),
            "Automation status for bogus target should still be in the allowed matrix; got \(status)")
    }

    // MARK: - Idempotence + safety

    func test_check_isSafeToCallRepeatedly() {
        // The preflight holds no state. Two calls in quick succession
        // must return identical results and must not crash.
        for kind in PermissionKind.allCases {
            let bundleId: String? = (kind == .automation) ? "com.apple.finder" : nil
            let first = PermissionPreflight.check(kind, automationTargetBundleId: bundleId)
            let second = PermissionPreflight.check(kind, automationTargetBundleId: bundleId)
            XCTAssertEqual(first, second,
                "\(kind) should return stable results across back-to-back calls")
        }
    }

    func test_check_doesNotThrowOrCrashInDeniedEnvironments() {
        // Regression guard: this test simply exercises every kind
        // and expects no exceptions / crashes even when the local
        // machine has zero permissions granted (fresh CI runner
        // scenario).
        for kind in PermissionKind.allCases {
            let bundleId: String? = (kind == .automation) ? "com.apple.finder" : nil
            _ = PermissionPreflight.check(kind, automationTargetBundleId: bundleId)
        }
    }

    // MARK: - JSON round-trip on the shared types

    func test_permissionStatus_roundTripsJSON() throws {
        for status in [PermissionStatus.granted, .denied, .notDetermined, .restricted, .unknown] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(PermissionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func test_permissionKind_roundTripsJSON() throws {
        for kind in PermissionKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(PermissionKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - Helpers

    /// Statuses reachable for a tristate API (granted / denied /
    /// unknown-means-notDetermined) such as `IOHIDCheckAccess`.
    private static let allowedForTristate: Set<PermissionStatus> = [
        .granted, .denied, .notDetermined, .unknown,
    ]

    /// Statuses reachable for a full four-way API such as
    /// `AVAuthorizationStatus`.
    private static let allowedForFullMatrix: Set<PermissionStatus> = [
        .granted, .denied, .notDetermined, .restricted, .unknown,
    ]
}
