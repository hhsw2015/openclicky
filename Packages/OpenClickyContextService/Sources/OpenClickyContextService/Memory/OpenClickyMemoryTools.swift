// Ported from Everywhere: src/Everywhere.Mcp/Tools/MemoryTools.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// MCP-facing surface for the memory_* tool family. Each method mirrors
// the corresponding `[McpServerTool(Name = "...")]` in Everywhere's
// `MemoryTools.cs`, keeping the same argument order and return shape.
// Method names use the Swift-native camelCase form; the wire names are
// documented on each method so the MCP dispatcher can round-trip.

import Foundation

/// Wraps `MemoryStore` with the eight MCP-facing tool methods. Not a
/// singleton — callers pass in the store they want to bind against.
public struct OpenClickyMemoryTools: Sendable {

    public let store: MemoryStore

    public init(store: MemoryStore = .shared) {
        self.store = store
    }

    // MARK: - memory_read

    /// MCP tool name: `memory_read`. When `key` is nil returns the full
    /// top-level field map; otherwise returns just that key (empty dict
    /// if missing). Mirrors `MemoryTools.MemoryRead` conceptually but
    /// takes a field key instead of a site domain — openclicky is
    /// single-tenant.
    public func memoryRead(key: String? = nil) -> [String: String] {
        store.read(key: key)
    }

    // MARK: - memory_read_endpoint

    /// MCP tool name: `memory_read_endpoint`. Returns the endpoint or
    /// nil. Parallels `MemoryTools.MemoryReadEndpoint`.
    public func memoryReadEndpoint(endpoint: String) -> MemoryEndpoint? {
        store.readEndpoint(endpoint)
    }

    // MARK: - memory_write_endpoint

    /// MCP tool name: `memory_write_endpoint`. Overwrites an endpoint's
    /// fields and notes; the `lastWriteAt` timestamp is refreshed by
    /// `MemoryStore`. Throws `MemoryStoreError.mergeConflict` when the
    /// endpoint already exists and `force` is false, matching the
    /// MERGE_CONFLICT behaviour in `MemoryTools.MemoryWriteEndpoint`.
    public func memoryWriteEndpoint(
        endpoint: String,
        fields: [String: String] = [:],
        notes: [String] = [],
        force: Bool = false
    ) throws {
        let value = MemoryEndpoint(
            name: endpoint,
            fields: fields,
            notes: notes,
            lastWriteAt: 0
        )
        try store.writeEndpoint(value, force: force)
    }

    // MARK: - memory_write_field_map

    /// MCP tool name: `memory_write_field_map`. Bulk-merges `map` into
    /// the top-level field bag. Throws `mergeConflict` on the first
    /// colliding key when `force` is false — no partial writes.
    /// Parallels `MemoryTools.MemoryWriteFieldMap`.
    public func memoryWriteFieldMap(
        map: [String: String],
        force: Bool = false
    ) throws {
        try store.writeFieldMap(map, force: force)
    }

    // MARK: - memory_append_note

    /// MCP tool name: `memory_append_note`. Appends `text` as an ISO-
    /// timestamped entry. When `endpoint` is provided the note lives on
    /// that endpoint (created on demand); otherwise it goes into the
    /// global notes list. Parallels `MemoryTools.MemoryAppendNote`.
    public func memoryAppendNote(
        text: String,
        endpoint: String? = nil
    ) throws {
        try store.appendNote(text, endpoint: endpoint)
    }

    // MARK: - memory_snapshot (read)

    /// Openclicky superset: returns the whole in-memory store as a
    /// `MemorySnapshot`. This is a READ verb, kept under the historical
    /// method name for bridge compatibility.
    ///
    /// Semantic divergence from Everywhere: `MemoryTools.MemorySnapshot`
    /// (`MemoryTools.cs:162-175`) is a WRITE verb that copies a
    /// sanitised capture body into `sites/<site>/fixtures/<cmd>-<iso>.json`
    /// with 5-file rotation. That behaviour lives on
    /// `memorySnapshotWrite(cmd:content:)` in this port; the bridge
    /// dispatcher exposes both.
    public func memorySnapshot() -> MemorySnapshot {
        store.snapshot()
    }

    // MARK: - memory_snapshot (write, Everywhere semantic)

    /// MCP tool name: `memory_snapshot` per Everywhere wire semantic.
    /// Writes `content` to `<storeDir>/snapshots/<cmd>-<yyyymmddTHHmmssZ>.json`
    /// and keeps at most the 5 most recent files per `cmd`. Returns the
    /// absolute path of the file that was written.
    ///
    /// 1:1 with `MemoryTools.MemorySnapshot` (`MemoryTools.cs:162-175`)
    /// and `MemoryStore.WriteSnapshot` (`MemoryStore.cs:197-215`),
    /// collapsed to the single-tenant layout (`<storeDir>/snapshots/`
    /// in place of `sites/<domain>/fixtures/`).
    @discardableResult
    public func memorySnapshotWrite(
        cmd: String,
        content: String
    ) throws -> String {
        try store.writeSnapshot(cmd: cmd, content: content).path
    }

    // MARK: - memory_freshness

    /// MCP tool name: `memory_freshness`. Returns
    /// `{ freshness, lastWriteAt, stalenessSeconds }`. The `freshness`
    /// enum string (`fresh` / `stale` / `cold`) matches Everywhere's
    /// `MemoryTools.MemoryFreshness` wire shape (`MemoryTools.cs:158`);
    /// the numeric fields are openclicky supersets retained for the
    /// pre-fix downstream callers.
    public func memoryFreshness() -> MemoryFreshnessInfo {
        store.freshness()
    }

    // MARK: - memory_write_verify_fixture

    /// MCP tool name: `memory_write_verify_fixture`. Stores a raw JSON
    /// body against `cmd`. Throws `mergeConflict` when the fixture
    /// already exists and `force` is false, matching
    /// `MemoryTools.MemoryWriteVerifyFixture`.
    public func memoryWriteVerifyFixture(
        cmd: String,
        fixture: String,
        force: Bool = false
    ) throws {
        try store.writeVerifyFixture(cmd: cmd, fixture: fixture, force: force)
    }
}
