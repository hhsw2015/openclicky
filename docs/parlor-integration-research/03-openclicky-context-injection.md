# OpenClicky Context Injection — Subsystem Map

Scope: every context source that can reach an outgoing LLM request on a voice turn, how it is
triggered, what shape it takes, what it costs, and exactly where it lands in the prompt.

All paths absolute-relative to repo root `/Users/wowdd1/Dev/openclicky`.

Two facts to hold onto before reading the table:

1. There is **one central aggregator** for the SKI/Mirage lanes —
   `CompanionManager.buildSKIUtteranceContext` (`cursor-buddy/CompanionManager.swift:5783-5926`)
   — and a **separate, differently-ordered assembly** for the main in-app LLM lane inside
   `_analyzeVoiceResponseCore` (`cursor-buddy/CompanionManager+AIResponsePipeline.swift:667-869`).
   The two do not share code; they share sources. Divergence between them is the single biggest
   source of surprise in this subsystem.
2. Context splits across a **cache-stable system block** and a **volatile system block** plus a
   **user-prompt prefix**. The split is deliberate (Anthropic prompt-cache hashes bytes only up to
   the cache breakpoint) and documented at `cursor-buddy/CompanionManager.swift:18613-18624`.

---

## Source table

| Source | Trigger | Payload shape | Size / token cost | Where injected | file:line |
|---|---|---|---|---|---|
| **Screen history (OpenRewind) FTS hits** | Voice turn, only when `openclicky.screenHistory.capture.screen` is on and query non-empty | Text: top-3 FTS rows `  - [id ISO8601 windowName] snippet(140)` + drill-down tool pointer | ~3 x 200 chars = ~600 chars, ~150 tok | SKI/Mirage lane only, as `openrewind:` line in context brief | `cursor-buddy/CompanionManager.swift:5897-5917` |
| **Screen history via LTM query hits** | Every voice turn, query >= 2 chars | Text: `Relevant history for this question:` + top-4 hits, 160 chars each | ~480 chars (comment at `LongTermMemoryContext.swift:367-368`), ~120 tok | Main lane, user-prompt prefix (first block) | `cursor-buddy/OpenRewind/Bridge/LongTermMemoryContext.swift:251-400`, injected `CompanionManager+AIResponsePipeline.swift:716` |
| **LTM ambient blocks** (coverage, daily recap, recent activity, live focus, recent exchanges) | Every voice turn; ambient tiers dropped for `world_knowledge`/`live_context` intents | Text, 6 tiered blocks + 6-line protocol header | Budget `openclicky.ltm.budget_chars` default **6000 chars ≈ 1500 tok** | Main lane, user-prompt prefix | `LongTermMemoryContext.swift:95-244`, budget `:222-223`, applied `:671-712` |
| **Persistent memory (`memory.md`)** | Every voice turn, unconditional | Markdown, newest-first tail-truncated | `maxCharacters: 6_000` default ≈ **1500 tok** | **Volatile system block**, under `persistent memory:` header | `cursor-buddy/CodexHomeManager.swift:250-279`; injected `CompanionManager.swift:18626`, `:18783`, `:18806` |
| **App skill context** | Every voice turn; frontmost app matched against a hardcoded 10-app table | Text: tagline + app UI prose + concepts + workflows | **NO CAP**, 1.5-2.5 KB ≈ 400-600 tok | **Volatile system block** | `cursor-buddy/OpenClickyAppSkillContext.swift:26-59`, `:97-385`; injected `CompanionManager.swift:18596-18601` |
| **Context stash** (pins / whiteboard / links / annotations / selection) | Every voice turn (read), written by hotkeys | Text: `pinned UI elements (N):` + rows, plus window/URL | Uncapped in prompt; source fields sanitised (selection 200, title 80, url 256, annotation body 800) | Main lane user-prompt prefix (2nd block); also realtime system prompt | `CompanionManager.swift:18898+`; injected `CompanionManager+AIResponsePipeline.swift:724-727`, `CompanionManager.swift:18794` |
| **"Everywhere" active window** | Every voice turn; nil when OpenClicky is frontmost | Text: `[active-window] app= · window="…160" · url= · file= · workdir=` + `[picked-context]` <=6 rows | ~200-500 chars, ~60-120 tok | Main lane user-prompt prefix (3rd block) | `cursor-buddy/AssistAgent/AssistAgentActiveWindowContext.swift:43-56`; injected `CompanionManager+AIResponsePipeline.swift:729-732` |
| **xlinkBook topics** | Every AI path, gated `AppBundleConfiguration.xlbEnabled()` (default **false**) | Text: `[xlb-context]` block, up to 5 candidates + tool pointer + optional agent-state | Hard cap `xlbContextMaxChars = 1500` ≈ **375 tok** | Main lane, **prepended to raw user prompt** (innermost, closest to question) | `CompanionManager+AIResponsePipeline.swift:382`, `:480-551`; applied `:699` |
| **xlinkBook topics (SKI variant)** | SKI/Mirage lane, gated same key but read as default **true** | Text: `matched topics: A, B, C.` + tool menu | **No cap** | SKI/Mirage `xlb:` brief line | `CompanionManager.swift:5843-5878` |
| **Runtime storage map** | Every voice turn, unconditional | Text: 13 absolute filesystem paths | ~700 chars ≈ 175 tok | **Volatile system block** | `CompanionManager.swift:18575-18594` |
| **Visual-guidance calibration** | Only when >=1 calibration sample exists | Text: long prose + per-screen offsets | ~1500 chars ≈ 375 tok when present | **Volatile system block** | `CompanionManager.swift:18641-18649`, `:18734-18744` |
| **Web-search capability note** | Only Anthropic provider + Agent SDK live | Text, one paragraph | ~350 chars ≈ 90 tok | **Volatile system block** | `CompanionManager.swift:18769-18779` |
| **Clipboard** | SKI/Mirage lane, when non-empty | Text: `clipboard has N chars — related tool: get_clipboard` (metadata only, NOT contents) | ~60 chars | SKI/Mirage `clipboard:` line | `CompanionManager.swift:5919-5923` |
| **Screenshots** | Voice turn when `shouldAttachScreenContext`; prewarmed at key-down | **IMAGE** JPEG, max dim 1280, quality 0.8, one per display | ~1600 tok/image (Anthropic) | `images[]` array on the request | `cursor-buddy/CompanionScreenCaptureUtility.swift:168-175`, `:195-196`; assembled `CompanionManager+AIResponsePipeline.swift:1912-1914` |
| **Camera frame** | Voice turn when `openClickyCameraVoiceContextEnabled` OR transcript matches ~20 phrases | **IMAGE** JPEG quality 0.78, **native `.high` preset, no downscale** | Highest per-image cost of any source; unbounded | `images[]` array | `cursor-buddy/OpenClickyCameraCaptureController.swift:227`, `:314`; gate `CompanionManager+AIResponsePipeline.swift:1344-1361`; appended `:1917` |
| **Circle-select crop** | User circles a region while speaking | **IMAGE** JPEG crop + ambient summary text | Variable | `images[]` **first**, plus a note appended to user prompt | `CompanionManager+AIResponsePipeline.swift:1906-1909`, `:1924-1927` |
| **MCP endpoint advert** | SKI/Mirage lane when bridge port live | Text: URL + truncated token + tool list | ~150 chars | SKI/Mirage `mcp:` line | `CompanionManager.swift:5822-5826`, rendered `CompanionManager+AIResponsePipeline.swift:3000-3003` |

---

## Injection points

Three distinct assembly sites. Order matters and differs between them.

### A. Main in-app LLM lane — `_analyzeVoiceResponseCore`
`cursor-buddy/CompanionManager+AIResponsePipeline.swift:667-869`

Entered from `analyzeVoiceResponse` (`:600-640`), which first checks for a voice profile switch.

```
:678   XLBSensorTools.resetTurnBudget()          // per-turn xlb cap reset (was monotonic)
:689   systemPrompt = AssistAgentBridge.effectiveSystemPrompt(systemPrompt)
:699   xlbInjectedUserPrompt = applyXLBHintIfEnabled(to: userPrompt)
       // -> "[xlb-context]…[/xlb-context]\n\n" + userPrompt

:702-735  dynamic prefix assembly (skipped entirely on reentrant assist-agent rounds):
   1. :716  LongTermMemoryContext.build(query:)     -> ltmBlock + "\n\n"
   2. :724  currentStashContextForVoicePrompt()     -> stashCtx + "\n\n"
   3. :729  AssistAgentActiveWindow.capture()?.promptBlock -> block + "\n\n"
   final:   prefix + "---\n\nCurrent request:\n" + xlbInjectedUserPrompt
```

So the final user message is, outermost to innermost:

```
<LTM block>

<stash block>

<[active-window] + [picked-context]>

---

Current request:
[xlb-context]
…
[/xlb-context]

<actual transcript>
```

The xlb hint deliberately sits **closest to the question** (comment `:693-698`), while LTM/stash/
active-window land in front. Rationale given at `:679-686`: keeping volatile per-turn context near
the user's utterance puts the model's attention on it at inference time rather than diluting it
across a large system prompt.

The system prompt is supplied by the caller, normally
`currentVoiceResponseSystemPrompt()` (`CompanionManager.swift:18603-18611`) =
`stableVoiceResponseSystemPrompt()` + `"\n\n"` + `dynamicVoiceResponseSystemContext()`.

`dynamicVoiceResponseSystemContext()` (`CompanionManager.swift:18625-18639`), in order:
```
inlineWebSearchCapabilityPromptIfAvailable()   :18628  (Anthropic + Agent SDK only)
currentAppSkillContextPrompt()                 :18629  (uncapped skill fragment)
visualGuidanceCorrectionLearningPrompt()       :18630  (only if calibration samples exist)
runtimeStorageContextForVoicePrompt()          :18632  (13 filesystem paths)
"persistent memory:" header + guidance         :18634-18635
codexHomeManager.persistentMemoryContext()     :18626/:18637  (6000 chars)
```

Cache discipline: only `stableVoiceResponseSystemPrompt()` may carry `cache_control`
(`:18613-18618`). Everything above is intentionally placed **after** the breakpoint so it does not
invalidate the cached prefix.

Dispatch then builds `LLMRequest` (`:857-864`) and routes by provider through
`dispatchViaLLMRegistry` (`:865-868`).

### B. SKI / Mirage lane — `buildSKIUtteranceContext` -> `buildMirageContextBrief`
`cursor-buddy/CompanionManager.swift:5783-5926` and
`cursor-buddy/CompanionManager+AIResponsePipeline.swift:2976-3006`

`buildSKIUtteranceContext` returns `OpenClickyFileBridge.UtteranceContext` with seven optional
brief strings, gathered in this order:

```
1. :5793-5820  focusedWindowLine + everywhereActiveWindowBrief   (AssistAgentActiveWindow)
2. :5822-5826  mcpURL + mcpToken
3. :5828-5841  ltmMemoriesBrief         (count + first 80 chars, NOT the full LTM block)
4. :5843-5878  xlbTopicsBrief           (fuzzyLookup limit 3)
5. :5880-5890  screenOCRStashBrief      (first line, 80 chars)
6. :5892-5917  openrewindOCRHitsBrief   (FTS top-3, gated on screen-capture toggle)
7. :5919-5923  clipboardBrief           (char count only)
```

`buildMirageContextBrief` (`CompanionManager+AIResponsePipeline.swift:2976-3006`) then renders
these into a flat block appended to the Peeky orchestrator's system prompt, in fixed order
`focused_window, everywhere, ltm, xlb, stash, openrewind, clipboard, mcp` (`:2979-3003`), prefixed
with `"OpenClicky context (available signals — expand via MCP tools when useful):\n"` (`:3005`).

Critical difference from lane A: this lane ships **pointers, not payloads**. Each brief names the
MCP tool that expands it (`openrewind.search`, `xlb_get_topic_meta`, `get_focused_context`,
`get_clipboard`). Total brief is a few hundred tokens versus several thousand for lane A. The CLI
agent decides what to expand.

For SKI Mode proper, `_analyzeVoiceResponseCore` short-circuits at `:747-843`: the **raw**
transcript goes into `event.text` and the enrichment rides as a structured `context` object on the
same `.oc/events.jsonl` event (`:766-769`, `:812-820`), rather than being concatenated into a prompt.

### C. Realtime speech lane
`cursor-buddy/CompanionManager.swift:18782-18801` (sync) and `:18805-18830` (async)

```
Self.companionRealtimeVoiceSystemPrompt
currentRealtimeRoutingContextPrompt()
currentAppSkillContextPrompt()
runtimeStorageContextForVoicePrompt()
currentStashContextForVoicePrompt[Async]()
"persistent memory:" + persistentMemoryContext()
```

Stashes are deliberately **not** drained here (`:18808-18812`) — unlike Shift+Space's
capture/consume/clear cycle, a voice conversation may reference the same pin across turns. The user
clears manually with Alt+C. `drainAllStashesForVoiceTurn()` exists at `:18844-18849` for the
one-shot path.

Note this lane carries no images: any turn with visual context is routed away from Realtime into
the screenshot-aware path (`CompanionManager+AIResponsePipeline.swift:1942`).

---

## Token budget

Per voice turn, main in-app lane, everything enabled. Text estimated at 4 chars/token.

**System blocks**

| Component | Chars | Tokens | Notes |
|---|---:|---:|---|
| Stable voice system prompt | ~6000 | ~1500 | cacheable, amortises to ~150 on hit |
| Web-search note | 350 | 90 | Anthropic + SDK only |
| App skill fragment | 2000 | 500 | uncapped; Blender/Premiere are the largest |
| Visual-guidance calibration | 1500 | 375 | only when samples exist |
| Runtime storage map | 700 | 175 | constant |
| Persistent memory | 6000 | 1500 | hard cap |
| **System subtotal** | | **~4140** | (excl. cached stable block) |

**User-prompt prefix**

| Component | Chars | Tokens |
|---|---:|---:|
| LTM block (budgeted) | 6000 | 1500 |
| LTM query hits (appended after budget) | 480 | 120 |
| Stash block | 800 | 200 |
| Active-window + picked | 400 | 100 |
| xlb hint | 1500 | 375 |
| Transcript | 200 | 50 |
| **Prefix subtotal** | | **~2345** |

**Images**

| Component | Tokens |
|---|---:|
| Screenshot, 1280px, 1 display | ~1600 |
| Second display (if present) | ~1600 |
| Camera frame (native res, no downscale) | ~1600-3000+ |

**Totals**

- Text-only turn: **~6500 tok** (~2800 with a warm prompt cache)
- Typical turn, one screenshot: **~8100 tok**
- Worst case, two displays + camera: **~12000-13500 tok**

Conversation history sits on top of all of this.

Two budget notes worth flagging:

- The two 6000-char budgets (LTM at `LongTermMemoryContext.swift:222-223`, persistent memory at
  `CodexHomeManager.swift:250`) are independent and both default-on, so memory alone is ~3000 tok
  before anything else.
- The app skill fragment is the only text source with **no cap at all**
  (`OpenClickyAppSkillContext.swift:26-59`). It is bounded in practice only because the table has
  exactly 10 hand-written entries.

xlb MCP tools have their own separate per-turn ceiling: `xlbTurnBudget()` = 15% of the model's
context window clamped to `[8_000, 60_000]` (`cursor-buddy/AppBundleConfiguration.swift:328-332`),
enforced by `TurnBudgetActor` (`XLBSensorTools.swift:1283-1299`) and reset each turn at
`CompanionManager+AIResponsePipeline.swift:678`. That budget covers tool *responses*, not the hint.

---

## Multimodal readiness

The question is which sources are already pixels and which have been flattened to text on the way
in. A multimodal frontend model could consume the former directly.

### Already images — pass through as base64, no text intermediation

| Source | Format | Encoder |
|---|---|---|
| Screenshots | JPEG, max 1280px, q0.8 | `CompanionScreenCaptureUtility.swift:168-175`, `:195-196` |
| Camera frames | JPEG q0.78, native `.high` preset | `OpenClickyCameraCaptureController.swift:227`, `:314` |
| Circle-select crops | JPEG crop | `CompanionManager+AIResponsePipeline.swift:1906-1909` |

All three land in the same `images: [(data: Data, label: String)]` array and are base64-encoded per
provider: Anthropic `ClaudeAPI.swift:155-160` and `:379-384` (with PNG-signature sniffing at
`:84-95`), OpenAI `OpenAIAPI.swift:92` and `:377`, Agent SDK `ClaudeAgentSDKAPI.swift:241`.

**Already-multimodal, ready today.** The only work for a new frontend model is honoring the `label`
string, which currently carries dimensions and camera name as human-readable metadata
(`OpenClickyCameraCaptureController.swift:172`, `CompanionManager+AIResponsePipeline.swift:1913`).

### Images on disk, currently reachable only as text

**Screen history frames.** This is the significant one. OpenRewind stores actual pixels:

- Frames are captured at 2 fps baseline, widening to 30 s when idle
  (`OpenRewind/Capture/CaptureScheduler.swift:59`, `:134-135`, `:165-178`), deduped at similarity
  threshold 0.9985 (`Capture/FrameDedup.swift:64`).
- They are encoded into **HEVC .mp4 chunks** at `<vault>/chunks/YYYYMM/DD/<xid>.mp4`, rolling at
  150 frames or 300 s (`Capture/Chunker.swift:5`, `:18`, `:42-46`). Hot frames before encode are
  JPEG q0.85 (`:380`).
- The `frame` table carries `videoId` + `videoFrameIndex`
  (`Kit/SchemaInstaller.swift:42-53`), so any frame is addressable back to its pixels.
- Vault root `~/Library/Application Support/OpenRewind/`, DB `db-enc.sqlite3` (SQLCipher)
  (`Kit/Storage.swift:8`, `:17-18`, `:27`).
- Retention default **3 months**, configurable 1 day / 1 week / 1 month / 3 / 6 / 1 year / forever
  (`Kit/RetentionManager.swift:20-39`).

Retrieval today goes through FTS5 (`searchRanking`, bm25 weights `1.0, 0.3, 3.0`) plus NLEmbedding
vectors (Apple built-in, **300-dim**, EN + zh-Hans, `Bridge/EmbeddingIndex.swift:5-6`, `:50-51`),
RRF-fused (`LongTermMemoryContext.swift:341`). What reaches the prompt is a 140-160 char OCR
snippet per hit.

So the pipeline is: pixels -> Vision OCR -> FTS/embedding -> **160-char text snippet** -> prompt.
A multimodal model could instead be handed the frame itself. The plumbing already exists —
`Reader.cachedImage(for:)` (`Kit/Reader.swift:1015`) and
`ReaderAggregates.thumbnailJPEG(for:)` (`Kit/ReaderAggregates.swift:44`) both return pixels, and
`ContextExtractor` already produces a `jpegBase64_1280` field
(`Kit/ContextExtractor.swift:45`) that nothing currently sends to a model. This is the clearest
multimodal upgrade available: swap the snippet for the frame on the top 1-2 hits.

**Whiteboard captures.** `readWhiteboardImage` exists as an MCP tool
(`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyStashTools.swift:236`)
but the voice prompt only ever sees `whiteboard_pending=true regions=N`.

**PTT screenshot archive.** `Bridge/PTTScreenshotArchive.swift:25` persists JPEGs per push-to-talk
turn; consumed for OCR indexing, not re-shown to the model.

### Text-only by nature

LTM aggregates, persistent memory, app skill fragments, xlb topics, runtime storage map, active
window, clipboard metadata, MCP adverts. No pixel representation exists or is wanted.

### Summary for a multimodal frontend

- **Zero work:** screenshots, camera, circle-select — already images end to end.
- **High value, plumbing exists:** screen-history frames. Currently 160 chars of OCR per hit stands
  in for a full frame that is sitting in an addressable mp4 chunk.
- **Small win:** whiteboard region images, already exposed over MCP.
- **Cost asymmetry to fix first:** camera frames ship at native `.high` resolution with no
  downscaling, while screenshots are clamped to 1280px
  (`OpenClickyCameraCaptureController.swift:227` vs `CompanionScreenCaptureUtility.swift:168`).
  A camera frame can cost more tokens than both displays combined.

---

## Cross-cutting issues found

1. **The xlb index is empty in production.** `startWatchingIfEnabled()`
   (`OpenRewind/Bridge/XLBTopicIndex.swift:1376`) has no callers in `cursor-buddy/`, and there is no
   launch-time `syncIfNeeded()`. The only trigger is the Settings "Rebuild Index" button
   (`OpenClickySettingsWindowManager.swift:3103`). The live SQLite has 0 rows in every table, so
   `fuzzyLookup` returns `[]` and no `[xlb-context]` block is ever produced until the user clicks
   Rebuild.
2. **Contradictory xlb enable defaults on the same key.** `AppBundleConfiguration.xlbEnabled()`
   defaults **false** (`AppBundleConfiguration.swift:253`) and gates the prompt block + MCP tool
   registration; `CompanionManager.swift:5847` reads `openclicky.xlb.enabled` as **default-true**
   and gates the SKI hint. Same key, opposite defaults, different lanes.
3. **App skills are not files.** Despite `AppResources/OpenClicky/` shipping bundled skills, the
   voice lane reads a hardcoded 10-app Swift table (`OpenClickyAppSkillContext.swift:97-385`).
   Adding a bundled skill has zero voice-lane effect. Tracked as P1/P2 in
   `OPENCLICKY_ARCHITECTURE_REVIEW.md:207`, `:216`.
4. **`MemoryStore` (`memory.json`) is never read into any prompt** — MCP tool surface only
   (`Packages/OpenClickyContextService/.../Memory/MemoryStore.swift:63-81`), disconnected from
   `persistentMemoryContext`. The file does not currently exist on disk.
5. **Context hotkey tap installs as `.listenOnly`** because macOS 26 requires Input Monitoring TCC
   for `.defaultTap` (`OpenClickyContextHotkeys.swift:138-150`). Consequence: Shift+Space leaks a
   literal space into the frontmost text field instead of being swallowed.
6. **Dead code:** `LongTermMemoryContext.llmExpandQuery` (`:606-634`) is defined but never called.
7. **Stale comment:** `xlb_get_topic_meta` output claims LPA community detection
   (`XLBSensorTools.swift:401`); `graphCommunity` has used Louvain since F13
   (`XLBTopicIndex.swift:2221-2255`).

---

## Appendix: on-disk locations

| What | Path |
|---|---|
| OpenRewind vault | `~/Library/Application Support/OpenRewind/` |
| OpenRewind DB | `<vault>/db-enc.sqlite3` (SQLCipher) |
| OpenRewind video chunks | `<vault>/chunks/YYYYMM/DD/<xid>.mp4` (HEVC) |
| Persistent memory | `~/Library/Application Support/OpenClicky/AgentMode/CodexHome/memory.md` (rotates at 120 KB) |
| Memory archives | `.../CodexHome/archives/memory/` |
| Memory articles | `.../CodexHome/memories/YYYY-MM-DD-<slug>.md` |
| Context stash | `~/Library/Application Support/OpenClicky/context-stash.json` (0600, 5-min TTL) |
| MemoryStore | `~/Library/Application Support/OpenClicky/memory.json` (unused) |
| xlb index | `~/Library/Application Support/OpenClicky/xlb-topic-index.sqlite` (schema v18) |
| xlb graph export | `~/Library/Application Support/OpenClicky/xlb-graph.json` |
| xlb source data | `~/.xlb-env/xlinkBook/db/library/*-library` (40 files, ~44 MB) |

### OpenRewind SQLite schema
`cursor-buddy/OpenRewind/Kit/SchemaInstaller.swift:13+`. Rewind 1.5607-compatible.

Tables: `segment` (:14), `video` (:27), `frame` (:42), `node` (:56), `doc_segment` (:68),
`audio` (:74), `transcript_word` (:88, with OpenClicky `speakerId` extension), `event` (:107),
`summary` (:122), `frame_processing` (:131), `purge`, plus OpenClicky-only sidecars for embeddings
(300-dim BLOB) and `openclicky_db_storage_snapshot`.

Full-text: three tables mirroring Rewind — `search` (FTS4), `searchRanking` (FTS5, bm25 weights
`1.0, 0.3, 3.0`), `searchOffsets` (FTS4), all Porter-tokenized, plus an `fts3tokenize` helper.

### Reader query API
`cursor-buddy/OpenRewind/Kit/Reader.swift`: `recentEntries(limit:)` :364,
`entryByID(_:)` :388, `entries(from:to:)` :404, `lastSeconds(_:)` :430, `search(_:limit:)` :441,
`ocr(for:)` :597, `segments(from:to:)` :659, `transcriptWords(segmentID:)` :717,
`transcriptText(segmentID:)` :761, `context(for:)` :868, `cachedImage(for:)` :1015.

`Kit/ReaderAggregates.swift`: `thumbnailJPEG(for:)` :44, `appUsage` :287, `dailyRecap` :366,
`searchForAI(_:)` :474, `aiContext(around:)` :488, `exportJSONL(to:)` :552.

`Kit/ContextExtractor.swift:178-189`: `extract(image:capturedAt:bundleID:windowName:browserUrl:
ambient:recognitionLevel:thumbnailWidth:analytics:precomputedOCR:)` returns
`OpenRewindExtractedContext` (:21-80) — OCR text + nodes, language, content kind, perceptual hash,
dominant colors, keywords, AX nodes, transcript snippet, recent apps, recent UI events, segment
echo, frame id, and `jpegBase64_1280`.
