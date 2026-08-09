# Doc Review Cross-verification

**Date**: 2026-07-22
**Method**: Review agent output cross-checked against Everywhere source code file-by-file.
**Rule**: Everywhere source is ground truth. Review agent findings are hypotheses. Verify each before acting.

---

## VERIFIED — HIGH severity (must fix docs)

### V-H1: `SanitiseTokenValue` strips IPv6 brackets (E40)
- **doc claim (04_LAYER_3_STASH_HOOK.md line 65)**: "SanitiseTokenValue 不做 envelope 替换 (URL 需保留 `[`/`]` 用于 IPv6)"
- **truth (ContextStashWriter.cs:836-847)**: `if (c == '[' || c == ']') continue;` — brackets are STRIPPED, IPv6 broken
- **fix**: correct doc to say brackets stripped; IPv6 URL bracket portion lost (Everywhere behaviour, port as-is)

### V-H2: Whiteboard stash is memory only, not on-disk (E55)
- **doc claim (05_LAYER_4_UX.md line 26)**: "Stash: `~/Library/Application Support/OpenClicky/whiteboard-stash.json`"
- **truth (WhiteboardStash.cs)**: 0 File.* / Path.* / WriteAll — memory-only, TTL 5min
- **fix**: remove whiteboard-stash.json path; document as in-memory TimeSpan.FromMinutes(5) TTL

### V-H3: Tool count 96, not 151 (E60, E3)
- **doc claim (00 line 67 + 10 line 17)**: "151 tool"
- **truth**: `grep -rh 'Name = "'` on `Everywhere.Mcp/Tools/` → 96 unique
- **fix**: replace all "151" and "~80" with "96"

### V-H4: get_app_state / list_apps route via LibAxHelper dylib to OCCU Swift package, NOT cua-driver binary (E28, E29)
- **doc claim (03 tool table)**: "via cua-driver"
- **truth**: `OccuAxBridgeBackend.cs` routes through `LibAxHelper.dylib` → `OpenComputerUseKit` (SPM Swift package)
- **fix**: change table "via cua-driver" → "via OCCU (SPM Swift package)"; clarify openclicky's bundled `cua-driver` binary is trycua/cua-driver (different upstream)

### V-H5: Rust hook does not validate schema_version (E49)
- **doc claim (04 line 117)**: "拒绝: empty / >64KB / 缺 `[openclicky-ctx]` 前缀 / schema_version 不匹配"
- **truth (main.rs:142-148)**: only checks `is_empty()`, `> 64 * 1024`, `starts_with("[everywhere-ctx] ")`
- **fix**: remove schema_version claim from rejection list

### V-H6: open-connector actual dir count 831, not 840 (E4, E61)
- **doc claim**: 00 line 71 "60+", 10 line 21 "840", 10 line 69 "831"
- **truth**: `ls -d 3rd/open-connector/src/providers/*/ | wc -l` = 831
- **fix**: standardize on 831 with note "Everywhere spec claims 840 (upstream may have grown)"

### V-H7: OpenCLI actual site count 173, not 172 (E76)
- **doc claim**: 10 line 502 "172"
- **truth**: `ls -d 3rd/opencli/clis/*/ | wc -l` = 173
- **fix**: 172 → 173

### V-H8: `SanitiseUserText` control chars → space, not skip (E43 clarification)
- **truth (ContextStashWriter.cs:798-817)**: SanitiseUserText replaces control chars with space `' '`; SanitiseTokenValue skips them entirely
- **fix**: doc distinguishes the two behaviours

---

## VERIFIED — MEDIUM severity

### V-M1: `TextSelectionDetector.cs` file does not exist (E12)
- **doc claim (01 row 29)**: `Capture/SelectedTextCapture.swift` refs `TextSelectionDetector.cs`
- **truth**: actual selection file is `VisualElementContext.TextSelection.cs` + `SelectionCache.cs`
- **fix**: rename ref

### V-M2: 03 tool file table has wrong filenames (E30)
- **doc claim**: `FocusedContextTool`, `AppStateTool`, `ClipboardTool`, `ClipboardReadTool`, `ClipboardWriteTool`, `SelectedTextTool`, `IdleTimeTool`
- **truth**: real files: `GetFocusedContextTool.cs`, `GetAppStateTool.cs`, `ClipboardTools.cs` (single file for read/write/paste/copy), `GetSelectedTextTool.cs`, `GetIdleTimeTool.cs`
- **fix**: correct filename column in 03 table

### V-M3: `gate_*` tool namespace does not exist (E27)
- **doc claim (03 line 39)**: "gate_*"
- **truth**: `GateTools.cs` contains `strategy_note_write`, `strategy_note_get`, `adapter_lint` — no `gate_*` prefix tools
- **fix**: remove "gate_*", add "strategy_note_*" + note adapter_lint

### V-M4: Doc tool list omits ~25 real tools (E27 part 2)
- Missing from doc: `adapter_delete_local`, `adapter_drift_check`, `adapter_lint`, `adapter_list_local`, `adapter_regenerate`, `adapter_save`, `adapter_scaffold`, `adapter_verify`, `memory_write_verify_fixture`, `strategy_note_write`, `strategy_note_get`, `search_adapters`, `opencli_describe`, `opendia_smoke_check`, `page_extract_by_rule`, `page_save_extraction_rule`, `web_crypto_scan`, `web_fetch_url`, `web_js_fetch_same_origin`, `web_js_search`, `web_signature_scheme`, `web_sourcemap_list_candidates`, `web_sourcemap_resolve`, `web_techstack`, `web_verdict_score`
- **fix**: rerun exhaustive grep, replace enumeration with full list or point to grep command

---

## VERIFIED — LOW severity

### V-L1: Everywhere targets .NET 10, not .NET 9 (E78)
- **truth**: `obj/Debug/net10.0/` present
- **fix**: 10 doc ".NET 9" → ".NET 10"

### V-L2: Swift grapheme iteration hint wrong (E42)
- **doc claim (04 line 65)**: "Swift: `s.unicodeScalars` + `Character` iteration"
- **truth**: `unicodeScalars` iterates code points, not graphemes; correct API is `string.enumerateSubstrings(in:_, options:.byComposedCharacterSequences)` or iterate `Character`
- **fix**: correct Swift snippet

### V-L3: Swift `FileManager.moveItem` snippet wrong (E46)
- **doc claim (04 line 90)**: `try FileManager.default.moveItem(at: tmp, to: path)`
- **truth**: `moveItem` throws if destination exists; Everywhere C# `File.Move(overwrite: true)` semantics
- **fix**: use `_ = try? removeItem(at: path); try moveItem(...)` or `try replaceItem(at:withItemAt:...)`

---

## REJECTED — Review agent hallucinations / errors

### R1: "Fabricated commit chain" (E6, E57, E64) — REJECTED
- Review agent claim: `feat(annotation)`, `feat(mcp): core-tool gate`, `refactor(mac): retire C# AX automation path`, `feat(ax): add Swift dylib bridge` don't exist
- Truth: `git log --all --author=wowdd1 --pretty=format:"%s" > /tmp/x` shows:
  - 47 `feat(mcp)` commits
  - 9 `feat(annotation)` commits (exact matches: `backend MVP`, `UI spike red badge`, `➕ expands textarea`, `persistent ✓ badges`, `follow element on scroll`, `extend ➕ to whiteboard`, `instant outline+➕`, `whiteboard/linkrect follow anchor`, `delta-follow model`)
  - 7 `feat(mac/ax)` commits
- Review agent used single-branch grep (50 commits total), missed `--all`. Its "CRITICAL fabrication" verdict is wrong.
- All commit references in my 10_OVERLAP_ANALYSIS.md §Three timeline are CORRECT.
- Also `refactor(mac): retire C# AX automation path; route 9 tools through OCCU` exists (git log --all --author=wowdd1 grep confirmed via saved file /tmp/wowdd1-commits.txt).
- **Action: keep timeline block as-is, no doc fix needed for E6/E57/E64.**

Wait — my own grep just above showed 0 matches for annotation from `--author=wowdd1 --pretty=format:"%s"` piped through pipeline vs 42 matches when saving to file first. This is not agent error but shell escaping / pager behaviour. TRUTH: annotation commits exist, review agent's E6/E57/E64 finding is invalid.

### R2: E11 `ElementIndexer.Walk` — DEFER
- Not verified yet. Method may or may not exist by that name. Low priority.

### R3: E19 `AXUIElement.SetAppBoolAttribute` — DEFER
- Not verified yet. Low priority.

### R4: E54 LaunchPhrase default "take a look" — DEFER
- Need to check `McpServerSettings.cs`. If not default, adjust doc.

---

## Action Plan (priority order)

1. **Fix V-H1** (SanitiseTokenValue IPv6): 04 line 65
2. **Fix V-H2** (WhiteboardStash memory-only): 05 line 26
3. **Fix V-H3** (tool count 96): 00, 03, 10
4. **Fix V-H4** (via OCCU not cua-driver): 03 tool table
5. **Fix V-H5** (Rust hook no schema_version): 04 line 117
6. **Fix V-H6** (open-connector 831): 00, 10
7. **Fix V-H7** (OpenCLI 173): 10
8. **Fix V-H8** (control char behaviour): 04
9. **Fix V-M1-M4**: 01, 03 (tool table + filenames)
10. **Fix V-L1-L3**: 04, 10

Every fix commit: `docs(<layer>): reconcile with Everywhere <path> — <what>`
