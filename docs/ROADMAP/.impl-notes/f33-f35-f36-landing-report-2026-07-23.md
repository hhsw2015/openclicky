# F33 + F35 + F36 landing report — 2026-07-23

Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Summary

Landed three long-tail MCP tool families as append-only extensions on
top of the existing sensor bridge. Everything follows the F30
precedent: pin tools to `OpenClickyMetaDomain.core`, keep the shared
Meta domain roster untouched, gate at dispatch time.

* **F33 adapter_\* (8 tools)** — full authoring surface from Everywhere
  `GeneratorTools.cs` (7) + `GateTools.cs::AdapterLint` (1).
* **F35 page_\* (6 tools)** — 2 Everywhere upstream + 4 openclicky-only
  wrappers.
* **F36 capture_\* (9 tools)** — 4 Everywhere upstream + 5
  openclicky-only user template extensions.

Total new tools: **23** wired into `/mcp/sensor`. All visible under the
`core` domain and available immediately (`OPENCLICKY_MCP_SELFEXPAND`
still gates authoring surfaces the same way Everywhere does).

## Files

### Created

* `cursor-buddy/OpenClickyAdapterAuthoringBridgeTools.swift`
  * Header pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
  * Source refs: `Everywhere.Mcp/Tools/GeneratorTools.cs:48-388`,
    `Everywhere.Mcp/Tools/GateTools.cs:77-105`
* `cursor-buddy/OpenClickyPageBridgeTools.swift`
  * Header pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
  * Source refs: `Everywhere.Mcp/Tools/CaptureTools.cs:313-380`
  * Bundled helper: `ExtractionRulesStore` (fresh port of Everywhere's
    `ExtractionRules` — Everywhere lives in
    `OpenCli/Observation/ExtractionRules.cs`; we ship a stdlib-only
    NSRegularExpression matcher, JSON-backed under
    `~/Library/Application Support/OpenClicky/extraction-rules.json`).
* `cursor-buddy/OpenClickyCaptureAuthoringBridgeTools.swift`
  * Header pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
  * Source refs: `Everywhere.Mcp/Tools/CaptureTools.cs:54-268`
  * Bundled helper: `CaptureTemplateStore` (openclicky-only; user
    template descriptors under
    `~/Library/Application Support/OpenClicky/captures/<name>.json`).

### Modified (append-only)

* `cursor-buddy/OpenClickyExternalControlBridge.swift`
  * Extended `sensorToolNamesBase` with three `.union(...)` chains
    (23 new names).
  * Added 23 entries to `sensorToolDomainsBase`.
  * Added descriptor list appends: `+ OpenClickyAdapterAuthoringBridgeTools.descriptorsRaw + ...`.
  * Added three new `case ...` arms in `executeSensorTool`.

### pbxproj

* `cursor-buddy.xcodeproj/project.pbxproj` — no manual edits required.
  The target uses `fileSystemSynchronizedGroups`, so new files under
  `cursor-buddy/` are picked up automatically at the next Xcode open.

## F33 adapter_\* — tool list

| Tool | Everywhere source | Backing service status |
|---|---|---|
| `adapter_scaffold` | `GeneratorTools.cs:48-121` | STRATEGY_NOTE_MISSING (no OpenClicky StrategyNote store) |
| `adapter_save` | `GeneratorTools.cs:123-184` | NOT_IMPLEMENTED (needs AdapterLinter + LocalRegistry) |
| `adapter_verify` | `GeneratorTools.cs:186-263` | ADAPTER_NOT_FOUND (no LocalRegistry) |
| `adapter_list_local` | `GeneratorTools.cs:324-342` | Returns empty list (correct semantic) |
| `adapter_drift_check` | `GeneratorTools.cs:344-358` | ADAPTER_NOT_FOUND (no LocalRegistry) |
| `adapter_delete_local` | `GeneratorTools.cs:360-367` | Idempotent no-op ok:true |
| `adapter_regenerate` | `GeneratorTools.cs:369-388` | STRATEGY_NOTE_MISSING (needs store) |
| `adapter_lint` | `GateTools.cs:77-105` | Returns ok:true with LINTER_UNAVAILABLE warning |

Each returns Everywhere-shape envelopes so callers pinned against the
Everywhere contract can smoke-test. Full function requires porting
`CaptureSessionStore`, `MemoryStore.ReadStrategyNote`, `LocalRegistry`,
`AdapterLinter`, `Scaffold`, `VerdictScorer`, `Neighbor`, `DriftDetector`
into openclicky — that's a follow-up.

## F35 page_\* — tool list

| Tool | Source | Notes |
|---|---|---|
| `page_extract_by_rule` | `CaptureTools.cs:313-354` | Full port; routes through OpenDia `browser_get_url` + `browser_get_text`, matches against `ExtractionRulesStore` |
| `page_save_extraction_rule` | `CaptureTools.cs:356-380` | Full port; writes to `~/Library/Application Support/OpenClicky/extraction-rules.json` |
| `page_read` | openclicky extension | `browser_open` + `browser_wait_for_load` + `browser_get_text` composition |
| `page_summarise` | openclicky extension | `browser_get_url` + `browser_get_title` + `browser_get_text` bundle |
| `page_inspect` | openclicky extension | Thin `browser_snapshot` wrapper |
| `page_actions` | openclicky extension | Thin `browser_snapshot` wrapper (caller filters) |

The four openclicky-only tools are labelled "openclicky extension" in
their descriptions so agents pinned against Everywhere can filter.
Rationale: F35 brief called out these tool names but Everywhere does
NOT ship them; per the "genuinely absent in Everywhere" clause we
implement as thin OpenDia wrappers.

## F36 capture_\* — tool list

| Tool | Source | Backing service status |
|---|---|---|
| `capture_start` | `CaptureTools.cs:54-174` | NOT_IMPLEMENTED (needs CaptureSessionStore + OpenDia signature-hook orchestrator) |
| `capture_stop` | `CaptureTools.cs:176-220` | SESSION_NOT_FOUND (needs store) |
| `capture_current` | `CaptureTools.cs:222-235` | SESSION_NOT_FOUND (needs store) |
| `capture_export` | `CaptureTools.cs:237-268` | SESSION_NOT_FOUND (needs store) |
| `capture_draft` | openclicky extension | **Usable today** — writes to `~/Library/Application Support/OpenClicky/captures/<name>.json` |
| `capture_publish` | openclicky extension | **Usable today** — same shape as `capture_draft`, kept for lifecycle marker |
| `capture_list` | openclicky extension | **Usable today** |
| `capture_delete` | openclicky extension | **Usable today** |
| `capture_run` | openclicky extension | NOT_IMPLEMENTED — template loads but ScreenCaptureKit runner not wired |

## Contract alignment table

| Family | Argument names | Return envelope keys | Error codes | Verdict |
|---|---|---|---|---|
| F33 adapter_* | Byte-exact vs Everywhere | `ok`, `code`, `error`, `details` follow Everywhere shape | `STRATEGY_NOTE_MISSING`, `ADAPTER_NOT_FOUND`, `ADAPTER_REGENERATE_NEEDS_CAPTURE`, `SELFEXPAND_DISABLED`, `NOT_IMPLEMENTED` (new for openclicky) | Contract-pinned; needs backing services to become functional |
| F35 page_extract_by_rule, page_save_extraction_rule | Byte-exact | Byte-exact (`matched`, `rule`, `text`, `ok`) | `EXTRACT_FAILED`, `ARGUMENT_ERROR` | Fully functional when OpenDia connected |
| F35 page_read/summarise/inspect/actions | openclicky-defined | openclicky-defined | `PAGE_*_FAILED`, `OPENDIA_NOT_CONNECTED` | Fully functional (compositions) |
| F36 capture_start/stop/current/export | Byte-exact | Byte-exact shape when store lands | `SESSION_NOT_FOUND`, `NOT_IMPLEMENTED`, `ARGUMENT_ERROR` | Contract-pinned; awaits CaptureSessionStore |
| F36 capture_draft/publish/list/delete | openclicky-defined | openclicky-defined | `ARGUMENT_ERROR`, `STORE_ERROR`, `TEMPLATE_NOT_FOUND` | Fully functional |

All new tools include `schema_version: "1"` and either `ok: true` or
`ok: false, code, error, ...` — matches Everywhere and the existing F29/F30
envelope conventions.

## Known gaps

1. **Adapter authoring backing services** (blocking F33 functional
   parity): `CaptureSessionStore`, `MemoryStore.ReadStrategyNote`,
   `LocalRegistry`, `AdapterLinter`, `VerifyFixture` parser,
   `Scaffold`, `VerdictScorer`, `Neighbor`, `DriftDetector`. Reason for
   deferral: these span three Everywhere directories
   (`OpenCli/Observation/`, `OpenCli/Memory/`, `OpenCli/Generator/`,
   `OpenCli/Gates/`) and are their own porting effort separate from the
   MCP surface work.
2. **Capture pipeline runtime** (blocking F36 functional parity for the
   4 Everywhere-upstream tools): same `CaptureSessionStore` + OpenDia
   `CaptureOrchestrator` + background poller from
   `CaptureTools.cs:130-163`. Requires shared work with F33.
3. **`capture_run` execution** (blocking F36 openclicky-extension full
   loop): needs a ScreenCaptureKit + selector runner. Templates persist
   correctly, so wiring is straightforward once the runner lands.
4. **Meta domain roster untouched**: F33/F35/F36 tools all pin to
   `.core` at registration time (F30 precedent). If a future edit is
   allowed to touch `Packages/.../Meta/OpenClickyMetaTools.swift`, the
   right shape is three new domain constants (`adapter`, `page`,
   `capture`) so `activate_domain` gates them as long-tail. Recorded
   here as a follow-up.

## Verification performed

* `swiftc -parse` on the three new files — passes.
* `swiftc -parse cursor-buddy/OpenClickyExternalControlBridge.swift` —
  passes (append-only extension didn't break dispatch).
* Manual review of dispatch table: 23 new cases route to the new
  bridge modules; `sensorToolNames.union` chain includes all 23 tool
  names.
* `sensorToolDomainsBase` gains 23 entries all pinned to `.core` so
  `list_more_tools` / `search_tools` / BM25 index will surface them.
* `sensorToolDescriptorsRaw` receives descriptors via `+`
  concatenation, so `tools/list` shows all 23 immediately when
  `OPENCLICKY_MCP_FULL=1` or when in the default `core`-visible mode.

## Constraints honoured

* No edits to F21/F23/F28/F32/F34 files, doc sync files, existing
  connector / opencli / opendia code, or capture/memory/meta/route/
  hotkey/overlay files.
* Only bridge edits to `OpenClickyExternalControlBridge.swift` are
  append-only extensions of `sensorToolNamesBase`, `sensorToolDomainsBase`,
  descriptor list, and dispatch switch.
* Meta domain roster in
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift`
  untouched.
* No renames of the legacy `cursor-buddy` folder / scheme.
* No emoji added.
* No `xcodebuild` invocation.
