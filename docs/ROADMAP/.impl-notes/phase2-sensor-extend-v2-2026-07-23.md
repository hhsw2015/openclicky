# Phase 2 sensor extension v2 impl notes — 2026-07-23

Extend `/mcp/sensor` from 22 → 43 tools by adding 7 doc readers + 8 memory
tools + 6 meta tools.

## Ground truth

- Bridge: `cursor-buddy/OpenClickyExternalControlBridge.swift` (already imports
  `OpenClickyContextService`).
- SPM APIs read-only:
  - `DocRead{Pdf,Docx,Xlsx,Pptx,Epub,Html,Txt}.read(path:URL, maxPages:Int?) async throws -> DocReaderResult`
    with `text`, `pageCount?`, `wordCount?`, `mimeType`, `warnings`.
  - `OpenClickyMemoryTools(store: MemoryStore.shared)` — 8 methods.
  - `OpenClickyMetaToolRegistry` — no shared singleton in SPM; the bridge owns
    a static instance and registers all sensor tools at init time.

## Registry integration

- Add a private static registry `sensorMetaRegistry` on
  `OpenClickyExternalControlBridgeServer`.
- Register all 43 sensor descriptors with domain + `isHidden` (core visible,
  others hidden until domain activated).
- Wire a `MetaToolDispatchDelegate` conformer (`SensorMetaDispatchDelegate`)
  that forwards `dispatch(name:argumentsJson:)` back to
  `executeSensorTool` with parsed arguments — reuses the existing dispatch
  table.

## Domain assignment

- `core` (22 existing tools): all Phase 1 + Phase 5 Layer 0 sensor tools.
  Visible in default `tools/list`.
- `doc_readers` (7): `doc_read_pdf`, `doc_read_docx`, `doc_read_xlsx`,
  `doc_read_pptx`, `doc_read_epub`, `doc_read_html`, `doc_read_txt`. Hidden.
- `memory` (8): `memory_read`, `memory_read_endpoint`, `memory_write_endpoint`,
  `memory_write_field_map`, `memory_append_note`, `memory_snapshot`,
  `memory_freshness`, `memory_write_verify_fixture`. Hidden.
- Meta tools filed under `core` so they always list (they are the surface for
  discovering the hidden tiers): `list_more_tools`, `search_tools`,
  `activate_domain`, `list_domains`, `call_tool`, `batch`. Visible.

## tools/list gate

`sensorToolDescriptors` returns core-visible descriptors when the domain gate
is on (default), otherwise all. Hidden-but-active-domain tools are also
returned. `OPENCLICKY_MCP_FULL=1` bypasses the gate entirely.

Note: this replaces the previous static `sensorToolDescriptors` list. The
descriptor list is now derived from the registry + activation set. Sensor tool
allowlist for `tools/call` is also derived from the registry so all 43 tools
are dispatchable regardless of activation.

## Doc reader argument shape

- All 7 doc readers accept `{ path: string, max_pages?: int }`.
- Result envelope: `{ text, page_count, word_count, mime_type, warnings }`
  (snake_case for wire consistency with existing sensor envelopes).
- Errors: `fileNotFound` / `archiveInvalid` / `parseFailed` /
  `encodingFailed` → `{error: "..."}` + `isError:true`.

## Test plan

Extend `scripts/test-mcp-sensor.sh`:

- expected tool count = 22 core + 6 meta = 28 visible under default gate; when
  `activate_domain` calls succeed the hidden domains join the list. Simpler: assert
  `>= 22` and include the new visible meta tools (`list_more_tools`, `search_tools`,
  `activate_domain`, `list_domains`, `call_tool`, `batch`) → visible count 28.
- Assert `list_more_tools` (no category) returns hidden doc + memory tools (15).
- Assert `list_more_tools category="doc_readers"` returns 7.
- Assert `search_tools query="get_focused_context"` top hit is
  `get_focused_context`.
- Assert `activate_domain name="memory"` returns `{ok:true, ...}` and
  `memory_read` becomes visible via `tools/list`.
- Assert `list_domains` returns entries for the 9 known domains.
- `call_tool name="get_idle_time"` returns seconds.
- `batch` two-step round-trip.
- `doc_read_txt path=/etc/hostname` returns text field.
- `memory_read` returns entries dict (may be empty).
- `memory_append_note` then `memory_snapshot` shows the note.
