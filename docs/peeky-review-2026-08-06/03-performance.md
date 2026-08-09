# Peeky (mirage) Pipeline Performance Audit

Date: 2026-08-06
Reference: /private/tmp/Peeky/peeky/src/ (Rust; `main.rs:36` shares one `reqwest::Client` across `SttDeepgram` / `TtsCartesia` / `ClaudeMirage`, giving pooled TCP + TLS + h2 multiplexing).

---

## Verified Fast

- **Cartesia token cache is hot-path safe.** `MirageCartesiaClient.currentToken()` (`MirageCartesiaClient.swift:106-108`) delegates to `MirageTokenCache.token` (`MirageTokenCache.swift:46-54`) which keeps the JWT until `expiresAt - 300s`. Direct port of Peeky `PROXY_TOKEN_REFRESH_MARGIN_SECS` (`token_cache.rs`). Multi-sentence turns reuse one token. Same shape for Deepgram (`MirageDeepgramClient.swift:109,173-175`).
- **Sentence-level TTS pipelining is correct.** `StreamingTTSSession.enqueueSentence` (`ElevenLabsTTSClient.swift:908-921`) fires `Task.detached(priority:.userInitiated)` for the fetch synchronously with sentence detection, while a separate `jobChain` awaits the previous sentence's *playback* future before scheduling. So sentence N+1's PCM is being fetched during N's playback. Matches Peeky's `StreamHelper` semantics.
- **Sentence flush is immediate.** `StreamingTTSSession.appendText` (`ElevenLabsTTSClient.swift:577-581`) calls `flushCompleteSentences()` synchronously on every delta; `flushCompleteSentences` (`:636-654`) drains all boundaries visible in the buffer in one pass. No wait-for-next-chunk. `nextSentenceCut` (`:751`) also fires on trailing terminal punctuation at end-of-delta (`:825-833`) so the last sentence of a stream starts TTS before `[DONE]`.
- **Screenshot has no double-resize.** `CompanionScreenCaptureUtility` sets `SCStreamConfiguration.{width,height}` to fit 1280 (`CompanionScreenCaptureUtility.swift:168-176, 261-271`) so the GPU emits a pre-resized `CGImage`; only one JPEG encode (`:195-197, :278`). `analyzeMirageResponse` explicitly documents that no extra resize happens (`CompanionManager+AIResponsePipeline.swift:2529-2532`).
- **Agent-event JSON parse happens once.** `ClaudeAgentRunner.swift:559` calls `JSONSerialization.jsonObject` once per CLI line and stores the dict inside `MirageAgentEvent.raw` (`ClaudeAgentRunner.swift:62,561`). The orchestrator forwards the same struct to the pipeline (`MiragePeekyOrchestrator.swift:594`, `CompanionManager+AIResponsePipeline.swift:2662`) which walks `event.raw` without re-parsing. No double decode.

---

## Bottlenecks

### 1. MirageWireTransport spins up a fresh `MultiThreadedEventLoopGroup` + `NIOSSLContext` + TCP + TLS handshake per Anthropic call (SEVERE)

`MirageWireTransport.send` (`MirageWireTransport.swift:79-219`) allocates a new `MultiThreadedEventLoopGroup(numberOfThreads: 1)` on `:91`, builds a new `NIOSSLContext` on `:96-104` and calls `bootstrap.connect(...)` on `:119` for every request; `cleanupGroup.shutdownGracefully()` runs on `onTermination` (`:206-211`). Peeky uses one process-wide `reqwest::Client` (`peeky/src/main.rs:36`) with h2 connection pooling — one TLS handshake amortised over the lifetime of the app.

Cost estimate to `<mirage-worker>.workers.dev` from a residential US client:
- TCP three-way: ~30-80 ms
- TLS 1.3 1-RTT (BoringSSL/NIOSSL): ~40-100 ms
- HTTP/2 preface + SETTINGS + HEADERS: ~30-60 ms
- **Wall-clock overhead per turn: ~150-350 ms typical, 300-500 ms on 4G / GFW hop.**

Every classifier round-trip (`MiragePeekyOrchestrator.swift:273`), every branch call (`sendNonStreaming`, `streamText`), and every integration retry (`:409-478`) pays this again. An `integration` turn hitting the 3-call cap (`:387`) burns 900-1500 ms of handshake alone. `NIOSSLContext` construction is not free either — internally builds an SSL_CTX and loads the system trust roots on every request.

**Fix:** hoist a shared `NIOSSLContext` (immutable, thread-safe) into a `MirageWireTransport` singleton actor and reuse a small `EventLoopGroup`. Real fix is a keepalive HTTP/2 connection actor, but the low-risk first step is:

```diff
--- a/cursor-buddy/MirageWireTransport.swift
+++ b/cursor-buddy/MirageWireTransport.swift
@@ -66,7 +66,25 @@ struct MirageWireResponse {
 enum MirageWireTransport {
+    // Shared across all requests. TLSConfig + NIOSSLContext are both
+    // immutable after init; a single group amortises TLS init across
+    // the app's lifetime (Peeky reqwest::Client parity).
+    private static let sharedGroup: MultiThreadedEventLoopGroup = {
+        MultiThreadedEventLoopGroup(numberOfThreads: 1)
+    }()
+    private static let sharedSSLContext: NIOSSLContext = {
+        var cfg = TLSConfiguration.makeClientConfiguration()
+        cfg.applicationProtocols = ["h2"]
+        // Force-unwrap: identical to per-request path; a failure here
+        // means the system trust store is unreadable and every mirage
+        // call would fail regardless.
+        return try! NIOSSLContext(configuration: cfg)
+    }()
+
     static func send(_ request: MirageWireRequest) async throws -> MirageWireResponse {
@@ -89,18 +107,8 @@ enum MirageWireTransport {
-        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
-        var tlsConfig = TLSConfiguration.makeClientConfiguration()
-        tlsConfig.applicationProtocols = ["h2"]
-        let sslContext: NIOSSLContext
-        do {
-            sslContext = try NIOSSLContext(configuration: tlsConfig)
-        } catch {
-            try? await group.shutdownGracefully()
-            throw MirageWireError.tls(error)
-        }
+        let group = Self.sharedGroup
+        let sslContext = Self.sharedSSLContext
@@ -206,10 +214,8 @@ enum MirageWireTransport {
             continuation.onTermination = { _ in
                 iterationTask.cancel()
-                Task {
-                    try? await cleanupGroup.shutdownGracefully()
-                }
+                // Group is shared; do NOT shut it down between requests.
             }
```

Also drop the `try? await group.shutdownGracefully()` on the `.missingStatus` early return (`:215`).

Estimated saving: **~200-400 ms per Anthropic call**, i.e. saves 400-1200 ms on a 3-call integration turn.

### 2. Cartesia is not warmed on profile switch into mirage (MEDIUM)

`CompanionManager+Profiles.swift:42-63` warms `OpenClickyIntentClassifier.bootstrap()` and `MirageDeepgramClient.warm()` on `switchingIntoMirage`, but **`MirageCartesiaClient.shared.warm()` is missing.** The Cartesia mint (~1-2s cold, up to ~20s under aegis-proxy cold-start according to the callflow spec) then lands on the user's first spoken reply.

`CompanionManager.swift:2670-2683` does warm Cartesia — but only when the app **boots** with mirage already active. Any user who launches the app on another profile and switches to mirage pays the Cartesia mint on their first turn. Same gap in the `peekyFree` case of `warmModelClientsForSelectedModel` at `CompanionManager.swift:2160-2178`.

**Fix:**

```diff
--- a/cursor-buddy/CompanionManager+Profiles.swift
+++ b/cursor-buddy/CompanionManager+Profiles.swift
@@ -54,6 +54,10 @@ extension CompanionManager {
             Task.detached(priority: .utility) {
                 await MirageDeepgramClient.shared.warm()
             }
+            // Cartesia mint cold-start (~1-2s, up to ~20s on aegis-proxy
+            // cold container) lands on the first spoken reply otherwise.
+            Task.detached(priority: .utility) {
+                await MirageCartesiaClient.shared.warm()
+            }
```

Same three-line addition inside the `.peekyFree` branch at `CompanionManager.swift:2174` (before `break`). Run classifier / Deepgram / Cartesia warms as `Task.detached` (which they already are), so all three fire in parallel — that is the parity with Peeky's `tokio::join!(dg, seed)` at `stt_deepgram.rs:106` and `tts_cartesia.rs:108`.

### 3. Cartesia streaming uses `URLSession.shared.bytes(for:).lines` — line-by-line String decoding (LOW-MED)

`MirageCartesiaClient.synthesize` (`MirageCartesiaClient.swift:144-183`) reads SSE via `bytes.lines`. `URLSession.AsyncBytes.lines` decodes UTF-8 one grapheme at a time and materialises each line as a `String` before the base64 payload is stripped and decoded. Peeky's Rust path reads `response.bytes_stream()` and does `buffer.push_str` on raw slices, splitting on `\n\n` frames (`tts_cartesia.rs:219-244`) — no per-line String allocation.

For a 30-second reply Cartesia streams ~40-80 chunks. This is not a wall-clock bottleneck, but under contention (agent branch + TTS concurrent) it costs measurable CPU on the main audio path. Also `CartesiaTTSClient.decodePCMSamples` (`CartesiaTTSClient.swift:394-419`) reads the PCM one byte at a time and pairs them into `Int16` — should batch.

**Fix:** switch to `bytes` (raw byte iterator) with a `\n\n` frame splitter, and read PCM into an `UnsafeMutablePointer<Int16>`-backed buffer sized to `response.expectedContentLength` when known.

### 4. Cartesia SSE + Deepgram token mints don't share the transport with Anthropic (LOW)

`MirageCartesiaClient.mintCartesiaToken` (`MirageCartesiaClient.swift:68`) and the SSE call (`:144`) go through `URLSession.shared`, which has its own connection pool but is a **different** pool from `MirageBackendClient.session` (`MirageBackendClient.swift:104`) and from `MirageWireTransport` (which is not pooled — see finding 1). Peeky uses one client for everything (`main.rs:36`).

Not urgent: `URLSession.shared` does pool internally per host. Two hosts here (`aegis-proxy.*.workers.dev` and `api.cartesia.ai`) each end up with their own live h2 connection. Fine. Documenting so the finding-1 fix doesn't try to unify all four call sites at once.

### 5. `MirageWireTransport` never times out an idle response body (LOW)

The 15s connect timeout at `:113` covers TCP+TLS. Once headers are in, there is no read deadline on the body stream — if aegis-proxy hangs mid-response the caller must observe the `URLSession` request timeout via URLSession fallback, but on the NIO path the async iterator will block indefinitely. `MirageBackendClient` sets `timeoutIntervalForRequest = 60` on its URLSession (`:98`) but that instance is not used on the NIO path.

**Fix:** attach an `IdleStateHandler` to the pipeline, or set a `Task` deadline in `MiragePeekyOrchestrator.sendNonStreaming` (60 s).

### 6. Notch heartbeat re-asserts `voiceState` every 1 s (LOW)

`CompanionManager+AIResponsePipeline.swift:2599-2624` publishes `voiceState` every tick. Under mirage where a turn can run 30-50 s, that's 30-50 `@Published` writes triggering SwiftUI reconciliation for the notch. Cheap individually, wasteful in aggregate; gate on `voiceState != targetPhase` (already done at `:2615`) and also skip when the caption text hasn't changed.

---

## Suggested Fix Priority

| # | Impact | Effort | Owner-visible symptom |
|---|--------|--------|-----------------------|
| 1 | High (~200-400 ms/req) | ~30 LOC | Every Peeky turn slower than reference by 1-3 handshakes |
| 2 | Medium (~1-2 s first turn only) | 3 LOC | First voice reply after switching into mirage stutters |
| 3 | Low | ~40 LOC | Sustained CPU during long TTS |
| 5 | Low | ~10 LOC | Hangs on flaky Worker instance |
| 6 | Low | ~5 LOC | UI thread pressure during long turns |

Finding 1 is the only place OpenClicky is materially slower than Peeky reference; the rest are polish. The rest of the mirage pipeline (token caching, sentence pipelining, JSON parse count, screenshot pipeline) is at reference parity or better.
