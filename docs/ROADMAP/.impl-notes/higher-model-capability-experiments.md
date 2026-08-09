# Higher-model capability experiments

Two independent POCs against the HeyClicky Free `/chat-tool-call`
endpoint. Same wire (`HeyClickyProxyClient.postJSON`) so they can be
validated externally without touching voice/UI code.

## Endpoint under test

`POST /chat-tool-call`
- Body: `query, screenshotBase64, mimeType, client_capabilities,
  frontmost_app_bundle_id, environment, session_id?,
  screenshotWidthInPixels?, screenshotHeightInPixels?`
- Response: `HigherModelResponse { text, clipboardText?, typing?,
  point?, widgets, walkthrough?, annotationText? }`

Server prompt is server-side (opaque); we can only shape:
1. `query` string content
2. `client_capabilities` declared string list
3. Whether we send screenshot / dims

## POC 1 — Tool-call extension

**Question**: Can the higher-model perform actions beyond the current
built-in set (`clipboard_copy`, `walkthrough.beats`, `typing`, `point`)?
Specifically: file write, HTTP request, subprocess execution.

**Hypothesis**: `client_capabilities: [...]` is a declarative feature
flag the server prompt reads to decide which action fields to populate
in the response. Adding new strings may unlock new response fields OR
may be silently ignored (server prompt has no matching handler).

**Test protocol**:

1. Send a query explicitly asking the model to perform action X:
   ```
   query: "Write the string 'poc test' to /tmp/openclicky_poc.txt"
   client_capabilities: ["write_file"]
   ```
2. Inspect response JSON keys. Look for `writeFile`, `file_write`,
   `fileOperation`, or freeform `text` describing intent.
3. Try progressively richer capability names + prompt hints:
   `run_shell`, `subprocess`, `curl`, `http_request`.
4. Cross-check by removing capabilities — does the same query
   produce different output shape?

**Expected outcomes**:
- Server ignores unknown capabilities → response schema unchanged
  → **conclusion: server prompt is fixed; extending needs server
  changes**
- Server acknowledges via new response field → we can wire client
  handlers for each
- Server emits text-only "I would write ... but cannot" → server
  knows about the concept but has no execution channel

**Deliverable**: A single-shot script that POSTs 5-10 variations
and dumps the response JSON. Grep for unexpected keys.

## POC 2 — Long-output continuation (no information loss)

**Question**: When a query needs > server single-response cap
(~2-4k chars observed in `HigherModelResponse.text`), can we
orchestrate the model to produce the full content in segments
without silent truncation?

**Design principle** (user's requirement): NOT "detect truncation
and stitch" — that loses information at the boundary. Instead:
**contract-based segmentation** — model knows in advance it has N
segments and writes to a per-segment budget.

**Protocol design**:

Round 1 query:
```
Task: produce full text of <thing>. This is a multi-part response.

Rules:
- Output at most M chars this turn.
- If material remains, end with the literal line:
    [NEXT: part_2_covers=<one-sentence topic of next segment>]
- If everything fits, end with the literal line:
    [DONE]
- Never emit either marker mid-content.

Now write PART 1.
```

Round K query (K > 1):
```
Continuing multi-part response. Previous parts:

--- Part 1 ---
<prior part 1 text>

--- Part K-1 ---
<prior part K-1 text>

Rules unchanged: max M chars, end with [NEXT: ...] or [DONE].

Now write PART K.
```

**Termination**:
- Model emits `[DONE]` → stop, concatenate parts
- Max K reached (e.g. K=10 safety cap) → stop with warning
- Response missing marker → treat as `[DONE]` (server capped
  without cooperation)

**Test protocol**:

1. Prompt: "输出鲁迅《狂人日记》全文" (known-long, > any single
   response cap)
2. Run the loop with M=1500, max_k=10.
3. Concat parts, compare to canonical text. Zero-loss = success.
4. Also test a task where the model has to invent content
   (spec / architecture doc) — check semantic continuity across
   parts, no repetition at boundaries.

**Deliverable**: A standalone Swift script (or plain `curl`
harness) that runs the multi-part loop and dumps concatenated
output + per-round char counts.

## POC location

Neither POC needs OpenClicky UI. Both can be a single Swift file
in `Packages/OpenClickyContextService/Sources/Experiments/` or a
scripts/*.sh wrapper. Neither should touch `HeyClickyChatToolCallClient`
until POC results confirm feasibility.

## Follow-up (only if POCs succeed)

- POC 1 → design a proper capability negotiation protocol; client
  handlers for approved actions; UX permission dialog.
- POC 2 → add `postChatToolCallMultiPart(query:maxParts:budget:)`
  to `HeyClickyChatToolCallClient` and route long-doc gestures
  through it.
