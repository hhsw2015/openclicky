# F33 adapter_* + F35 page_* + F36 capture_* landing review — 2026-07-23

Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`

Files audited:

- `cursor-buddy/OpenClickyAdapterAuthoringBridgeTools.swift` (8 tools)
- `cursor-buddy/OpenClickyPageBridgeTools.swift` (6 tools + `ExtractionRulesStore`)
- `cursor-buddy/OpenClickyCaptureAuthoringBridgeTools.swift` (9 tools + `CaptureTemplateStore`)
- Bridge wire in `cursor-buddy/OpenClickyExternalControlBridge.swift`

Everywhere reference:

- `src/Everywhere.Mcp/Tools/GeneratorTools.cs:48-388` (7 adapter_* tools + `opendia_smoke_check`)
- `src/Everywhere.Mcp/Tools/GateTools.cs:77-105` (`adapter_lint`)
- `src/Everywhere.Mcp/Tools/CaptureTools.cs:54-268` (4 capture_* tools)
- `src/Everywhere.Mcp/Tools/CaptureTools.cs:313-380` (2 page_* tools)

## F33 adapter_* alignment table

| Tool | Everywhere args | Openclicky args | Return code (openclicky) | Everywhere reference | Verdict |
|---|---|---|---|---|---|
| adapter_scaffold | `site, name, session_id, description?, neighbor_hint?` (`GeneratorTools.cs:52-56`) | Same (`OpenClickyAdapterAuthoringBridgeTools.swift:66-81`) | `STRATEGY_NOTE_MISSING` when store absent (`:239-247`) | Everywhere returns same code at `GeneratorTools.cs:61` when note missing | Contract-pinned. Openclicky always returns the code because there is no `StrategyNote` store. |
| adapter_save | `site, name, source, verify_fixture, session_id?` (`GeneratorTools.cs:127-130`) | Same (`OpenClickyAdapterAuthoringBridgeTools.swift:88-98`) | `ARGUMENT_ERROR` (bad JSON) or `NOT_IMPLEMENTED` (`:250-278`) | Everywhere ARGUMENT_ERROR: `GeneratorTools.cs:135` | `ARGUMENT_ERROR` byte-match; `NOT_IMPLEMENTED` is openclicky-invented — no upstream collision. |
| adapter_verify | `site, name, fixture_override?` (`GeneratorTools.cs:188-191`) | `site, name` only — no `fixture_override` (`OpenClickyAdapterAuthoringBridgeTools.swift:107-115`) | `ADAPTER_NOT_FOUND` (`:280-290`) | `GeneratorTools.cs:197` | Missing `fixture_override` argument — divergence from upstream schema not mentioned in landing report. |
| adapter_list_local | `()` no args (`GeneratorTools.cs:324-342`) | `()` (`OpenClickyAdapterAuthoringBridgeTools.swift:110-127`) | Returns `{schema_version, ok:true, adapters:[]}` (`:292-303`) | Everywhere returns a JsonArray directly, not an object. See Issue #1. | Envelope shape diverges. |
| adapter_drift_check | `site, name, current_output` (`GeneratorTools.cs:346`) | Same (`OpenClickyAdapterAuthoringBridgeTools.swift:130-139`) | `ADAPTER_NOT_FOUND` (`:305-316`) | `GeneratorTools.cs:353` | Aligned. |
| adapter_delete_local | `site, name` (`GeneratorTools.cs:362`) | Same (`OpenClickyAdapterAuthoringBridgeTools.swift:146-153`) | `ok:true` idempotent (`:318-334`) | `GeneratorTools.cs:365: return new JsonObject { ["ok"] = true }...` | Aligned. |
| adapter_regenerate | `site, name, session_id?` (`GeneratorTools.cs:374`) | Same (`OpenClickyAdapterAuthoringBridgeTools.swift:161-168`) | `ADAPTER_REGENERATE_NEEDS_CAPTURE` if session_id missing, else `STRATEGY_NOTE_MISSING` (`:336-353`) | `GeneratorTools.cs:377/383` — same two codes in that order | Aligned. |
| adapter_lint | `source, site?, name?, fixture?` (`GateTools.cs:79-83`) | Same (`OpenClickyAdapterAuthoringBridgeTools.swift:175-183`) | `{ok:true, errors:[], warnings:[LINTER_UNAVAILABLE]}` (`:355-376`) | `GateTools.cs:98-104` returns `{ok, errors, warnings}` | Shape aligned; openclicky adds a `LINTER_UNAVAILABLE` warning inside the empty warnings list. |

**Self-expand gate**: `adapter_*` execute at `OpenClickyAdapterAuthoringBridgeTools.swift:194-197` — early-return `SELFEXPAND_DISABLED` when `OPENCLICKY_MCP_SELFEXPAND=0`. Everywhere: `GeneratorTools.cs:57` etc. Aligned.

## F35 page_* alignment table

| Tool | Everywhere args | Openclicky args | Return | Verdict |
|---|---|---|---|---|
| page_extract_by_rule | `url?` (`CaptureTools.cs:317-320`) | Same (`OpenClickyPageBridgeTools.swift:58-64`) | `{matched, rule?, text}` (`:207-223`) | `CaptureTools.cs:338/346-351` returns `{matched, rule?, text}` — aligned. Openclicky adds `schema_version, ok`. |
| page_save_extraction_rule | `url_pattern, kind, selector, priority?` (`CaptureTools.cs:361-364`) | Same (`OpenClickyPageBridgeTools.swift:73-79`) | `{ok:true}` (`:256`) or `ARGUMENT_ERROR` (`:238-244`) | `CaptureTools.cs:367-370, 379` — aligned. |
| page_read | (openclicky-native) | `url?, format?` (`OpenClickyPageBridgeTools.swift:88-93`) | `{schema_version, ok, text, format}` (`:265-283`) | Not present in Everywhere. Documented in report §"page_*". |
| page_summarise | (openclicky-native) | `()` (`OpenClickyPageBridgeTools.swift:98-106`) | `{schema_version, ok, url, title, text}` (`:287-304`) | Not present in Everywhere. |
| page_inspect | (openclicky-native) | `selector?` (`OpenClickyPageBridgeTools.swift:113-118`) | `{schema_version, ok, snapshot}` (`:307-325`) | Not present in Everywhere. |
| page_actions | (openclicky-native) | `()` (`OpenClickyPageBridgeTools.swift:123-129`) | `{schema_version, ok, snapshot, note}` (`:328-342`) | Not present in Everywhere. |

**OpenDia gate**: `execute` at `OpenClickyPageBridgeTools.swift:158-163` returns `OPENDIA_NOT_CONNECTED` when subprocess is not running (matches Everywhere's `OPENDIA_NOT_CONNECTED` at `CaptureTools.cs:324`). `page_save_extraction_rule` skips the gate — pure disk write. Aligned.

**Self-expand gate**: `OpenClickyPageBridgeTools.swift:140-144`. Everywhere: `CaptureTools.cs:322`. Aligned.

**Extraction rules store**: `~/Library/Application Support/OpenClicky/extraction-rules.json` (`OpenClickyPageBridgeTools.swift:418`). Everywhere: `~/.everywhere/extraction-rules.json`. Documented sandbox-friendly rename.

## F36 capture_* alignment table

| Tool | Everywhere args | Openclicky args | Return | Verdict |
|---|---|---|---|---|
| capture_start | `tab_id?, origin?` (`CaptureTools.cs:59-63`) | Same (`OpenClickyCaptureAuthoringBridgeTools.swift:69-72`) | `NOT_IMPLEMENTED` (`:226-234`) | Contract-pinned; landing report §"F36 capture_*" acknowledges. |
| capture_stop | `session_id` (`CaptureTools.cs:178-180`) | Same (`OpenClickyCaptureAuthoringBridgeTools.swift:83-84`) | `SESSION_NOT_FOUND` (`:236-244`) | Everywhere `SESSION_NOT_FOUND` at `CaptureTools.cs:218`. Byte-match. |
| capture_current | `session_id` (`CaptureTools.cs:225`) | Same (`OpenClickyCaptureAuthoringBridgeTools.swift:95-96`) | `SESSION_NOT_FOUND` (`:246-254`) | Aligned. |
| capture_export | `session_id` (`CaptureTools.cs:242`) | Same (`OpenClickyCaptureAuthoringBridgeTools.swift:107-108`) | `SESSION_NOT_FOUND` (`:256-264`) | Aligned. |
| capture_draft | (openclicky-native) | `name, selector?, region?` (`OpenClickyCaptureAuthoringBridgeTools.swift:120-135`) | `{schema_version, ok, name, path}` (`:268-299`) | Fully implemented; writes to `~/Library/Application Support/OpenClicky/captures/<name>.json`. |
| capture_publish | (openclicky-native) | `name` (`OpenClickyCaptureAuthoringBridgeTools.swift:145-148`) | Same as `capture_draft` — dispatch aliased at `:212` | Lifecycle marker; identical impl. |
| capture_list | (openclicky-native) | `()` (`OpenClickyCaptureAuthoringBridgeTools.swift:156-159`) | `{schema_version, ok, captures:[...]}` (`:301-317`) | Implemented. |
| capture_delete | (openclicky-native) | `name` (`OpenClickyCaptureAuthoringBridgeTools.swift:167-170`) | `{schema_version, ok, name, existed}` (`:319-340`) | Implemented. |
| capture_run | (openclicky-native) | `name` (`OpenClickyCaptureAuthoringBridgeTools.swift:180-183`) | `NOT_IMPLEMENTED` with `template` echo (`:342-366`) | Landing report confirms stub. Template load path works — `CaptureTemplateStore.load` at `:462-470`. |

**Self-expand gate**: `OpenClickyCaptureAuthoringBridgeTools.swift:192-196`. Everywhere: `CaptureTools.cs:66`. Aligned.

## Bridge wire audit (all 23 F33/F35/F36 tools)

- **sensorToolNamesBase**: unions with `OpenClickyAdapterAuthoringBridgeTools.toolNames` (`OpenClickyExternalControlBridge.swift:1801`), `OpenClickyPageBridgeTools.toolNames` (`:1803`), `OpenClickyCaptureAuthoringBridgeTools.toolNames` (`:1805`). All 23 present in the three static `toolNames` sets. PASS.
- **sensorToolDomainsBase**: all 23 pinned to `.core` (`OpenClickyExternalControlBridge.swift:1904-1911, 1916-1921, 1925-1933`). Landing report §"Bridge wire" confirms F30 precedent. Note: this contradicts the F15/F17 recommendation of separate `adapter`, `page`, `capture` domains. Documented as follow-up in landing report §"Known gaps 4". Not a bug, but a deferred item.
- **Descriptor concat**: `+ OpenClickyAdapterAuthoringBridgeTools.descriptorsRaw + OpenClickyPageBridgeTools.descriptorsRaw + OpenClickyCaptureAuthoringBridgeTools.descriptorsRaw` (`OpenClickyExternalControlBridge.swift:2501-2503`). PASS.
- **Dispatch**: F33 -> `:3052-3060`, F35 -> `:3063-3069`, F36 -> `:3072-3081`. Each family routes into its own `.execute` static. PASS.
- **Prefix collision check**: `adapter_*` / `page_*` / `capture_*` do not collide with existing `browser_*` / `connector_*` / `opencli_*` / `chat_*` / `web_*` / `advisor_*` prefix families. PASS.
- **sensor_health capture_count**: computed as `sensorToolDescriptorsRaw.count` (`OpenClickyExternalControlBridge.swift:2607`) — dynamic, so the F33/F35/F36 additions are counted automatically. PASS.

## Issues

### Issue 1 — `adapter_list_local` return shape diverges from Everywhere (MEDIUM)

Everywhere returns a bare `JsonArray` — `GeneratorTools.cs:341: return arr.ToJsonString();` — with each entry `{site, name, generated_at, adapter_version, sha256}`. Openclicky returns `{schema_version:"1", ok:true, adapters:[]}` (`OpenClickyAdapterAuthoringBridgeTools.swift:296-301`). Callers pinned to the Everywhere contract that expect `result[0].site` will fail against openclicky (must go through `result.adapters[0].site`). Either wrap in an object on both sides via a schema patch (document as intentional divergence) or return a bare array from openclicky.

### Issue 2 — `adapter_verify` schema drops `fixture_override` argument (LOW)

Everywhere: `AdapterVerify(string site, string name, string? fixture_override = null, CancellationToken ct = default)` (`GeneratorTools.cs:188-191`). Openclicky descriptor at `OpenClickyAdapterAuthoringBridgeTools.swift:107-115` exposes only `site` and `name`. Since the implementation is `NOT_IMPLEMENTED` anyway, this is not user-visible today — but when the backing service lands, the argument will not be recognisable through the descriptor. Add `fixture_override` to the input schema now to keep the contract in sync.

### Issue 3 — `ExtractionRulesStore.upsert` re-entrant lock deadlock (CRITICAL)

`OpenClickyPageBridgeTools.swift:438-448`:

```
func upsert(_ rule: Rule) throws {
    lock.lock(); defer { lock.unlock() }
    var rules = loadUnsafe()           // <- also locks
    ...
    try save(rules)
}
```

`loadUnsafe` at `:450-458` also does `lock.lock(); defer { lock.unlock() }`. `NSLock` is not reentrant — the second `lock()` from the same thread will deadlock the caller permanently.

Reproduction: any single call to `page_save_extraction_rule` will hang forever. This is the primary write path for the tool.

Fix options: (a) remove the `lock.lock()` from `loadUnsafe` and rename to `readRulesLocked()` (caller ensures lock); (b) restructure `upsert` to release before calling `loadUnsafe` — but then the read/modify/write is racy. Option (a) is what other stores in this repo do — e.g. `OpenClickyPickStore`, `OpenClickyWhiteboardStore` (verify against those). See also `CaptureTemplateStore.load/save` at `:446-460` where separate methods each take their own lock without cross-calling — that pattern works because they never chain from within a locked section.

### Issue 4 — `capture_publish` and `capture_draft` are functionally identical (LOW)

Dispatch at `OpenClickyCaptureAuthoringBridgeTools.swift:211-212`: `capture_publish` routes to the same `handleDraft` as `capture_draft`. Landing report says "Currently a lifecycle marker" and the descriptor at `:141-142` says the same. Two problems: (a) `capture_publish` accepts only `{name}` in its input schema (`:143-149`) but `handleDraft` reads `selector` and `region` too (`:275-283`) — if a caller uses `capture_publish` with those, they'll be silently applied. (b) There is no distinguishing state field written to the file to mark "published vs draft" — so the lifecycle-marker contract is not observable. Either add a `state: "draft" | "published"` field to the persisted `CaptureTemplate` or collapse the two into one tool.

### Issue 5 — `CaptureTemplate` persistence has no schema version (LOW)

`CaptureTemplate` at `OpenClickyCaptureAuthoringBridgeTools.swift:398-408` has no schema-version field baked into the on-disk JSON. When the runner eventually lands, future migrations will have to guess format. Add `schema_version: "1"` to the struct now — cheap and prevents a stale-file trap later.

### Issue 6 — `page_extract_by_rule` matched-envelope has an inconsistent `text` payload shape (LOW)

At `OpenClickyPageBridgeTools.swift:200`, `browser_get_text` returns a `[String: Any]` envelope; the code assigns the entire envelope to `"text"` (`:212`) and to `"text"` again at `:221`. The Everywhere version at `CaptureTools.cs:338-351` explicitly casts to `text?.ToJsonString() ?? ""` and to `extracted is null ? "" : extracted.ToJsonString()`. Openclicky emits a dict instead of a JSON string — the wire shape differs. A caller expecting `result.text` to be a string will get an object.

Fix: apply `JSONSerialization.data(withJSONObject: envelope)` and store the resulting string, or extract `envelope["result"]?["text"]` scalar.

### Issue 7 — `page_summarise` returns raw envelope inside `text` key (LOW)

`OpenClickyPageBridgeTools.swift:291, 297`: `textRes = try await callBrowser(tool: "browser_get_text", arguments: [:])` — the resulting `[String: Any]` envelope goes straight into `body["text"]`. Same string-vs-dict inconsistency as Issue 6. The `url` and `title` fields at `:295-296` are extracted via `extractScalar`, but `text` bypasses that helper.

### Issue 8 — Domain choice `.core` for `adapter_*`, `page_*`, `capture_*` violates F15/F17 gating discipline (MEDIUM — deferred by landing report)

23 tools land in `.core`, which is the always-visible search tier per `OpenClickyMetaDomain.core` semantics at `OpenClickyMetaTools.swift:71-72`. Everywhere hides these behind SPEC gates (`SelfExpandGate`). The landing report §"Known gaps 4" documents this as an intentional deferral — but the practical effect is that `tools/list` on a fresh session surfaces the entire 23-tool authoring pile alongside real always-on tools like `get_focused_context`. The self-expand gate at execute-time hides the *execution* of these tools when `OPENCLICKY_MCP_SELFEXPAND=0`, but not their *listing*. This inflates the default tools/list payload agents receive by 23 stubs. Follow-up: add `adapter`, `page`, `capture` domain constants and pin these tools out of `.core`.

### Issue 9 — Envelope key mismatch: `error` vs `message` (LOW)

F33/F35/F36 error envelopes use `{"ok":false, "code", "error"}` (`OpenClickyAdapterAuthoringBridgeTools.swift:392-401`, `OpenClickyPageBridgeTools.swift:368-377`, `OpenClickyCaptureAuthoringBridgeTools.swift:384-393`). Everywhere across `GeneratorTools.cs:451`, `GateTools.cs:127`, `CaptureTools.cs:420` all use `{"ok":false, "code", "message"}`. Landing report §"Contract alignment table" claims byte-shape parity — that is false for the error-key rename. Cross-family internal consistency also breaks: F32 chat_bus uses `message` (`OpenClickyChatBusTools.swift:174-180`) while F33/F35/F36 use `error`. Standardise on `message` to preserve the Everywhere pin, or document the intentional rename across all landing reports.

### Issue 10 — Descriptor text advertises the wrong browser tool names (COSMETIC)

`OpenClickyPageBridgeTools.swift:87, 112, 125` describe the tools as calling `browser_get_text`, `browser_snapshot`, etc. `OpenClickyOpenDiaBridgeTools.toolList` (referenced at bridge wire) publishes these under the `browser_` prefix. `page_extract_by_rule` handler at `:186, 200, 216, 272` uses `browser_get_url`, `browser_get_text`. Verify these names exist in the OpenDia advertised list — Everywhere `GeneratorTools.opendia_smoke_check` at `:414-426` normalises by stripping `browser_` prefix because OpenDia advertises without prefix. If the openclicky bridge only advertises stripped names, `callBrowser("browser_get_url", ...)` will 404 upstream. Not verified in this review — spot check advised.

## Contract-only-tool marking

Landing report §"F33 adapter_*": every tool clearly returns a well-formed error envelope with structural evidence (`backing_service: "OpenClickyStrategyNoteStore (unimplemented)"` at `:246`, `backing_services: ["AdapterLinter (unimplemented)", "LocalRegistry (unimplemented)"]` at `:273-276`). Callers can distinguish stubs from real responses. PASS.

Landing report §"F36 capture_run" surfaces `NOT_IMPLEMENTED` with a `template` echo (`OpenClickyCaptureAuthoringBridgeTools.swift:357-365`), also a clear stub signal. PASS.

## Verdict

**F33 adapter_***: 8 tools wired with mostly correct contract shape. Issues 1 (list-shape divergence) and 2 (missing `fixture_override`) are contract drift that will bite when backing services land. Issue 9 (error vs message key) is a byte-shape parity claim in the report that the code does not fulfil.

**F35 page_***: 2 Everywhere + 4 openclicky-native wrappers wired. Issue 3 (ExtractionRulesStore re-entrant deadlock) is a **critical bug** — `page_save_extraction_rule` will hang on any real call. Issue 6/7 (browser envelope leaking into `text` key) breaks scalar-string contract on both `page_extract_by_rule` and `page_summarise`.

**F36 capture_***: 4 Everywhere-shape stubs + 5 openclicky-native (4 usable + 1 stub). Issue 4 (`capture_publish` == `capture_draft`) makes the lifecycle marker functionally invisible. Issue 5 (no schema version in `CaptureTemplate` on-disk shape) is a small forward-compat gap.

**Bridge wire**: 23/23 F33+F35+F36 names correctly wired. Issue 8 (all-`.core` domain choice) is a documented deferral, not a wiring bug. No prefix collisions with other families.

**Priority fix list**:

1. Issue 3 — deadlock in `ExtractionRulesStore.upsert` — blocks `page_save_extraction_rule`.
2. Issue 6 — `page_extract_by_rule` payload wraps browser envelope inside `text` instead of scalar string; breaks Everywhere-pinned callers.
3. Issue 9 — settle on `message` vs `error` key across all bridge tool families.
4. Issue 1 — `adapter_list_local` return shape.
5. Issue 4 — collapse or differentiate `capture_publish` / `capture_draft`.
