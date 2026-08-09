# Phase 5 — Memory Tools Port (2026-07-23)

Port of Everywhere `src/Everywhere.Mcp/Tools/MemoryTools.cs` +
`src/Everywhere.Mcp/OpenCli/Memory/MemoryStore.cs` @30e03e9d.

## Everywhere source read

- `MemoryTools.cs` exposes 8 MCP tools guarded by `SelfExpandGate`, each
  wrapping calls into `MemoryStore`. Names:
  - `memory_read` — freshness + metadata for a site
  - `memory_read_endpoint` — one `EndpointSpec` under a site
  - `memory_write_endpoint` — write `EndpointSpec`, merge-conflict guarded
  - `memory_write_field_map` — bulk write `FieldMapEntry` values
  - `memory_write_verify_fixture` — 4-tuple verify fixture
  - `memory_append_note` — append ISO-timestamped note to `notes.md`
  - `memory_freshness` — fresh / stale / cold bucket
  - `memory_snapshot` — write sanitized fixture, keep last 5 per cmd
- Storage layout under `~/.everywhere/sites/<domain>/`:
  - `endpoints.json` (dict name→EndpointSpec)
  - `field-map.json` (dict name→FieldMapEntry)
  - `verify/<cmd>.json`
  - `notes.md` (ISO-timestamped `---` separated blocks)
  - `metadata.json` (site metadata, `verifiedAt` ms)
  - `fixtures/<cmd>-<ISO>.json` (rotated, keep last 5)
- Concurrency: `MergeSafeWriter.WriteAtomic` writes to `<path>.tmp` then
  renames; `MergeSafeWriter.MergeAtomic` wraps read/mutate/write in a
  cross-process file lock and throws `MemoryLockTimeoutException`.
- Freshness: `Freshness.Classify(verifiedAt)` returns `fresh` (<30d),
  `stale` (30–90d), `cold` (>90d). `verifiedAt == 0` → `cold`.
- Timestamp source: `SystemClock.NowMs()` → unix milliseconds.

## OpenClicky adaptation

Single-tenant (no per-site fanout). One JSON envelope at
`~/Library/Application Support/OpenClicky/memory.json` with the same
conceptual shape:

```
{
  "endpoints":       { name: MemoryEndpoint },
  "fieldMap":        { key: string },
  "notes":           [ "ISO\ntext" ],
  "verifyFixtures":  { cmd: raw-json-string },
  "lastWriteAt":     unix-ms
}
```

`MemoryEndpoint` = `{ name, fields:{k:v}, notes:[…], lastWriteAt }`.

Concurrency: in-process `NSLock` around the cache + atomic file write
using a tmp path plus `Darwin.rename`. Cross-process locking is out of
scope (openclicky runs a single app process).

Method surface on `OpenClickyMemoryTools` mirrors the C# names in
`snake_case` bindings and camelCase Swift methods:

- `memoryRead(key:)` — dict of entries (or one entry if key given)
- `memoryReadEndpoint(endpoint:)` — one endpoint or nil
- `memoryWriteEndpoint(endpoint:fields:notes:force:)` — MERGE_CONFLICT
  when the endpoint already exists and `force == false`
- `memoryWriteFieldMap(map:force:)` — bulk merge into top-level fieldMap
- `memoryAppendNote(text:endpoint:)` — append note; `endpoint==nil`
  appends to global notes, else to the endpoint's `notes`
- `memorySnapshot()` — full dump (`MemorySnapshot`)
- `memoryFreshness()` — `{ last_write, staleness_seconds }`
- `memoryWriteVerifyFixture(cmd:fixture:force:)` — store JSON string

## Types (appended to Types/CaptureTypes.swift)

- `MemoryEntry`, `MemoryEndpoint`, `MemorySnapshot`, `MemoryFreshnessInfo`
- All `Codable`, `Equatable`, `Sendable`.

## Files touched

- Sources/OpenClickyContextService/Memory/MemoryStore.swift (new)
- Sources/OpenClickyContextService/Memory/OpenClickyMemoryTools.swift (new)
- Sources/OpenClickyContextService/Types/CaptureTypes.swift (append)
- Tests/OpenClickyContextServiceTests/MemoryStoreTests.swift (new)
