// Ported from Everywhere: src/Everywhere.Mcp/Tools/MemoryTools.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Single-tenant JSON store backing the memory_* MCP tools. Corresponds
// conceptually to Everywhere's `MemoryStore.cs` — but openclicky runs
// as one process with a single user, so the per-`sites/<domain>/` fanout
// collapses to one envelope file:
//
//     ~/Library/Application Support/OpenClicky/memory.json
//
// Writes are atomic: serialise → write to `<path>.tmp` → `Darwin.rename`
// over the target. Concurrent readers/writers within one process are
// serialised through `NSLock`. Cross-process locking is out of scope.

import Foundation
import Darwin

/// Errors surfaced to `OpenClickyMemoryTools` and translated into MCP
/// error envelopes. Mirrors the C# `MergeConflictException` shape.
public enum MemoryStoreError: Error, Equatable, Sendable {
    /// Attempted to overwrite an existing endpoint / verify-fixture
    /// entry without `force = true`. `path` is the logical key that
    /// clashed (endpoint name, field-map key, or verify cmd).
    case mergeConflict(path: String)
    /// Persisted file exists but cannot be decoded as JSON. Everywhere
    /// swallows this and returns an empty dict; we surface it so tests
    /// can pin the atomic-write invariant.
    case decodeFailure(path: String, underlying: String)
    /// Failed to write the tmp file or rename it into place.
    case ioFailure(path: String, underlying: String)
}

/// Thread-safe persistent store for openclicky's memory tools.
public final class MemoryStore: @unchecked Sendable {

    // MARK: - Init

    /// Default singleton pointing at
    /// `~/Library/Application Support/OpenClicky/memory.json`.
    public static let shared: MemoryStore = MemoryStore()

    /// Absolute path to the envelope file on disk.
    public let storeURL: URL

    /// Injected clock — unit tests use a monotonically-increasing stub.
    /// Returns unix milliseconds (matches Everywhere's `SystemClock.NowMs`).
    public let clock: @Sendable () -> Int64

    private let lock = NSLock()
    private var cache: MemorySnapshot

    /// Designated initialiser. `storeURL` is only used when writes
    /// happen; the parent directory is created on demand.
    public init(
        storeURL: URL = MemoryStore.defaultStoreURL(),
        clock: @escaping @Sendable () -> Int64 = { MemoryStore.currentMillis() }
    ) {
        self.storeURL = storeURL
        self.clock = clock
        self.cache = Self.loadFromDisk(url: storeURL) ?? MemorySnapshot()
    }

    /// `~/Library/Application Support/OpenClicky/memory.json`. Falls back
    /// to the tmp dir if `applicationSupportDirectory` is unavailable
    /// (headless sandboxes, CI without a real HOME).
    public static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            base = support
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("memory.json", isDirectory: false)
    }

    // MARK: - Read

    /// Read all entries (key omitted) or the single top-level field-map
    /// value for `key`. Mirrors `memory_read` semantics.
    public func read(key: String? = nil) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let key else { return cache.fieldMap }
        if let value = cache.fieldMap[key] {
            return [key: value]
        }
        return [:]
    }

    /// Return the endpoint bag, or `nil` if it has not been written yet.
    public func readEndpoint(_ endpoint: String) -> MemoryEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return cache.endpoints[endpoint]
    }

    /// Full store dump (`memory_snapshot`).
    public func snapshot() -> MemorySnapshot {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// Categorical + numeric freshness for the whole store.
    ///
    /// `freshness` mirrors Everywhere's `Freshness.Classify`
    /// (`Freshness.cs:11-17`): `<30d fresh`, `30d-90d stale`, `>=90d
    /// cold`. When nothing has been written yet the bucket is `cold`
    /// (matches `MemoryStore.cs:191`, which returns "cold" when
    /// `VerifiedAt == 0`) and both numeric fields are zero.
    public func freshness() -> MemoryFreshnessInfo {
        lock.lock(); defer { lock.unlock() }
        let last = cache.lastWriteAt
        if last == 0 {
            return MemoryFreshnessInfo(
                freshness: .cold,
                lastWriteAt: 0,
                stalenessSeconds: 0
            )
        }
        let now = clock()
        let ageMs = max(0, now - last)
        let bucket = Self.classifyFreshness(ageMs: ageMs)
        let staleness = ageMs / 1_000
        return MemoryFreshnessInfo(
            freshness: bucket,
            lastWriteAt: last,
            stalenessSeconds: staleness
        )
    }

    /// Everywhere's day boundaries (`Freshness.cs:9`): 24h in ms.
    private static let dayMs: Int64 = 24 * 3_600 * 1_000

    /// 1:1 with `Freshness.Classify` (`Freshness.cs:11-17`).
    static func classifyFreshness(ageMs: Int64) -> MemoryFreshnessBucket {
        if ageMs < 30 * dayMs { return .fresh }
        if ageMs < 90 * dayMs { return .stale }
        return .cold
    }

    // MARK: - Write

    /// Write or overwrite an endpoint. Throws `mergeConflict` when the
    /// entry already exists and `force` is false (parallels the
    /// `MergeConflictException` in `MemoryStore.WriteEndpoint`).
    public func writeEndpoint(
        _ endpoint: MemoryEndpoint,
        force: Bool = false
    ) throws {
        lock.lock(); defer { lock.unlock() }
        if !force, cache.endpoints[endpoint.name] != nil {
            throw MemoryStoreError.mergeConflict(path: endpoint.name)
        }
        var stamped = endpoint
        stamped.lastWriteAt = clock()
        cache.endpoints[endpoint.name] = stamped
        cache.lastWriteAt = stamped.lastWriteAt
        try persist()
    }

    /// Bulk merge into the top-level field map. `force = false` throws
    /// on the first colliding key so partial writes never happen.
    public func writeFieldMap(
        _ mapping: [String: String],
        force: Bool = false
    ) throws {
        lock.lock(); defer { lock.unlock() }
        if !force {
            for key in mapping.keys where cache.fieldMap[key] != nil {
                throw MemoryStoreError.mergeConflict(path: key)
            }
        }
        for (k, v) in mapping { cache.fieldMap[k] = v }
        cache.lastWriteAt = clock()
        try persist()
    }

    /// Append an ISO-8601-timestamped note. When `endpoint` is provided
    /// the note is appended to that endpoint's `notes`; the endpoint is
    /// created on demand. Otherwise it goes into the global `notes`
    /// list (parallel to Everywhere's `notes.md`).
    public func appendNote(_ text: String, endpoint: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let iso = Self.iso8601(fromMillis: now)
        let entry = "\(iso)\n\(text)"
        if let endpoint {
            var target = cache.endpoints[endpoint] ?? MemoryEndpoint(name: endpoint)
            target.notes.append(entry)
            target.lastWriteAt = now
            cache.endpoints[endpoint] = target
        } else {
            cache.notes.append(entry)
        }
        cache.lastWriteAt = now
        try persist()
    }

    /// Store a raw JSON body against `cmd`. Throws `mergeConflict` when
    /// the fixture already exists and `force` is false, matching
    /// `MemoryStore.WriteVerifyFixture` semantics.
    public func writeVerifyFixture(
        cmd: String,
        fixture: String,
        force: Bool = false
    ) throws {
        lock.lock(); defer { lock.unlock() }
        if !force, cache.verifyFixtures[cmd] != nil {
            throw MemoryStoreError.mergeConflict(path: cmd)
        }
        cache.verifyFixtures[cmd] = fixture
        cache.lastWriteAt = clock()
        try persist()
    }

    /// Write a sanitised capture body to
    /// `<storeDir>/snapshots/<cmd>-<yyyymmddTHHmmssZ>.json` and keep at
    /// most `keepLast` newest files per `cmd`. Returns the URL that was
    /// written.
    ///
    /// 1:1 with `MemoryStore.WriteSnapshot` (`MemoryStore.cs:197-215`)
    /// and the `memory_snapshot(site, cmd, content)` wire semantics of
    /// `MemoryTools.MemorySnapshot` (`MemoryTools.cs:162-175`).
    /// openclicky is single-tenant so the per-site directory collapses
    /// to `<storeDir>/snapshots/`. Rotation matches Everywhere's
    /// `EnumerateFiles($"{cmd}-*.json").OrderByDescending(Name)` pattern.
    ///
    /// Note: the no-arg `snapshot()` above returns a `MemorySnapshot`
    /// value (openclicky superset used by `memory_snapshot` bridge
    /// dispatch). The Everywhere wire verb "snapshot" is a write; this
    /// method is that write.
    @discardableResult
    public func writeSnapshot(
        cmd: String,
        content: String,
        keepLast: Int = 5
    ) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let dir = Self.snapshotsDirectory(for: storeURL)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw MemoryStoreError.ioFailure(
                    path: dir.path,
                    underlying: "mkdir: \(error)"
                )
            }
        }
        let stamp = Self.compactTimestamp(fromMillis: clock())
        let target = dir.appendingPathComponent("\(cmd)-\(stamp).json", isDirectory: false)
        do {
            try Data(content.utf8).write(to: target, options: .atomic)
        } catch {
            throw MemoryStoreError.ioFailure(
                path: target.path,
                underlying: "write: \(error)"
            )
        }
        // Best-effort rotation. Matches Everywhere's `try/catch { }` in
        // `MemoryStore.cs:210-213` — a rotation failure never surfaces.
        Self.rotateSnapshots(dir: dir, cmd: cmd, keepLast: keepLast)
        return target
    }

    /// Directory used by `writeSnapshot`. Exposed for tests.
    static func snapshotsDirectory(for storeURL: URL) -> URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// Enumerate `<cmd>-*.json`, keep the `keepLast` newest by filename
    /// (compact UTC timestamps sort lexicographically), delete the
    /// rest. Silent on errors, per Everywhere's `MemoryStore.cs:210-213`.
    private static func rotateSnapshots(dir: URL, cmd: String, keepLast: Int) {
        guard keepLast >= 0 else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = "\(cmd)-"
        let matches = names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted(by: >) // descending by name = newest first
        guard matches.count > keepLast else { return }
        for stale in matches.dropFirst(keepLast) {
            try? fm.removeItem(at: dir.appendingPathComponent(stale, isDirectory: false))
        }
    }

    // MARK: - Test-only helpers

    /// Discard the cache and reload from disk. Only used by tests that
    /// want to verify persistence across a fresh `MemoryStore`.
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        cache = Self.loadFromDisk(url: storeURL) ?? MemorySnapshot()
    }

    // MARK: - Persistence

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do {
            data = try encoder.encode(cache)
        } catch {
            throw MemoryStoreError.ioFailure(
                path: storeURL.path,
                underlying: "encode: \(error)"
            )
        }
        try Self.atomicWrite(data: data, to: storeURL)
    }

    /// Write to `<path>.tmp` and `Darwin.rename` over the destination
    /// so partial writes never surface. Parent directory is created on
    /// demand. Matches Everywhere's `MergeSafeWriter.WriteAtomic`.
    static func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            do {
                try fm.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
            } catch {
                throw MemoryStoreError.ioFailure(
                    path: parent.path,
                    underlying: "mkdir: \(error)"
                )
            }
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw MemoryStoreError.ioFailure(
                path: tmp.path,
                underlying: "write: \(error)"
            )
        }
        let renamed = tmp.withUnsafeFileSystemRepresentation { fromPtr -> Int32 in
            guard let fromPtr else { return -1 }
            return url.withUnsafeFileSystemRepresentation { toPtr in
                guard let toPtr else { return -1 }
                return rename(fromPtr, toPtr)
            }
        }
        if renamed != 0 {
            // Best-effort cleanup so a failed rename doesn't leave the
            // tmp shadow around for the next writer.
            try? fm.removeItem(at: tmp)
            throw MemoryStoreError.ioFailure(
                path: url.path,
                underlying: "rename: \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func loadFromDisk(url: URL) -> MemorySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MemorySnapshot.self, from: data)
    }

    // MARK: - Time

    /// Unix milliseconds. Uses `Date().timeIntervalSince1970` for
    /// portability; Everywhere uses `DateTimeOffset.UtcNow`.
    public static func currentMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso8601(fromMillis ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000.0)
        return iso8601Formatter.string(from: date)
    }

    /// UTC `yyyyMMddTHHmmssZ`. Matches Everywhere's snapshot filename
    /// stamp (`MemoryStore.cs:202`). Locale-independent.
    private static let compactTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    static func compactTimestamp(fromMillis ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000.0)
        return compactTimestampFormatter.string(from: date)
    }
}
