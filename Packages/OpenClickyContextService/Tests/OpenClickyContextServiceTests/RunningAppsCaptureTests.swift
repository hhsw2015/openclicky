// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for RunningAppsCapture. Runs under both Xcode and
// `swift test` — no UI activation is required because
// `NSWorkspace.shared.runningApplications` returns a non-empty list
// even in a headless test process (it always contains the test host).

import XCTest
import AppKit
@testable import OpenClickyContextService

final class RunningAppsCaptureTests: XCTestCase {

    // Skip UI-touching subtests when the harness sets this flag.
    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    // MARK: - Core contract

    func test_list_returnsNonEmpty_onAnyMac() {
        // The test process itself is a running app, so this list is
        // guaranteed to contain at least one entry on any live Mac.
        let apps = RunningAppsCapture.list()
        XCTAssertFalse(apps.isEmpty, "runningApplications must include at least this process")
    }

    func test_list_everyEntryHasPositivePid() {
        let apps = RunningAppsCapture.list()
        for app in apps {
            XCTAssertGreaterThan(
                app.processId, 0,
                "Everywhere drops pid <= 0 entries (VisualElementContext.cs:105)"
            )
        }
    }

    func test_list_dropsProhibitedActivationPolicy() {
        // Mirror of Everywhere's `activationPolicy == Prohibited continue`
        // (VisualElementContext.cs:103).
        let apps = RunningAppsCapture.list()
        for app in apps {
            XCTAssertNotEqual(
                app.activationPolicy, .prohibited,
                "\(app.name ?? app.bundleId ?? "?") slipped past the Prohibited filter"
            )
        }
    }

    // MARK: - Order stability across quick reads

    func test_list_orderIsStableAcrossImmediateReads() {
        // NSWorkspace's documented contract does not promise ordering, but
        // empirically consecutive reads with no launch/exit event yield
        // identical pid sequences. Snap two reads back-to-back and compare.
        let first = RunningAppsCapture.list().map(\.processId)
        let second = RunningAppsCapture.list().map(\.processId)
        // The set of pids should match — if a launch/exit happens between
        // the two calls we tolerate it (asymmetric-difference small).
        let firstSet = Set(first)
        let secondSet = Set(second)
        let churn = firstSet.symmetricDifference(secondSet)
        XCTAssertLessThanOrEqual(
            churn.count, 2,
            "Excessive pid churn between back-to-back reads: \(churn)"
        )
        // On the pids common to both, order should be preserved.
        let firstFiltered = first.filter { firstSet.intersection(secondSet).contains($0) }
        let secondFiltered = second.filter { firstSet.intersection(secondSet).contains($0) }
        XCTAssertEqual(
            firstFiltered, secondFiltered,
            "Order of stable pids diverged across immediate reads"
        )
    }

    // MARK: - Field population smoke tests

    func test_list_containsCurrentProcess_whenRegisteredWithLaunchServices() throws {
        // NSWorkspace.runningApplications only enumerates processes registered
        // with LaunchServices (typically .app bundles or accessory apps that
        // called TransformProcessType). A `swift test` host is a bare CLI
        // binary that will NOT appear here — we skip in that case rather than
        // failing on a legitimate LaunchServices-absent path.
        let pid = ProcessInfo.processInfo.processIdentifier
        let apps = RunningAppsCapture.list()
        let policy = NSRunningApplication.current.activationPolicy
        if policy == .prohibited {
            XCTAssertNil(
                apps.first(where: { $0.processId == pid }),
                "Prohibited test host should have been filtered out"
            )
            return
        }
        if apps.first(where: { $0.processId == pid }) == nil {
            throw XCTSkip("Test host not registered with LaunchServices — expected under `swift test`")
        }
    }

    func test_list_fieldsMatchNSRunningApplication() throws {
        // Cross-check one entry (the test host is the easiest to introspect).
        try XCTSkipIf(
            NSRunningApplication.current.activationPolicy == .prohibited,
            "Test host is Prohibited, cannot cross-check"
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let apps = RunningAppsCapture.list()
        guard let entry = apps.first(where: { $0.processId == pid }) else {
            throw XCTSkip("Test host not registered with LaunchServices — see test_list_containsCurrentProcess…")
        }
        let live = NSRunningApplication.current
        XCTAssertEqual(entry.bundleId, live.bundleIdentifier)
        // localizedName can legitimately be nil for the swift-testrunner.
        XCTAssertEqual(entry.name, live.localizedName)
        XCTAssertEqual(entry.executableName, live.executableURL?.lastPathComponent)
        XCTAssertEqual(entry.isHidden, live.isHidden)
        XCTAssertEqual(entry.isFinishedLaunching, live.isFinishedLaunching)
        XCTAssertEqual(entry.ownsMenuBar, live.ownsMenuBar)
        XCTAssertEqual(entry.launchDate, live.launchDate)
    }

    // MARK: - Optional UI-gated: Finder should be running on any user session

    func test_list_includesFinder_onUserSession() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        let apps = RunningAppsCapture.list()
        let hasFinder = apps.contains(where: { $0.bundleId == "com.apple.finder" })
        // Finder can be missing on a fully headless VM. When we cannot find
        // it AND there is no user WindowServer session, skip rather than fail.
        if !hasFinder {
            let hasAnyRegular = apps.contains(where: { $0.activationPolicy == .regular })
            if !hasAnyRegular {
                throw XCTSkip("No Regular apps present — likely headless session")
            }
            XCTFail("Finder expected on a live user session but was not present")
        }
    }

    // MARK: - JSON round-trip

    func test_runningAppInfo_roundTripsJSON() throws {
        let launched = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = RunningAppInfo(
            processId: 424242,
            bundleId: "com.apple.finder",
            name: "Finder",
            executableName: "Finder",
            activationPolicy: .regular,
            isHidden: false,
            isFinishedLaunching: true,
            ownsMenuBar: false,
            launchDate: launched
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = try encoder.encode(sample)
        let decoded = try decoder.decode(RunningAppInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_runningAppInfo_nilOptionalFieldsRoundTrip() throws {
        let sample = RunningAppInfo(
            processId: 1,
            bundleId: nil,
            name: nil,
            executableName: nil,
            activationPolicy: .accessory,
            isHidden: false,
            isFinishedLaunching: false,
            ownsMenuBar: false,
            launchDate: nil
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(RunningAppInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }
}
