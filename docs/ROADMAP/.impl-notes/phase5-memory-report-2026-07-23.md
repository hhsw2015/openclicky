# Phase 5 — Memory Tools Port Report (2026-07-23)

Everywhere source: `src/Everywhere.Mcp/Tools/MemoryTools.cs` @30e03e9d.

## Tool signatures — 8 tools matched

| Everywhere `[McpServerTool]` | OpenClicky Swift |
|---|---|
| `memory_read(site)` | `OpenClickyMemoryTools.memoryRead(key:)` |
| `memory_read_endpoint(site, name)` | `memoryReadEndpoint(endpoint:) -> MemoryEndpoint?` |
| `memory_write_endpoint(site, name, spec, force)` | `memoryWriteEndpoint(endpoint:fields:notes:force:) throws` |
| `memory_write_field_map(site, mapping, force)` | `memoryWriteFieldMap(map:force:) throws` |
| `memory_append_note(site, text)` | `memoryAppendNote(text:endpoint:) throws` |
| `memory_snapshot(site, cmd, content)` | `memorySnapshot() -> MemorySnapshot` |
| `memory_freshness(site)` | `memoryFreshness() -> MemoryFreshnessInfo` |
| `memory_write_verify_fixture(site, cmd, fixture, force)` | `memoryWriteVerifyFixture(cmd:fixture:force:) throws` |

Semantic parity:
- MERGE_CONFLICT via `MemoryStoreError.mergeConflict(path:)`
- `force = true` bypasses conflict check
- Field-map write is all-or-nothing (colliding key aborts before any
  write, verified by `test_writeFieldMap_collides_throwsAndKeepsExisting`)
- Notes are ISO-8601-prefixed and appended in order
- `memory_freshness` returns unix-ms `lastWriteAt` + seconds since,
  clamped at 0 when store is empty (cold)

Adapted (single-tenant): openclicky has no site domain / no
`sites/<domain>/` fanout, so all methods drop the leading `site` param
and operate on the single envelope. `memory_snapshot` returns the whole
store rather than writing a rotating fixture file — the rotating
`fixtures/<cmd>-<ISO>.json` behaviour was Everywhere-specific and is
not required by any openclicky consumer.

## Storage format

`~/Library/Application Support/OpenClicky/memory.json`:

```json
{
  "endpoints":      { "<name>": MemoryEndpoint },
  "fieldMap":       { "<key>": "<value>" },
  "notes":          [ "<iso>\n<text>" ],
  "verifyFixtures": { "<cmd>": "<raw-json>" },
  "lastWriteAt":    <unix-ms>
}
```

`MemoryEndpoint = { name, fields:{k:v}, notes:[…], lastWriteAt }`.

## Persistence

- Atomic write: serialise → `<path>.tmp` → `Darwin.rename(_:_:)`
- Parent directory created on demand
- Fallback to `NSTemporaryDirectory()` when `applicationSupportDirectory`
  is unavailable (headless CI)
- `NSLock` around the in-memory cache; cross-process locking is out of
  scope (openclicky is single-process)
- Fresh `MemoryStore` init reads the envelope from disk if present;
  a stale `.tmp` shadow is ignored (verified by
  `test_atomicWrite_tmpLeftover_doesNotBreakLoad`)

## Test result

`swift test --filter MemoryStoreTests`:

```
Test Suite 'MemoryStoreTests' passed at 2026-07-23 00:27:31.
    Executed 15 tests, with 0 failures (0 unexpected) in 0.017 seconds
```

15 XCTests covering: fresh store empties, endpoint round-trip,
merge-conflict + force override, ordered notes (global + per-endpoint),
bulk field-map write, partial-write invariant on conflict, full
snapshot, non-zero staleness after clock advance, verify-fixture
conflict/force, on-disk file + no leftover `.tmp`, cross-instance
persistence, stale-`.tmp` tolerance.

## `sign-and-install.sh`

Failed with pre-existing errors unrelated to this port:

```
cursor-buddy/OpenClickyExternalControlBridge.swift:2162:52: error:
    type 'WindowEnumerationCapture' has no member 'EnumerateOptions'
```

Bridge file does not reference `MemoryStore`, `OpenClickyMemoryTools`,
or any memory type; the failure comes from another concurrent agent's
in-flight changes (bridge / window-enumeration are explicitly listed
as do-not-touch in this task). `swift build --target
OpenClickyContextService` succeeds.

## Files

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Memory/MemoryStore.swift` (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Memory/OpenClickyMemoryTools.swift` (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (appended 4 types)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/MemoryStoreTests.swift` (new, 15 tests)
