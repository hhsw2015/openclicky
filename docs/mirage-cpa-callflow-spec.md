# CPA Mirage Call-Flow Spec

Reference implementation walkthrough of the `mirage-uuid` upstream in **CLIProxyAPIPlus** (CPA). Every phase names the exact Go file, function, and line where the behaviour lives so a Swift port can be verified 1:1 against the source.

Scope: only the request path that ends up hitting the free-tier Cloudflare Worker upstream (`auth.Attributes["auth_style"] == "mirage-uuid"`). Everything unrelated (Bedrock, Vertex, first-party Anthropic OAuth, TaijiAI relays) is called out only when a shared code path forks on `isMirageAuth(auth)` / `isAnthropicHostBaseURL(baseURL)`.

Swift host paths use `cursor-buddy/…` (the folder retains the legacy `cursor-buddy` name per project rule 4).

---

## 1. Executive summary

CPA mirage is a Claude request that has been stripped of all Claude-CLI/SDK fingerprints and forwarded to an arbitrary Cloudflare-Worker upstream authenticated only by a rotating UUID header. The end-to-end shape is:

1. **Route.** Client hits `/v1/messages`. Manager picks the auth whose model prefix matches (`mirage/<model>`), then `rewriteModelForAuth` strips `mirage/` from the model string (`sdk/cliproxy/auth/conductor.go:3883-3896`).
2. **Executor entry.** `ClaudeExecutor.Execute` or `ExecuteStream` (`internal/runtime/executor/claude_executor.go:303, :576`) is invoked with the un-prefixed model.
3. **Model + thinking suffix parsing.** `thinking.ParseSuffix(req.Model)` splits `claude-fable-5(max)` → `{ModelName:"claude-fable-5", RawSuffix:"max"}` (`internal/thinking/suffix.go:22`, `apply.go:224`).
4. **Cred lookup.** `claudeCreds(auth)` returns `(api_key, base_url)` from `auth.Attributes` (`claude_executor.go:1915`). For mirage the api-key is the literal placeholder `"mirage-unused-placeholder"` and base_url is empty.
5. **Translate + apply thinking.** Body is translated to Claude format, then `thinking.ApplyThinking` mutates it based on the suffix (adaptive+effort, budget_tokens, etc.).
6. **Body pre-processing pipeline.** ~12 mutators run in fixed order (§2.2). Key mirage-relevant ones: `normalizeClaudeSamplingForUpstream`, `ensureClaudeThinkingDisplay`, cache_control auto-inject/limit/normalize, `extractAndRemoveBetas`.
7. **URL construction.** `claudeFullURL(auth)` overrides the default `{baseURL}/v1/messages?beta=true` — for mirage this returns the CF Worker URL directly (§2.3).
8. **Header application.** `applyClaudeHeaders` (`claude_executor.go:1641`) sees `authStyle == "mirage-uuid"` at L1684 and takes an **early-return branch**: it wipes every Claude-CLI fingerprint header, writes exactly five lowercase headers, plus a conditional lowercase `anthropic-beta` when the body invokes thinking, then returns.
9. **Send.** A uTLS-based rustls-fingerprinted HTTP client sends the request via WARP MASQUE tunnels.
10. **Response.** On 429, `mirageEntryFor(auth).forceRotate()` swaps the pool's UUID immediately. Success streams SSE lines line-by-line to the client scanner.

Everything after phase 5 lives entirely inside `internal/runtime/executor/`; nothing else in CPA needs to know mirage exists.

---

## 2. Request lifecycle (per phase)

### 2.1 Auth resolution + tier detection

Read at the top of `Execute`/`ExecuteStream`:

```go
// claude_executor.go:310-315
baseModel := thinking.ParseSuffix(req.Model).ModelName
upstreamModel := e.upstreamModel(baseModel)
apiKey, baseURL := claudeCreds(auth)
if baseURL == "" {
    baseURL = "https://api.anthropic.com"
}
```

`claudeCreds` (`claude_executor.go:1915-1929`) reads `auth.Attributes["api_key"]` and `["base_url"]`; if `api_key` is empty it also falls back to `auth.Metadata["access_token"]` (OAuth). For a mirage entry from `synthesizeClaudeKeys` the values are:

| Attribute | Mirage value | Source |
|---|---|---|
| `api_key` | `mirage-unused-placeholder` | `config.ClaudeKey.APIKey` |
| `base_url` | *(empty)* | `config.ClaudeKey.BaseURL` |
| `full_url` | e.g. `https://upstream.example.workers.dev/v1/messages` | `ClaudeKey.FullURL` → `synthesizer/config.go:217-219` |
| `auth_style` | `mirage-uuid` | `ClaudeKey.AuthStyle` → `synthesizer/config.go:214-216` (lowercased) |
| `strip_anthropic_beta` | `true` | `synthesizer/config.go:190-192` |
| `source` | `config:claude[<token>]` | `synthesizer/config.go:165` |
| `config_index` | numeric | `synthesizer/config.go:167` |
| `mirage_rotate_at` | *(NOT set by synthesizer — falls back to default 19)* | Only observed in tests; §4 |
| `proxy-url` (on `Auth.ProxyURL`, not attributes) | `warp` | `synthesizer/config.go:242, 269` |

`isMirageAuth(auth)` (`claude_mirage.go:132-137`) is the single tier check used everywhere downstream:

```go
func isMirageAuth(auth *cliproxyauth.Auth) bool {
    if auth == nil || auth.Attributes == nil { return false }
    return strings.EqualFold(
        strings.TrimSpace(auth.Attributes["auth_style"]),
        "mirage-uuid",
    )
}
```

**Swift port gap.** The Swift side already stores `MirageSecrets.upstreamURL` and derives everything else statically (auth_style is implicit from the fact that we selected `.peekyFree`). No parity gap here — CPA's Attribute-bag is a config-driven runtime concern that Swift resolves at compile time via `OpenClickyModelProvider`.

---

### 2.2 Body pre-processing pipeline

The mutator sequence is identical between `Execute` (`:330-414`) and `ExecuteStream` (`:602-682`). Below each row: what it does, whether it fires for a mirage request, and why.

| # | Function | Location | Fires for mirage? | Notes |
|---|---|---|---|---|
| 1 | `helps.TranslateRequestWithCodexMultiAgentV2` | :331, :602 | Yes | Converts `req.Payload` from source format (openai / gemini / responses) to Claude Messages format. For an already-Claude client this is a no-op. |
| 2 | `helps.SetStringIfDifferent(body, "model", upstreamModel)` | :332 | Yes | Writes the un-suffixed model name. |
| 3 | `thinking.ApplyThinking(body, req.Model, from, to, "claude")` | :334, :605 | **Yes — critical for mirage** | Parses the suffix (`ParseSuffix`) and rewrites `thinking.type`/`budget_tokens`/`output_config.effort` per §2.4. |
| 4 | `normalizeThinkingForAdaptiveModels` | :338 (defn :1425) | Yes for `opus-4-7` | Reverse-maps `thinking.type=enabled` + `budget_tokens` to `thinking.type=adaptive` + `output_config.effort` for Opus 4.7 which only supports adaptive. |
| 5 | `parseBillingExploit(auth)` / `injectExploitSuffixClaude` | :340-343 | Off (mirage yaml has no `billing-exploit`) | — |
| 6 | `rebuildMidSystemMessagesToTopLevel` (if `rebuild-mid-system-message`) | :345-347 (defn :1935) | Off for mirage | — |
| 7 | `applyCloaking` | :351 | Effectively no-op | Cloak is `nil` on mirage entries (`ClaudeKey.Cloak *CloakConfig` is unset). |
| 8 | `helps.ApplyPayloadConfigWithRequest` | :358 | Yes | Applies model-level YAML overrides. Mirage models have no overrides. |
| 9 | `ensureModelMaxTokens(body, baseModel)` | :359 | Yes | Fills `max_tokens` from the model registry if the client didn't set one. |
| 10 | `injectOpenRouterProvider` | :360 (defn :1342) | **No** — early-return unless `base_url` contains `openrouter.ai` | Mirage `base_url` is empty. |
| 11 | `disableThinkingIfToolChoiceForced` | :363 (defn :1406) | Yes | If `tool_choice.type in {"any","tool"}`, strips `thinking` and `output_config.effort`. |
| 12 | `normalizeClaudeSamplingForUpstream` | :364 (defn :1475) | Yes | Unconditionally deletes `temperature` and `top_p`; if thinking is enabled/adaptive/auto, also deletes `top_k`. |
| 13 | `context_management` strip | :369-371 | **Yes** (mirage `base_url` is empty, `isAnthropicHostBaseURL("")` returns false → strip) | `sjson.DeleteBytes(body, "context_management")` |
| 14 | `ensureClaudeThinkingDisplay` | :374 (defn :1492) | Yes | If `thinking.type ∈ {enabled,adaptive,auto}` and `thinking.display` unset, sets `display="summarized"`. Otherwise redact-thinking returns signature-only blocks. |
| 15 | `countCacheControls(body) == 0 → ensureCacheControl(body)` | :377-379 (defn :2881) | Yes | Auto-injects cache breakpoints on last tool / last system / second-to-last user turn. |
| 16 | `enforceCacheControlLimit(body, 4)` | :384 (defn :3041) | Yes | Strips excess breakpoints to at most 4 (Anthropic max). |
| 17 | `normalizeCacheControlTTL(body)` | :388 (defn :2953) | Yes | Downgrades any 1h-TTL block that follows a 5m-TTL block to 5m to satisfy `prompt-caching-scope-2026-01-05`. |
| 18 | `extractAndRemoveBetas(body)` | :392 (defn :1314) | Yes | Pulls `body.betas` into `extraBetas []string`, deletes the body field. Mirage clients typically don't send `betas`. |
| 19 | `shouldStripThinkingForSession(ctx) → stripThinkingBlocksFromHistory` | :399-401 (defn `claude_executor_bedrock.go:698`) | Only after a prior 400 marked the session | Bedrock-motivated; harmless on mirage. |
| 20 | `isClaudeOAuthToken(apiKey)` → `prepareClaudeOAuthToolNamesForUpstream` | :402-406 | **No** (placeholder key is not an OAuth token) | — |
| 21 | `sanitizeClaudeMessagesForClaudeUpstreamWithDebug` | :407 (defn :123) | Yes | Applies signature-stripping / message shape fixes for non-Anthropic upstreams. |
| 22 | `signAnthropicMessagesBody` (CCH signing) | :411 (defn `claude_signing.go:163`) | **No** — `oauthToken` false and `experimentalCCHSigningEnabled` off | Skipped entirely on mirage. |

At the end of this pipeline `bodyForTranslation` and `bodyForUpstream` are set. Only `bodyForUpstream` is what actually goes on the wire.

**Swift port gap (P0/P1).** Present in Swift's `analyzeMirageResponse` today:
- Nothing between steps 3 and 22 is being reproduced on the client. Since Swift is the client (not a proxy), most steps that clean up junk sent by Claude-CLI/SDK clients are unnecessary. **But the following still matter for byte-identical parity:**
  - Step 3 (`ApplyThinking` / suffix parsing) — **P0**. See §2.4 and §5. Without this `(max)/(xhigh)/(N)` on the model name has zero effect.
  - Step 14 (`ensureClaudeThinkingDisplay`) — **P1**. If Swift ever sends `thinking.type` and skips `thinking.display`, the mirage upstream's redact-thinking beta returns only signature blocks (no visible thinking text).
  - Step 15/16/17 (cache_control) — **P2**. Only meaningful if we start sending multi-turn conversation history that would exceed 4 breakpoints. Current Swift usage is single-turn / minimal, so skip.
  - Step 11 (`disableThinkingIfToolChoiceForced`) — **P2**. Only if Swift adds tool-choice support.
  - Step 12 (`normalizeClaudeSamplingForUpstream`) — **P1**. If our body carries `temperature`/`top_p`/`top_k` alongside `thinking`, the upstream's underlying account may 400. Swift should not send these fields alongside a thinking block.
  - Step 18 (`extractAndRemoveBetas`) — **N/A**. Swift never inserts a body-level `betas` array.

---

### 2.3 URL construction

```go
// claude_executor.go:434-438  (streaming: :697-701 identical shape)
} else if fullURL := claudeFullURL(auth); fullURL != "" {
    url = fullURL
} else {
    url = fmt.Sprintf("%s/v1/messages?beta=true", baseURL)
}
```

`claudeFullURL(auth)` (`claude_executor.go:1908-1913`) is a plain read of `auth.Attributes["full_url"]`. For mirage this is whatever `MIRAGE_UPSTREAM_URL` was set to at deploy time — full path included (e.g. `https://upstream.workers.dev/v1/anthropic/messages`).

Vertex mode (`isVertexClaudeAuth`) forks earlier and never overlaps with mirage. Both codepaths converge at `httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(bodyForUpstream))`.

**Swift port gap.** Already handled — `MirageSecrets.upstreamURL` is used verbatim in `MirageWireTransport`. Nothing to do.

---

### 2.4 Model suffix parsing (thinking intensity)

The Go suffix parser is in `internal/thinking/suffix.go` — but the actual body-shape transformation happens after two more hops:

1. **`thinking.ParseSuffix(model)`** (`suffix.go:22`): tokenizes `claude-fable-5(xhigh)` into `SuffixResult{ModelName: "claude-fable-5", RawSuffix: "xhigh", HasSuffix: true}`.
2. **`thinking.ApplyThinking(body, model, from, to, providerKey="claude")`** (`thinking/apply.go:165`). Calls `applyThinking` (:197) which:
   - re-parses the suffix (:224),
   - looks up `modelInfo := registry.LookupModelInfo(baseModel, "claude")`,
   - if a suffix is present: `parseSuffixToConfig` (`apply.go:406-437`) builds a `ThinkingConfig`,
   - validates via `ValidateConfig` (module-internal),
   - invokes the Claude applier `internal/thinking/provider/claude/apply.go`, which writes the actual JSON.
3. **`parseSuffixToConfig`** logic (in priority order):
   - `ParseSpecialSuffix`: `"none"` → `{Mode: ModeNone, Budget: 0}`; `"auto"` or `"-1"` → `{Mode: ModeAuto, Budget: -1}`.
   - `ParseLevelSuffix`: literal `minimal`/`low`/`medium`/`high`/`xhigh`/`max` (case-insensitive) → `{Mode: ModeLevel, Level: <level>}`.
   - `ParseNumericSuffix`: non-negative integer → `budget=N`. `0` collapses to `ModeNone`. `>0` → `{Mode: ModeBudget, Budget: N}`.
   - Unknown → empty config (passthrough).

4. **Claude applier** (`internal/thinking/provider/claude/apply.go:72-167`) then writes the body. The final shape depends on `modelInfo.Thinking.Levels`. For **adaptive-capable Claude 4+ models** (mirage's whole model list is adaptive):

| Suffix on model id | `thinking.type` | `thinking.budget_tokens` | `output_config.effort` |
|---|---|---|---|
| `(none)` | `"disabled"` | *(deleted)* | *(deleted)* |
| `(auto)` / `(-1)` | `"adaptive"` | *(deleted)* | *(deleted — upstream default)* |
| `(minimal)` | `"adaptive"` | *(deleted)* | `"minimal"` |
| `(low)` | `"adaptive"` | *(deleted)* | `"low"` |
| `(medium)` | `"adaptive"` | *(deleted)* | `"medium"` |
| `(high)` | `"adaptive"` | *(deleted)* | `"high"` |
| `(xhigh)` | `"adaptive"` | *(deleted)* | `"xhigh"` |
| `(max)` | `"adaptive"` | *(deleted)* | `"max"` |
| `(N)` — integer > 0 | `"enabled"` | `N` (clamped so `max_tokens > budget_tokens`) | *(deleted)* |
| `(0)` | `"disabled"` | *(deleted)* | *(deleted)* |
| No suffix | body passes through | body passes through | body passes through |

For adaptive Opus 4.7 specifically, `normalizeThinkingForAdaptiveModels` (§2.2 step 4) also up-converts a bare `thinking.type=enabled` + budget into adaptive+effort. That table (`claude_executor.go:1438-1454`) is:

| Body `thinking.budget_tokens` | Rewritten `output_config.effort` |
|---|---|
| `>= 128000` | `max` |
| `>= 32768` | `xhigh` |
| `>= 24576` | `high` |
| `>= 8192` | `medium` |
| `>= 1024` | `low` |
| `> 0`, `< 1024` | `low` |
| `0` or missing | `high` |

Full Go pseudocode reconstruction for `mirage/claude-fable-5(SUFFIX)`:

```pseudo
model := "claude-fable-5(SUFFIX)"       // "mirage/" stripped by rewriteModelForAuth
suffix := parseSuffix(model)             // {"claude-fable-5", "SUFFIX"}
modelInfo := lookup(suffix.ModelName)    // has .Thinking.Levels ≠ ∅ → adaptive
if not suffix.HasSuffix {
    passthrough(body); return
}
switch classifySuffix(suffix.RawSuffix):
  case SPECIAL:
    switch value:
      case "none": body["thinking.type"] = "disabled"; drop budget_tokens, drop output_config.effort
      case "auto"/"-1": body["thinking.type"] = "adaptive"; drop budget_tokens, drop output_config.effort
  case LEVEL:                            // low/medium/high/xhigh/max/minimal
    body["thinking.type"] = "adaptive"
    body["output_config.effort"] = value
    drop body["thinking.budget_tokens"]
  case NUMERIC:
    n := atoi(value)
    if n == 0: body["thinking.type"] = "disabled"
    else:
      body["thinking.type"] = "enabled"
      body["thinking.budget_tokens"] = clampBudget(n, modelInfo)
      // adaptive up-conversion for opus-4-7 happens in
      // normalizeThinkingForAdaptiveModels _after_ this step
```

The dual budget↔level mapping (also used by `ConvertBudgetToLevel` at `internal/thinking/convert.go:77-97`):

| Budget range | Level |
|---|---|
| `-1` | `auto` |
| `0` | `none` |
| `1..512` | `minimal` |
| `513..1024` | `low` |
| `1025..8192` | `medium` |
| `8193..24576` | `high` |
| `24577..32768` | `xhigh` |
| `> 32768` | (kept as budget, up to 128000 = "max") |

And forward direction (`ConvertLevelToBudget`, `convert.go:11-22`):
```
none→0, auto→-1, minimal→512, low→1024, medium→8192, high→24576, xhigh→32768, max→128000
```

Any client-side implementation that wants to emit exactly what CPA emits should implement **the LEVEL branch** — that's what mirage's `(max)/(xhigh)/(high)/(medium)/(low)` cases all reduce to. Numeric budgets need the additional adaptive up-conversion for Opus 4.7 (see §5).

**Swift port gap (P0).** This is the biggest missing piece.

- Location to add: a helper next to `analyzeMirageResponse` (in `CompanionManager+AIResponsePipeline.swift`) or a dedicated file `cursor-buddy/MirageThinkingSuffix.swift`.
- Suggested signature:

  ```swift
  struct MirageThinkingSuffix {
      enum Effort: String { case minimal, low, medium, high, xhigh, max }
      enum Mode { case none, auto, level(Effort), budget(Int) }
      static func parse(fromModelID id: String) -> (baseModel: String, mode: Mode?)
      static func applyToBody(_ body: inout [String: Any], mode: Mode, isOpus47: Bool)
  }
  ```

- Complexity: ~120 LOC (regex to extract `(...)`, switch on the token, then set `thinking.type` and either `thinking.budget_tokens` or `output_config.effort`).
- Verification: replicate CPA test-suite tables (`levelToBudgetMap`, `ConvertBudgetToLevel`) as Swift unit tests. Recommended fixture set: the exact 8 subcases in `TestApplyClaudeHeaders_MirageThinkingBeta` (`claude_mirage_headers_test.go:147-160`).

---

### 2.5 Header application — `applyClaudeHeaders`

Signature: `applyClaudeHeaders(r *http.Request, auth *cliproxyauth.Auth, apiKey string, stream bool, extraBetas []string, body []byte, cfg *config.Config, incomingHeaders http.Header, _ bool) error` (`claude_executor.go:1641`).

The dispatch is a `switch` on `strings.ToLower(auth.Attributes["auth_style"])` (:1668). The mirage branch (`case mirageAuthStyle:` at L1684-1763) is a **complete early return** — none of the fingerprint headers below the branch fire. Sequence:

1. **Delete list** (L1699-1730). Every canonical *and* lowercase form of every possibly-present Claude-CLI header is deleted twice — once via `r.Header.Del(name)` (canonical only) and once via `delete(r.Header, name)` (exact case):
   ```
   Authorization, X-Api-Key,
   Anthropic-Beta, Anthropic-Dangerous-Direct-Browser-Access,
   X-App,
   X-Stainless-Retry-Count, X-Stainless-Runtime, X-Stainless-Lang,
   X-Stainless-Timeout, X-Stainless-Package-Version, X-Stainless-Runtime-Version,
   X-Stainless-Arch, X-Stainless-Os, X-Stainless-Helper-Method,
   X-Claude-Code-Session-Id, X-Client-Request-Id,
   User-Agent, Accept-Encoding, Accept,
   content-type, anthropic-version, user-agent, accept, accept-encoding
   ```
2. **Write lowercase wire-format headers** by direct map assignment (L1737-1748), bypassing Go's `Set()` canonicalization:
   ```go
   lower := map[string][]string{
       "content-type":      {"application/json"},
       "anthropic-version": {"2023-06-01"},
       mirageDeviceHeader:  {mirageEntryFor(auth).next()},  // "x-peeky-device-id"
       "user-agent":        {"reqwest/0.13.4"},
       "accept":            {"*/*"},
       "accept-encoding":   nil,  // nil slice suppresses Go's auto-gzip default
   }
   ```
3. **Conditional lowercase `anthropic-beta`** (L1757-1759):
   ```go
   if body != nil && mirageThinkingActive(body) {
       lower["anthropic-beta"] = []string{"interleaved-thinking-2025-05-14"}
   }
   ```
   `mirageThinkingActive(body)` (`claude_mirage.go:110-129`) inspects the body and returns `true` iff any of:
   - `thinking.type` (case-insensitive) is `"enabled"` or `"adaptive"`, OR
   - `output_config.effort` exists and is non-empty (any value), OR
   - `thinking.budget_tokens > 0`.
4. **Commit** (L1760-1762): write the map back into `r.Header` and `return nil`. The `extraBetas` parameter, `strip_anthropic_beta`, `Anthropic-Version` config default, `X-Stainless-*` headers, `X-App`, `X-Claude-Code-Session-Id`, `x-client-request-id` — none of these are applied on the mirage branch. The comment at L1699 explicitly forbids them.

Key facts to preserve in a Swift port:
- **Header names must be exact lowercase.** HTTP/2 HPACK normalises anyway, but HTTP/1.1 caller-case would reveal a distinct fingerprint. Reqwest 0.13.4 emits lowercase.
- **`accept-encoding` must be present with an empty/absent value**, not just deleted. Go uses a nil-slice sentinel to prevent `http.Transport` from auto-adding `Accept-Encoding: gzip`. Reqwest 0.13.4 built without gzip/brotli features omits the header entirely. Swift's `URLSession` also auto-adds encoding hints — the Swift NIO H2 transport (`MirageWireTransport`) must not include it.
- **`Anthropic-Version: 2023-06-01`** is not the configurable `ClaudeHeaderDefaults` version; it's hard-coded on the mirage branch.
- **`extraBetas` is silently discarded** on the mirage branch. Body-level `betas` (from `extractAndRemoveBetas` in §2.2) never reach the wire on mirage.
- **`strip_anthropic_beta` attribute** is irrelevant on mirage because the branch returns before the shared header block. However, the mirage YAML has `strip-anthropic-beta: true` anyway, as belt-and-braces if someone were to ever remove the early return.

Test coverage that codifies the contract:
- `TestApplyClaudeHeaders_MirageWireFormat` (`claude_mirage_headers_test.go:21-126`) asserts each of the five headers and rejects every fingerprint header both in canonical and lowercase form.
- `TestApplyClaudeHeaders_MirageStreamSuppressesAcceptEncoding` (:189-206) asserts `accept-encoding: nil` even under `stream=true`.
- `TestApplyClaudeHeaders_MirageRotatesDeviceIDAcrossCalls` (:212-241) verifies pool rotation.

**Swift port gap.** Already implemented — `MirageWireTransport.swift` uses SwiftNIO HTTP/2 with byte-exact headers; VPS-verified 200 OK. Nothing to do.

---

### 2.6 Send + response handling

**HTTP client.** `helps.NewUtlsHTTPClient(ctx, e.cfg, auth, 0)` (`claude_executor.go:472`, `:740`). This client:

- Uses uTLS with the rustls-0.23.42 `ClientHelloSpec` (see `helps/utls_client.go:mirageRustlsClientHelloSpec` in the porting guide — cipher suite / group / signature order derived from rustls source).
- Reads `auth.ProxyURL` (`Auth.ProxyURL`, not attributes) — for mirage this is the sentinel `warp`, which routes through the in-process `usque` MASQUE tunnel via `proxypool.WARPDialContext()`.
- `HeadroomDo(httpClient, httpReq)` (`helps/proxy_helpers.go:265`) wraps the actual `.Do()` call for headroom-based compression / stream accounting.

**Success path (non-stream, `Execute` :525-573).**
- `decodeResponseBody` (:1538) magic-byte-detects gzip/zstd if `Content-Encoding` is absent, otherwise honours the header (gzip/deflate/br/zstd).
- `data, _ := io.ReadAll(decodedBody)` (:538).
- Stream flag (`stream = from != to`, :324) tells the parser whether this is a translated SSE dump or plain JSON.
- For plain JSON: `helps.ParseClaudeUsage(data)` → `reporter.Publish`.
- Response goes through `restoreClaudeOAuthToolNamesFromResponse` (no-op for mirage) and `restoreResponseModel` (rewrites `model` back to the client-facing form).
- `sdktranslator.TranslateNonStream` transforms Claude→responseFormat if needed.

**Success path (streaming, `ExecuteStream` :800-960ish).**
- If `responseFormat == to` (both `claude`), events are forwarded line-by-line without translation (:810-896). Each SSE line goes through `restoreClaudeOAuthToolNamesFromStreamLine` and `restoreResponseModel`, then is written to the output channel with a trailing newline.
- The billing-exploit marker detection at :836-885 does NOT fire for mirage (no `billing_exploit` attribute).
- Empty-stream guard (`checkEmptyStreamGuard`, :1393) publishes a 503 if the upstream closes without any content events.

**Error path (both).**
- `httpResp.StatusCode < 200 || >= 300` at :480 / :749.
- The body is decoded, read, and logged (`AppendAPIResponseChunk`, :498/:767).
- `if StatusCode == 400 && isThinkingErrorMessage(body)`: mark session for future thinking-strip (:506/:775).
- **`if StatusCode == 429 && isMirageAuth(auth)`: `mirageEntryFor(auth).forceRotate()`** (:513-517, :780-784). The current request still errors out with `statusErr{code: 429, msg: <body>}` — no inline retry, no synthetic success. The pool is now on a fresh UUID; the client's next request starts a new quota bucket.
- Everything else surfaces as `statusErr` to the client.

**Swift port gap (P0/P1).**
- `MirageBackendClient` already implements rotation on 429 (P0 already covered).
- `MirageWireTransport` sends via SwiftNIO H2 — TLS fingerprinting is Apple's default. **Not** rustls. VPS testing confirmed 200 OK, so evidently the current upstream doesn't do TLS fingerprint validation, but if a future upstream tightens this we'd need a `SwiftNIO SSL` custom cipher list or an FFI to a rustls binding. **P2 — not required today**.
- WARP tunnelling is a CPA-server-only concern (originating from a Cloudflare Worker to a Cloudflare Worker gets rejected). A macOS client's originating IP is already a real client IP, so **WARP is irrelevant for Swift**. Don't try to replicate it.
- SSE line-by-line forwarding is already implemented in Swift via the underlying `URLSession` bytes stream / SwiftNIO channel. Verified working.

---

### 2.7 Response post-processing

**Request logging.** Every successful & failed request writes an `UpstreamRequestLog` via `helps.RecordAPIRequest` (`claude_executor.go:460` and `:723`):
```go
helps.RecordAPIRequest(ctx, e.cfg, helps.UpstreamRequestLog{
    URL:       url,
    Method:    http.MethodPost,
    Headers:   sanitizeHeadersForLog(httpReq.Header.Clone(), auth),
    Body:      bodyForUpstream,
    ...
})
```

`sanitizeHeadersForLog(h, auth)` (`claude_mirage.go:144-154`) replaces the `x-peeky-device-id` value with `[REDACTED]` iff `isMirageAuth(auth)` — otherwise a request log that captures rotating UUIDs would correlate all N of them to the same auth entry and defeat rotation. Other headers are left as-is.

**Response chunking.** `helps.AppendAPIResponseChunk(ctx, cfg, chunk)` (`:498, :543, :767, :826`) accumulates bytes for request-log persistence. In stream mode this is called per-line inside the scanner loop.

**Usage accounting.** `reporter := helps.NewExecutorUsageReporter(...)` at :318/:591. `reporter.Publish(ctx, detail)` on each usage event; `reporter.EnsurePublished(ctx)` after stream close. `reporter.TrackFailure(ctx, &err)` in a `defer` captures any late error.

**Swift port gap.**
- Log redaction (`sanitizeHeadersForLog`) — **P2**. Only meaningful if we ever ship a system-wide log capture. `OpenClickyMessageLogStore` should redact `x-peeky-device-id` before persisting; a one-line replacement in the log-writer path. Complexity: ~5 LOC.

---

## 3. Config → runtime path

The lifecycle from environment variable to `applyClaudeHeaders`:

```
MIRAGE_UPSTREAM_URL (env)
  ↓
scripts/gen_llm_config_v2.py :: generate_mirage()      # emits yaml block
  ↓
config.yaml (deploy-only, gitignored)
  ↓
internal/config/config.go :: ClaudeKey                  # yaml → struct
  ↓
internal/watcher/synthesizer/config.go :: synthesizeClaudeKeys
  ↓
sdk/cliproxy/auth/Auth{Attributes: map[string]string}
  ↓
claude_executor.go :: Execute/ExecuteStream reads auth.Attributes[...]
```

Concrete YAML emitted by `generate_mirage()` (`scripts/gen_llm_config_v2.py:1443-1493`):

```yaml
- api-key: mirage-unused-placeholder
  full-url: {MIRAGE_UPSTREAM_URL}
  auth-style: mirage-uuid
  prefix: mirage
  priority: 1
  weight: 1
  disable-cooling: true
  strip-anthropic-beta: true
  proxy-url: warp
  models:
    - name: claude-opus-5
    - name: claude-fable-5
    - name: claude-sonnet-5
    - name: claude-opus-4-8
    - name: claude-opus-4-7
    - name: claude-opus-4-6
    - name: claude-sonnet-4-6
    - name: claude-sonnet-4-5
    - name: claude-haiku-4-5-20251001
```

Mapping to `auth.Attributes` in `synthesizeClaudeKeys` (`synthesizer/config.go:137-282`):

| YAML key | attribute key | line |
|---|---|---|
| `api-key` | `api_key` | :166 |
| `base-url` | `base_url` | :180-182 (empty for mirage → not set) |
| `full-url` | `full_url` | :217-219 |
| `auth-style` (lowercased) | `auth_style` | :214-216 |
| `strip-anthropic-beta: true` | `strip_anthropic_beta` | :190-192 |
| `prefix` | `auth.Prefix` field, not attribute | :153 |
| `priority` | `priority` | :176-178 |
| `weight` | `AttributeWeight` (`weight`) | :179 |
| `disable-cooling: true` | `metadata["disable_cooling"] = true` | :172-175 |
| `proxy-url` | `auth.ProxyURL` field, not attribute | :242, :269 |
| `models` | `models_hash` (only the sha; actual mapping lives in Manager per-auth model table) | :186-188 |

`mirage_rotate_at` is **not** emitted by the YAML or the synthesizer — `mirageEntryFor` falls back to `mirageDefaultRotateAt = 19` (`claude_mirage.go:24, 53-59`).

Prefix routing: `auth.Prefix = "mirage"` causes `Manager.rewriteModelForAuth` (`sdk/cliproxy/auth/conductor.go:3883-3896`) to strip `mirage/` from the front of the requested model before passing it to the executor. In effect the client can force this auth by naming `mirage/<model>`; without the prefix the priority=1/weight=1 combination keeps it as last-resort.

**Swift port gap.**
- The whole yaml→attribute lifecycle is a CPA-server concern. Swift stores the equivalent info at compile time (`OpenClickyModelCatalog` model provider tag + `MirageSecrets.upstreamURL`). No port needed.
- The `mirage/` prefix strip is already handled in Swift's `MirageBackendClient` (per the "已知情报" — "`mirage/` prefix strip").

---

## 4. 429 rotation semantics (full)

State machine (per-auth, keyed by `auth.ID`):

```go
type mirageEntry struct {
    mu        sync.Mutex
    deviceID  string       // current UUID, "" until first use
    counter   int          // requests served since last rotation
    threshold int          // default 19, per-auth override via mirage_rotate_at
}
```

**`next()`** (`claude_mirage.go:73-85`) is called exactly once per outgoing request, inside `applyClaudeHeaders`:
```
lock
if deviceID == "" OR counter >= threshold:
    deviceID = uuid.NewString()
    counter  = 0
counter++
unlock
return deviceID
```
That's *pre-increment threshold check*: at threshold=19 the 19th request re-uses the current UUID (counter goes 18 → 19), and the 20th request rotates first (counter was 19, so ≥19 triggers, new UUID, counter set to 0 then ++ → 1). Since Cloudflare Worker quotas are typically 20/day, the 20th request of a UUID is the very first one on a fresh bucket — this gives a **1-request safety margin** before the daily cap.

**`forceRotate()`** (`claude_mirage.go:88-97`) is called from `Execute`/`ExecuteStream` when the upstream returns 429:
```
lock
deviceID = uuid.NewString()
counter  = 1
unlock
```
Counter is set to `1` (not `0`) because a `forceRotate` is only useful in the context of a pending next request; setting counter to 1 acknowledges that "if this rotate immediately precedes another request, we've already used one slot of the new bucket." (Note: `forceRotate` returns the new UUID but the caller never uses the return value.)

**Concurrency.** `mirageMu` (`claude_mirage.go:34`) is an `sync.RWMutex` guarding the `miragePool` map. Each entry has its own `sync.Mutex` (`mirageEntry.mu`) for counter/UUID mutations. Under N concurrent requests to the same auth:
- They all lookup the same `*mirageEntry` under `RLock` (fast path, :47-50) — first call creates via double-checked locking under `Lock` (:61-68).
- Each `next()` call serializes on `mirageEntry.mu`. First N-19 calls see the same UUID, then rotation, etc.
- A concurrent 429 that fires `forceRotate` while another goroutine is inside `next()` will serialize; the losing goroutine may get a UUID that was just rotated. In practice this is fine — the rotated UUID is still a valid UUID and the 429-inducing request is already flagged as failed.

**Does the failed request get retried inline?** No. Both `Execute` (:519-523) and `ExecuteStream` (:789-790) return `statusErr{code: 429, msg: <body>}` after the rotate call. The client (or higher-level conductor) decides whether to try another auth.

**Cooldown interaction.** The mirage YAML sets `disable-cooling: true` (`synthesizer/config.go:173-175` maps to `metadata["disable_cooling"]`). This means the conductor does *not* mark the auth as cool-down after a 429 — the entry stays in rotation and the very next request has a fresh UUID.

**Swift port gap.** Already covered by `MirageBackendClient` (per "已知情报"). The threshold and forceRotate behaviours match. Verify with a unit test whose stub `MirageWireTransport` returns 429 twice in a row and asserts UUID differs across calls (`MirageBackendClient` should also apply the pre-increment check on `next()`).

---

## 5. Thinking budget ↔ effort mapping (bidirectional)

Two symmetric tables live in `internal/thinking/convert.go`:

**Level → Budget** (`convert.go:11-22`, function `ConvertLevelToBudget` :42-45):

| Level | Budget |
|---|---|
| `none` | `0` |
| `auto` | `-1` |
| `minimal` | `512` |
| `low` | `1024` |
| `medium` | `8192` |
| `high` | `24576` |
| `xhigh` | `32768` |
| `max` | `128000` |

**Budget → Level** (`convert.go:60-97`, function `ConvertBudgetToLevel`):

| Budget | Level |
|---|---|
| `< -1` | *(invalid)* |
| `-1` | `auto` |
| `0` | `none` |
| `1..512` | `minimal` |
| `513..1024` | `low` |
| `1025..8192` | `medium` |
| `8193..24576` | `high` |
| `> 24576` | `xhigh` |

Two subtleties:

1. **`max` is asymmetric.** Level→Budget maps `max` to 128000, but Budget→Level never produces `max` — anything above 24576 collapses to `xhigh`. This is why the Opus 4.7 up-conversion table (`normalizeThinkingForAdaptiveModels`, `claude_executor.go:1438-1454`) has its own explicit `>= 128000` case: it needs to detect the `max` intent through the budget field.
2. **`ValidateConfig` may clamp budgets** based on `modelInfo.Thinking.Min` / `.Max`. A `(200000)` suffix against a model whose max is 32768 gets clamped to 32768. That happens *inside* the applier, not at parse time.

For mirage, since every model in the model list is adaptive (`.Thinking.Levels ≠ ∅`), the applier's ModeBudget branch is rarely hit — `(N)` numeric suffixes still produce `thinking.type=enabled` + `budget_tokens`, but the mirage upstream then forwards that verbatim.

**Swift port gap (P0).** Duplicate the tables (both directions) as static Swift constants in the same file as the suffix parser (§2.4). Complexity: 20 LOC of pure data + the two conversion functions. Unit test with all boundary values (0, 1, 512, 513, 1024, 1025, 8192, 8193, 24576, 24577, 32768, 128000, 200000).

---

## 6. Swift-side status vs. CPA (parity matrix)

Everything below tracks what OpenClicky's Swift side already implements against the CPA behaviour catalogued above. Sources: user's "已知情报" plus grep of `/Users/wowdd1/Dev/openclicky/cursor-buddy`.

| Capability | CPA source | Swift state | Gap / action |
|---|---|---|---|
| UUID pool + `next()` threshold=19 | `claude_mirage.go:73-85` | Implemented in `MirageBackendClient` (actor UUID pool, `rotateAt=19`) | — |
| Force-rotate on 429 | `claude_mirage.go:88-97`, executor :513, :780 | Implemented (`MirageBackendClient` 429 forceRotate) | — |
| Byte-exact 5 wire headers (`content-type`, `anthropic-version`, `x-peeky-device-id`, `user-agent`, `accept`) + `accept-encoding` nil | `claude_executor.go:1699-1748` | Implemented in `MirageWireTransport.swift` via SwiftNIO H2; VPS 200 OK | — |
| Suppress `Accept-Encoding` auto-gzip in stream | `claude_executor.go:1747` (nil slice) | Implemented (NIO H2 doesn't inject Accept-Encoding) | — |
| Conditional lowercase `anthropic-beta: interleaved-thinking-2025-05-14` when body signals thinking | `claude_executor.go:1757-1759`, `claude_mirage.go:110-129` | Implemented (`thinkingActive` helper used before header write) | — |
| Model suffix `(max)/(xhigh)/(high)/(medium)/(low)/(minimal)/(auto)/(none)/(N)` → body injection | `internal/thinking/apply.go` + `provider/claude/apply.go` | **Missing** | **P0**: implement `MirageThinkingSuffix.parse` + `applyToBody` per §2.4. |
| Level ↔ budget conversion (both directions) | `internal/thinking/convert.go` | **Missing** | **P0**: static tables + two funcs, ~20 LOC. |
| `normalizeThinkingForAdaptiveModels` (Opus 4.7 up-convert) | `claude_executor.go:1425-1462` | **Missing** | **P1**: only if we let user pick Opus 4.7 with a numeric budget. Small (~30 LOC). |
| `normalizeClaudeSamplingForUpstream` (strip temperature/top_p/top_k when thinking active) | `claude_executor.go:1475-1486` | **Missing** | **P1**: 1-line strip in `analyzeMirageResponse` before send. |
| `disableThinkingIfToolChoiceForced` | `claude_executor.go:1406-1420` | N/A (no tool_choice usage today) | **P2**. |
| `ensureClaudeThinkingDisplay` → `thinking.display = "summarized"` | `claude_executor.go:1492-1507` | **Missing** | **P1**: iff we ever send thinking. One `sjson.SetBytes`-equivalent line. Without this, redact-thinking upstream returns signature-only blocks. |
| `ensureCacheControl` auto-inject | `claude_executor.go:2881-2895` | **Missing** | **P2**: only useful when we send multi-turn history. Skip until observed. |
| `enforceCacheControlLimit(body, 4)` | `claude_executor.go:3041` | **Missing** | **P2**: same rationale. |
| `normalizeCacheControlTTL` | `claude_executor.go:2953-3023` | **Missing** | **P2**. |
| `extractAndRemoveBetas` | `claude_executor.go:1314-1331` | **N/A** — we don't accept client betas | Skip. Explicit statement in doc so future maintainers don't reintroduce. |
| `context_management` strip | `claude_executor.go:369-371, 640-642` | **N/A** — Swift never sends `context_management`; the mirage upstream isn't `anthropic.com` so even if it did, CPA would strip. Native strip in Swift is trivial (1 line) and cheap insurance. | **P2** if we ever add multi-turn compaction hints. |
| `sanitizeHeadersForLog` (redact device-id) | `claude_mirage.go:144-154` | **Missing (but log surface is limited)** | **P2**: hook into `OpenClickyMessageLogStore` write path; ~5 LOC. |
| WARP MASQUE outbound | `internal/proxypool/warpdialer.go` + `helps/utls_client.go` | **N/A for Swift** — this is a CPA-server IP concern (Worker→Worker rejection); a macOS client has a real client IP already | Skip. Do NOT try to port. |
| Rustls-0.23.42 JA3 ClientHelloSpec | `helps/utls_client.go` | **N/A today** — VPS testing shows upstream accepts default macOS TLS | **P2** if upstream starts JA3-gating. Custom TLS via SwiftNIO SSL cipher list would work. |
| Prefix strip (`mirage/<model>` → `<model>`) | `sdk/cliproxy/auth/conductor.go:3883-3896` | Implemented (`MirageBackendClient` per "已知情报") | — |
| CCH signing (`signAnthropicMessagesBody`) | `claude_signing.go:163` | **N/A** — mirage does not sign | Skip. |
| OAuth tool-name prefix rewriting | `claude_executor.go:2028` | **N/A** — placeholder key is not OAuth | Skip. |
| SSE line-by-line forwarding | `claude_executor.go:810-896` | Implemented in Swift transport | — |

Summary counts: 3 P0 items, 3 P1, ~6 P2, ~5 N/A.

---

## 7. Port checklist (priority-ordered)

### P0 — blockers for correct behaviour

1. **Suffix parser + applier.**
   File: `cursor-buddy/MirageThinkingSuffix.swift` (new, ~150 LOC).
   Public API:
   ```swift
   enum MirageThinkingMode: Equatable {
       case none
       case auto
       case level(String)      // "minimal" / "low" / "medium" / "high" / "xhigh" / "max"
       case budget(Int)
   }
   enum MirageThinkingSuffix {
       static func parseModelID(_ id: String) -> (baseModel: String, mode: MirageThinkingMode?)
       static func applyToBody(_ body: inout [String: Any], mode: MirageThinkingMode, isOpus47: Bool)
       static func levelToBudget(_ level: String) -> Int?    // convert.go:42-45
       static func budgetToLevel(_ budget: Int) -> String?   // convert.go:77-97
   }
   ```
   Call site: `CompanionManager+AIResponsePipeline.swift` `analyzeMirageResponse` — after building the request dict but before serializing to JSON.
   Test: replicate `TestApplyClaudeHeaders_MirageThinkingBeta` 8 subcases as XCTest.

2. **Level/budget conversion tables.** Included in the same file as (1). Boundary tests: values `{0, 1, 512, 513, 1024, 1025, 8192, 8193, 24576, 24577, 32768, 128000}` in both directions.

3. **Verify `mirageThinkingActive`-equivalent gate for the anthropic-beta header.** Confirm the Swift transport only emits `anthropic-beta: interleaved-thinking-2025-05-14` when the *final* body carries `thinking.type ∈ {enabled, adaptive}` OR `output_config.effort` non-empty OR `thinking.budget_tokens > 0`. This is already implemented per "已知情报" — audit that the gate reads the *post-suffix-injection* body, not the pre-injection body.

### P1 — parity with CPA output

4. **`ensureClaudeThinkingDisplay`.** In `MirageThinkingSuffix.applyToBody`, after setting `thinking.type`, also set `thinking.display = "summarized"` if not already set and `thinking.type ∈ {enabled, adaptive, auto}`. ~5 LOC.

5. **`normalizeClaudeSamplingForUpstream`.** In `analyzeMirageResponse` or the transport just before send: strip `temperature`, `top_p`; also strip `top_k` iff thinking is active. ~6 LOC. Reasoning: some anthropic-compatible upstreams 400 on `temperature` + thinking.

6. **`normalizeThinkingForAdaptiveModels` for Opus 4.7.** Only when the client (a) selects `mirage/claude-opus-4-7` and (b) provides a numeric budget suffix. Detect by `model.contains("opus-4-7") || model.contains("opus-4.7")`. Rewrite `thinking.type=enabled` + `budget_tokens` → `thinking.type=adaptive` + `output_config.effort=<mapped>`. Mapping is the reverse table in §2.4. ~30 LOC.

### P2 — nice-to-have

7. **`sanitizeHeadersForLog`.** In `OpenClickyMessageLogStore` (or wherever request headers are persisted for the log viewer), replace `x-peeky-device-id` value with `[REDACTED]` on write. ~5 LOC. Only meaningful if we ship the log viewer feature to end users.

8. **`disableThinkingIfToolChoiceForced`.** Skip until we add tool-choice UI. When we do: if `tool_choice.type ∈ {any, tool}`, delete `thinking` and `output_config.effort`. ~10 LOC.

9. **Cache-control auto-inject / limit / TTL normalize.** Only when we start emitting multi-turn conversation histories. Full port is ~200 LOC (`ensureCacheControl` alone is 3 helper funcs). Defer until observed benefit.

10. **`context_management` strip.** One-liner cheap insurance: if body has `context_management`, delete it before send. ~2 LOC. Zero cost, low-hanging fruit; add now.

11. **Rustls ClientHello parity.** Not needed unless the upstream starts JA3-gating. Would require SwiftNIO SSL cipher/extension ordering matching rustls 0.23.42. Substantial (~200 LOC + verified fingerprint test). Do only in response to a concrete regression.

---

## Appendix A — Files touched (CPA side, mirage feature)

Per `docs/mirage-change-manifest.md`, 5 commits landed in:

- `internal/config/config.go` — `ClaudeKey.FullURL` field (yaml `full-url,omitempty`, :707-710).
- `internal/watcher/synthesizer/config.go` — `full_url` and `auth_style` attribute writes (:214-219).
- `internal/runtime/executor/claude_mirage.go` — new file (154 LOC): `mirageEntry` pool, `mirageThinkingActive`, `sanitizeHeadersForLog`, `isMirageAuth`.
- `internal/runtime/executor/claude_executor.go` — `applyClaudeHeaders` mirage branch (:1684-1763), URL construction (:434-438, :697-701), 429 rotation (:513-517, :780-784), `RecordAPIRequest` uses `sanitizeHeadersForLog` (:463, :726), `claudeFullURL` helper (:1908-1913).
- `internal/runtime/executor/claude_mirage_headers_test.go` — 242 LOC of contract tests.
- `internal/proxypool/*` — WARP MASQUE dialer changes (CPA-server-only, ignored for Swift).
- `internal/runtime/executor/helps/utls_client.go` — rustls JA3 spec + workers.dev ALPN fast-path (ignored for Swift).
- `sdk/cliproxy/rtprovider.go` — SDK sentinel handling (ignored for Swift).
- `scripts/gen_llm_config_v2.py` — `generate_mirage()` yaml emitter (deploy-side).

## Appendix B — Line-level cross-reference (quick jump)

| Concept | File | Lines |
|---|---|---|
| `mirageEntry` struct | claude_mirage.go | 27-32 |
| `mirageEntryFor(auth)` | claude_mirage.go | 39-69 |
| `next()` counter check | claude_mirage.go | 73-85 |
| `forceRotate()` | claude_mirage.go | 88-97 |
| `mirageThinkingActive(body)` | claude_mirage.go | 110-129 |
| `isMirageAuth(auth)` | claude_mirage.go | 132-137 |
| `sanitizeHeadersForLog(h, auth)` | claude_mirage.go | 144-154 |
| `Execute` entry | claude_executor.go | 303 |
| `ExecuteStream` entry | claude_executor.go | 576 |
| Body pipeline (non-stream) | claude_executor.go | 330-414 |
| Body pipeline (stream) | claude_executor.go | 602-682 |
| URL fork | claude_executor.go | 434-438, 697-701 |
| `applyClaudeHeaders` mirage branch | claude_executor.go | 1684-1763 |
| Delete list | claude_executor.go | 1699-1730 |
| Lowercase write | claude_executor.go | 1737-1748 |
| Anthropic-beta gate | claude_executor.go | 1757-1759 |
| 429 rotation call (non-stream) | claude_executor.go | 513-517 |
| 429 rotation call (stream) | claude_executor.go | 780-784 |
| `claudeFullURL(auth)` | claude_executor.go | 1908-1913 |
| `claudeCreds(auth)` | claude_executor.go | 1915-1929 |
| `isAnthropicHostBaseURL` | claude_executor.go | 1898-1904 |
| `disableThinkingIfToolChoiceForced` | claude_executor.go | 1406-1420 |
| `normalizeThinkingForAdaptiveModels` | claude_executor.go | 1425-1462 |
| `normalizeClaudeSamplingForUpstream` | claude_executor.go | 1475-1486 |
| `ensureClaudeThinkingDisplay` | claude_executor.go | 1492-1507 |
| `ensureCacheControl` | claude_executor.go | 2881-2895 |
| `countCacheControls` | claude_executor.go | 2897-2940 |
| `normalizeCacheControlTTL` | claude_executor.go | 2953-3023 |
| `enforceCacheControlLimit` | claude_executor.go | 3041- |
| `extractAndRemoveBetas` | claude_executor.go | 1314-1331 |
| `ParseSuffix` | internal/thinking/suffix.go | 22 |
| `ApplyThinking` entry | internal/thinking/apply.go | 165 |
| `applyThinking` core | internal/thinking/apply.go | 197 |
| `parseSuffixToConfig` | internal/thinking/apply.go | 406-437 |
| Claude applier `Apply()` | internal/thinking/provider/claude/apply.go | 72-167 |
| `ConvertLevelToBudget` | internal/thinking/convert.go | 42-45 |
| `ConvertBudgetToLevel` | internal/thinking/convert.go | 77-97 |
| `levelToBudgetMap` | internal/thinking/convert.go | 11-22 |
| `synthesizeClaudeKeys` | internal/watcher/synthesizer/config.go | 137-282 |
| `generate_mirage()` | scripts/gen_llm_config_v2.py | 1443-1493 |
| `TestApplyClaudeHeaders_MirageWireFormat` | claude_mirage_headers_test.go | 21-126 |
| `TestApplyClaudeHeaders_MirageThinkingBeta` | claude_mirage_headers_test.go | 142-183 |
| `TestApplyClaudeHeaders_MirageStreamSuppressesAcceptEncoding` | claude_mirage_headers_test.go | 189-206 |
| `TestApplyClaudeHeaders_MirageRotatesDeviceIDAcrossCalls` | claude_mirage_headers_test.go | 212-241 |
