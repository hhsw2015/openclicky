// OpenClicky-unique capability. See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 28.
//
// Hermetic XCTest coverage for `RecentSessionsCapture`. Every fixture is
// materialised under a fresh directory in `NSTemporaryDirectory()` and torn
// down in `tearDown`. Dates use fixed values (relative to a fixed `now`) so
// the >30d staleness gate is deterministic on CI.

import XCTest
@testable import OpenClickyContextService

final class RecentSessionsCaptureTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for root in tempRoots {
            try? fm.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(
            "openclicky-recentsessions-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        tempRoots.append(dir)
        return dir
    }

    /// Matches `OpenClickyJSONFileStore.defaultEncoder` in production:
    /// pretty-printed, sorted keys, default `Date` policy (double
    /// seconds-since-reference-date). Keeping the encoder identical
    /// means the fixtures below decode via the exact same path the app
    /// writes with.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Mirrors the on-disk `ChatWorkspaceArchiveStore.Snapshot` shape
    /// exactly — only the fields the capture consumes are needed but
    /// all are declared so the JSON matches the production layout.
    private struct FixtureEntry: Codable {
        var id: String
        var role: String
        var text: String
        var createdAt: Date
    }

    private struct FixtureSnapshot: Codable {
        var id: UUID
        var title: String
        var accentThemeRawValue: String
        var entries: [FixtureEntry]
        var activeThreadID: String?
        var lastSubmittedPrompt: String?
        var createdAt: Date?
        var latestActivityAt: Date?
        var wasRelaunchResumeCandidate: Bool?
        var activeTurnID: String?
        var activeLeaseID: String?
        var leaseExpiresAt: Date?
    }

    private func writeArchived(_ snapshots: [FixtureSnapshot], to base: URL) throws {
        let url = base.appendingPathComponent(
            "archived-session-snapshots.json", isDirectory: false
        )
        let data = try makeEncoder().encode(snapshots)
        try data.write(to: url, options: [.atomic])
    }

    private func writeRelaunchable(_ snapshots: [FixtureSnapshot], to base: URL) throws {
        let url = base.appendingPathComponent(
            "relaunchable-session-snapshots.json", isDirectory: false
        )
        let data = try makeEncoder().encode(snapshots)
        try data.write(to: url, options: [.atomic])
    }

    private func writeRawArchived(_ data: Data, to base: URL) throws {
        let url = base.appendingPathComponent(
            "archived-session-snapshots.json", isDirectory: false
        )
        try data.write(to: url, options: [.atomic])
    }

    private func makeSnapshot(
        id: UUID = UUID(),
        title: String = "Task",
        createdAt: Date,
        latestActivityAt: Date,
        lastSubmittedPrompt: String? = "do the thing",
        wasRelaunchResumeCandidate: Bool? = false,
        entries: [FixtureEntry] = []
    ) -> FixtureSnapshot {
        FixtureSnapshot(
            id: id,
            title: title,
            accentThemeRawValue: "blue",
            entries: entries,
            activeThreadID: nil,
            lastSubmittedPrompt: lastSubmittedPrompt,
            createdAt: createdAt,
            latestActivityAt: latestActivityAt,
            wasRelaunchResumeCandidate: wasRelaunchResumeCandidate,
            activeTurnID: nil,
            activeLeaseID: nil,
            leaseExpiresAt: nil
        )
    }

    // MARK: - Empty / missing directory

    func test_returnsEmpty_whenBaseDirectoryMissing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openclicky-nope-\(UUID().uuidString)", isDirectory: true)
        let now = Date()

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: missing, now: now
        )

        XCTAssertEqual(result, [])
    }

    func test_returnsEmpty_whenDirectoryExistsButNoSnapshotFiles() throws {
        let dir = try makeTempDir()
        let now = Date()

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )

        XCTAssertEqual(result, [])
    }

    func test_returnsEmpty_forLimitZeroOrNegative() throws {
        let dir = try makeTempDir()
        let now = Date()
        let snapshot = makeSnapshot(
            createdAt: now.addingTimeInterval(-60),
            latestActivityAt: now.addingTimeInterval(-30)
        )
        try writeArchived([snapshot], to: dir)

        XCTAssertEqual(
            RecentSessionsCapture.recent(limit: 0, baseDirectory: dir, now: now),
            []
        )
        XCTAssertEqual(
            RecentSessionsCapture.recent(limit: -3, baseDirectory: dir, now: now),
            []
        )
    }

    // MARK: - Single valid entry

    func test_singleValidSession_populatesFields() throws {
        let dir = try makeTempDir()
        let now = Date()
        let started = now.addingTimeInterval(-3_600)
        let updated = now.addingTimeInterval(-60)
        let sessionID = UUID()
        let snapshot = makeSnapshot(
            id: sessionID,
            title: "Refactor voice pipeline",
            createdAt: started,
            latestActivityAt: updated,
            lastSubmittedPrompt: "Refactor CompanionManager voice pipeline for OpenClicky",
            wasRelaunchResumeCandidate: false,
            entries: [
                FixtureEntry(id: "u1", role: "user", text: "Refactor CompanionManager voice pipeline for OpenClicky", createdAt: started),
                FixtureEntry(id: "a1", role: "assistant", text: "Done — split into voice + response modules.", createdAt: updated)
            ]
        )
        try writeArchived([snapshot], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )

        XCTAssertEqual(result.count, 1)
        let ref = result[0]
        XCTAssertEqual(ref.id, sessionID.uuidString)
        XCTAssertNil(ref.projectPath)
        XCTAssertNil(ref.projectSlug)
        XCTAssertEqual(ref.startedAt.timeIntervalSince1970,
                       started.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(ref.lastUpdatedAt.timeIntervalSince1970,
                       updated.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(ref.status, "completed")
        XCTAssertEqual(
            ref.taskSummary,
            "Refactor CompanionManager voice pipeline for OpenClicky"
        )
    }

    func test_singleValidSession_marksRunningWhenRelaunchable() throws {
        let dir = try makeTempDir()
        let now = Date()
        let snapshot = makeSnapshot(
            createdAt: now.addingTimeInterval(-600),
            latestActivityAt: now.addingTimeInterval(-60),
            wasRelaunchResumeCandidate: true,
            entries: [
                FixtureEntry(id: "u1", role: "user", text: "keep going", createdAt: now.addingTimeInterval(-600))
            ]
        )
        try writeRelaunchable([snapshot], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "running")
    }

    // MARK: - Sorting + limit

    func test_multipleSessions_sortedByLastUpdatedDesc_andLimited() throws {
        let dir = try makeTempDir()
        let now = Date()

        let older = makeSnapshot(
            id: UUID(),
            title: "older",
            createdAt: now.addingTimeInterval(-7_200),
            latestActivityAt: now.addingTimeInterval(-3_600),
            lastSubmittedPrompt: "older prompt"
        )
        let newer = makeSnapshot(
            id: UUID(),
            title: "newer",
            createdAt: now.addingTimeInterval(-1_800),
            latestActivityAt: now.addingTimeInterval(-300),
            lastSubmittedPrompt: "newer prompt"
        )
        let middle = makeSnapshot(
            id: UUID(),
            title: "middle",
            createdAt: now.addingTimeInterval(-5_000),
            latestActivityAt: now.addingTimeInterval(-1_500),
            lastSubmittedPrompt: "middle prompt"
        )

        try writeArchived([older, middle], to: dir)
        try writeRelaunchable([newer], to: dir)

        let all = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(all.map(\.taskSummary), [
            "newer prompt", "middle prompt", "older prompt"
        ])

        let limited = RecentSessionsCapture.recent(
            limit: 2, baseDirectory: dir, now: now
        )
        XCTAssertEqual(limited.map(\.taskSummary), [
            "newer prompt", "middle prompt"
        ])
    }

    // MARK: - Malformed JSON

    func test_malformedJson_wholeFileSkipped_noCrash() throws {
        let dir = try makeTempDir()
        let now = Date()
        try writeRawArchived(Data("{not-valid-json".utf8), to: dir)

        // Good relaunchable file lives alongside so we can prove the
        // capture doesn't abort the whole call on one bad file.
        let good = makeSnapshot(
            createdAt: now.addingTimeInterval(-600),
            latestActivityAt: now.addingTimeInterval(-60),
            lastSubmittedPrompt: "still valid"
        )
        try writeRelaunchable([good], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.map(\.taskSummary), ["still valid"])
    }

    func test_partialMalformedJson_keepsGoodEntries() throws {
        let dir = try makeTempDir()
        let now = Date()

        // Hand-rolled JSON: one valid entry, one entry missing id.
        let updated = now.addingTimeInterval(-60)
        let updatedSeconds = updated.timeIntervalSinceReferenceDate
        let createdSeconds = now.addingTimeInterval(-3_600).timeIntervalSinceReferenceDate
        let goodID = UUID().uuidString
        let json = """
        [
          {
            "id": "\(goodID)",
            "title": "good",
            "accentThemeRawValue": "blue",
            "entries": [],
            "lastSubmittedPrompt": "good prompt",
            "createdAt": \(createdSeconds),
            "latestActivityAt": \(updatedSeconds),
            "wasRelaunchResumeCandidate": false
          },
          {
            "title": "missing id",
            "accentThemeRawValue": "blue",
            "entries": [],
            "createdAt": \(createdSeconds),
            "latestActivityAt": \(updatedSeconds)
          }
        ]
        """
        try writeRawArchived(Data(json.utf8), to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, goodID)
        XCTAssertEqual(result[0].taskSummary, "good prompt")
    }

    // MARK: - Staleness

    func test_staleSessions_skipped() throws {
        let dir = try makeTempDir()
        let now = Date()
        let fresh = makeSnapshot(
            id: UUID(),
            title: "fresh",
            createdAt: now.addingTimeInterval(-3_600),
            latestActivityAt: now.addingTimeInterval(-60),
            lastSubmittedPrompt: "fresh prompt"
        )
        let stale = makeSnapshot(
            id: UUID(),
            title: "stale",
            createdAt: now.addingTimeInterval(-40 * 24 * 3_600),
            latestActivityAt: now.addingTimeInterval(-31 * 24 * 3_600),
            lastSubmittedPrompt: "stale prompt"
        )
        try writeArchived([fresh, stale], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.map(\.taskSummary), ["fresh prompt"])
    }

    func test_boundaryStaleness_thirtyDaysExactlyKept() throws {
        let dir = try makeTempDir()
        let now = Date()
        // Exactly 30 days old: age = 30d, which is NOT > 30d, so it is kept.
        let boundary = makeSnapshot(
            id: UUID(),
            title: "boundary",
            createdAt: now.addingTimeInterval(-30 * 24 * 3_600 - 3_600),
            latestActivityAt: now.addingTimeInterval(-30 * 24 * 3_600),
            lastSubmittedPrompt: "still valid at boundary"
        )
        try writeArchived([boundary], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Dedupe across files

    func test_sameSessionInBothFiles_dedupedPreferringFresherTimestamp() throws {
        let dir = try makeTempDir()
        let now = Date()
        let sharedID = UUID()

        let fresher = makeSnapshot(
            id: sharedID,
            title: "fresher-copy",
            createdAt: now.addingTimeInterval(-3_600),
            latestActivityAt: now.addingTimeInterval(-30),
            lastSubmittedPrompt: "fresher"
        )
        let staler = makeSnapshot(
            id: sharedID,
            title: "staler-copy",
            createdAt: now.addingTimeInterval(-4_000),
            latestActivityAt: now.addingTimeInterval(-600),
            lastSubmittedPrompt: "staler"
        )

        try writeRelaunchable([fresher], to: dir)
        try writeArchived([staler], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, sharedID.uuidString)
        XCTAssertEqual(result[0].taskSummary, "fresher")
    }

    // MARK: - Task summary shaping

    func test_taskSummary_collapsesWhitespaceAndTruncates() throws {
        let dir = try makeTempDir()
        let now = Date()
        let longPrompt = "please   refactor \n\nthe   " + String(repeating: "x", count: 200)
        let snapshot = makeSnapshot(
            createdAt: now.addingTimeInterval(-600),
            latestActivityAt: now.addingTimeInterval(-60),
            lastSubmittedPrompt: longPrompt
        )
        try writeArchived([snapshot], to: dir)

        let result = RecentSessionsCapture.recent(
            limit: 10, baseDirectory: dir, now: now
        )
        XCTAssertEqual(result.count, 1)
        let summary = result[0].taskSummary ?? ""
        XCTAssertEqual(summary.count, 80)
        XCTAssertTrue(summary.hasPrefix("please refactor the "))
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertFalse(summary.contains("  "))
    }
}
