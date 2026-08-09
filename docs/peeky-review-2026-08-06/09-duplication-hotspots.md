# 09 — Duplication Hotspots

Audit target: three profiles (`heyclickyFree`, `ski`, `mirage/peekyFree`) with parallel pipelines built by copy-paste. Only flags where two or more sites do the same job in the same way and could be one function today. "Coupled by design" pairs (e.g. Mirage vs Anthropic direct client that must fingerprint differently) are intentionally excluded from the top section.

Every claim below is `path:line`. Filenames are relative to `/Users/wowdd1/Dev/openclicky/`.

---

## Duplication Confirmed (Extract)

### D1. SSE `event: … / data: {…}` line-accumulator parser (Anthropic)

Three near-identical parsers stitch chunked bytes into lines, filter `data: `, JSON-decode, dispatch on `type == "content_block_delta"` with `delta.type == "text_delta"`, terminate on `[DONE]` / `message_stop`:

- `cursor-buddy/CompanionManager+AIResponsePipeline.swift:2831-2860` — mirage streaming path, line-buffer + JSONSerialization + `content_block_delta` branch.
- `cursor-buddy/MiragePeekyOrchestrator.swift:669-708` — mirage orchestrator, identical shape (`streamText(body:onTextChunk:)`).
- `cursor-buddy/ClaudeAPI.swift:283-333` — direct Anthropic path, uses `URLSession.bytes.lines` (`\n`-delimited already) but the payload branch is byte-for-byte the same JSON schema handling.
- `scripts/test-mirage-backend.swift:141` — same schema (fine to leave as a script, but shares the contract).

Proposed API (single place):
```swift
enum AnthropicSSEParser {
    static func consume(
        chunks: AsyncThrowingStream<Data, Error>,
        onTextDelta: @escaping (String) -> Void
    ) async throws -> String
    // yields accumulated text; auto-handles [DONE] + message_stop
}
```
Savings: ~90 LOC across three call sites, one canonical bug surface.

### D2. Mirage token cache pattern — half-extracted, single call sites only

`cursor-buddy/MirageTokenCache.swift:24-68` is already a clean actor with `token(mint:)` / `invalidate()` / `snapshot()`. Two providers use it:

- `cursor-buddy/MirageDeepgramClient.swift:109` — Deepgram JWT lane.
- `cursor-buddy/MirageCartesiaClient.swift:50` — Cartesia bearer lane.

The mint closures at `MirageDeepgramClient.swift:118-149` and `MirageCartesiaClient.swift:55-87` are structurally identical:

1. `nextDeviceID()` from `MirageBackendClient`.
2. POST `{}` with `x-peeky-device-id` + `reqwest/0.13.4` UA.
3. 429 → `forceRotate()` + throw.
4. 200 → decode `token` + `expires_in` (fallback 60s).

Proposed extraction: `MirageTokenCache` grows a `mintFromAegisProxy(endpoint:errorType:)` helper (or a free function in `MirageBackendClient`) so each provider just declares "here is my mint endpoint + error type". Savings: ~50 LOC per provider = ~100 LOC.

The same shape also appears (differently) in `cursor-buddy/HeyClickyTurnLeaseClient.swift:320` (402/429 handling for ephemeral lease). Different auth model — leave alone, but note for a future generic `EphemeralCredentialCache`.

### D3. Retry-After parsing

`cursor-buddy/MirageBackendClient.swift:489-500` has both:
- `retryAfterSeconds(fromURLResponse: HTTPURLResponse)`
- `retryAfterSeconds(fromNIO: HPACKHeaders)`

Called 5 times in the same file (`:359, :383, :407, :435, :479`). Not duplicated elsewhere today — this one is already extracted correctly. **Leave**.

### D4. `BuddyPCM16AudioConverter` usage — extracted, verified

`cursor-buddy/BuddyAudioConversionSupport.swift:11` is the one converter. Consumers (all identical construction pattern `BuddyPCM16AudioConverter(targetSampleRate: 16000)`):

- `AssemblyAIStreamingTranscriptionProvider.swift:157`
- `DeepgramStreamingTranscriptionProvider.swift:105`
- `MirageDeepgramTranscriptionProvider.swift:70`
- `WhisperLocalTranscriptionProvider.swift:92`
- `OpenAIRealtimeSpeechClient.swift:1094`
- `OpenAIAudioTranscriptionProvider.swift:77`
- `OpenClickyParakeetTranscriptionProvider.swift:224`
- `ElevenLabsTTSClient.swift:1516` (`DeepgramVoiceAgentClient` bidirectional turn)

Converter itself is shared. **Confirmed extracted — no duplication.**

### D5. WSS session lifecycle (STT providers)

`cursor-buddy/StreamingWebSocketTranscriptionSession.swift:17-104` already owns open / receive-loop / send / close. Subclasses at:

- `DeepgramStreamingTranscriptionProvider.swift:64` (session subclass)
- `AssemblyAIStreamingTranscriptionProvider.swift:...` (session subclass)

`MirageDeepgramClient.swift:257-419` reimplements the same lifecycle from scratch (own actor, `URLSessionWebSocketTask`, own recv loop, own Finalize/CloseStream). That is a **genuine duplicate** of the WSS lifecycle scaffolding. The mirage session cannot use the shared base directly because it lives inside an actor and needs the JWT-in-`Sec-WebSocket-Protocol` handshake, but the *scaffolding* (open + recvLoop + JSON control frames + graceful close) is the same code.

Proposed: promote `StreamingWebSocketTranscriptionSession` primitives into a `WebSocketAudioSessionCore` value type that both a `NSObject`-based subclass path and the `MirageDeepgramClient.Session` actor path can compose. Savings: ~70-90 LOC in `MirageDeepgramClient.swift`.

### D6. `nextSentenceCut` sentence splitter (streaming TTS)

Currently ONE definition:
- `cursor-buddy/ElevenLabsTTSClient.swift:751` — `fileprivate static func nextSentenceCut`, plus `wordCount`, `splitLongSentenceIntoClauses`, `testChunksForStreaming`.

Callers of the split logic:
- `ElevenLabsTTSClient.swift:637, :727` (internal).
- `CartesiaTTSClient.swift`, `DeepgramTTSClient.swift`, `OpenAIRealtimeSpeechClient.swift` all use `StreamingTTSSession`, and the `StreamingTTSSession` type itself lives in ElevenLabsTTSClient.swift (`:517`, `:1023`) — so all clients share the same sentence logic transitively.

**Not duplicated — but the file placement is wrong.** `StreamingTTSSession`, `nextSentenceCut`, `FillerPhraseLibrary` all live inside `ElevenLabsTTSClient.swift` (76.6KB file) even though they are pan-TTS. `cursor-buddyTests/CodexAgentModeTests.swift:489-535` already tests them as generic `StreamingTTSSession.*` methods.

Proposed: **half-extracted — finish** by moving `StreamingTTSSession`, `FillerPhraseLibrary`, and the sentence-split statics out of `ElevenLabsTTSClient.swift` into `TTSSentenceStreaming.swift` alongside `TTSStreamingPlaybackEngine.swift`. Zero behavior change; ~700 LOC relocation.

### D7. Streaming TTS playback plumbing — extracted, verified

`cursor-buddy/TTSStreamingPlaybackEngine.swift:16-115` is the shared enum. Six clients use it (`ElevenLabsTTSClient`, `CartesiaTTSClient`, `MicrosoftEdgeTTSClient`, `OpenAIRealtimeSpeechClient`, `DeepgramTTSClient`, `DeepgramVoiceAgentClient`). **Confirmed extracted — no duplication.**

### D8. `speakFillerIsolated` — Cartesia-only today

`cursor-buddy/CartesiaTTSClient.swift:284-342` runs a fully-local `AVAudioEngine + AVAudioPlayerNode` so filler playback doesn't collide with the streaming session's engine (comment on `CompanionManager+AIResponsePipeline.swift:2582`: "no engine collision. Do NOT start a second `speakFillerIsolated`").

Only defined in Cartesia. ElevenLabs uses `FillerPhraseLibrary` prebaked PCM buffers scheduled directly on the streaming session (`CompanionManager+AIResponsePipeline.swift:1982, :2580`) — a different mechanism. **Similar but distinct — leave**, but note the design asymmetry in future work.

### D9. `ClickyAgentDockItem(...)` construction

Six call sites all construct `ClickyAgentDockItem` with the same 11 fields:

- `CompanionManager.swift:1834`
- `CompanionManager.swift:3422` (agent-mode task, `.starting`)
- `CompanionManager.swift:16074` (voice agent task)
- `CompanionManager.swift:16266`
- `CompanionManager.swift:17709`
- `MenuBarPanelManager.swift:1129`
- `CompanionManager+SKIModeDockMirror.swift:117` (SKI mirror, `deriveShimState`-driven)
- `CompanionManager+AIResponsePipeline.swift:2560, :2732` (mirage per-turn shim, twice: start + finish)

Every mirage/SKI/heyclicky site duplicates the same "make a dock item that mirrors a session shim" recipe inline. `CompanionManager+SKIModeDockMirror.swift:106` already isolated `deriveShimState`. The Peeky pipeline (`CompanionManager+AIResponsePipeline.swift:2553-2573` and `:2732-2749`) hand-rolls the same shim + upsert dance.

Proposed API:
```swift
extension CompanionManager {
    func upsertShimDockItem(
        id: UUID,
        title: String,
        userInstruction: String,
        accent: ClickyAccentTheme,
        state: (status: ClickyAgentDockStatus,
                stage: String?,
                activityLines: [String],
                caption: String?)
    )
}
```
Savings: ~40 LOC in `CompanionManager+AIResponsePipeline.swift`, unifies the "per-turn dock shim" pattern used by SKI mirror, Peeky mirage, and voice-agent starts.

### D10. `CodexAgentSession` shim construction

Four sites build a shim `CodexAgentSession` for a non-Codex flow:

- `CompanionManager.swift:1762`, `:1776` — reload from snapshot (real sessions, not shims).
- `CompanionManager+SKIModeDockMirror.swift:88` — `CodexAgentSession(id: shimUUID, title: title, accentTheme: accent)` + `.forceVisibleForSKIShim()` + `cm.registerSKIShimAgentSession(shim)`.
- `CompanionManager+AIResponsePipeline.swift:2556-2558` — mirage: `CodexAgentSession(id: dockID, title: dockTitle, accentTheme: .rose)` + `.forceVisibleForSKIShim()` + `self.registerSKIShimAgentSession(s)`.

Same three-line pattern, twice. HeyClicky path does not create a shim of this shape (uses realtime session directly), so only two duplicates today — but the second site was **explicitly copied** ("mirroring SKI's shim pattern (CompanionManager+SKIModeDockMirror.swift:80-129)" comment at `:2549`).

Proposed API:
```swift
extension CompanionManager {
    @MainActor
    func makeShimAgentSession(
        id: UUID,
        title: String,
        accent: ClickyAccentTheme,
        skiBridge: (workspace: String, skiSessionID: String)? = nil
    ) -> CodexAgentSession
}
```
Savings: 6 LOC per site, canonicalizes the "external-pipeline masquerades as a Codex session" contract. When Peeky orchestrator adds its own dock, D9+D10 keep this from re-multiplying.

### D11. Locale-aware caption/filler tables — mirage only, unclaimed pattern

`CompanionManager+AIResponsePipeline.swift:2915-2924` — `mirageCaptions` static table (7 keys × 6 langs).
`CompanionManager+AIResponsePipeline.swift:2938-2945` — `mirageFillerPhrases` static table (6 langs).
`CompanionManager+AIResponsePipeline.swift:2907-2908` — `mirageUILang()` reads `OpenClickyLocaleManager.shared.currentLanguage.prefix(2)`.

Neither SKI nor HeyClicky has a comparable table today (grepped `heyClickyCaptions`, `statusCaption.*localized`, `fillerPhrases` — no other tables found). HeyClicky/SKI use `NSLocalizedString` / `Text(...)` at UI sites.

The pattern itself (static `[String: [String: String]]` + `mirageUILang()` lookup) is a mini private-i18n system inside the mirage lane, bypassing the app's `Localizable.xcstrings`. Not a copy-paste hotspot yet, but this table WILL get copied the moment Peeky orchestrator wants its own captions. **Half-extracted — finish** by moving to `OpenClickyLocaleManager.shortCaption(_:)` before the second copy appears.

### D12. Screenshot capture + 1280 resize + JPEG encode

Multiple call sites all doing `maxDim = 1280`, aspect-preserving resize, JPEG q=0.7-0.85:

- `CompanionScreenCaptureUtility.swift:168, :195-196` — full screen (q=0.8).
- `CompanionScreenCaptureUtility.swift:261, :278-279` — focused window (q=0.8).
- `CompanionScreenCaptureUtility.swift:341-342` — cropped region (q=0.85).
- `OpenRewind/Capture/CaptureCoordinator.swift:816` — thumbnailWidth 1280.
- `OpenRewind/Kit/ReaderAggregates.swift:65, :79` — maxDim: 1280.
- `OpenRewind/Kit/ContextExtractor.swift:186, :254` — `jpegBase64_1280`.
- `HeyClickyChatToolCallClient.swift:170, :175, :669` — hand-rolled: "1280 max-dim @ q=0.55 lands around 30-60KB".
- `OpenClickyExternalControlBridge.swift:3036, :4407, :4559, :4570` — MCP tool exposing "downscaled to `max_dim` (default 1280)".
- `HeyClickyFreePlanningClient.swift:112` — `imgWidth = 1280`.
- `HeyClickyRealtime/HeyClickyRealtimeSession.swift:734, :951, :956` — assumes "downscaled space (1280×800)".
- `AssistAgent/AssistAgentRewindTools.swift:415` — `maxDim: 1280`.
- `AssistAgent/AssistAgentDirectTransport.swift:292-300` — SOF fallback `(1280, 800)`.

Two separate implementations (CompanionScreenCaptureUtility vs HeyClickyChatToolCallClient vs OpenRewind ContextExtractor) do the same "resize CGImage to fit 1280 max-dim, JPEG-encode" work. HeyClicky uses q=0.55, Companion uses q=0.8, OpenRewind uses q=0.7 (`Packages/OpenClickyBrowser/.../BrowserWorkspace.swift:2422`) — the quality difference is intentional (network fingerprint / bandwidth), but the resize-and-encode math is not.

Proposed API:
```swift
enum BuddyImageResizer {
    static func resizedJPEG(_ cgImage: CGImage, maxDim: Int, quality: Double) -> Data?
}
```
Savings: ~30 LOC across five files, and one canonical place for the "1280 space" contract that Realtime + MCP + HeyClicky all reference by hard-coded number today (`HeyClickyRealtimeSession.swift:734` for example asserts pixel space in a comment — that comment could become a constant reference).

---

## Similar But Distinct (Leave)

- **`MirageBodyPipeline.apply` vs `ClaudeAPI` body construction.** `MirageBodyPipeline.swift:33-323` deliberately mirrors CPA's `claude_executor.go` transforms (thinking normalization, cache_control injection, betas extraction). Direct `ClaudeAPI.swift:192-198` builds a minimal `{model, max_tokens, stream, system, messages}` body with no thinking / no cache / no betas — because the direct path uses paid `x-api-key` auth and doesn't need Anthropic Beta compatibility with third-party relays. Merging would force the direct path to run transforms it doesn't need. **Coupled by design — leave.**

- **`GlobalPushToTalkShortcutMonitor` vs `SKIModeHotkeyMonitor`.** Both implement CGEvent-tap monitors, but for orthogonal shortcut spaces (`GlobalPushToTalkShortcutMonitor.swift:15` = push-to-talk / shift double-tap / escape; `SKIModeHotkeyMonitor.swift:34` = configurable app-scoped chord hotkeys). Non-trivial shared machinery (CFMachPort event tap creation), but they publish different domain events. Comment at `OpenClickyContextHotkeys.swift:26` explicitly says "Design notes vs. `GlobalPushToTalkShortcutMonitor.swift`" — signals awareness. **Leave, but bookmark for a future `MacEventTapKit`.**

- **429 handling in `MirageBackendClient` (5 call sites in one file).** Same file, already centralized on `forceRotate()` + `retryAfterSeconds(...)`. Only the two adjacent files (`MirageCartesiaClient.swift:72, :152` and `MirageDeepgramClient.swift:135`) also call `forceRotate()` — those already share `MirageBackendClient.shared`. **Fine.**

- **`ClaudeAPI` (direct) vs `ClaudeAgentSDKAPI` (SDK bridge).** Different transports (URLSession bytes vs stdio to Node), different auth (API key vs Claude Code sign-in). CLAUDE.md line "Do not delete `ClaudeAPI.swift` or the HTTP path — it is the deliberate fallback." **Coupled by design — leave.**

---

## Half-Extracted (Finish)

1. **D2 — Aegis-proxy token mint** — `MirageTokenCache` exists but the mint closures are duplicated. Push the mint recipe into a helper. (~100 LOC.)
2. **D5 — WSS lifecycle** — `StreamingWebSocketTranscriptionSession` covers 2/3 STT clients. `MirageDeepgramClient.Session` reinvents. Reconcile into one core. (~70 LOC.)
3. **D6 — Streaming TTS statics** — `StreamingTTSSession`, `FillerPhraseLibrary`, `nextSentenceCut` all live inside `ElevenLabsTTSClient.swift` despite being pan-TTS. Move to their own file(s). (~700 LOC relocation, zero behavior change.)
4. **D9+D10 — Shim + dock item construction** — SKI mirror and Peeky mirage both build "fake CodexAgentSession + ClickyAgentDockItem" tuples inline; only difference is transcript source. Extract `makeShimAgentSession(...)` and `upsertShimDockItem(...)`. (~50 LOC now, prevents ×3 growth when Peeky orchestrator gains a UI.)
5. **D11 — Mini-i18n table** — mirage-only today, will get copied next. Move into `OpenClickyLocaleManager.shortCaption(_:)` before it multiplies. (Pre-emptive; ~30 LOC saved future.)
6. **D12 — 1280 resize + JPEG** — Companion capture, HeyClicky tool client, OpenRewind reader, and MCP bridge all hand-roll it. Extract `BuddyImageResizer.resizedJPEG(...)`. (~30 LOC across 5 files; also formalizes the "1280 space" contract the Realtime session asserts.)

---

## Recommended Shared Modules

| Module | Absorbs | Rationale |
|---|---|---|
| `AnthropicSSEParser.swift` | `CompanionManager+AIResponsePipeline.swift:2831-2860`, `MiragePeekyOrchestrator.swift:669-708`, `ClaudeAPI.swift:283-333` | Same wire, same JSON schema, three copies. |
| `TTSSentenceStreaming.swift` | `StreamingTTSSession`, `nextSentenceCut`, `splitLongSentenceIntoClauses`, `wordCount`, `FillerPhraseLibrary` — all currently inside `ElevenLabsTTSClient.swift` | 700 LOC misfiled; 5 TTS clients use it. |
| `AegisProxyTokenMint.swift` | Deepgram + Cartesia mint closures | Same 4-step recipe. |
| `BuddyImageResizer.swift` | 1280 resize + JPEG encode paths | 5+ call sites, one contract. |
| `CompanionManager+AgentDockShim.swift` (extension) | `makeShimAgentSession(...)`, `upsertShimDockItem(...)` | Formalize the "external pipeline masquerades as a Codex session" contract shared by SKI mirror and Peeky mirage. |
| `WebSocketAudioSessionCore.swift` | `StreamingWebSocketTranscriptionSession` primitives, usable from actor-based `MirageDeepgramClient.Session` | 2 subclasses + 1 actor doing the same open/recv/close. |

Total conservative LOC savings across proposed extractions: **~350 LOC deleted, ~700 LOC relocated**. More importantly: one canonical bug surface per contract (SSE schema, dock shim, sentence cut, image resize).
