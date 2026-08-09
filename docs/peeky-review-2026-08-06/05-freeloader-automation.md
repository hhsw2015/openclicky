# Peeky Free ("白嫖") Freeloader Automation Audit — 2026-08-06

Scope: OpenClicky's mirage lane vs. reference Peeky Rust
(`/private/tmp/Peeky/peeky`) and reference proxy
(`/private/tmp/Peeky/proxy`) and CPA (`/Users/wowdd1/Dev/CLIProxyAPIPlus`).

---

## Correctly Ported

1. **`x-peeky-device-id` header literal — verbatim match.**
   - Swift: `cursor-buddy/MirageBackendClient.swift:49`
     (`private let mirageDeviceHeader = "x-peeky-device-id"`), plus token
     mints at `MirageDeepgramClient.swift:127` and
     `MirageCartesiaClient.swift:65`.
   - Rust: `peeky/src/providers/proxy_contract.rs:7`
     (`DEVICE_ID_HEADER = "x-peeky-device-id"`).
   - CPA: `internal/runtime/executor/claude_mirage.go:23`. Header name +
     lowercase casing all agree.

2. **UUID rotation cadence (19-of-20).**
   - `MirageBackendClient.swift:61` — `mirageDefaultRotateAt = 19`.
   - `claude_mirage.go:24` — `mirageDefaultRotateAt = 19`. Same auto-rotate,
     same force-rotate-on-429 semantics
     (`MirageBackendClient.swift:109-125` vs `claude_mirage.go:73-97`).

3. **Wire header set + order for Anthropic Messages.**
   `MirageBackendClient.swift:266-303` emits (in order):
   `content-type`, `anthropic-version: 2023-06-01`, `x-peeky-device-id`,
   `user-agent: reqwest/0.13.4`, `accept: */*`, optional `anthropic-beta`.
   Matches Peeky Rust reqwest defaults + the extra headers explicitly set
   in `claude/mod.rs:100-133`.

4. **UA pinned to `reqwest/0.13.4`.** `MirageBackendClient.swift:54`. Rust
   client is `reqwest 0.13.x`; the exact minor version is the fingerprint
   OpenClicky must copy.

5. **Deepgram token exchange contract.**
   - `POST /v1/deepgram/token`, JSON `{}` body, response
     `{token, expires_in}`, TTL fallback = 3600s.
     `MirageDeepgramClient.swift:118-146`.
   - Peeky Rust equivalent: `stt_deepgram.rs:138-171` (same response shape,
     though Rust uses a 60s fallback — see divergence #2 below).
   - `Sec-WebSocket-Protocol: bearer, <jwt>` upgrade at
     `MirageDeepgramClient.swift:232` correctly handles Deepgram's macOS
     URLSession quirk.

6. **Cartesia token + SSE.** `MirageCartesiaClient.swift:55-83, 117-184`.
   Cartesia-Version `2026-03-01` matches `tts_cartesia.rs:94` and proxy
   `handlers/tokens.ts:107`. Model `sonic-2`, voice
   `a0e99841-438c-4a64-b679-ae501e7d6091`, 24 kHz mono s16le — all match.

7. **Thinking suffix table.** `MirageThinkingSuffix.swift:36-109` parses
   `(none)/(auto)/-1/(minimal|low|medium|high|xhigh|max)/(N)` in the same
   priority order as CPA `internal/thinking/apply.go:406-437`
   (`ParseSpecialSuffix -> ParseLevelSuffix -> ParseNumericSuffix -> {}`).
   Budget-to-effort ladder `MirageThinkingSuffix.swift:230-240` mirrors
   `claude_executor.go:1438-1454`.

8. **`context_management` strip.** `MirageBodyPipeline.swift:128-130`
   unconditionally removes the field — same behaviour CPA
   `claude_executor.go:369-371` applies to non-`anthropic.com` base URLs.
   Since mirage always points at aegis-proxy, unconditional is correct.

9. **Interleaved-thinking beta auto-attach.**
   `MirageBackendClient.swift:139-156, 285-303` re-implements
   `mirageThinkingActive` from `claude_mirage.go:110-129` bit for bit
   (`thinking.type in {enabled, adaptive}`, non-empty
   `output_config.effort`, or `budget_tokens > 0`).

10. **Empty-template git posture.** Both `MirageSecrets.swift` and
    `HeyClickySecrets.swift` are `git update-index --skip-worktree`
    (verified: `git ls-files -v` shows `S` flag for both). Index copies
    have empty strings; local worktree carries the personal fill-in.

---

## Divergent from Reference

1. **Device UUID is per-process, not per-install.**
   `MirageBackendClient.swift:80` seeds `deviceID` with a fresh
   `UUID().uuidString.lowercased()` in the actor's default init and
   rotates in memory. There is **no disk persistence.**
   Reference: `peeky/src/providers/device_id.rs:22-42` reads/writes
   `~/Library/Application Support/peeky/device_id`, so the SAME UUID
   survives restarts and daily quota is truly per-install.
   Consequence: every OpenClicky launch gets a fresh 20/day bucket —
   effectively unbounded free usage per user. This is either (a) the
   intent (freeloader-max), or (b) an anti-abuse gap. Flag it explicitly.

2. **Token TTL fallback mismatch.** `MirageDeepgramClient.swift:144` and
   `MirageCartesiaClient.swift:81` fall back to **3600s** when the proxy
   omits `expires_in`. Rust reference (`stt_deepgram.rs:23`,
   `tts_cartesia.rs:16`) falls back to **60s** —
   deliberately conservative. A 3600s Swift-side fallback under an
   upstream that actually returns short TTLs could keep using stale
   tokens for ~59 minutes. Low-impact today (proxy always sets
   `expires_in`), but violates the "never treat a token as longer-lived
   than it is" contract.

3. **Refresh margin doubled.** `MirageTokenCache.swift:35` defaults
   `refreshMargin = 300`s. Peeky Rust
   `peeky/src/tuning.rs:59` uses `PROXY_TOKEN_REFRESH_MARGIN_SECS = 120`.
   Same class of value, but 5 min vs 2 min. The header comment on
   `MirageTokenCache.swift:31-32` claims parity with Rust; it doesn't
   match.

4. **No invite-code / session-JWT headers on token mint.** Rust mints
   `stt_deepgram.rs:150-156` and `tts_cartesia.rs:151-156` conditionally
   send `x-peeky-invite-code` and `Authorization: Bearer <jwt>` when the
   local user has them. Swift always sends only `x-peeky-device-id`
   (`MirageDeepgramClient.swift:127`, `MirageCartesiaClient.swift:65`).
   OpenClicky has no invite-code / session-JWT lifecycle at all, so the
   tier will always be "demo/anonymous" regardless of the operator's
   proxy tier config. If the aegis-proxy operator raises daily quotas
   for invite holders, OpenClicky users cannot ever benefit.

5. **Quota tracking is fully absent.**
   `PeekyFreePanelView.swift:64-105` shows only a green/orange "aegis-proxy
   configured" dot — no "N / 20 today" counter, no local mirror of the
   proxy's `usage.rs` KV values, no lookahead warning as UUID approaches
   rotation. `MirageBackendClient.swift:79-129` keeps `counter` in
   memory but never surfaces it. Peeky doesn't render a counter either
   (it fires the trial wall when the 429 lands), so this is
   arguably parity — but the audit brief flagged "20/day counter" as an
   expected feature; it does not exist.

6. **1M-context beta auto-attach has no Rust parity.**
   `MirageBackendClient.swift:291-292` appends `context-1m-2025-08-07`
   for opus-5/4-8/4-7/sonnet-4-6/fable-5. Peeky Rust only sends
   `anthropic-beta: computer-use-2025-01-24` on
   `agent_loop.rs:190` and `find_action.rs:90` — never 1M. This is a
   deliberate OpenClicky extension (comment at
   `MirageBackendClient.swift:289-291` names it). Risk: aegis-proxy's
   underlying Anthropic key may not be entitled to 1M context; the
   header will 400 or silently truncate. Confirm proxy operator has 1M
   entitlement before shipping.

7. **URLSession fallback path leaks fingerprint headers.** When
   SwiftNIO is not linked (fallback branch
   `MirageBackendClient.swift:329-345, 379-408, 414-433`), URLSession
   auto-adds `Accept-Encoding: gzip, deflate, br`, `Accept-Language`,
   `Priority`, and its own `User-Agent` — the exact fingerprint set the
   `MirageWireTransport` (line 5-25 comment) was built to erase. Both
   the streaming and non-streaming send paths silently degrade. On
   builds that ship without SPM NIO deps, mirage would be trivially
   detectable at the wire.

8. **`Session.start()` never called.** `MirageDeepgramClient.swift:261`
   defines `start()` (idempotent kick-off of `recvLoop`), but nothing in
   the codebase calls it — no callers in
   `MirageDeepgramTranscriptionProvider.swift` either (verified by
   grep). The recv loop only runs if some path invokes it. Compared to
   the Rust `send_task` in `stt_deepgram.rs:228-255` this is a latent
   bug: `awaitFinal()` at line 306 parks a waiter that nobody signals
   until `parseEvent` fires, which nobody triggers because the recv
   loop is dormant. (May work by accident on a different code path;
   worth verifying with an actual PTT.)

---

## Fragile / Missing

1. **`MirageError.quotaExhausted` is defined but never thrown.**
   `MirageBackendClient.swift:440,452-453`. The 429 path only calls
   `forceRotate()` and returns the raw status to the caller
   (line 323, 343, 364, 389, 430). Callers see
   `MirageError.upstreamStatus(429, ...)` instead of the semantically
   accurate variant. Downstream code that pattern-matches on
   `.quotaExhausted` will never trigger.

2. **Retry-after honoring is missing.**
   `MirageError.quotaExhausted(retryAfter: TimeInterval?)` has a slot
   for it, but 429 handling never parses `Retry-After` from the response
   headers. Peeky Rust does not honor it either, so this is
   soft-fragile: the aegis-proxy operator cannot slow the client fleet
   down via that header.

3. **No graceful degradation when aegis-proxy is unreachable.**
   `MirageBackendClient.send` throws `.invalidResponse` /
   `.upstreamStatus` up to `CompanionManager+AIResponsePipeline.swift:2818-2822`
   which rethrows as `MirageError.upstreamStatus`. No fallback to
   Anthropic-direct with the user's own key, no fallback to Apple
   Foundation Models, no user-visible "aegis-proxy unreachable, try
   another lane" nudge. `MirageLocalRelay.swift:218-224` also swallows
   the mirage error into a 502 with no retry loop — Claude Code CLI
   sees "bad gateway" and gives up. Peeky Rust behaves the same way on
   the reference client, but Peeky is single-lane so has no better
   answer; OpenClicky *has* fallbacks and doesn't use them here.

4. **`accept-encoding` explicitly stripped only on NIO path.** The
   spec (docs/mirage-cpa-callflow-spec.md:532) mandates *no*
   `accept-encoding`. NIO branch (`wireHeaders`) respects that.
   URLSession branch does not — see divergence #7 above.

5. **`Session.sendPCM` fires on the socket without wait-for-open.**
   `MirageDeepgramClient.swift:272-274`: if the WSS is still upgrading
   when the first PCM arrives, `task.send` will buffer / silently drop
   depending on URLSession internals. Reference `send_task` runs after
   `connect_async` returns (`stt_deepgram.rs:214-217`) — Rust cannot
   race the open. Swift has no equivalent guard.

6. **`stripSamplingParams` inside suffix applier + inside pipeline is
   duplicated.** `MirageThinkingSuffix.swift:199-203` and
   `MirageBodyPipeline.swift:107-119` both drop `temperature` / `top_p`
   / `top_k`. Not a bug (idempotent), but confusing — the pipeline
   ordering assumes suffix runs first and body still needs a second
   sweep, which is only true for `.passthrough` mode. Delete the
   pipeline copy or the suffix copy after documenting which owns the
   contract.

---

## Suggested Fix

### Fix A. Persist the device UUID on disk (parity with Rust).

`cursor-buddy/MirageBackendClient.swift`:

```diff
 actor MirageBackendClient {
     static let shared = MirageBackendClient()

-    private var deviceID: String = UUID().uuidString.lowercased()
+    private var deviceID: String = Self.loadOrCreateDeviceID()
     private var counter: Int = 0
     private let rotateAt: Int
     private let session: URLSession

+    private static func deviceIDURL() -> URL {
+        let fm = FileManager.default
+        let base = try? fm.url(for: .applicationSupportDirectory,
+                               in: .userDomainMask,
+                               appropriateFor: nil, create: true)
+        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
+            .appendingPathComponent("openclicky/mirage_device_id")
+    }
+
+    private static func loadOrCreateDeviceID() -> String {
+        let url = deviceIDURL()
+        if let s = try? String(contentsOf: url, encoding: .utf8),
+           let uuid = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
+            return uuid.uuidString.lowercased()
+        }
+        let fresh = UUID().uuidString.lowercased()
+        try? FileManager.default.createDirectory(
+            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
+        try? fresh.write(to: url, atomically: true, encoding: .utf8)
+        return fresh
+    }
```

On `forceRotate` we deliberately do NOT rewrite the file — the on-disk
UUID is the stable "install id" the proxy meters daily; rotation is an
in-memory *derived* stream. Match Rust by leaving disk alone.

### Fix B. Emit `.quotaExhausted` on 429.

`cursor-buddy/MirageBackendClient.swift:323, 343, 364, 389, 430`:

```diff
-        if response.status == 429 { forceRotate() }
+        if response.status == 429 {
+            forceRotate()
+            var buf = Data()
+            for try await chunk in response.body {
+                buf.append(Data(chunk.readableBytesView))
+            }
+            throw MirageError.quotaExhausted(retryAfter:
+                response.headers.first(name: "retry-after")
+                    .flatMap { TimeInterval($0) })
+        }
```

Do this on both NIO and URLSession branches. Callers in
`CompanionManager+AIResponsePipeline.swift:2818` should then pattern-match
`.quotaExhausted` and surface a UI "trial quota exhausted for the day"
instead of a generic `upstream 429`.

### Fix C. Kill URLSession fallback OR give it accept-encoding + `httpAdditionalHeaders` scrub.

Preferred (kill the fallback so the fingerprint gap is impossible):

```diff
 #if !(canImport(NIOCore) && ...)
-    fatalError("MirageBackendClient requires SwiftNIO SPM deps")
+#error("Mirage lane requires SwiftNIO (swift-nio + swift-nio-http2 + swift-nio-ssl). Wire the SPM deps into the Xcode project.")
 #endif
```

If keeping fallback for CI parse-checks: set
`cfg.httpShouldSetCookies = false` and `cfg.httpAdditionalHeaders = ["Accept-Encoding": "", "Accept-Language": "", "User-Agent": mirageUserAgent]`
at line 96 — verified via `MIRAGE_WIRE_LOG=1` that URLSession honors
override of `User-Agent` but silently reinjects `Accept-Encoding` unless
you set the value to empty string.

### Fix D. Token TTL fallback to 60s, refresh margin to 120s.

`cursor-buddy/MirageDeepgramClient.swift:144` and
`cursor-buddy/MirageCartesiaClient.swift:81`:

```diff
-        let ttl = TimeInterval((obj["expires_in"] as? Int) ?? 3600)
+        let ttl = TimeInterval((obj["expires_in"] as? Int) ?? 60)
```

`cursor-buddy/MirageTokenCache.swift:35`:

```diff
-    init(refreshMargin: TimeInterval = 300) {
+    init(refreshMargin: TimeInterval = 120) {
```

### Fix E. Guard 1M beta behind a proxy-capability probe.

`MirageBackendClient.swift:291-293` — swap the static allow-list for a
runtime opt-in flag defaulting off:

```diff
-        if let m = pendingModelForBeta, Self.supportsOneMillionContext(m) {
+        if let m = pendingModelForBeta,
+           Self.supportsOneMillionContext(m),
+           UserDefaults.standard.bool(forKey: "openClickyMirageOneMillionBetaOptIn") {
             betas.append("context-1m-2025-08-07")
         }
```

Reason: aegis-proxy's underlying Anthropic key entitlement is unknown to
the OpenClicky client. Peeky reference never sends the beta; the safer
default is "off, opt in via Settings after your proxy operator confirms
1M entitlement."

### Fix F. Kick `Session.start()` after task.resume().

`cursor-buddy/MirageDeepgramClient.swift:234`:

```diff
         task.resume()
-        return Session(task: task)
+        let s = Session(task: task)
+        await s.start()
+        return s
```

Without this, `awaitFinal()` parks a continuation nothing ever fires.

### Fix G. Add a lane-status counter in `PeekyFreePanelView`.

Expose `MirageBackendClient.shared.snapshot()` in `statusGroup`:

```diff
 Text(t("Active profile:", "当前配置:"))
     .font(.system(size: 11))
     .foregroundColor(.secondary)
+ Text(mirageRotationSummary())
+     .font(.system(size: 11))
+     .foregroundColor(.secondary)
```

with a helper that renders `~counter / rotateAt on <first 8 chars of
UUID>`. This is diagnostic only — you cannot see the proxy's actual
per-day count without adding a `/v1/usage` endpoint on aegis-proxy —
but the rotation counter is the closest local proxy for "how close am I
to the next UUID roll."

---

## Summary Table

| Concern                              | Verdict     | Location                                       |
|--------------------------------------|-------------|------------------------------------------------|
| `x-peeky-device-id` literal          | Correct     | `MirageBackendClient.swift:49`                 |
| UUID rotation @ 19                   | Correct     | `MirageBackendClient.swift:61,109-125`         |
| UUID persistence per-install         | **Missing** | `MirageBackendClient.swift:80`                 |
| Header order (NIO)                   | Correct     | `MirageBackendClient.swift:266-303`            |
| Header order (URLSession fallback)   | **Broken**  | `MirageBackendClient.swift:329-345`            |
| Token mint contract                  | Correct     | `MirageDeepgramClient.swift:118-146`           |
| Token TTL fallback (3600 vs 60)      | Divergent   | `MirageDeepgramClient.swift:144`               |
| Refresh margin (300 vs 120)          | Divergent   | `MirageTokenCache.swift:35`                    |
| Invite-code / session-JWT on mint    | **Missing** | `MirageDeepgramClient.swift:123-129`           |
| Quota display in PeekyFreePanelView  | **Missing** | `PeekyFreePanelView.swift:64-105`              |
| MirageSecrets empty-template posture | Correct     | git index blob `ad260a2` shows empty URL       |
| Thinking suffix parse                | Correct     | `MirageThinkingSuffix.swift:65-109`            |
| Body `context_management` strip      | Correct     | `MirageBodyPipeline.swift:128-130`             |
| 1M beta auto-attach                  | Divergent   | `MirageBackendClient.swift:291-292`            |
| 429 → `.quotaExhausted` variant      | **Missing** | `MirageBackendClient.swift:323,343,364`        |
| Aegis-unreachable fallback           | **Missing** | `MirageLocalRelay.swift:218-224` + pipeline    |
| `Session.start()` invoked            | **Missing** | `MirageDeepgramClient.swift:187-236`           |
