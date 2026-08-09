// Ported from Everywhere: src/Everywhere.Mcp/Tools/MemoryTools.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for MemoryStore + OpenClickyMemoryTools. Every test
// uses a scratch file under NSTemporaryDirectory() so we never touch
// the real ~/Library/Application Support/OpenClicky/memory.json.

import XCTest
@testable import OpenClickyContextService

final class MemoryStoreTests: XCTestCase {

    // MARK: - Test scaffolding

    private var storeURL: URL!
    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "openclicky-memory-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDir,
            withIntermediateDirectories: true
        )
        storeURL = testDir.appendingPathComponent("memory.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let testDir, FileManager.default.fileExists(atPath: testDir.path) {
            try? FileManager.default.removeItem(at: testDir)
        }
        try super.tearDownWithError()
    }

    /// Builds a store bound to `storeURL` with a fixed clock. Callers
    /// pass an inout tick counter so tests can advance time between
    /// mutations.
    private func makeStore(startingAt ms: Int64 = 1_000_000) -> (MemoryStore, () -> Int64) {
        let boxed = ClockBox(value: ms)
        let store = MemoryStore(
            storeURL: storeURL,
            clock: { boxed.value }
        )
        return (store, { boxed.value })
    }

    private final class ClockBox: @unchecked Sendable {
        var value: Int64
        init(value: Int64) { self.value = value }
    }

    // MARK: - Fresh store

    func test_freshStore_read_returnsEmpty() {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        XCTAssertTrue(tools.memoryRead().isEmpty)
        XCTAssertNil(tools.memoryReadEndpoint(endpoint: "missing"))
        XCTAssertEqual(tools.memorySnapshot(), MemorySnapshot())
    }

    func test_freshStore_freshness_isColdWithZeroTimestamps() {
        // Everywhere `MemoryStore.cs:191` returns "cold" when
        // `VerifiedAt == 0`. The Swift port must expose the same
        // categorical bucket for a never-written store.
        let (store, _) = makeStore()
        let info = OpenClickyMemoryTools(store: store).memoryFreshness()
        XCTAssertEqual(info.freshness, .cold)
        XCTAssertEqual(info.lastWriteAt, 0)
        XCTAssertEqual(info.stalenessSeconds, 0)
    }

    // MARK: - Endpoint write / read

    func test_writeEndpoint_then_readReturnsValue() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteEndpoint(
            endpoint: "api.example.com",
            fields: ["token": "abc", "region": "eu-west-1"]
        )
        let got = tools.memoryReadEndpoint(endpoint: "api.example.com")
        XCTAssertNotNil(got)
        XCTAssertEqual(got?.name, "api.example.com")
        XCTAssertEqual(got?.fields["token"], "abc")
        XCTAssertEqual(got?.fields["region"], "eu-west-1")
        XCTAssertGreaterThan(got?.lastWriteAt ?? 0, 0)
    }

    func test_writeEndpoint_withoutForce_mergeConflicts() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteEndpoint(
            endpoint: "same",
            fields: ["a": "1"]
        )
        XCTAssertThrowsError(try tools.memoryWriteEndpoint(
            endpoint: "same",
            fields: ["a": "2"]
        )) { error in
            guard case MemoryStoreError.mergeConflict(let path) = error else {
                return XCTFail("expected mergeConflict, got \(error)")
            }
            XCTAssertEqual(path, "same")
        }
        // Original value must survive the failed write.
        XCTAssertEqual(tools.memoryReadEndpoint(endpoint: "same")?.fields["a"], "1")
    }

    func test_writeEndpoint_withForce_overwrites() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteEndpoint(endpoint: "same", fields: ["a": "1"])
        try tools.memoryWriteEndpoint(
            endpoint: "same",
            fields: ["a": "2"],
            force: true
        )
        XCTAssertEqual(tools.memoryReadEndpoint(endpoint: "same")?.fields["a"], "2")
    }

    // MARK: - Append note

    func test_appendNote_threeTimes_returnsOrderedNotes() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryAppendNote(text: "first")
        try tools.memoryAppendNote(text: "second")
        try tools.memoryAppendNote(text: "third")
        let snap = tools.memorySnapshot()
        XCTAssertEqual(snap.notes.count, 3)
        // Preserved insertion order; ISO prefix + newline + body.
        XCTAssertTrue(snap.notes[0].hasSuffix("\nfirst"))
        XCTAssertTrue(snap.notes[1].hasSuffix("\nsecond"))
        XCTAssertTrue(snap.notes[2].hasSuffix("\nthird"))
    }

    func test_appendNote_toEndpoint_createsEndpointOnDemand() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryAppendNote(text: "kb-1", endpoint: "kb")
        try tools.memoryAppendNote(text: "kb-2", endpoint: "kb")
        let ep = tools.memoryReadEndpoint(endpoint: "kb")
        XCTAssertNotNil(ep)
        XCTAssertEqual(ep?.notes.count, 2)
        XCTAssertTrue(ep!.notes[0].hasSuffix("\nkb-1"))
        XCTAssertTrue(ep!.notes[1].hasSuffix("\nkb-2"))
    }

    // MARK: - Field map bulk write

    func test_writeFieldMap_bulkWrites_thenReadReturnsAll() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteFieldMap(map: [
            "one": "1",
            "two": "2",
            "three": "3",
        ])
        let all = tools.memoryRead()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all["two"], "2")
        // Single-key read shape.
        XCTAssertEqual(tools.memoryRead(key: "one"), ["one": "1"])
        XCTAssertTrue(tools.memoryRead(key: "missing").isEmpty)
    }

    func test_writeFieldMap_collides_throwsAndKeepsExisting() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteFieldMap(map: ["k": "v1"])
        XCTAssertThrowsError(try tools.memoryWriteFieldMap(map: ["k": "v2", "other": "x"])) { error in
            guard case MemoryStoreError.mergeConflict(let path) = error else {
                return XCTFail("expected mergeConflict, got \(error)")
            }
            XCTAssertEqual(path, "k")
        }
        // Partial-write invariant: the non-colliding key must NOT
        // have been written when the conflict aborted the operation.
        XCTAssertEqual(tools.memoryRead(key: "k"), ["k": "v1"])
        XCTAssertTrue(tools.memoryRead(key: "other").isEmpty)
    }

    // MARK: - Snapshot

    func test_snapshot_returnsFullState() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteEndpoint(endpoint: "e", fields: ["a": "1"])
        try tools.memoryWriteFieldMap(map: ["k": "v"])
        try tools.memoryAppendNote(text: "n")
        try tools.memoryWriteVerifyFixture(cmd: "cmd", fixture: "{}")

        let snap = tools.memorySnapshot()
        XCTAssertEqual(snap.endpoints["e"]?.fields["a"], "1")
        XCTAssertEqual(snap.fieldMap["k"], "v")
        XCTAssertEqual(snap.notes.count, 1)
        XCTAssertEqual(snap.verifyFixtures["cmd"], "{}")
        XCTAssertGreaterThan(snap.lastWriteAt, 0)
    }

    // MARK: - Freshness

    func test_freshness_returnsNonZeroStalenessAfterWait() throws {
        let clock = ClockBox(value: 10_000_000) // 10_000 sec
        let store = MemoryStore(storeURL: storeURL, clock: { clock.value })
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryAppendNote(text: "hello")
        // Advance clock by 42s and read.
        clock.value += 42_000
        let info = tools.memoryFreshness()
        XCTAssertEqual(info.freshness, .fresh)
        XCTAssertEqual(info.lastWriteAt, 10_000_000)
        XCTAssertEqual(info.stalenessSeconds, 42)
    }

    func test_freshness_bucketBoundaries_matchEverywhere() throws {
        // 1:1 with `Freshness.Classify` (`Freshness.cs:11-17`):
        //   * <30d = fresh
        //   * 30d-90d = stale
        //   * >=90d = cold
        let dayMs: Int64 = 24 * 3_600 * 1_000
        let base: Int64 = 1_700_000_000_000
        let clock = ClockBox(value: base)
        let store = MemoryStore(storeURL: storeURL, clock: { clock.value })
        let tools = OpenClickyMemoryTools(store: store)

        try tools.memoryAppendNote(text: "seed")
        // <30d — fresh
        clock.value = base + 29 * dayMs
        XCTAssertEqual(tools.memoryFreshness().freshness, .fresh)
        // Exactly 30d — stale boundary
        clock.value = base + 30 * dayMs
        XCTAssertEqual(tools.memoryFreshness().freshness, .stale)
        // 60d — stale
        clock.value = base + 60 * dayMs
        XCTAssertEqual(tools.memoryFreshness().freshness, .stale)
        // 89d — stale
        clock.value = base + 89 * dayMs
        XCTAssertEqual(tools.memoryFreshness().freshness, .stale)
        // 90d — cold boundary
        clock.value = base + 90 * dayMs
        XCTAssertEqual(tools.memoryFreshness().freshness, .cold)
        // 200d — cold
        clock.value = base + 200 * dayMs
        XCTAssertEqual(tools.memoryFreshness().freshness, .cold)
    }

    // MARK: - Snapshot write (Everywhere semantic)

    func test_writeSnapshot_writesFileAndReturnsPath() throws {
        let clock = ClockBox(value: 1_700_000_000_000)
        let store = MemoryStore(storeURL: storeURL, clock: { clock.value })
        let tools = OpenClickyMemoryTools(store: store)
        let path = try tools.memorySnapshotWrite(cmd: "ls", content: "{\"a\":1}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents, "{\"a\":1}")
        XCTAssertTrue(path.contains("/snapshots/ls-"), "unexpected path: \(path)")
        XCTAssertTrue(path.hasSuffix(".json"))
    }

    func test_writeSnapshot_rotatesKeepingLastFive() throws {
        let clock = ClockBox(value: 1_700_000_000_000)
        let store = MemoryStore(storeURL: storeURL, clock: { clock.value })
        // Write 7 snapshots, one second apart, each with a different
        // body so we can identify which survive rotation.
        var writtenPaths: [String] = []
        for i in 0 ..< 7 {
            clock.value += 1_000
            let p = try store.writeSnapshot(cmd: "cmd", content: "iter-\(i)")
            writtenPaths.append(p.path)
        }
        let dir = MemoryStore.snapshotsDirectory(for: storeURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let cmdFiles = files.filter { $0.hasPrefix("cmd-") && $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(cmdFiles.count, 5)
        // The two oldest must be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenPaths[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenPaths[1]))
        // The five newest must remain.
        for i in 2 ..< 7 {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: writtenPaths[i]),
                "expected \(writtenPaths[i]) to survive rotation"
            )
        }
    }

    func test_writeSnapshot_isolatesPerCmd() throws {
        let clock = ClockBox(value: 1_700_000_000_000)
        let store = MemoryStore(storeURL: storeURL, clock: { clock.value })
        // Six writes for `cmd-a` (one over the cap) then two for
        // `cmd-b`. Rotation is per-cmd; the `cmd-b` files stay.
        for _ in 0 ..< 6 {
            clock.value += 1_000
            _ = try store.writeSnapshot(cmd: "aaa", content: "a")
        }
        for _ in 0 ..< 2 {
            clock.value += 1_000
            _ = try store.writeSnapshot(cmd: "bbb", content: "b")
        }
        let dir = MemoryStore.snapshotsDirectory(for: storeURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aaaFiles = files.filter { $0.hasPrefix("aaa-") && $0.hasSuffix(".json") }
        let bbbFiles = files.filter { $0.hasPrefix("bbb-") && $0.hasSuffix(".json") }
        XCTAssertEqual(aaaFiles.count, 5, "aaa should have rotated")
        XCTAssertEqual(bbbFiles.count, 2, "bbb should be untouched")
    }

    // MARK: - Verify fixture

    func test_writeVerifyFixture_conflict_and_force() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteVerifyFixture(cmd: "ls", fixture: "{\"a\":1}")
        XCTAssertThrowsError(try tools.memoryWriteVerifyFixture(cmd: "ls", fixture: "{\"a\":2}")) { error in
            guard case MemoryStoreError.mergeConflict = error else {
                return XCTFail("expected mergeConflict, got \(error)")
            }
        }
        try tools.memoryWriteVerifyFixture(cmd: "ls", fixture: "{\"a\":2}", force: true)
        XCTAssertEqual(tools.memorySnapshot().verifyFixtures["ls"], "{\"a\":2}")
    }

    // MARK: - Atomic persistence

    func test_atomicWrite_producesFileOnDisk() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteFieldMap(map: ["persist": "yes"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        // tmp shadow must not survive a successful rename.
        let tmpPath = storeURL.appendingPathExtension("tmp").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpPath))
    }

    func test_atomicWrite_survivesReload_freshStoreReadsSameEnvelope() throws {
        let (store, _) = makeStore()
        let tools = OpenClickyMemoryTools(store: store)
        try tools.memoryWriteEndpoint(
            endpoint: "cross-instance",
            fields: ["stored": "on-disk"]
        )
        try tools.memoryAppendNote(text: "durable")

        // Fresh store instance backed by the SAME file — should decode
        // the previous envelope verbatim.
        let secondary = MemoryStore(storeURL: storeURL)
        let seen = OpenClickyMemoryTools(store: secondary).memorySnapshot()
        XCTAssertEqual(seen.endpoints["cross-instance"]?.fields["stored"], "on-disk")
        XCTAssertEqual(seen.notes.count, 1)
    }

    func test_atomicWrite_tmpLeftover_doesNotBreakLoad() throws {
        // Simulate a crashed writer that left `memory.json.tmp` behind.
        // `MemoryStore.init` must ignore the tmp file and start clean
        // (missing target == fresh store).
        let tmp = storeURL.appendingPathExtension("tmp")
        try Data("{\"broken\":true}".utf8).write(to: tmp)
        let store = MemoryStore(storeURL: storeURL)
        XCTAssertEqual(store.snapshot(), MemorySnapshot())
    }
}
