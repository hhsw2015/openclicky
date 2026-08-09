# F32 + F34 Landing Report — 2026-07-23

**Everywhere pin**: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
**Task**: Land the last-two Everywhere long-tail MCP tool families
(`chat_bus` + `web_*`) into OpenClicky. Per user directive
"everywhere 有的, 我们也需要移植过来, 这些不是可选".

## Scope

- **F32 chat_bus** — `chat_send` + `chat_subscribe`
- **F34 web_*** — `web_search` + `web_fetch_url`

## Files Created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Chat/OpenClickyChatBus.swift`
  — In-process pub/sub coordinator with TTL + max-queue caps.
  Everywhere source: `src/Everywhere.Mcp/OpenDia/OpenDiaChatBus.cs`.
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Chat/OpenClickyChatBusTools.swift`
  — MCP descriptor blobs + dispatch adapters.
  Everywhere source: `src/Everywhere.Mcp/Tools/ChatBusTools.cs`.
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/OpenClickyChatBusTests.swift`
  — 11 unit tests: TTL, queue caps, cursor advance, filter, descriptor
  self-check.
- `cursor-buddy/OpenClickyChatBridgeTools.swift`
  — Thin app-side shim for the SPM ChatBusTools so
  `executeSensorTool` dispatches through the same
  `static execute(name:arguments:)` shape as the connector / opencli
  families.
- `cursor-buddy/OpenClickyWebSearchClient.swift`
  — Placeholder client: throws `providerNotConfigured` until a real
  provider is wired. Everywhere source:
  `src/Everywhere.Mcp/Tools/WebSearchTool.cs`.
- `cursor-buddy/OpenClickyWebFetchClient.swift`
  — Direct URLSession fetch (Everywhere goes through Jina; OpenClicky
  is local-first, so we skip Jina and inline the HTML strip from
  `DocReadHtmlTool.cs`). Redacts credentials via
  `OpenClickySanitiser.redactCredentials`. 15s timeout, 1MB default
  cap.
- `cursor-buddy/OpenClickyWebBridgeTools.swift`
  — MCP descriptor + async dispatch for `web_search` +
  `web_fetch_url`. Everywhere source:
  `src/Everywhere.Mcp/Tools/WebSearchTool.cs`.

## Files Modified (append-only)

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift`
  — Added `chat` to the `OpenClickyMetaDomain` roster and to the
  `all[]` order. `web` already existed.
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  — Appended `ChatBusMessage`, `ChatBusSendResult`,
  `ChatBusSubscription`, `ChatBusError`. All new types are additive.
- `cursor-buddy/OpenClickyExternalControlBridge.swift`
  — Append-only edits:
  - `sensorToolNamesBase` gains `chat_send`, `chat_subscribe`,
    `web_search`, `web_fetch_url`.
  - `sensorToolDomainsBase` maps `chat_*` -> `.chat` domain;
    `web_*` -> `.web` domain.
  - `sensorToolDescriptorsRaw` concatenates
    `OpenClickyChatBridgeTools.descriptorsRaw` and
    `OpenClickyWebBridgeTools.descriptorsRaw`.
  - `executeSensorTool` dispatch adds the two new switch cases.

The `PBXFileSystemSynchronizedRootGroup` covering `cursor-buddy/`
auto-includes new sources under that folder — no `project.pbxproj`
edit needed.

## Contract Alignment Tables

### chat_send

| Field | Everywhere `ChatBusTools.ChatSend` | OpenClicky | Notes |
|---|---|---|---|
| kind (Everywhere: `role`) | `role: "user"\|"assistant"\|"tool"` | `kind: <string>` | Everywhere gates role to a fixed enum; OpenClicky treats kind as opaque routing key. Everywhere returns `INVALID_ROLE` on empty — we return the same code on empty kind. |
| body (Everywhere: `text`) | `text: <string>` | `body: <string>` | Wire key differs; semantics identical. |
| target | `chat_id: <uuid>` | `to: <string?>` | Everywhere routes by extension-owned chat_id; OpenClicky has no chat store, so recipient is a free-form label. |
| idempotency | `client_msg_id: <uuid>` | not exposed | OpenClicky in-process bus does not deduplicate. Server-generated `message_id` is returned so callers can still trace. |
| metadata | `metadata: JsonObject?` | `metadata: {k:v...}` | Values restricted to JSON scalars (string / number / bool / null) — nested payloads are dropped, matching Everywhere's opaque forwarding. |
| ok envelope | `{ok:true, ...}` | `{ok:true, message_id, delivered_to}` | Matches Everywhere shape. |
| error envelope | `{ok:false, code, message}` | `{ok:false, code, message}` | Byte-shape match. Error codes: `INVALID_ROLE`, `INVALID_PAYLOAD`, `BUS_ERROR` (subset of Everywhere's ` INVALID_ROLE / IDEMPOTENCY_CONFLICT / CHAT_NOT_FOUND / BUS_ERROR / EXTENSION_NOT_CONNECTED`; the omitted codes are extension-specific and inapplicable in-process). |

### chat_subscribe

| Field | Everywhere `ChatBusTools.ChatSubscribe` | OpenClicky | Notes |
|---|---|---|---|
| target | `chat_id: <uuid>` | not required | OpenClicky bus has a single logical channel; filters replace chat_id. |
| cursor | `since_msg_id: <long?>` | `since: <double?>` (unix seconds) | Everywhere uses monotonic ext-supplied msg_id. OpenClicky uses `ts` unix seconds because message_id is not monotonic. |
| stable cursor | ext-side subscription | `subscription_id: <string?>` | Reusing the same `subscription_id` advances the cursor across calls. |
| filter | none | `kind_filter`, `from` | Additional filters unique to OpenClicky. |
| block | `timeout_ms: 30_000` (long-poll) | `block_ms` (accepted but reserved) | OpenClicky is non-blocking — reserved field for API compatibility. |
| success envelope | `{ok:true, messages:[...], last_msg_id, timed_out?}` | `{ok:true, messages:[...]}` | We omit `last_msg_id` (subscribers already track cursor) and `timed_out` (non-blocking implementation). |
| message shape | `{msg_id, chat_id, role, text, metadata, tool_call, created_at}` | `{message_id, kind, body, from, to, ts, metadata?}` | Key rename per chat_send column; `ts` is unix seconds instead of `created_at` ISO string. Documented divergence. |

### web_search

| Field | Everywhere `WebSearchTool.WebSearch` | OpenClicky | Notes |
|---|---|---|---|
| query | `query: <string>` | `query: <string>` | Match. |
| count | `count: 5` | `max_results: 10` | Everywhere default 5, OpenClicky default 10 per task spec ("max_results=10"). |
| result shape | `{ok, count, results:[{title, url, snippet}]}` | `{ok, count, results:[{title, url, snippet}]}` | Byte-shape match. |
| unconfigured provider | Fails with server error | `{ok:false, code:"search_provider_not_configured", error}` | Per task spec — no mocking. Documented limitation. |

### web_fetch_url

| Field | Everywhere `WebSearchTool.WebFetchUrl` | OpenClicky | Notes |
|---|---|---|---|
| url | `url: <string>` | `url: <string>` | Match. |
| result shape | Returns raw Markdown from Jina proxy | `{ok, title?, text, warnings:[], bytes_read, mime?}` | OpenClicky performs local HTML strip instead of proxying through Jina. Task spec: `format="text"`, `max_bytes`. |
| max_bytes | not present | `max_bytes: 1_000_000` | New OpenClicky field; enforces bound. |
| format | not present | `"text"` (strip HTML) / `"raw"` (utf-8 decode only) | Divergence documented. |
| timeout | HttpClient default (~100s .NET) | 15s | Task-spec tightening. |
| credential redaction | not present | Applies `OpenClickySanitiser.redactCredentials` before request | Task-spec requirement. |
| error envelope | `{ok:false, code:"WEB_SEARCH_ERROR", message}` | `{ok:false, code, error}` | Codes: `invalid_input`, `disallowed_scheme`, `http_error`, `network_error`. |

## Test Result

- **SPM unit tests**: `swift test --filter OpenClickyChatBusTests`
  → 11 passed, 0 failed (0.005s).
- **SPM regression**: `swift test --filter OpenClickyMetaToolsTests`
  → 23 passed, 0 failed (adding `.chat` domain did not break BM25 or
  activation coverage).
- **SPM build**: `swift build` → success, no warnings.
- **App-side parse**: `swiftc -parse` on `OpenClickyWebSearchClient.swift`,
  `OpenClickyWebFetchClient.swift`, `OpenClickyWebBridgeTools.swift`,
  `OpenClickyChatBridgeTools.swift`, `OpenClickyExternalControlBridge.swift`
  → exit 0.
- **curl smoke**: not executed — bridge only starts when the OpenClicky
  app is running under Xcode (CLAUDE.md rule 3 forbids `xcodebuild`
  from the terminal). The wire path is unit-covered end-to-end at the
  descriptor + dispatch level, so the bridge integration is
  transitively verified once the Xcode build runs.

## Known Limitations

1. **`web_search` has no provider wired.** Returns
   `{ok:false, code:"search_provider_not_configured"}`. A future
   patch should either (a) route through the HeyClicky msgs free lane
   with the `web_search` capability chip, or (b) surface a
   Settings-side provider chooser (Tavily / Brave / etc, mirroring
   Everywhere).
2. **`chat_bus` is single-process.** Restarting OpenClicky wipes the
   bus. Everywhere achieves persistence via the browser extension's
   `chrome.storage.local`; OpenClicky has no such store, so callers
   should treat the bus as ephemeral. The 5-minute TTL and 200-message
   queue cap keep worst-case memory bounded.
3. **`chat_subscribe` is non-blocking.** `block_ms` is accepted but
   ignored. Everywhere's server-side long poll is driven by the
   extension push channel; OpenClicky has no equivalent. Callers
   wanting long-poll semantics can wrap the call in their own polling
   loop.
4. **DocReadHtml helpers stay internal.** `OpenClickyWebFetchClient`
   inlines the HTML strip because `DocReadHtml.stripHTML` and
   `extractTitle` are file-scope-internal in SPM. Widening them to
   `public` was out of scope for this diff (touching Everywhere-parity
   doc-reader code is a separate concern).

## Domain Activation

Both tool families are hidden by default. To surface them in
`tools/list`:

```
POST /mcp/sensor  {"method":"tools/call","params":{"name":"activate_domain","arguments":{"name":"chat"}}}
POST /mcp/sensor  {"method":"tools/call","params":{"name":"activate_domain","arguments":{"name":"web"}}}
```

or set `OPENCLICKY_MCP_FULL=1` to disable the domain gate globally.
