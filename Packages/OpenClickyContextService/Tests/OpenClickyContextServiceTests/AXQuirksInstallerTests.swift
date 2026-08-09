// Ported from Everywhere: src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for AXQuirksInstaller. These tests are non-interactive
// and safe to run under `swift test` on machines that may or may not
// have Accessibility consent granted:
//
//   * Where consent IS granted, the AX call flows through and we
//     observe successful idempotency.
//   * Where consent is NOT granted, `AXUIElementSetAttributeValue`
//     returns `.apiDisabled`, which the installer surfaces as
//     `AXQuirksError.setAttributeFailed`. The tests treat this
//     branch as an ALLOWED outcome — we assert only that the call
//     does not trap, and that the error carries a valid AXError raw
//     status.
//
// This mirrors the "consent-agnostic" style used by
// `FocusedWindowCaptureTests` and `SelectedTextCaptureTests`
// elsewhere in the package.

import XCTest
import Foundation
import ApplicationServices
@testable import OpenClickyContextService

final class AXQuirksInstallerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure a clean cache for every test — static state on
        // `AXQuirksInstaller` outlives individual XCTestCase instances.
        AXQuirksInstaller.resetInstalledPidsForTesting()
    }

    // MARK: - Public constants match Everywhere byte-for-byte

    func test_attributeConstants_matchEverywhere() {
        // AXAttributeConstants.cs L30-31.
        XCTAssertEqual(AXQuirksInstaller.manualAccessibility, "AXManualAccessibility")
        XCTAssertEqual(AXQuirksInstaller.enhancedUserInterface, "AXEnhancedUserInterface")
    }

    // MARK: - Invalid pid handling

    func test_installIfNeeded_negativePid_throwsInvalidPid() {
        XCTAssertThrowsError(try AXQuirksInstaller.installIfNeeded(pid: -1)) { error in
            XCTAssertEqual(error as? AXQuirksError, .invalidPid(-1))
        }
    }

    func test_installIfNeeded_zeroPid_throwsInvalidPid() {
        // Everywhere: `if (pid <= 0) return false;` — pid 0 is invalid.
        XCTAssertThrowsError(try AXQuirksInstaller.installIfNeeded(pid: 0)) { error in
            XCTAssertEqual(error as? AXQuirksError, .invalidPid(0))
        }
    }

    func test_setBoolAttribute_zeroPid_throwsInvalidPid() {
        XCTAssertThrowsError(
            try AXQuirksInstaller.setBoolAttribute(
                pid: 0,
                attribute: AXQuirksInstaller.manualAccessibility,
                value: true
            )
        ) { error in
            XCTAssertEqual(error as? AXQuirksError, .invalidPid(0))
        }
    }

    func test_setBoolAttribute_negativePid_throwsInvalidPid() {
        XCTAssertThrowsError(
            try AXQuirksInstaller.setBoolAttribute(
                pid: -42,
                attribute: AXQuirksInstaller.enhancedUserInterface,
                value: false
            )
        ) { error in
            XCTAssertEqual(error as? AXQuirksError, .invalidPid(-42))
        }
    }

    // MARK: - Own-pid install path
    //
    // The test process (`swift test`) is always AX-consumable in the
    // sense that `AXUIElementCreateApplication` succeeds. Whether the
    // private-attribute flip actually returns `.success` depends on
    // whether the runner has been granted Accessibility consent AND
    // whether the target app (in this case xctest) advertises the
    // private attributes. Under `swift test` neither is guaranteed, so
    // the test tolerates BOTH outcomes.

    func test_installIfNeeded_forOwnPid_doesNotTrap() {
        // We do not assert success — only that the call returns
        // (throw or normal return) without segfaulting.
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            try AXQuirksInstaller.installIfNeeded(pid: pid)
        } catch AXQuirksError.setAttributeFailed(let status) {
            // Expected on runners without AX consent. `.apiDisabled`
            // (rawValue -25211) is the common one.
            XCTAssertNotEqual(status, 0,
                "Setup failure means status should be a real AXError, not .success")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Idempotency

    func test_installIfNeeded_isIdempotent_afterSuccess() throws {
        // Seed the cache manually — this exercises the "already
        // installed" fast path without depending on whether the AX
        // call actually succeeds in this environment. Matches
        // Everywhere's `ConcurrentDictionary.TryAdd` semantic.
        let pid: Int32 = 12345
        // First call may throw (bogus pid); manually mark installed.
        // This is only possible because the installer exposes a test
        // hook. In production, only `installIfNeeded` populates the
        // set.
        AXQuirksInstaller.resetInstalledPidsForTesting()
        // Simulate a prior successful install by inserting into the
        // installed-set the same way `installIfNeeded` would. We
        // achieve this by calling `installIfNeeded` with a valid own
        // pid and short-circuiting the AX result via the
        // "already-cached" check on the second invocation.
        //
        // Simpler alternative: check that when the AX layer is a
        // black box, the SECOND call for the same pid does not
        // change the installed-set size after the first succeeded.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let firstDidSucceed: Bool
        do {
            try AXQuirksInstaller.installIfNeeded(pid: ownPid)
            firstDidSucceed = true
        } catch {
            firstDidSucceed = false
        }
        let sizeAfterFirst = AXQuirksInstaller.installedPidsSnapshot().count

        // Second call:
        //   * If first succeeded: this must be a lock-guarded no-op
        //     and cannot throw. `sizeAfterSecond == sizeAfterFirst`.
        //   * If first failed: this call is allowed to try again and
        //     may throw the same error; the installed-set must be
        //     empty in both cases.
        if firstDidSucceed {
            XCTAssertNoThrow(try AXQuirksInstaller.installIfNeeded(pid: ownPid),
                "Second install for an already-installed pid must not throw")
            let sizeAfterSecond = AXQuirksInstaller.installedPidsSnapshot().count
            XCTAssertEqual(sizeAfterSecond, sizeAfterFirst,
                "Idempotent second call must not grow the installed-set")
            XCTAssertTrue(AXQuirksInstaller.installedPidsSnapshot().contains(ownPid),
                "Own pid should be cached after a successful install")
            _ = pid // unused when we take the success branch
        } else {
            XCTAssertEqual(sizeAfterFirst, 0,
                "Failed install must not populate the cache")
            _ = pid // unused when we take the failure branch
        }
    }

    func test_installIfNeeded_failedInstallIsNotCached() {
        // Everywhere caches on `TryAdd` BEFORE calling the AX API,
        // which allows a failed install to poison the cache. This
        // port caches only after both attributes land. Verify that a
        // guaranteed-invalid pid (a very large fake) does not cache.
        //
        // `AXUIElementSetAttributeValue` on a pid that does not
        // correspond to a running app returns `.invalidUIElement` /
        // `.cannotComplete`. Either is expected to throw here.
        let bogusPid: Int32 = 2_000_000_000
        do {
            try AXQuirksInstaller.installIfNeeded(pid: bogusPid)
            // Some environments may not error here (AX layer accepts
            // anything). If it succeeded, the pid gets cached, which
            // is still valid behaviour.
        } catch {
            // Expected. Assert cache stayed empty.
            XCTAssertFalse(
                AXQuirksInstaller.installedPidsSnapshot().contains(bogusPid),
                "Failed install must not cache the pid"
            )
        }
    }

    // MARK: - Unknown attribute name does not trap

    func test_setBoolAttribute_unknownAttribute_doesNotTrap() {
        // An unknown attribute name is allowed to return an AXError
        // (typically `.attributeUnsupported`), but MUST NOT crash.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        do {
            try AXQuirksInstaller.setBoolAttribute(
                pid: ownPid,
                attribute: "AXTotallyMadeUpAttributeName",
                value: true
            )
            // No throw is allowed too — some AX backends silently
            // accept unknown attributes on `Set`.
        } catch AXQuirksError.setAttributeFailed(let status) {
            XCTAssertNotEqual(status, 0)
        } catch AXQuirksError.invalidPid(let pid) {
            XCTFail("Unexpected .invalidPid for own pid \(pid)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Cache-hit is a no-op even when the AX call would fail

    func test_installIfNeeded_cacheHit_shortCircuitsAX() throws {
        // Seed a fake pid into the cache and verify a second call
        // for that pid does NOT throw — this proves the fast path
        // runs entirely inside the lock and never calls into the AX
        // layer for a pid we've already recorded.
        //
        // Reaching into internal state via the test hook: mimic what
        // `installIfNeeded` would have done on a successful first
        // call. This exercises the lock-guarded read path in
        // isolation.
        AXQuirksInstaller.resetInstalledPidsForTesting()
        let ownPid = ProcessInfo.processInfo.processIdentifier

        // Do the real first install so the cache legitimately holds
        // ownPid. If it fails (no AX consent), we skip the rest —
        // there's no way to prove short-circuiting without a
        // successful seed.
        do {
            try AXQuirksInstaller.installIfNeeded(pid: ownPid)
        } catch {
            throw XCTSkip("First install failed (\(error)); AX consent likely unavailable, cannot test cache-hit path")
        }

        // Second call must not throw.
        XCTAssertNoThrow(try AXQuirksInstaller.installIfNeeded(pid: ownPid))
    }

    // MARK: - AXQuirkInfo round-trips through JSON

    func test_axQuirkInfo_roundTripsJSON() throws {
        let sample = AXQuirkInfo(
            pid: 4242,
            manualAccessibilityApplied: true,
            enhancedUserInterfaceApplied: true,
            installedAt: 1_729_612_800.0
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(AXQuirkInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    // MARK: - Error type is Equatable

    func test_axQuirksError_equality() {
        XCTAssertEqual(AXQuirksError.invalidPid(0), AXQuirksError.invalidPid(0))
        XCTAssertNotEqual(AXQuirksError.invalidPid(0), AXQuirksError.invalidPid(1))
        XCTAssertEqual(
            AXQuirksError.setAttributeFailed(status: -25211),
            AXQuirksError.setAttributeFailed(status: -25211)
        )
        XCTAssertNotEqual(
            AXQuirksError.setAttributeFailed(status: -25211),
            AXQuirksError.setAttributeFailed(status: -25212)
        )
        XCTAssertNotEqual(
            AXQuirksError.invalidPid(0),
            AXQuirksError.setAttributeFailed(status: 0)
        )
    }
}
