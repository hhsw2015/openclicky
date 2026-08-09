# OpenClicky Voice Pipeline — End-to-End Technical Spec

Companion doc to the forthcoming SKI reverse-engineering spec. Describes the
DEFAULT path (HeyClicky Free lane) plus every configured alternative for STT,
response, and TTS. Sources: `cursor-buddy/*.swift` at HEAD (main).

**Default lane summary.** Ship default is the `heyclicky-free-speech`
response model (`OpenClickyModelCatalog.swift:152-157`), which routes the
whole turn — STT + LLM + TTS — through a single OpenAI Realtime WebSocket
authenticated with a proxy-minted ephemeral (`{proxy}/agent/realtime/session`).
Both listening and speaking are free on this lane, and the STT/TTS pills
in the Listen / Think / Speak strip collapse into one "HeyClicky Free"
chip. Deepgram nova-3 via `HeyClickyProxyTranscriptionProvider` is a
**decomposed fallback** lane, used only when the user overrides to a
non-realtime response model or a non-`.openAIRealtime` TTS provider.

## 0. Default Path Flow (HeyClicky Free realtime lane, PTT one-shot)

```
                +------------------------------------+
User hotkey --> | GlobalPushToTalkShortcutMonitor    |   CGEventTap (nonisolated)
                | (ctrl+option modifier-only tap)    |   emits .pressed/.released
                +------------------+-----------------+
                                   |
                                   v
                +------------------------------------+
                | BuddyDictationManager              |   @MainActor
                | - AVAudioEngine (input tap)        |   256-sample tap buffer
                | - float32 or int16 PCM             |   native rate (e.g. 48k)
                | - warmed-up pre-provider buffer    |
                +------------------+-----------------+
                                   |
             PCM buffers (mic)     v
     +-----------------------------------------------------+
     | HeyClickyRealtimeSession.beginPushToTalk            |  @MainActor, singleton
     |   Persistent WS via HeyClickyRealtimeTransport      |
     |   1) POST {proxy}/agent/realtime/session (ephemeral)|
     |   2) WSS wss://api.openai.com/v1/realtime           |  OpenAI Realtime protocol
     |      - input_audio_buffer.append (PCM16 24kHz)      |
     |      - session.update (instructions, tools, voice)  |
     |      - response.create -> audio deltas + transcript |
     |      - assistant audio ==> HeyClickyRealtimeAudioEngine
     |   Refresh ephemeral every ~8 min, seamless swap     |
     +-----+---------------------------------+-------------+
           |                                 |
           | assistant PCM 24kHz             | user transcript + assistant transcript
           v                                 v
     +-----------------------+   +----------------------------------+
     | AVAudioPlayerNode     |   | Companion side-effects:          |
     | (24kHz PCM16)         |   |   · tool_call use_screen_context |
     | Speaker output.       |   |     -> HigherModelResponse-shaped
     | Server-side VAD +     |   |        reply inlined back to WS  |
     | barge-in cancel.      |   |   · LTM append, caption overlay  |
     +-----------------------+   +----------------------------------+
```

Decomposed fallback path (Deepgram STT -> `/chat-tool-call` LLM -> separate
TTS provider) is documented in the "HeyClicky Free — decomposed fallback
lane" subsection below.

## A. Mic capture

- Stack: `AVFoundation` (`AVAudioEngine`, `AVAudioPCMBuffer`). No
  `AVAudioSession` (macOS). No CoreAudio HAL calls in the STT path.
  `OpenRewind/Capture/AudioCapture.swift` runs a separate parallel engine for
  the LTM audio segmenter.
- PTT hotkey: `BuddyDictationManager.BuddyPushToTalkShortcut.currentShortcutOption
  = .controlOption` (modifier-only tap). Bound via a `CGEventTap` created in
  `GlobalPushToTalkShortcutMonitor.swift` on `.flagsChanged`. Alternate
  options exist for `.shiftFunction`, `.shiftControl`, `.controlOptionSpace`,
  `.shiftControlSpace`; only `.controlOption` is compiled in as the default.
- Format: input tap uses the input node's native `outputFormat(forBus: 0)` —
  usually 48 kHz float32 mono/stereo depending on device; conversion happens
  downstream (`BuddyPCM16AudioConverter(targetSampleRate: 16_000)`).
- Buffer size: **256 frames** (`installTap(onBus: 0, bufferSize: 256, ...)` in
  `BuddyDictationManager.swift:806`). "Smaller tap buffers lower
  capture-to-provider handoff latency."
- Pre-provider buffering: if the provider takes >0 ms to open (e.g. WS
  handshake), buffers are queued (`bufferAudioUntilTranscriptionProviderReady`)
  up to a bounded ring, then flushed once ready.
- AEC / VAD: **no local AEC or VAD**. VAD is delegated to the streaming STT
  provider (Deepgram `endpointing=300`, AssemblyAI turn-based). Barge-in is
  physically impossible because PTT enforces half-duplex.
- End-of-speech: hotkey `.released` → `isFinalizingTranscript = true` →
  provider gets `requestFinalTranscript()`. Fallback timer
  `finalTranscriptFallbackDelaySeconds` (2.8s AssemblyAI / 3.0s Deepgram)
  finalizes with the best-so-far interim if the server never sends
  `end_of_turn`.

## Provider role taxonomy (three layers)

OpenClicky's providers fill one, two, or all three of these roles. SKI
Mode wants to decouple them; today several are entangled.

- **STT** — audio in -> text out. Pure transcription, no reasoning.
- **S2S** — realtime speech-to-speech. Audio in -> LLM turn -> audio
  out over a single socket. The provider owns the mic and speaker for
  the whole turn; text is a side effect.
- **TTS** — text in -> audio out. Pure synthesis, no reasoning.

| Provider | STT | S2S | TTS | Class(es) | Notes |
|---|:-:|:-:|:-:|---|---|
| Deepgram STT (nova-3) | X | | | `DeepgramStreamingTranscriptionProvider` | WS `v1/listen`, streaming |
| AssemblyAI (u3-rt-pro) | X | | | `AssemblyAIStreamingTranscriptionProvider` | WS `v3/ws`, streaming |
| Apple SFSpeech | X | | | `AppleSpeechTranscriptionProvider` | On-device `SFSpeechAudioBufferRecognitionRequest` |
| Parakeet (FluidAudio) | X | | | `OpenClickyParakeetTranscriptionProvider` | Local CoreML, Apple Silicon only |
| Whisper (OpenAI hosted) | X | | | `OpenAIAudioTranscriptionProvider` | HTTP `/v1/audio/transcriptions`, full-utterance |
| Whisper.cpp / large-v3-turbo local | - | - | - | (not integrated) | Missing — see §H |
| HeyClicky Free — realtime lane (**DEFAULT**) | (X) | X | X | `HeyClickyRealtimeSession` (+ `HeyClickyRealtimeTransport` / `HeyClickyRealtimeAudioEngine`) | **DEFAULT**. `heyclicky-free-speech` model. Persistent WS to `wss://api.openai.com/v1/realtime` authenticated with ephemeral minted at `{proxy}/agent/realtime/session`. STT + LLM + TTS collapse into one "HeyClicky Free" pill |
| HeyClicky Free — decomposed STT lane (fallback) | X | | | `HeyClickyProxyTranscriptionProvider` | Fallback only. Fires when user picks a non-realtime response model or a non-`.openAIRealtime` TTS. Mints ephemeral Deepgram token, streams to nova-3 direct |
| OpenAI Realtime BYOK | (X) | X | X | `OpenAIRealtimeSpeechClient` | Same WS transport as the HeyClicky Free default lane, but authenticated with the user's own OpenAI key. Three roles in one socket — see below |
| Deepgram Voice Agent | X | X | X | `DeepgramVoiceAgentClient` | WS `wss://agent.deepgram.com`, STT + LLM + TTS bundled server-side |
| ElevenLabs | | | X | `ElevenLabsTTSClient` | Streaming PCM 22.05 kHz |
| Cartesia (sonic-turbo) | | | X | `CartesiaTTSClient` | Streaming PCM 22.05 kHz |
| Deepgram Aura | | | X | `DeepgramTTSClient` | Streaming PCM 24 kHz linear16 |
| Microsoft Edge TTS | | | X | `MicrosoftEdgeTTSClient` | Streaming, no API key |
| Kokoro-en local TTS | - | - | - | (not integrated) | Missing — see §H |
| Apple Foundation Models | | | | `AppleFoundationModelsVoiceClient` | Text-only LLM; no audio at all. Uses whichever STT + TTS the user picked in Settings |
| Claude Agent SDK / Anthropic REST | | | | `ClaudeAgentSDKAPI` / `ClaudeAPI` | Text-only LLM; same |
| Codex / OpenAI Responses | | | | `CodexVoiceSession` / `OpenAIAPI` | Text-only LLM; same |

`(X)` under STT for the two realtime rows = the transcript is a byproduct
of the S2S turn (delivered via `.heyClickyRealtimeUserTranscript` /
OpenAI `conversation.item.input_audio_transcription.completed`), and
OpenClicky reuses it for LTM and logging. You cannot get just the
transcript from these sockets without paying for the full LLM turn.

### OpenAI Realtime — three modes in one class

`OpenAIRealtimeSpeechClient` is the same class regardless of which mode
you enter; the entry point selects the role.

1. `beginBidirectionalVoiceTurn(...)` -> full S2S. Mic PCM streams up,
   `response.create` emits assistant audio deltas + transcript deltas.
   Entered when `selectedModel.provider == .openAI` AND `selectedModel.id`
   is a realtime speech id (`gpt-realtime-2.1-mini` default,
   `gpt-realtime-2.1`, `gpt-realtime-1.5`).
2. `speakText(...)` -> TTS-only. Called by `voiceTTSClient.speakText`
   when `selectedTTSProvider == .openAIRealtime` AND the response text
   came from a different LLM path (Claude / Codex / Apple / HeyClicky
   `/chat-tool-call`). Session opens without mic input, the finished
   assistant text is written via `conversation.item.create` role=assistant,
   then `response.create` fires with `output_modalities: ["audio"]`.
   OpenAI Realtime becomes a premium TTS provider only.
3. `parseTranscriptArgument(...)` helper -> STT byproduct. Not a
   standalone STT path; only meaningful inside an active S2S turn when
   the model tool-calls `use_screen_context` with a `transcript` arg.

### HeyClicky Free — realtime lane (default) vs decomposed lane (fallback)

**Realtime lane is the SHIP DEFAULT.** The default voice-response model
is `heyclicky-free-speech` (`OpenClickyModelCatalog.swift:157`,
`provider: .heyclickyFree`), whose comment (`:152-156`) is authoritative:

> HeyClicky Free realtime speech model: same underlying OpenAI Realtime
> WS transport as GPT Realtime, but authenticated with a proxy-minted
> ephemeral so listening + speaking are both free. Selecting this makes
> the STT + TTS lanes collapse into one "HeyClicky Free" pill in the
> Listen / Think / Speak strip.

`CompanionManager.shouldRoutePTTToHeyClickyRealtimeSession`
(`CompanionManager.swift:6024`) returns true when ALL of:

- HeyClicky Free is signed in (Supabase session valid),
- `selectedTTSProvider == .openAIRealtime`,
- selected voice-response model id is a realtime speech id
  (`heyclicky-free-speech` on the default lane; also true for
  `gpt-realtime-2.1-mini` etc. under BYOK).

When true, `HeyClickyRealtimeSession.beginPushToTalk()` handles the WHOLE
turn — STT + LLM + TTS — over one persistent WS to
`wss://api.openai.com/v1/realtime`. The `/chat-tool-call` HTTP path and
`HeyClickyProxyTranscriptionProvider` STT path are BOTH skipped for that
turn. Screen-context tool calls are marshalled back into the same WS as
`conversation.item.create` role=tool_response so the model speaks the
answer inline.

**Decomposed lane is a FALLBACK.** Fires when any realtime-routing
condition above is false — user picks a text response model
(`heyclicky-free` chat, Claude, Codex, Apple), or overrides TTS to
ElevenLabs / Cartesia / Aura / Edge. Path:
`HeyClickyProxyTranscriptionProvider` (Deepgram nova-3 via ephemeral
token) for STT -> `HeyClickyChatToolCallClient` HTTP `/chat-tool-call`
for LLM -> whichever TTS `selectedTTSProvider` names.

## Realtime speech-to-speech vs decomposed pipeline

Trade-offs when choosing between an S2S provider and a
STT + LLM + TTS decomposition (SKI Mode's target shape):

| Dimension | S2S (Realtime / Voice Agent) | Decomposed (STT -> LLM -> TTS) |
|---|---|---|
| First-audio latency | ~350-700 ms (server pipelines internally) | 900 ms - 1.6 s (STT final -> LLM first token -> TTS first sentence) |
| Barge-in | Native server `response.cancel` | Needs local AEC + VAD; OpenClicky is PTT-only today |
| Language switching | Needs session update / recreate | Free per layer |
| Voice choice | Locked to vendor voices (`cedar`, ...) | Any TTS voice; can mix Kokoro-en + Aura-zh |
| Cost | Audio-minute S2S rate (expensive) | Token LLM + char TTS + sec STT (cheaper) |
| Local option | None viable in 2026 | Whisper.cpp + local LLM + Kokoro |
| Tool use | Realtime tool-calls only | Any function-calling LLM |
| Screen context | Awkward — `input_audio_buffer.commit` + `item.create` | Natural — regular HTTP with `image_url` |
| Model swap | New model = new socket contract | Each layer swappable independently |
| Failure blast radius | Socket dies -> whole turn dies | Per-layer failover |
| Debug / audit | No mid-turn text if WS drops | Every layer produces an artifact |
| Streaming granularity | Server decides pacing | Sentence-pipelined TTS |

**SKI Mode implication (vs. Realtime-default baseline).** OpenClicky's
ship default sits in the S2S column — low-latency, native barge-in, but
locked to OpenAI Realtime voices, no offline option, every turn burns
proxy quota, no inspectable intermediate text. SKI Mode targets the
decomposed column: Whisper.cpp STT + external CLI LLM + Kokoro-en (or
`OpenAIRealtimeSpeechClient.speakText(...)` mode-2 as premium zh TTS).
Cost: ~500 ms extra first-audio latency and loss of server-side barge-in
until local AEC/VAD lands. Gains: offline capability, per-language voice
choice, per-layer swappability, no quota burn, per-layer text artifact
for debug. Migration is additive — Realtime stays available in TTS-only
mode without owning the mic.

## B. STT providers (details)

Selection in `BuddyTranscriptionProviderFactory.selectedProviderID()`.
UserDefaults key: `openClickyVoiceTranscriptionProvider`. `automatic`
resolves through `configuredFallback`: parakeet → assemblyAI → deepgram →
openAI → appleSpeech.

| Provider | Class | Mode | Auth | Endpoint | Latency |
|---|---|---|---|---|---|
| HeyClicky Free (decomposed lane only) | `HeyClickyProxyTranscriptionProvider` | Streaming (proxied) | Supabase JWT (X-Clicky-*) | POST `{proxyBaseURL}/v2/dictation/deepgram-token` -> WSS `api.deepgram.com/v1/listen?model=nova-3` | ~120 ms first partial (WS + token mint) |
| Parakeet | `OpenClickyParakeetTranscriptionProvider` | Local, streaming (FluidAudio Parakeet, Apple Silicon only) | none (CoreML weights on disk) | in-process | ~200 ms |
| Apple Speech | `AppleSpeechTranscriptionProvider` | On-device, streaming (`SFSpeechAudioBufferRecognitionRequest`) | TCC speech recognition | in-process | ~150 ms |
| AssemblyAI | `AssemblyAIStreamingTranscriptionProvider` | Streaming, WS `v3` | API key (or Cloudflare token proxy) | `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le&format_turns=true&speech_model=u3-rt-pro` | 100-200 ms first partial |
| Deepgram | `DeepgramStreamingTranscriptionProvider` | Streaming, WS | API key (`openClickyDeepgramAPIKey`) | `wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&smart_format=true&endpointing=300` | 100-200 ms |
| Whisper (OpenAI file) | `OpenAIAudioTranscriptionProvider` | Full-utterance HTTP | `openClickyOpenAIAPIKey` | POST `/v1/audio/transcriptions` | 700 ms-2 s |

Notes:
- The default HeyClicky Free lane does NOT enter this table — its STT
  runs inside the OpenAI Realtime WS (see the "HeyClicky Free — realtime
  lane" row in the taxonomy). `HeyClickyProxyTranscriptionProvider` only
  fires on the decomposed fallback lane. When it does, it is a thin
  ephemeral-token facade: it mints a Deepgram token via
  `{proxy}/v2/dictation/deepgram-token`, then hands off to
  `DeepgramStreamingTranscriptionSession` with `apiKey = <deepgram_token>`.
  The audio bytes go direct to Deepgram, not through the proxy.
- Whisper.cpp local: **NOT integrated.** Only Parakeet (Apple Silicon,
  FluidAudio) covers local streaming.
- Language: providers auto-detect; language hints are only injected into
  the OpenAI Realtime transcription config (see §C).
- Keyterms passed as biasing list (Deepgram `keyterm=` for nova-3+ /
  `keywords=` for nova-2; AssemblyAI `keyterms_prompt=<JSON>`).

## C. Response pipeline

Entry: `CompanionManager+AIResponsePipeline.swift:_analyzeVoiceResponseCore`.

1. Reset per-turn xlb budget: `XLBSensorTools.resetTurnBudget()`.
2. **Stable system prompt** = `AssistAgentBridge.effectiveSystemPrompt(base)`
   — base + `AssistAgentPrompt.systemPromptBlock` when
   `openClickyAssistAgentEnabled == true`.
3. **xlb hint injection** — `Self.applyXLBHintIfEnabled(to: userPrompt)`
   prepends an xlinkBook context snippet on the raw user prompt. Applied
   inside the core so every path (voice / visual / automation / text chat)
   sees it uniformly.
4. **Dynamic prefix** (skipped on reentrant assist rounds), in order:
   - LTM: `LongTermMemoryContext.build(query: userPrompt)` — hybrid
     NLEmbedding + FTS retrieval over OpenRewind vault (cached 5 min).
   - Stash context: `currentStashContextForVoicePrompt()` — PickStash,
     LinkRectStash, WhiteboardStash, AnnotationStash, selected text,
     frontmost app / window / URL.
   - Active-window helper: `AssistAgentActiveWindow.capture()?.promptBlock`
     (adds browser URL via AppleScript).
5. Model selection: `modelID ?? selectedModel` (UserDefaults
   `openClickySelectedModel`). If the model is a speech id (realtime),
   swap to its paired analysis model via
   `OpenClickyModelCatalog.voiceAnalysisModel(withID:)`.
6. **Provider switch** on `selectedVoiceResponseModel.provider`:

| provider | Path | File |
|---|---|---|
| `.apple` | `AppleFoundationModelsVoiceClient.analyzeVoiceResponse` (macOS 26+ `SystemLanguageModel`; text-only, images described as unavailable) | `AppleFoundationModelsVoiceClient.swift` |
| `.anthropic` | `analyzeClaudeResponse` → **Agent SDK first** (`ClaudeAgentSDKAPI.analyzeImageStreaming`) → fallback direct HTTP `ClaudeAPI.analyzeImageStreaming` when SDK nil or throws (non-cancel) and `anthropicAPIKey != nil` | `ClaudeAgentSDKAPI.swift`, `ClaudeAPI.swift` |
| `.openAI` | `analyzeOpenAIOrCodexVoiceResponse` — for non-speech ids: **Codex app-server first** (`analyzeCodexVoiceResponse` via `CodexVoiceSession`), then OpenAI REST fallback | `CodexVoiceSession.swift`, `OpenAIAPI.swift` |
| `.codex` | `analyzeCodexVoiceResponse` (direct Codex, no OpenAI fallback) | `CodexVoiceSession.swift` |
| `.deepgram` | throws — Deepgram Voice Agent owns the mic directly | see §E |
| `.heyclickyFree` | `HeyClickyChatToolCallClient.analyzeVoiceResponse` — POST `{proxyBaseURL}{chatToolCallPath="/chat-tool-call"}` | `HeyClickyChatToolCallClient.swift` |

7. Response returns raw text. If the reply carries `[ASSIST] {...}` and the
   caller is NOT already in a reentrant round,
   `AssistAgentBridge.shared.handleModelReply` executes the assist loop and
   replaces `[ASSIST_RESULT]` with the summary.

Streaming: all cloud paths are token-streaming SSE / delta. Apple
Foundation Models returns one full-text chunk. HeyClicky `/chat-tool-call`
is a one-shot JSON response (`HigherModelResponse`), not SSE — chunks are
faked by emitting the full text at the end.

## D. AssistAgent + HeyClicky tool loop

- **System prompt** (`AssistAgent/AssistAgentPrompt.swift`):
  - `systemPromptBlock` — short Chinese paragraph appended to the base
    system prompt, tells the model "you have a local assist agent, call it
    with `[ASSIST] {"goal":"...","workdir":"/abs or omit"}`" when it needs
    real ground truth.
  - `loopSystemPrompt(goal, workdir, maxRounds)` — full tool-menu prompt
    only sent once the model invokes `[ASSIST]`. Chinese field names:
    `"步骤"` (step) `"需要"` (need) | `"完成"` (done), `"类型"` (type),
    `"参数"` (args), `"原因"` (reason).
- **Tool menu (Chinese type names)**, dispatched by
  `AssistAgent/AssistAgentTools.swift`:
  - `截屏` screenshot, `文件内容` read_file, `文件大纲` file_outline,
    `目录列表` list_dir, `路径匹配` glob, `搜索结果` grep, `命令输出`
    run_shell, `网页内容` http_get, `网络搜索` builtin_search,
    `xlb·搜主题` / `xlb·主题内容` / `xlb·主题元信息` / `xlb·语法帮助` /
    `xlb·标签内容` / `xlb·执行` / `xlb·图谱` / `xlb·当前视图`,
    `查历史` query_history, `写入完成` write_file, `局部替换` edit_file,
    `批量替换` multi_edit, `追加片段` append_chunk, `差量应用` apply_diff,
    `存记忆` / `读记忆` save/read memory,
    `分派并行` parallel_dispatch,
    `屏幕历史·搜索` / `·帧详情` / `·日汇总` / `·问答` / `·最近` /
    `·会议` / `·转录` / `·打开帧` / `·定位` (OpenRewind vault).
- **Loop** (`AssistAgent/AssistAgentLoop.swift`): synchronous
  think→tool→result rounds. Transport (`AssistAgentTransport`) wraps
  `HeyClickyChatToolCallClient` so account rotation / session cycling reuse
  the free-tier proxy. Auto-extends max_rounds once if useful progress
  continues; hard cap 50.
- **Chat client vs. direct model call**: `HeyClickyChatToolCallClient`
  bundles the model turn *plus* client-executable side effects. The proxy
  returns a `HigherModelResponse` (see `HeyClickyTypes.swift:346`) with:
  - `text` — spoken/displayed answer
  - `clipboardText` — write to clipboard (preserving prior contents)
  - `typing: TypingInstruction {text, x?, y?, label?, screen?}` — click at
    (x,y) then synth-type. Gated on user transcript containing "type", "输入",
    "打入", "帮我打", "填入", "write ", "paste ".
  - `point: PointCoordinate {x, y, label, screen?}` — buddy flies to point
  - `walkthrough.beats[]` — sequence of `WalkthroughBeat`. Kinds:
    `target` (arms guided click, radius default 40),
    `point` (flies buddy),
    `type` (same guard as `typing`),
    `hover` (draws circle annotation),
    `highlight` (draws rect annotation),
    `arrow`, `curve`, `shape` (with `shapeKind: line|arrow|circle|curve|polygon`).
  - `widgets[]` — `WidgetPayload {type, payload}` — rendered by
    `HeyClickyWidgetSlotView`.
  - `annotationText` — short caption near screen annotations.

## E. TTS providers

Selection in `CompanionManager.voiceTTSClient` (dispatched by
`selectedTTSProvider`, UserDefaults `openClickyTTSProvider`).

| Provider | Class | Streaming | Format | Endpoint / Voice | Notes |
|---|---|---|---|---|---|
| ElevenLabs | `ElevenLabsTTSClient` | Sentence-pipelined (per-sentence POST, in-order playback) | PCM 22.05 kHz s16 mono | POST `https://api.elevenlabs.io/v1/text-to-speech/{voiceID}/stream?output_format=pcm_22050` | Default. First-audio latency ~700 ms |
| Cartesia | `CartesiaTTSClient` | Sentence-pipelined | PCM 22.05 kHz s16 mono | POST `https://api.cartesia.ai/tts/bytes` `Cartesia-Version: 2026-03-01` model `sonic-turbo` | Same StreamingTTSSession pipeline as EL |
| Deepgram Aura | `DeepgramTTSClient` | Sentence-pipelined | PCM 24 kHz linear16 | POST `https://api.deepgram.com/v1/speak?encoding=linear16&sample_rate=24000&container=none&model={voice}` | Reuses `openClickyDeepgramAPIKey` |
| OpenAI Realtime | `OpenAIRealtimeSpeechClient` | Bidirectional WS (full turn) | 24 kHz PCM16 | `wss://api.openai.com/v1/realtime` (or HeyClicky-minted ephemeral) | Selecting this ALSO owns mic — it is not "just" TTS |
| Microsoft Edge | `MicrosoftEdgeTTSClient` | Streaming | PCM | edge-tts endpoint | No API key; free |
| Deepgram Voice Agent | `DeepgramVoiceAgentClient` | Full-duplex agent (STT+LLM+TTS bundled) | 24 kHz | `wss://agent.deepgram.com` | Owns mic/speaker end-to-end when selected |

Playback: every non-realtime TTS routes through `TTSStreamingPlaybackEngine`
using `AVAudioEngine` + `AVAudioPlayerNode` scheduled buffers. First-sentence
playback starts before the LLM finishes generating.

Volume: `openClickyVoicePlaybackVolume` (default 0.45), applied on the
`mainMixerNode`. Interruption: any new voice turn cancels
`activeStreamingSession` and tears down the engine before starting the next.

## F. Playback

- Engine: `AVAudioEngine` + `AVAudioPlayerNode` per streaming session
  (rebuilt each request to avoid stale buffered audio).
- One-shot completion sounds / onboarding music use `AVAudioPlayer`
  (`CompanionManager.swift:2727`, `+HeyClicky.swift:1396`).
- Interruption handling: `voiceState` transitions to `.processing` /
  `.responding` cancel the previous player. `interruptCurrentVoiceResponse()`
  is called at the top of `sendTranscriptToClaudeWithScreenshot`.
- Volume: `openClickyVoicePlaybackVolume` UserDefaults key, default 0.45.
- Mic overlap: **no barge-in**. PTT is push-to-talk half-duplex. Realtime
  and Deepgram Voice Agent paths handle their own duplex internally.

## G. Integration surfaces

- **External MCP bridge** (`OpenClickyExternalControlBridge.swift`):
  loopback HTTP+SSE on `127.0.0.1:32123` (env override
  `OPENCLICKY_MCP_PORT`, fallback ladder walks +10 ports). Exposes 130+
  sensor tools (`sensorToolNamesBase` + OpenDia `browser_*` (~120) + OpenRewind
  `openrewind.*` (9) + adapter/page/capture/connector/opencli/chat_bus/
  clipboard/web families). Bearer auth via
  `openClickyExternalControlBridgeToken`. Consumed by external agents
  (Codex, Claude Code via MCP config.toml).
- **Codex Agent Mode** (`CodexAgentSession.swift`, `CodexHUDWindowManager.swift`):
  spawns the bundled `codex` runtime under `AppResources/OpenClicky/OpenCLIRuntime/`
  with a rendered `config.toml` (see `ClickyCodexConfigTemplate.swift`) that
  points at the external bridge port. Runs a full sub-agent loop in a HUD
  window.
- **xlinkBook**: `XLBTopicIndex` reads the user's xlb graph (path in
  `openclicky.xlb.graphJsonPath` UserDefaults). `XLBSensorTools` exposes
  eight tools (`xlb·搜主题`, `xlb·主题内容`, `xlb·图谱`, etc.) both to
  AssistAgent and the external MCP bridge.
- **Rewind vault** (`OpenRewind/*`) — long-term memory:
  - `Capture/` continuously records screen (SCStream), audio segments
    (AVAudioEngine), and AX events into a local vault under the
    OpenRewind storage root.
  - `ScreenHistoryAIProvider` / `ScreenHistoryAIBackend` expose FTS +
    semantic (NLEmbedding) search consumed by `LongTermMemoryContext.build`
    in the response pipeline and by the `屏幕历史·*` assist-agent tools.

## H. Missing pieces vs SKI

Things SKI has that OpenClicky does NOT:

- **Full-duplex barge-in** — mic muted while TTS is speaking; only PTT
  supported. Barge-in would need speaker AEC (currently absent).
- **Silero VAD ONNX local** — no local VAD; endpoint detection lives in
  the STT provider (server-side). No ONNX runtime linked.
- **Whisper large-v3-turbo local** — no whisper.cpp / MLX Whisper
  integration. Only Parakeet (FluidAudio, Apple Silicon only, `small`-tier
  weights) covers local STT. No `.bin` GGUF pipeline.
- **Kokoro local TTS** — every TTS provider requires network. Microsoft
  Edge TTS is free but still hits an internet endpoint. No on-device
  neural TTS.
- **File-bridge IPC (`.ski/events.jsonl` / `.ski/commands.jsonl`)** — no
  file-per-line JSONL append protocol for external processes to observe /
  drive turns. All external IPC goes through the HTTP/SSE MCP bridge.
- **UDS presence socket (`agents.sock`)** — no Unix-domain socket
  advertising which agents are alive; discovery is via the MCP bridge's
  `/health` and Codex config regeneration.
- **Multi-project routing** — no per-project working directory scoping
  for voice turns. The active project is a global concept
  (`OpenClickyProfile`), not per-conversation.
- **Model download UX** — Parakeet weights use
  `OpenClickyLocalSpeechModelCache.modelsExist(for:)` and a manager but
  there is no in-app catalog picker for other local models. No
  whisper/kokoro download flow.

## Key UserDefaults keys (voice-relevant)

| Key | Purpose |
|---|---|
| `openClickyVoiceTranscriptionProvider` | STT provider (`automatic`, `parakeet`, `apple`, `assemblyai`, `deepgram`, `openai`, `heyclicky_free`) |
| `openClickyTTSProvider` | TTS provider (`openAIRealtime`, `elevenLabs`, `cartesia`, `deepgram`, `microsoftEdge`) |
| `openClickyVoicePlaybackVolume` | Playback volume 0.0-1.0 (default 0.45) |
| `openClickyVoiceResponseLanguage` | `auto` / `zh` / `en` / `ja` / `es` / `fr` / `de` |
| `openClickyVoiceResponseCaptionsEnabled` | Bool caption overlay |
| `openClickyVoiceResponseCaptionFont` / `Opacity` | Caption styling |
| `openClickySpeculativePreFireEnabled` | Bool — pre-fire TTS request before final transcript |
| `openClickyVoiceActivationMode` | `push_to_talk` / `toggle_wake_word` / `always_wake_word` |
| `openClickySelectedModel` | Voice response model id (routed via provider) |
| `openClickySpeechModel` | OpenAI Realtime speech id (`gpt-realtime-2.1-mini` default) |
| `openClickyAnthropicAPIKey` | Anthropic key (Keychain-backed) |
| `openClickyOpenAIAPIKey` | OpenAI key |
| `openClickyElevenLabsAPIKey` / `openClickyElevenLabsVoiceID` | ElevenLabs config |
| `openClickyCartesiaAPIKey` / `openClickyCartesiaVoiceID` | Cartesia config |
| `openClickyOpenAIRealtimeVoiceID` | Realtime voice id (default `cedar`) |
| `openClickyDeepgramAPIKey` | Deepgram key (shared STT + TTS + agent) |
| `openClickyDeepgramTTSVoice` | Aura voice id |
| `openClickyDeepgramVoiceAgentThinkModel` | Deepgram Voice Agent thinker model |
| `openClickyMicrosoftEdgeVoiceID` | Edge TTS voice |
| `openClickyAssemblyAIAPIKey` | AssemblyAI key |
| `openClickyAssistAgentEnabled` | Bool — inject assist system prompt block |
| `openclicky.contextAwarenessEnabled` | Bool — preflight context on HeyClicky lane |
| `openClickyHeyClickyProxyBaseURL` | HeyClicky Free proxy base URL |
| `openClickyHeyClickyOAuthAuthorizeURL` | Google-OAuth authorize URL |
| `openClickyHeyClickySupabaseURL` / `SupabaseAnonKey` | Supabase auth backend |
| `openClickyHeyClickyChatToolCallPath` | Default `/chat-tool-call` |
| `openClickyHeyClickyTranscriptionPath` | Default `/audio/transcriptions` |
| `openClickyHeyClickyRealtimeEphemeralPath` | Default `/agent/realtime/session` |
| `openClickyHeyClickyCodexEphemeralPath` | Default `/agent/session-token` |
| `openClickyHeyClickyDictationReceiptPath` | Deepgram-token mint path |
| `openClickyHeyClickyHeaderPrefix` | Default `X-Clicky-` |
| `openClickyHeyClickySessionAccessToken` / `RefreshToken` | Supabase JWT pair (Keychain) |
| `openClickyExternalControlBridgeToken` | Bearer for the loopback MCP server |
| `openClickyXLBEnabled` / `openClickyXLBHostUrl` / `openclicky.xlb.graphJsonPath` | xlinkBook |

## Endpoints reference

- Deepgram STT WS: `wss://api.deepgram.com/v1/listen`
- Deepgram TTS: `https://api.deepgram.com/v1/speak`
- Deepgram Voice Agent: `wss://agent.deepgram.com`
- AssemblyAI STT WS: `wss://streaming.assemblyai.com/v3/ws`
- ElevenLabs TTS: `https://api.elevenlabs.io/v1/text-to-speech/{voiceID}/stream`
- Cartesia TTS: `https://api.cartesia.ai/tts/bytes` (Cartesia-Version `2026-03-01`)
- OpenAI Realtime WS: `wss://api.openai.com/v1/realtime`
- OpenAI transcriptions: `POST https://api.openai.com/v1/audio/transcriptions`
- Anthropic Messages: `https://api.anthropic.com/v1/messages` (fallback)
- HeyClicky proxy: `{HeyClickySecrets.proxyBaseURL}` (gitignored)
  - `POST /v2/dictation/deepgram-token` — ephemeral DG token
  - `POST /chat-tool-call` — main response with HigherModelResponse
  - `POST /agent/realtime/session` — ephemeral realtime bearer
  - `POST /agent/session-token` — Codex ephemeral
- Supabase auth: `{SupabaseURL}/auth/v1/token`, `/auth/v1/user`
- OpenClicky external MCP bridge: `http://127.0.0.1:32123` (SSE + JSON-RPC)

## Sample intermediate payload shapes

### HeyClicky `/chat-tool-call` request body

```json
{
  "query": "[openclicky-context]\n<preflight>...\n[ASSIST-agent hint]\n...\n<user transcript> (image dimensions: 1568x980 pixels)",
  "screenshotBase64": "<jpeg base64, downscaled to 1568 max-dim @ q=0.75>",
  "screenshotWidthInPixels": 1568,
  "screenshotHeightInPixels": 980,
  "mimeType": "image/jpeg",
  "client_capabilities": ["walkthrough_v2", "point", "typing", "clipboard", "widget"],
  "frontmost_app_bundle_id": "com.googlecode.iterm2",
  "environment": {"os": "macOS 15.1", "app_version": "1.0.40", "locale": "en-US"},
  "session_id": "sess_..."
}
```

### `HigherModelResponse` (decoded)

```json
{
  "text": "That's the submit button. [POINT:854,612:submit]",
  "clipboardText": null,
  "typing": null,
  "point": {"x": 854, "y": 612, "label": "submit", "screen": 0},
  "widgets": [],
  "walkthrough": {
    "language": "en",
    "beats": [
      {"kind": "target", "x": 854, "y": 612, "r": 40, "label": "Submit"},
      {"kind": "highlight", "x": 800, "y": 590, "width": 120, "height": 44, "label": "Submit button"}
    ]
  },
  "annotationText": "Click here to submit"
}
```

### AssemblyAI streaming Turn message

```json
{"type":"Turn","transcript":"how do I submit","turn_order":3,"end_of_turn":true,"turn_is_formatted":true}
```

### Deepgram nova-3 Results message

```json
{"type":"Results","channel":{"alternatives":[{"transcript":"how do I submit"}]},"is_final":true,"speech_final":true}
```

### AssistAgent tool round (Chinese JSON)

```json
{"步骤":"需要","类型":"搜索结果","参数":{"路径":"cursor-buddy/","模式":"analyzeVoiceResponse","忽略大小写":true},"原因":"定位主入口"}
```

```json
{"步骤":"完成","答案":"入口是 CompanionManager+AIResponsePipeline.swift:_analyzeVoiceResponseCore (line 556)。走 provider switch,heyclickyFree 分支到 HeyClickyChatToolCallClient.analyzeVoiceResponse (HeyClickyChatToolCallClient.swift:41)。"}
```
