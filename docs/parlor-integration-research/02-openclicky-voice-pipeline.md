# OpenClicky Voice Pipeline (key-press to spoken reply)

Status: complete. Verified against code as of 2026-08-08; supersedes the stale
`docs/OPENCLICKY_VOICE_PIPELINE.md` where they disagree.
Scope: three profiles — `heyclickyFree`, `ski`, `mirage-peekyFree`.
Related docs: `01-parlor-capabilities.md`, `03-openclicky-context-injection.md` (context assembly detail), `04-smart-turn-port-plan.md`.

---

## Stage 1 — Activation

### Profiles and their activation mode

All six built-in profiles ship `activationMode = push_to_talk`
(`cursor-buddy/OpenClickyProfile.swift:53,66,77,97,114,139`). The three in scope:

| Profile | id | STT | Response model | TTS | Activation |
|---|---|---|---|---|---|
| HeyClicky Free | `heyclicky_free` | `heyclickyFree` | `heyclicky-free-speech` | `openAIRealtime` | pushToTalk (`OpenClickyProfile.swift:82-100`) |
| SKI Mode | `ski_mode` | `whisperLocal` | `claude-haiku-4-5` | `microsoftEdge` | pushToTalk (`OpenClickyProfile.swift:108-117`) |
| Peeky Free (mirage) | `mirage` | `mirageDeepgram` | `mirage/claude-fable-5` | `mirageCartesia` | pushToTalk (`OpenClickyProfile.swift:129-146`) |

Activation mode is a *global* user setting, not a per-profile lock: the profile
merely seeds it (`CompanionManager+Profiles.swift:99-101`) and the user can flip
it in Settings (`OpenClickySettingsWindowManager.swift:685-694`).

### Mode 1 — `pushToTalk` (`OpenClickyVoiceActivationMode.pushToTalk`)

`OpenClickyWakeWordManager.swift:17` defines the enum; `usesWakeWord == false`
only for this case (`:42-44`).

Inputs: raw CGEvent stream.
- Tap: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, ...)` for `.flagsChanged | .keyDown | .keyUp` (`GlobalPushToTalkShortcutMonitor.swift:54-84`). Listen-only, so the chord is never swallowed from other apps.
- Chord: `BuddyPushToTalkShortcut.currentShortcutOption = .controlOption` (`BuddyDictationManager.swift:95`) i.e. **ctrl + option**, modifier-only, matched purely on `.flagsChanged` (`BuddyDictationManager.swift:163-177`). Space (`keyCode 49`, `:96`) is only used by the `*Space` variants, which are not the current default.
- Edge detection is level-triggered against `wasShortcutPreviouslyPressed`, so press == first frame the chord is complete, release == first frame it is not.
- Side channels on the same tap: **Escape** (`keyCode 53`, `:168-181`) → `escapeKeyPublisher` → `handleEscapeKeyPressed()`; **double-tap standalone Shift** (`:201-258`) → opens the main panel. Constants: `maximumShiftDoubleTapInterval = 0.24 s` (`:29`), `maximumStandaloneShiftTapHoldDuration = 0.18 s` (`:30`).

Processing: `shortcutTransitionPublisher` → main queue → `CompanionManager.handleShortcutTransition` (`CompanionManager.swift:5099-5104`, handler at `:6684`).

On `.pressed` (`CompanionManager.swift:6684-6808`), in order:
1. Bail if `voiceActivationMode.usesWakeWord` (then it is a toggle, see mode 2), if dictation already in progress, or if onboarding video is up (`:6687-6694`).
2. Cancel `transientHideTask`, show the cursor overlay, dismiss the menubar panel (`:6697-6708`).
3. `resetSpeculativeFireForNewUtterance()` (`:6725`).
4. **`startPrewarmedScreenshotCaptureIfPossible()` (`:6730`) — the screenshot is fired at key-down, in parallel with audio, explicitly so it does not serialize after the final transcript.**
5. `beginCircleSelectSessionIfEnabled()` (`:6731`) — optional "circle while talking" region select.
6. Cache the routing lane at press: `pttPressedRoutedToHeyClicky = shouldRoutePTTToHeyClickyRealtimeSession` (`:6736`). Comment at `:6734-6735`: a mid-hold provider swap would otherwise strand the HeyClicky WS mic-open.
7. Three mutually exclusive lanes:
   - **HeyClicky Free realtime**: `HeyClickyChatToolCallClient.capturePTTSnapshot()` (`:6751`) then `voiceState = .listening` and `HeyClickyRealtimeSession.shared.beginPushToTalk()` (`:6777-6778`). Mic audio goes straight up the WebSocket.
   - **Bidirectional realtime (OpenAI/Deepgram voice agent)**: `startBidirectionalRealtimeVoiceCapture(source: "keyboardShortcut")` (`:6781`).
   - **Everything else (SKI, mirage, local/quality)**: `buddyDictationManager.startPushToTalkFromKeyboardShortcut(...)` (`:6789-6807`) with `updateDraftText` (partial → circle-select + live computer-use), `submitDraftText` → `handleFinalVoiceTranscript`, and `onWillStartRecording` → `interruptCurrentVoiceResponse()` (barge-in).

On `.released` (`CompanionManager.swift:6809-6847`):
- Cancel `pendingKeyboardShortcutStartTask` — guards the quick press-release that would otherwise leave the waveform stuck (`:6813-6819`).
- Consume the cached lane (`:6823-6824`), never re-evaluate.
- HeyClicky: `endPushToTalk()` then `voiceState = .processing` (`:6832-6838`).
- Bidirectional: `finishBidirectionalRealtimeVoiceCaptureIfNeeded` (`:6840`).
- Default: `buddyDictationManager.stopPushToTalkFromKeyboardShortcut()` (`:6846`).

**Stop condition is purely key-up. There is no acoustic end-of-turn in this mode.**

### Mode 2 — `toggleWakeWord`

Same chord, but `.pressed` short-circuits into `toggleWakeWordListeningFromShortcut()` (`CompanionManager.swift:6687-6690`) and `.released` is a no-op (`:6810-6812`). The chord arms/disarms the "Hey Clicky" listener rather than recording.

`startWakeWordListeningIfNeeded` (`CompanionManager.swift:7086-7113`) refuses to arm unless `voiceState == .idle`, no dictation in flight, no realtime capture, and none of `voiceTTSClient` / `openAIRealtimeSpeechClient` / `deepgramVoiceAgentClient` is playing — i.e. it never listens over its own speech. Resume after a turn is debounced 450 ms (`scheduleWakeWordListeningResumeIfNeeded`, `:7121-7132`).

### Mode 3 — `alwaysWakeWord`

Identical detection path, but armed at launch when mic permission exists (`CompanionManager.swift:4857`, `:2796`).

Wake detection (`OpenClickyWakeWordManager.swift:147-266`):
- Inputs: `AVAudioEngine.inputNode` at the hardware format, 1024-frame tap (`:166-171`).
- Processing: `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`, `addsPunctuation = false`, `taskHint = .search` (`:153-158`). Start is refused outright if the locale has no on-device recognizer (`:90-92`) — deliberate: no always-on remote gate.
- Match: normalized fold + regex strip, then substring against `hey clicky` / `hay clicky` / `hey cliquey` / `hay cliquey` (`:254-266`). **Plain string match on the running partial transcript — no keyword-spotting model, no confidence threshold.**
- Output: `onWakeWordDetected(transcript)` → `CompanionManager.handleWakeWordDetected` (`CompanionManager.swift:1917`, handler `:7130-7192`).

`handleWakeWordDetected` ducks other audio (`wakeWordAudioDucker.duck`, `:7137`), prewarms the screenshot (`:7139`), then either opens a bidirectional realtime capture or starts `startAutoSubmittingDictationFromMicrophoneButton`. **Both branches are stopped by a hard 8-second timer** (`voiceFollowUpStopTask`, `try? await Task.sleep(nanoseconds: 8_000_000_000)` at `:7160` for realtime and `:7183` for dictation). That 8 s wall-clock cap is the only end-of-utterance signal for the wake-word path besides the provider's own VAD.

### SKI-specific activation surfaces

**`SKIModeHotkeyMonitor.swift`** is *not* a voice trigger. It is a `.defaultTap` (swallowing) CGEvent tap on `.keyDown` only (`:66-83`), active only when `OpenClickyProfileCatalog.activeProfile().id` is the SKI profile (`:117`). Four SKI-parity actions with a 0.4 s repeat guard (`:139`):
- `next_project` Ctrl+Shift+D (keycode 2) → cycle pinned workspace (`:45`, `:179-207`)
- `toggle_silent` Ctrl+Shift+V (keycode 9) → mute TTS, bubble still shows (`:46`, `:165-166`)
- `capture_screen` Ctrl+Shift+S (keycode 1) → proactive screenshot (`:47`, `:167-168`)
- `toggle_widget` unbound by default (`:48`)

**`SKIModeHandsFreeSession.swift`** is the one genuinely VAD-gated capture path, opt-in via `openclicky.ski.handsFreeMode` (default false) and only in the SKI profile (`:80-88`).
- Silence timeout: `openclicky.ski.vadSilenceMs`, **default 2000 ms**, converted to frames as `max(1, ms / 36)` (`:60-64`) — i.e. ~55 frames of 36 ms Silero chunks.
- Threshold: `openclicky.ski.vadThreshold`, **default 0.5** (`:66-70`).
- Utterances shorter than 0.5 s (`16_000 / 2` samples) are dropped (`:261`, `:334`).
- Speech ring capped at 60 s (`:227-229`); non-speech look-back trimmed to `chunkSize * 4` ≈ 144 ms (`:244-246`).
- Silero LSTM state is reset between utterances (`vad?.reset()`, `:260`).
- Output: `NotificationCenter` post `com.openclicky.ski.handsFreeUtteranceCaptured` carrying `[Int16]` samples (`:262-269`).

### Silence-timeout / end-of-utterance constants (all of them)

| Constant | Value | Location |
|---|---|---|
| SKI hands-free VAD silence | 2000 ms (user-tunable `openclicky.ski.vadSilenceMs`) | `SKIModeHandsFreeSession.swift:60-64` |
| SKI hands-free VAD threshold | 0.5 (`openclicky.ski.vadThreshold`) | `SKIModeHandsFreeSession.swift:66-70` |
| SKI hands-free min utterance | 8000 samples = 0.5 s | `SKIModeHandsFreeSession.swift:261` |
| PTT clip trim hangover | 14 frames ≈ 500 ms | `SileroVADTrim.swift:29` |
| PTT clip trim threshold | 0.5 | `SileroVADTrim.swift:24` |
| Wake-word turn hard stop | 8 s | `CompanionManager.swift:7160`, `:7183` |
| Wake-word relisten debounce | 450 ms | `CompanionManager.swift:7124` |
| Deepgram endpointing | 300 ms (query param) | `DeepgramStreamingTranscriptionProvider.swift:341` |
| OpenRewind capture VAD hangover | 1.5 s | `OpenRewind/Capture/AudioVAD.swift:28` (not on the PTT path) |
| Processing watchdog | 30 s | `CompanionManager.swift:1689` |
| Shift double-tap window | 240 ms / 180 ms hold | `GlobalPushToTalkShortcutMonitor.swift:29-30` |

**Answer to "is there end-of-utterance detection beyond VAD silence today?": no.**
Three mechanisms exist and that is all: (a) key release, (b) energy/probability
silence hangover (Silero in SKI hands-free and in PTT post-trim, Deepgram's
server-side `endpointing=300`), (c) a fixed 8 s wall clock on the wake-word
path. There is no semantic or acoustic-prosodic turn model (no Smart Turn, no
pitch/pause classifier, no "did they finish the sentence" check). See
`04-smart-turn-port-plan.md`.

---

## Stage 2 — Audio capture

### The single capture engine: `BuddyDictationManager`

One `AVAudioEngine` instance per manager (`BuddyDictationManager.swift:267`).
There is **no resampling in the capture layer** — the tap runs at the hardware
format and each provider converts for itself.

`startAudioCaptureBeforeProviderReady()` (`BuddyDictationManager.swift:800-818`):
- Format: `inputNode.outputFormat(forBus: 0)` — whatever the hardware gives (typically Float32 @ 44.1 or 48 kHz, mono or stereo). Not normalized here.
- **Buffer size: 256 frames** (`:806`). Comment at `:805`: "Smaller tap buffers lower capture-to-provider handoff latency." At 48 kHz this is ~5.3 ms per callback, ~190 Hz.
- Per buffer the tap does exactly two things: forward to `activeTranscriptionSession.appendAudioBuffer(buffer)` (`:808`) or, if the provider is not yet open, `bufferAudioUntilTranscriptionProviderReady` (`:810`); then `updateAudioPowerLevel(from:)` (`:812`).

### Pre-provider ring buffer (the "don't lose the first word" fix)

Providers advertise `shouldStartAudioCaptureBeforeProviderReady` (default
`true`, `BuddyTranscriptionProvider.swift:97-99`). When true the mic opens
*before* the provider socket, and everything captured meanwhile is deep-copied
into `audioBuffersCapturedBeforeProviderReady` (`:286`), capped at
**360 buffers** (`maximumBufferedAudioBuffersBeforeProviderReady`, `:287`) — at
256 frames / 48 kHz that is roughly 1.9 s of lead-in. On provider-ready the
whole ring is flushed in order (`:786-787`) and a
`voice.dictation.provider_ready` log records `providerOpenDurationMs` and
`bufferedAudioBufferCount` (`:789-797`).

Deep copy is format-agnostic across float32 / int16 / int32 channel data
(`copyAudioBuffer`, `:830-860`).

### Level metering (drives the waveform overlay)

`updateAudioPowerLevel` (`:1085-1139`): RMS over the buffer, `* 10.2` boost,
clamped to `[0,1]` (`:1098-1099`). Perf gate added in audit #334 P0-5
(`:1101-1119`): skip the MainActor hop entirely unless `|delta| >= 0.02` or a
0.9 s heartbeat is due — the raw callback fires ~50-190 Hz and every
`@Published` write bumped `objectWillChange`. History ring is 44 samples
(`recordedAudioPowerHistoryLength`, `:220`), baseline 0.02 (`:221`), sampled at
most every 30 ms (`:222`). **This RMS is display-only — it is not fed to any
turn-detection logic.**

### Conversion helpers: `BuddyAudioConversionSupport.swift`

- `BuddyPCM16AudioConverter` (`:11-70`): lazily rebuilds an `AVAudioConverter` whenever the input format description changes (`:28-31`), target is always **Int16 / mono / interleaved** at a caller-chosen sample rate (`:17-22`). Output frame capacity is `ceil(frames * ratio) + 32` (`:36-38`). Returns raw `Data`.
- `BuddyWAVFileBuilder.buildWAVData` (`:72-102`): 44-byte RIFF/WAVE header + PCM16 payload, for the batch providers that POST a file.

Target sample rates per provider are set by the caller, e.g. Deepgram and
whisper.cpp both use 16 kHz.

### VAD

There are two distinct VAD surfaces, and neither one is in the PTT capture loop
itself:

1. **`SileroVADTrim`** (`SileroVADTrim.swift`) — a *post-hoc trimmer*, not a turn detector. Called on a completed Int16 mono 16 kHz clip. Config: chunk 576 samples @ 16 kHz = 36 ms (`:21-22`), `speechThreshold = 0.5` (`:24`), `silenceHangoverFrames = 14` ≈ 500 ms (`:29`), `leadInFrames = 3` ≈ 108 ms (`:31`). One shared lazily-created `SileroVAD` reset per call (`:34-36`, `:53`). It splices `[firstSpeech - leadIn, lastSpeech + hangover]` (`:89-104`), returns `[]` if no frame is speech-tagged (`:90-93`), and returns the input unchanged if the model failed to load (`:42-52`). It then **peak-normalizes to ±16384 (~-6 dBFS) when peak < 12000** (`:106-125`) — added because quiet mic input at RMS ~0.03 made whisper hallucinate Chinese YouTube subtitle boilerplate. Logs `openclicky.silerovad.stats` and `.trim` with `speech_pct` / `kept_pct` / `peak_before` / `gain_applied`.
2. **`SKIModeHandsFreeSession`** — the only continuously-running VAD (covered in Stage 1). 16 kHz Int16 mono target (`:107-110`), input tap `bufferSize: 2048` at hardware format with a per-buffer `AVAudioConverter` (`:118-152`), then 576-sample Silero chunks on a serial `ingestQueue` (`:53-56`, `:197-249`).

### Provider readiness and finalize

`stopPushToTalk` (`:637-699`) tears down the mic (`tearDownAudioCapture(cancelTranscriptionSession: false)`, `:674`) and then calls
`activeTranscriptionSession?.requestFinalTranscript()` (`:675`). A watchdog
`DispatchWorkItem` fires after
`activeTranscriptionSession.finalTranscriptFallbackDelaySeconds` (provider-supplied) or the
default **2.4 s** (`defaultFinalTranscriptFallbackDelaySeconds`, `:219`) and force-finishes with
`completionReason: "fallback"` (`:679-698`). If the provider returns an empty
final but a non-empty partial exists, the partial wins
(`usedPartialFallback`, `:748-771`).

Latency instrumentation available today (all via `OpenClickyMessageLogStore`,
lane `voice`): `voice.dictation.recording_started.startupDurationMs` (`:615`),
`voice.dictation.provider_ready.providerOpenDurationMs` (`:792`),
`voice.dictation.final_transcript_ready.finalizeLatencyMs` (`:762`),
`voice.dictation.finished.recordingDurationMs` (`:927`).

---

## Stage 3 — STT

### Protocol

`BuddyTranscriptionProvider.swift:82-95`:

```
protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var shouldStartAudioCaptureBeforeProviderReady: Bool { get }   // default true, :97-99
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }
    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}
```

Session side (`:75-80`): `finalTranscriptFallbackDelaySeconds`,
`appendAudioBuffer(_:)`, `requestFinalTranscript()`, `cancel()`. Note the
protocol is **audio-in / text-out only** — there is no way for a provider to
hand the caller raw audio, embeddings, or timing metadata.

### Provider matrix

| ID (`:11-24`) | Class | Streaming? | Target rate | `fallbackDelaySeconds` | Keyterms |
|---|---|---|---|---|---|
| `deepgram` | `DeepgramStreamingTranscriptionProvider` | **streaming** (WSS) | 16 kHz Int16 mono | 3.0 (`:95`) | yes, as URL query |
| `mirage_deepgram` | `MirageDeepgramTranscriptionProvider` | **streaming** (WSS via aegis-proxy token) | 16 kHz (`:40`) | 3.0 (`:56`) | **only the first keyterm** (`:38`) |
| `heyclicky_free` | `HeyClickyProxyTranscriptionProvider` | **streaming** — mints a Deepgram token then *reuses* `DeepgramStreamingTranscriptionSession` verbatim with `model: nova-3` (`:70-80`) | 16 kHz | 3.0 (inherited) | full list, inherited |
| `whisper_local` | `WhisperLocalTranscriptionProvider` | **batch only** — "whisper.cpp large-v3-turbo is not streaming" (`:8`) | 16 kHz (`:83`) | **20.0** (`:81`) | **ignored** |
| `assemblyai` | `AssemblyAIStreamingTranscriptionProvider` | streaming | 16 kHz (`:144`) | 2.8 (`:147`) | `keyterms_prompt` JSON array (`:460`) |
| `openai` | `OpenAIAudioTranscriptionProvider` | batch (multipart upload) | 16 kHz (`:67`) | 8.0 (`:60`) | folded into a `prompt` string (`:267`) |
| `apple` | `AppleSpeechTranscriptionProvider` | streaming (SFSpeech) | native | 1.2 (`:61`) | ignored |
| `parakeet` | `OpenClickyParakeetTranscriptionProvider` | batch, `shouldStartAudioCaptureBeforeProviderReady = false` (`:28`) | 16 kHz (`:216`) | **12.0** (`:214`) | ignored |

Selection and fallback chain live in `BuddyTranscriptionProviderFactory`
(`BuddyTranscriptionProvider.swift:101-376`). `automatic` resolves through
`configuredFallback` (`:334-375`) in order: Parakeet → **whisper.cpp local**
→ AssemblyAI → Deepgram → OpenAI → Apple Speech. The whisper-before-cloud
ordering is deliberate (`:346-349`): offline, free, and better Chinese than
Apple Speech.

### Per-profile STT path

**`heyclickyFree`** — two distinct lanes depending on the *response model*, not the STT setting:
- Default (`responseModelID = "heyclicky-free-speech"`, `OpenClickyProfile.swift:90`): `shouldRoutePTTToHeyClickyRealtimeSession` is true because `model.provider == .heyclickyFree` (`CompanionManager.swift:7049-7052`), so `BuddyDictationManager` is **bypassed entirely**. Audio goes to `HeyClickyRealtimeAudioEngine(sampleRate: 24_000)` (`HeyClickyRealtime/HeyClickyRealtimeSession.swift:97`), base64-chunked into `input_audio_buffer.append` frames (`:244-247`). On release: `flushPending()` + `stopCapture()`, then commit — **but only if ≥ 5000 bytes were sent** (`:296`; comment at `:283` says OpenAI rejects < 100 ms). Server-side `turn_detection` is explicitly `NSNull()` (`:692`) — VAD is disabled, PTT is authoritative.
- If the user switches to `heyclicky-free-chat` in Advanced, the two-stage lane engages and `HeyClickyProxyTranscriptionProvider` mints a per-turn Deepgram token via `POST /v2/dictation/deepgram-token` (`:87-105`), then streams direct to `wss://api.deepgram.com/v1/listen` (not through the proxy). On `quotaExhausted` it triggers `HeyClickyAccountResetManager.attemptReset` (`:56-63`).

**`ski`** — `whisperLocal`, batch. `appendAudioBuffer` converts each buffer to
Int16 16 kHz and appends to `bufferedPCM16AudioData`; nothing is transcribed
until `requestFinalTranscript()`, which fires a single
`WhisperCppTranscriber.transcribe(utterance:)` (`WhisperLocalTranscriptionProvider.swift:~150-190`). Clips under
**8000 samples (0.5 s)** deliver an empty final. Language selection is
non-obvious (`:56-76`): explicit override wins, else it mirrors
`openClickyVoiceResponseLanguage` and force-pins `zh` / `en` rather than
`auto` — the comment records that auto-detect mistranslated Chinese to English
because OpenClicky's capture is quieter than SKI's VoiceProcessingIO+AGC path.
There is also a SKI-parity tail trim that cuts at the quietest 20 ms frame in
the last ~2 s when its RMS < 0.02. The 20 s fallback delay is the largest in
the app — a slow whisper pass will not be cut short.

**`mirage-peekyFree`** — `mirageDeepgram`. Wire-identical to paid Deepgram; only
the token source differs (aegis-proxy `/mint-token` vs the user's key, see the
header comment `MirageDeepgramTranscriptionProvider.swift:1-11`). Partials are
**polled**, not pushed: a `Task` reads `inner.currentPartial()` every 100 ms
(`:80-91`). Finalize is `inner.finalize()` then `awaitFinal(seconds: 3.0)`
(`:107-112`). The Float32→Int16/16 kHz conversion via
`BuddyPCM16AudioConverter` is load-bearing — the comment at `:96-99` records
that without it Deepgram saw zero audio and returned empty transcripts.

### Deepgram wire detail (shared by 3 of the 9 providers)

`DeepgramStreamingTranscriptionProvider.swift:329-362` builds
`wss://api.deepgram.com/v1/listen` (`:91`) with:
`model=<name>`, `encoding=linear16`, `sample_rate=16000`, `channels=1`,
`interim_results=true`, `smart_format=true`, **`endpointing=300`** (`:335-341`).

`endpointing=300` is the only server-side turn signal in the whole pipeline —
Deepgram emits `speech_final` after 300 ms of silence. Note the app **logs but
does not act on** `SpeechStarted` and `UtteranceEnd` frames (`:205-209` — bare
`print` statements). Those are exactly the frames a turn-detector would consume.

Keyterm parameter name is model-dependent (`:344-361`): `keyterm` for nova-3 /
nova-4+, `keywords` for nova-2 and older — mixing `keywords` with `model=nova-3`
fails the WebSocket upgrade.

Finalization handshake (`:218-273`): `requestFinalTranscript()` sets
`isAwaitingExplicitFinalTranscript` and starts a **1.6 s grace timer**
(`explicitFinalTranscriptGracePeriodSeconds`, `:93`). Any subsequent frame with
`from_finalize` / `is_final` / `speech_final` resolves it early (`:239-247`);
otherwise the timer force-delivers `bestAvailableTranscriptText()`. On WS error
mid-finalize with a non-empty partial, the partial is delivered rather than
erroring (`:288-294`).

### How `keyterms` flow

1. `BuddyDictationManager.buildTranscriptionKeyterms()` (`:1050-1083`) starts from a hardcoded base list — `makesomething`, `Learning Buddy`, `Codex`, `Claude`, `Anthropic`, `OpenAI`, `SwiftUI`, `Xcode`, `Vercel`, `Next.js`, `localhost` (`:1051-1063`).
2. It concatenates `contextualKeyterms`, set by the single caller of `updateContextualKeyterms` (`:337-339`).
3. Dedupe is case-insensitive but order-preserving (`:1066-1080`).
4. The result is passed once at `startStreamingSession(keyterms:)` (`:738`) — **keyterms are fixed for the whole session and cannot be updated mid-utterance**.
5. Each provider maps them differently (see matrix). Three providers (whisper, Apple, Parakeet) discard them silently; mirage keeps only the first.

---

## Stage 4 — Context assembly (entry points only)

**Full treatment is in `03-openclicky-context-injection.md`** — source table,
token costs, ordering, cache boundaries. This section lists only the call
surfaces so the trace stays connected.

### Two independent assemblers (they do not share code)

Doc 03 opens with this and it matters here: the SKI/Mirage lane and the main
in-app LLM lane assemble context separately and in different orders.

**A. Main in-app lane** — inline inside `_analyzeVoiceResponseCore`
(`cursor-buddy/CompanionManager+AIResponsePipeline.swift:667-869`).

**B. SKI / Mirage lane** — `CompanionManager.buildSKIUtteranceContext(userQuery:)`
(`cursor-buddy/CompanionManager.swift:5783-5926`), returning
`OpenClickyFileBridge.UtteranceContext` with named brief slots
(`focusedWindowLine`, `everywhereActiveWindowBrief`, `ltmMemoriesBrief`,
`xlbTopicsBrief`, `screenOCRStashBrief`, `openrewindOCRHitsBrief`,
`clipboardBrief`, `mcpURL`).
`buildMirageContextBrief(userQuery:)`
(`CompanionManager+AIResponsePipeline.swift:2976-3010`) is a thin flattener over
it that emits `key: value` lines (`focused_window:`, `everywhere:`, `ltm:`,
`xlb:`, `stash:`, `openrewind:`, `clipboard:`) and returns nil when empty.

### System-prompt entry points

`CompanionManager.swift:18603-18640`:
- `currentVoiceResponseSystemPrompt()` (`:18603-18611`) — legacy convenience; returns `stable + "\n\n" + dynamic`. Callers wanting cache safety should not use it.
- `stableVoiceResponseSystemPrompt()` (`:18616-18618`) — returns the byte-invariant `Self.companionVoiceResponseSystemPrompt`. **This is the only block that may carry `cache_control: {type:"ephemeral", ttl:"1h"}`** — Anthropic hashes exact bytes up to the breakpoint, so any volatile prefix defeats the cache.
- `dynamicVoiceResponseSystemContext()` (`:18625-18640`) — per-turn volatile block, emitted as the SECOND `system[]` entry with no `cache_control`. Composes `inlineWebSearchCapabilityPromptIfAvailable()`, `currentAppSkillContextPrompt()` (`:18596-18601`), `visualGuidanceCorrectionLearningPrompt()`, `runtimeStorageContextForVoicePrompt()`, and `codexHomeManager.persistentMemoryContext()`.

Call sites: warm-up (`CompanionManager.swift:2193`, `:2196`, `:2822`, `:2851`),
main pipeline (`:3799`, `:11796`), HeyClicky lane
(`CompanionManager+HeyClicky.swift:1327`), the split path
(`CompanionManager+AIResponsePipeline.swift:2916` uses `stablePrefix` directly),
and the external control bridge
(`OpenClickyExternalControlBridge.swift:4125`).

### Screenshot: `CompanionScreenCaptureUtility`

Relevant to a future multimodal router because it is the one path that already
produces an image in lockstep with the audio.

- `startPrewarmedScreenshotCaptureIfPossible()` (`CompanionManager+AIResponsePipeline.swift:1393-1404`) — fired at **key-down** (`CompanionManager.swift:6732`), at wake-word detection (`:7139`), and from two other turn starts (`:11096`, `:11114`). No-op without `hasScreenContentPermission`; a detached `Task` runs `captureAllScreensAsJPEG()`.
- `captureAllScreensForVoiceResponseIfAvailable()` (`:1363-1386`) — consumes the prewarm if it is younger than `prewarmedScreenshotMaxAge = 8.0 s` (`CompanionManager.swift:1737`), else cancels and captures fresh.
- Capture API (`CompanionScreenCaptureUtility.swift`): `currentShareableContent()` (`:39`), `prewarmShareableContent()` (`:54`, called at boot `CompanionManager.swift:2781`), `captureAllScreensAsJPEG()` (`:63`), `captureCursorScreenAsJPEG()` (`:70`), `captureFocusedWindowAsJPEG()` (`:239`), `cropCapture` (`:310`), `captureRegionAsJPEG` (`:367`).
- Downscale: `maxDimension = 1280`, aspect-preserving (`:168-175`, `:261-270`), JPEG-encoded. Output type `CompanionScreenCapture` (`(data: Data, label: String)` at use sites).

**Everything else — LTM budgets, OpenRewind FTS, XLB topics, app-skill table,
memory.md, clipboard, ordering, and per-source token costs — see
`03-openclicky-context-injection.md`.**

---

## Stage 5 — Intent classification / routing

There are **four separate routers** in the codebase and they are used by
different profiles. Nothing unifies them.

### Router 1 — `routeFinalVoiceTranscriptActionIfNeeded` (Layer 0, all profiles)

`CompanionManager.swift:7969-8034`. This runs first for every final transcript
(called at `:7807`, `:7943`, `:11141`) and is a **plain ordered chain of
keyword/regex predicates**, each returning `Bool` for "handled". In order:

`trySelfDrivingCodexDispatch` → `handleAgentCancellationRequestIfNeeded` →
`handleAgentStatusQuestionIfNeeded` → `handleClearOverlayAnnotationsRequestIfNeeded` →
`handleVisualGuidanceCalibrationCursorSampleIfNeeded` →
(`isScreenCalibrationRequest` explicitly returns `false` to force the
screenshot lane, `:7997-8000`) →
`handleAgentSelectionRequestIfNeeded` → `acceptPendingAgentOfferIfConfirmed` →
`submitPendingAgentVoiceFollowUp` → `startHybridAgentTaskIfNeeded` →
`startExplicitAgentTaskIfRequested` → `startAgentTaskFromDeferredLiveAgentRouteIfNeeded` →
`handleDirectComputerUseRequest` → `handleQuickLocalVoiceResponseIfNeeded` →
`submitContextualAgentFollowUp` → `startSmartAgentTaskIfNeeded` →
`startImplicitAgentTaskIfNeeded` → `false` (fall through to the LLM).

**No model involved. Text-only. Runs before any LLM sees the utterance.**

A partial-transcript variant runs *during* the utterance:
`handleLiveComputerUseTranscript` (`:8038-...`) fires once the partial reaches
8 characters (or is a known bare app-open phrase), feeding both the speculative
pre-fire path and live computer-use detection.

### Router 2 — `OpenClickyIntentClassifier` (BERT ONNX, on-device)

`OpenClickyIntentClassifier.swift`. Ported from Peeky's `routelet`
(`peeky/src/routelet/mod.rs`), deliberately un-namespaced so any profile can use
it (`:1-16`).

Pipeline (`:18-22`): `text → MirageRedact.preprocess → HF WordPiece tokenizer →
{input_ids, attention_mask, token_type_ids} → BERT embedder (ONNX, [1,384]) →
linear head coef[K][384]·v + intercept[K] → temperature-scaled softmax → argmax`.

- Labels (`:44-51`): `chat`, `find_action`, `integration`, `memory`, `none` (reject / out-of-distribution). The `agent` label from the original head is **dropped at load** (`:41-43`, `:153`) so softmax renormalizes over 4 real classes — agent turns are expected to arrive via the voice cue instead.
- Assets: `AppResources/OpenClicky/mirage-routelet/{embedder.onnx, head.json, tokenizer.json}` (`:23-26`). Runtime is `onnxruntime-swift-package-manager`; vocab (~30k entries, ~500 KB) is parsed straight out of `tokenizer.json` rather than reconstructing the HF pipeline (`:28-33`, `:75-78`).
- Lifecycle: `actor`, `shared` singleton, ORT env + session built lazily on first `embed()` and kept for the classifier's lifetime — "session load cost is a few hundred ms (127 MB model)" (`:86-90`). `bootstrap()` is kicked off at four places: `CompanionManager.swift:2213`, `:2733`, `CompanionManager+Profiles.swift:48`, `PeekyFreePanelView.swift:644`.
- API: `classify(_ text: String) async -> OpenClickyIntentPrediction?` (`:219`), returning `(intent, confidence)`. Returns nil (abstains) when not loaded.
- **Input is a `String`. There is no audio or image input path.**

### Router 3 — `MiragePeekyOrchestrator.classify` (Peeky Free only)

`MiragePeekyOrchestrator.swift:~205-230`. A four-tier cascade in Peeky's
`orchestrator.rs` order, with the stated latencies in comments:

1. **Agent voice cue** — prefix match, "sub-µs". Prefixes include `"peeky agent "` (and the OpenClicky equivalent). Returns `.agent`.
2. **Keyword allowlist** — "sub-µs exact match". Hardcoded transport verbs: `play, pause, resume, stop, mute, unmute, skip, next, next song, next track, previous, previous song, previous track` → `.integration`.
3. **On-device routelet** — Router 2, "**~45 ms**". Accepted only when `confidence >= routeletConfidenceThreshold = 0.85` (`:~192`) AND the label is not `.none`. Below threshold or reject class → abstain to tier 4. Comment notes routelet never emits `.agent` by design.
4. **Claude forced tool call** — "**~250-700 ms**, one mirage HTTP round-trip". `model: mirage/claude-haiku-4-5-20251001` (cheapest tier), `max_tokens: 80`, `stream: false`, `tool_choice: {type: "tool", name: "classify"}` with `MiragePrompts.classifier` + `MiragePeekyTools.classifierTool`.

If all four abstain, the failsafe is `.chat` (matches Peeky).

### Router 4 — `[ROUTE]` in-band tag (HeyClicky Free) — **removed**

Historically the Fable reply ended with a `[ROUTE] {…}` JSON line that the
client parsed and dispatched. That contract is gone. Two explicit tombstones:

- `HeyClickyChatToolCallClient.swift:606-609`: "`[ROUTE]` JSON dispatch removed. Chat replies stay chat replies; agent-lane routing lives entirely on client side in `routeFinalVoiceTranscriptActionIfNeeded` (Layer 0 'free agent' keyword + upstream agent detectors)."
- `:995-997`: "The `[ROUTE]` JSON tail contract used to live here — it has been removed... Agent-lane routing happens [client-side]."

What remains is the **data type**, still used because `RouteDispatcher` takes it
as its argument shape: `RouteParseResult` (`:894-960`) with fields `kind`,
`project_ref`, `slug`, `workdir`, `confidence`, `progress_driven`,
`completion_marker`. `effectiveCompletionMarker` (`:~942`) defaults to
`"LAST_COMPLETED: DONE"` when `progressDriven` is true and no marker was given.

Other in-band tags on the HeyClicky reply **are** still live and parsed:
`[TARGET:x,y,r:label:screenN]` → `HeyClickyGuidedClickManager.shared.arm(...)`
(`:595-604`), and `[ASSIST] {"goal":…}` → inline assist loop, bypassed inside
re-entrant rounds (`:611-...`).

### `OpenClickyRouteDispatcher` (the spawn side, not a classifier)

`OpenClickyRouteDispatcher.swift`, `@MainActor final class RouteDispatcher`,
`shared` singleton wired at `CompanionManager.swift:1928`.

Contract (`:10-15`): `kind == chat | ambiguous` → no spawn, TTS reply is enough;
`kind == short_task | long_task_new | long_task_existing` → spawn Codex.
Explicit constraint: "Fallback classifier NEVER uses utterance keyword tables.
It only consults preflight context signals (`WorkdirProbe.probe` on
`preflight.selectedFolder` + `ProjectRegistry` fuzzy match on transcript /
window title)."

`spawnCodex(route:userTranscript:preflight:)` (`:44-...`) resolves the workdir in
priority order: explicit `route.workdir` (tilde-expanded, existence-checked) →
`route.projectRef` via `ProjectRegistry.shared.lookup(...)` accepted at
`score > 0.75` → `preflight.selectedFolder` → nil (standalone
`~/OpenClicky/<slug>/`). Then `OpenClickyTaskDirectoryResolver.resolve` picks
`<workdir>/.openclicky/task/` or the standalone dir, and `composeAgentPrompt`
builds the agent prompt.

Called from `CompanionManager+SelfDrivingCodexDispatch.swift:76` (which is
itself tier 0 of Router 1) with `progressDriven: true` and a slug from
`RouteDispatcher.shared.makeSlug(from:)` (`:45`).

### Which profile uses which

| Profile | Layer 0 chain | Routelet ONNX | Peeky cascade | `[ROUTE]` |
|---|---|---|---|---|
| `heyclickyFree` | yes | bootstrap only, not consulted on this lane | no | removed; `[TARGET]` / `[ASSIST]` still live |
| `ski` | yes | available (header `:13-15` names SKI as a consumer) but no call site found | no | n/a |
| `mirage-peekyFree` | yes | **yes**, tier 3 of the cascade | **yes** | n/a |

---

## Stage 6 — LLM dispatch

### `LLMRequest` — the single request type

`cursor-buddy/LLMClient.swift:~24-48`:

```swift
struct LLMRequest {
    let model: String                       // provider-scoped, may be prefixed ("mirage/…")
    let systemPrompt: String                // caller already applied provider directives
    let conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    let userPrompt: String                  // the user's latest utterance (TEXT)
    let images: [(data: Data, label: String)]   // empty array = no visual input
    let assistantPrefill: String?           // Anthropic-only; others ignore silently
}
```

**There is no audio field.** `userPrompt` is a `String`; the only non-text
channel is `images`.

### `LLMCapabilities` — feature gate without switching on provider

`LLMClient.swift:~50-62`, an `OptionSet` with bits at 1<<0 … 1<<4. Observed
values in the adapters: `.images`, `.assistantPrefill`, `.tools`,
`.realtimeVoiceOnly`. Per-adapter (`LLMClientAdapters.swift`):

| Adapter | capabilities |
|---|---|
| `AppleFoundationLLMAdapter` | `[]` — text-only; `images` is passed but ignored downstream (`:41-43`) |
| `AnthropicLLMAdapter` | `[.images, .assistantPrefill]` |
| `OpenAILLMAdapter` | `[.images]` |
| `CodexLLMAdapter` | `[.images, .tools]` |
| `MirageLLMAdapter` | `[.images, .assistantPrefill]` |
| `HeyClickyLLMAdapter` | `[.images, .tools]` |
| `UnsupportedLLMAdapter` | `[.realtimeVoiceOnly]` |

### `LLMClient` protocol

`LLMClient.swift:~64-81`. `@MainActor protocol LLMClient: AnyObject` with
`var capabilities: LLMCapabilities { get }` and

```swift
func send(_ request: LLMRequest,
          onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String
```

Streaming is push-only through `onTextChunk`; the return value is the full
accumulated text. Returning `""` is a legal "provider intentionally suppressed
TTS" signal — that is the SKI contract. `@MainActor` on the protocol is
deliberate because the underlying `analyze*` helpers touch main-actor state.

### Registry

`LLMClientRegistry.swift:17-45` — a single `switch` over
`OpenClickyModelProvider`:
`.apple → AppleFoundationLLMAdapter`, `.anthropic → AnthropicLLMAdapter`,
`.openAI → OpenAILLMAdapter`, `.codex → CodexLLMAdapter`,
`.peekyFree → MirageLLMAdapter`, `.heyclickyFree → HeyClickyLLMAdapter`,
`.deepgram → UnsupportedLLMAdapter` (domain `"DeepgramVoiceAgentClient"`, code
`-20`, kept verbatim so existing `NSError.domain` pattern-matches still work).

Adapters are constructed fresh per dispatch and hold no state — they are pure
forwarders over a closure.

### `LLMDispatchHooks` — the closure indirection

`LLMClientAdapters.swift:24-37` plus typealiases at `:155-168`. The `analyze*`
methods on `CompanionManager` are `private`, so instead of widening access the
companion hands the registry a bag of six closures. The header note at `:29-31`
is worth quoting: "Extending this bag is the ONLY way to add a new provider
adapter — keeps every provider's parameter surface visible in one place so we
can spot drift (e.g. one adapter ignoring `assistantPrefill`)."

`makeLLMDispatchHooks()` (`CompanionManager+AIResponsePipeline.swift:878-953`)
builds it. Every non-Apple hook starts with
`guard let self else { throw CancellationError() }` and the same repeated
comment (`:889-891`, `:902-904`, `:914-916`, `:926-928`, `:938-940`):
returning `""` on a torn-down manager "would look like a legitimate empty reply
and the caller would happily speak silence."

Mapping: `apple → AppleFoundationModelsVoiceClient.analyzeVoiceResponse` (static,
no self); `anthropic → self.analyzeClaudeResponse`;
`openAI → self.analyzeOpenAIOrCodexVoiceResponse`;
`codex → self.analyzeCodexVoiceResponse`; `mirage → self.analyzeMirageResponse`;
`heyclicky → HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(companionManager: self, …)`.
Note only `anthropic` and `mirage` forward `assistantPrefill`; the others drop
it — matching the capability table.

### `dispatchViaLLMRegistry`

`CompanionManager+AIResponsePipeline.swift:963-970`. Three lines:

```swift
let client = LLMClientRegistry.client(for: provider, hooks: makeLLMDispatchHooks())
return try await client.send(request, onTextChunk: onTextChunk)
```

**This is the sole voice-response dispatch path.** The old provider `switch` was
deleted after a documented static-equivalence review
(`docs/peeky-review-2026-08-06/10-llmclient-equivalence.md`, cited at
`LLMClient.swift:11-12`, `LLMClientRegistry.swift:10-13`, `:955-961`).

### `analyzeVoiceResponse` → `_analyzeVoiceResponseCore`

Public entry `analyzeVoiceResponse` (`:600-655`) does two things before/after
the core:
1. **Voice profile switch pre-empt** (`:608-624`) — `handleVoiceProfileSwitch(userPrompt)` matches "switch to X" / "切换到 X" / "切到 X" across the three free lanes. Runs *before* dispatch so it never consumes quota; the confirmation string is returned and spoken like a normal reply.
2. **Assist-agent post-processing** (`:635-655`) — if the reply contains `[ASSIST] {...}`, `AssistAgentBridge.shared.handleModelReply(...)` runs the loop inline and splices the summary in, with a `progressChannel` that speaks stage updates. Skipped when `isReentrantRound`.

`_analyzeVoiceResponseCore` (`:667-869`) in order:
- `await XLBSensorTools.resetTurnBudget()` (`:678`) — resets the per-turn 20k cap so it does not accumulate.
- **Two-tier context split** (`:680-694`): STABLE layer = system prompt (identity + tool contracts); DYNAMIC layer = prepended to `userPrompt` (LTM, preflight/Everywhere AX, stash). Stated rationale: "keeping dynamic bits close to the actual user question means the model's attention lands on it at inference time rather than diluted across a massive system prompt."
- `AssistAgentBridge.effectiveSystemPrompt(systemPrompt)` unless re-entrant (`:696-698`).
- `Self.applyXLBHintIfEnabled(to: userPrompt)` (`:~706`) — applied to the raw prompt *before* the dynamic prefix, so LTM/stash/window blocks sit in front of it and the hint stays adjacent to the question.
- Context assembly (see Stage 4 / doc 03).
- **SKI early-return branch** (`:~780-843`): builds `buildSKIUtteranceContext`, calls `OpenClickyFileBridge.shared.writeUtteranceAndAwait(workspace:text:context:timeoutSeconds: 0.1)`, persists the user turn via `rememberVoiceExchange(reason: "ski_mode_utterance_only")`, and **returns `""`**. Comment at `:836-843`: the empty return means "handled elsewhere" — no TTS from the voice pipeline, and it specifically "prevents Claude Agent SDK fallback." The reply arrives later via the tail loop → `speakSKIModeAgentReply`. There is also a pending-approval variant that posts `com.openclicky.ski.utterancePendingApproval` and returns `""` to wait for confirm (`:~789-803`).
- Otherwise: construct `LLMRequest` (`:857-864`) and `dispatchViaLLMRegistry(provider: selectedVoiceResponseModel.provider, …)` (`:865-868`).

### The money rule in practice — `analyzeClaudeResponse`

`CompanionManager+AIResponsePipeline.swift:972-1050+`. Comment at `:982-986`:
"Claude Agent SDK FIRST (uses the local Claude Code sign-in the user already
pays for), direct ClaudeAPI HTTP only as fallback when the SDK is unavailable or
throws. Never short-circuit to HTTP for latency or capability reasons — direct
REST bills per token on the user's card."

Implementation: if `claudeAgentSDKAPI != nil`, set `.model` and
`.maxOutputTokens` from the catalog entry and call
`analyzeImageStreaming(images:systemPrompt:conversationHistory:userPrompt:assistantPrefill:onTextChunk:)`
(`:993-1010`). **`CancellationError` is rethrown, never treated as an
availability failure** (`:1011-1016`) — a user interrupt must not trigger the
paid fallback. Any other throw falls through to `ClaudeAPI` HTTP.

### Per-profile dispatch

| Profile | `provider` | Adapter | Underlying |
|---|---|---|---|
| `heyclickyFree` (default `heyclicky-free-speech`) | `.heyclickyFree` | `HeyClickyLLMAdapter` | `HeyClickyChatToolCallClient.shared.analyzeVoiceResponse` — but note the *default speech model* bypasses this entirely via `HeyClickyRealtimeSession` |
| `ski` (`claude-haiku-4-5`) | `.anthropic` | `AnthropicLLMAdapter` | in practice the SKI branch returns `""` before dispatch and the CLI agent answers through the file bridge |
| `mirage-peekyFree` (`mirage/claude-fable-5`) | `.peekyFree` | `MirageLLMAdapter` | `analyzeMirageResponse` → `MirageBackendClient` (aegis-proxy) |

---

## Stage 7 — TTS

### Provider surface

`OpenClickyTTSProvider` (`ElevenLabsTTSClient.swift:1804-1829`):
`openai_realtime`, `elevenlabs`, `cartesia`, `deepgram`, `microsoft_edge`,
`mirage_cartesia` (free-tier Cartesia through the same aegis-proxy mint
endpoint, wire-identical to `.cartesia`, `:1810-1814`).

`protocol OpenClickyTTSClient` (`:1251-1263`): `voiceID`, `isPlaying`,
`updateConfiguration(apiKey:voiceID:)`, `warmUpConnection()`,
`speakText(_:waitUntilFinished:onPlaybackStarted:)`,
**`beginStreamingResponse(onPlaybackStarted:) -> StreamingTTSSession`**,
`fetchSentenceSamples(_:) -> [Int16]`, `stopPlayback()`,
`cancelBidirectionalVoiceTurn()` (default no-op, `:1269`).

Stream format is 22.05 kHz mono for both ElevenLabs
(`streamSampleRate = 22_050`, `streamOutputFormatQueryValue = "pcm_22050"`,
`:45-46`) and Cartesia (`CartesiaTTSClient.swift:39`).

### `StreamingTTSSession` — sentence pipelining

`ElevenLabsTTSClient.swift:511-1010`. Provider-agnostic: it owns **no
networking**, only a `fetchSamples: @Sendable (String) async throws -> [Int16]`
closure supplied at construction (`:519-523`). Both ElevenLabs and Cartesia hand
it one.

Flow: `appendText(delta)` (`:576-581`) accumulates into `pendingText` and calls
`flushCompleteSentences()`; each detected sentence is `enqueueSentence`d.
Fetches run **in parallel**, but playback is serialized through a `jobChain`
task where each sentence awaits the previous before scheduling its buffers
(`:531-535`) — so audio stays in spoken order.

`finish()` (`:585-611`) flushes the unterminated tail, awaits the chain, then
`maybeStartBufferedPlaybackIfReady(force: true)` and
`waitForPlaybackToDrain`. `cancel()` (`:615-621`) flips `isCancelled`, cancels
the chain, and makes further `appendText` calls no-ops.

### Sentence-cut logic (`nextSentenceCut`, `:756-860`)

Constants:

| Constant | Value | Line |
|---|---|---|
| `minimumBufferedSecondsBeforePlayback` | **0.25 s** | `:545` |
| `preResponseFillerDelayMilliseconds` | **400 ms** | `:549` |
| `minimumWordsPerSentence` | **4** | `:552` |
| `maxWordsPerTTSChunk` | **32** | `:625` |
| `minimumWordsBeforePauseCut` | **15** | `:629` |
| `knownAbbreviations` | `mr, mrs, ms, dr, jr, sr, st, vs, etc, eg, ie` | `:553-555` |

Only 0.25 s of PCM is buffered before speech starts — comment at `:541-544`:
"the voice path is supposed to start speaking as soon as the first sentence is
synthesised, not wait for most of the model response."

Cut rules, in evaluation order inside the scan:
1. **Comma-like pause cut** — `,` `:` `;` (plus full-width CJK equivalents) once `wordCount >= minimumWordsBeforePauseCut (15)`. Lets long sentences start speaking without chopping short asides.
2. **Hard word-count cut** — at `wordCount >= maxWordsPerTTSChunk (32)` on the next whitespace. Explicitly "a last-resort safety cut, deliberately later than the natural comma threshold."
3. **Terminator cut** — `.` `!` `?` `\n` `。` `！` `？`. Requires `wordCount >= 4` unless the terminator is a newline (explicit breaks always cut). Abbreviation rejection applies only to `.` and only against `knownAbbreviations`. Requires the following char to be whitespace/newline — **except** when the terminator is the last char of the current delta, in which case it cuts immediately (`:~836-846`) so the TTS request can start before `response.done`.

Post-cut, if a sentence exceeds 32 words it is fed to
`splitLongSentenceIntoClauses` (`:672-728`), which breaks on `,` `:` `;`
` — ` ` -- ` and then hard-splits any remaining clause on word boundaries so no
single TTS request is multi-paragraph.

`wordCount` (`:651-665`) is CJK-aware: it counts CJK/kana scalars separately and
uses that count when `cjk >= 3` and it exceeds the space-split count — otherwise
Chinese text would look like one word and never cut.

`testChunksForStreaming` (`:730-754`) exposes the whole chunker for tests.

### `FillerPhraseLibrary` (`:1012-1200+`)

Pre-renders and disk-caches short openers so latency cover does not itself cost
latency (`:1026-1028`). Defaults (`:1029-1036`): `"one moment."`,
`"give me a second."`, `"checking now."`, `"let me check."`,
`"working on that."`.

`prepare(client:)` (`:1048-1090`) loads cached PCM synchronously (~80 KB/file),
then fetches missing phrases in a background `TaskGroup`; re-running with a
changed `voiceID` re-fetches.

`randomFiller()` (`:1099-1101`) avoids repeating the last phrase.
`contextualFiller(for:screenContextNeeded:)` (`:1105-1150+`) picks a phrase that
matches the turn: screen-context or "look at" / "take a look" →
checking-flavored; "do we" / "should we" / "does that" / "is that" →
deliberating-flavored.

Critically, `FillerSelection` returns **phrase text alongside samples**
(`:1092-1095`) so the LLM can be told which opener was spoken — the comment at
`:1096-1098` explains this binds the model's reply to the filler ("let me check"
→ the reply continues from a checking posture instead of restarting). The filler
is delayed 400 ms rather than firing instantly so it reads as a thinking beat
(`:546-549`).

### Playback plumbing — `TTSStreamingPlaybackEngine`

`TTSStreamingPlaybackEngine.swift`, a stateless `@MainActor enum` shared by all
five streaming clients (`:5-9`).

- `makeStreamFormat(sampleRate:)` (`:17-24`) — Float32, mono, non-interleaved.
- `scheduleSamples(_:on:format:startPlaybackIfNeeded:)` (`:26-65`) — Int16 → Float32 with `scale = (1/32768) * AppBundleConfiguration.voicePlaybackVolume()` (`:41`). Two hard guards documented from crashes: `player.engine` is weak, so calling `play()` on an engineless node throws `_engine != nil` and kills the process (`:46-53`); and if the engine is not running the buffer is **dropped rather than restarting mid-stream**, because restarting AVAudioEngine with queued samples causes audible skipping (`:54-59`).
- `waitForPlaybackToDrain(_:scheduledFrameCount:sampleRate:)` (`:67-100`) — polls `renderedSampleTime` at 80 ms, with a wall-clock deadline of `max(expectedDuration + 3.0, 3.0)`. The comment at `:77-82` notes `isPlaying` keeps reporting true after buffers drain, and that stopping on an unchanged/nil rendered-frame value clipped Cartesia/Deepgram playback when their players started before buffers were queued.

### Barge-in / interruption

`CompanionManager.interruptCurrentVoiceResponse()`
(`CompanionManager.swift:17843-17890`). Called from every path that opens the
mic: PTT press (`:6803`, `:6774`), wake-word dictation start (`:7180`), and ESC.
It tears down, in order:

1. `AssistAgentBridge.shared.cancelActive()` (`:17847`) — kills a live multi-round research loop so the user does not sit through work they have pivoted away from.
2. `currentVoiceResponseCancellationHandler?("interrupted")` and clears the request ID / completion token (`:17848-17851`).
3. `currentResponseTask?.cancel()` and `realtimeBidirectionalVoiceTask?.cancel()`; bumps `realtimeBidirectionalVoiceTurnGeneration` (`:17852-17857`) so late callbacks from the old turn are rejected.
4. `codexVoiceSession.cancelActiveTurn(reason: "voice_response_interrupted")` (`:17861`).
5. `cancelBidirectionalVoiceTurn()` then `stopPlayback()` on all three audio-owning clients — `openAIRealtimeSpeechClient`, `deepgramVoiceAgentClient`, `voiceTTSClient` (`:17862-17866`).
6. Clears queued **system announcements** (`pendingSystemAnnouncementSessionID` / `speakingSystemAnnouncementSessionID`, `:17867-17878`) — the comment records that without this, `speakSystemAnnouncementAfterCurrentTTS` would re-fire TTS right after an ESC or PTT barge-in.
7. Returns `voiceState` to `.idle` when no dictation is in progress (`:17879-17882`).

The HeyClicky realtime lane has its own barge-in inside
`beginPushToTalk` (`HeyClickyRealtime/HeyClickyRealtimeSession.swift:213-220`):
it keys off `isResponding || currentAssistantItemId != nil ||
playedAssistantAudioMs > 0` rather than `isResponding` alone, because playback
can still be flushing after the flag clears. It calls
`interruptCurrentResponse()` + `audioEngine.stopPlayback()` and resets both
trackers. The outer `CompanionManager` still calls
`interruptCurrentVoiceResponse()` separately (`:6777`) because a
`voiceTTSClient` announcement runs on a different transport that the session's
own barge-in cannot reach — the comment at `:6767-6776` cites the user report
"按快捷键说话时它也在说话".

### Per-profile TTS

| Profile | Provider | Path |
|---|---|---|
| `heyclickyFree` | `openAIRealtime` | audio deltas arrive on the same WS as the reply; `audioEngine.schedulePlayback(pcm16:)` (`HeyClickyRealtimeSession.swift:584`). No `StreamingTTSSession`, no sentence cutting — the model emits audio directly. |
| `ski` | `microsoftEdge` | `MicrosoftEdgeTTSClient` through `StreamingTTSSession`; muted when `openclicky.ski.replyMuted` is set by Ctrl+Shift+V (`SKIModeHotkeyKeys.isSilent`) |
| `mirage-peekyFree` | `mirageCartesia` | `CartesiaTTSClient` wire, aegis-proxy token, 22.05 kHz, through `StreamingTTSSession` |

---

## Stage 8 — Agent spawn

Two independent agent backends. They share the dock/bubble UI but nothing else.

### A. Codex — `CodexAgentSession` + `CodexProcessManager`

`CodexAgentSession.swift` (3717 lines) is the long-lived per-agent object;
`CodexProcessManager.swift` owns the subprocess.

Spawn (`CodexProcessManager.start(executableURL:codexHome:taskDir:taskProgressPath:)`,
`:21-60`):

```
codex app-server --listen stdio://
     -c approval_policy="never"
     -c sandbox_mode="workspace-write"
```

The seed sandbox is deliberately the *confined* one (`:38-46`): per-turn
`turn/start` params override it — Agent Mode requests `danger-full-access` where
the user asked for full power, the voice point-detector requests
`workspace-write` — so a future caller that forgets to set a sandbox gets the
confined default rather than the whole volume.

Environment carries the OpenClicky task-planning contract
(`docs/OPENCLICKY_TASK_SPEC.md`, `:60-75`): `$OPENCLICKY_TASK_DIR` and
`$OPENCLICKY_TASK_PROGRESS` are injected at spawn so codex can glob the task dir
and drive `LAST_COMPLETED: DONE`. `AGENTS-longrun-template.md` references those
env names verbatim.

Transport is line-delimited JSON-RPC over stdio with a pending-request map;
process exit fails all pending requests with "Codex app-server exited with
status N" (`:142`). There is also a one-shot `codex exec` path separate from the
persistent app-server (`:249-266`).

Turn lifecycle in the session: `submitPromptFromUI(_:screenContext:)` (`:771`)
→ `startPromptTurn(_:screenContext:)` (`:996`). The latter bumps
`runGeneration` first (`:999-1002`) — the comment notes a prompt can spend
minutes waiting on a file lease, so any prior preflight must be invalidated or
an older task could wake later and start a stale turn. `stop(reason:)` at
`:1149`. There is also a SKI-bridge submission path
(`submitPromptViaSKIBridge`, `:304`).

A watchdog in `CompanionManager` kills a stalled turn:
`heyClickyObserverStore.recordProgressAndCheckTimeout` →
`session.stop(reason: "turn_watchdog_timeout")`
(`CompanionManager.swift:5281-5288`).

### B. Claude Code — `ClaudeAgentRunner`

`ClaudeAgentRunner.swift`, an `actor`, **one instance per turn, disposed on
completion** (`:68-70`). Only caller is `MiragePeekyOrchestrator.swift:573`.

Concept (`:5-11`): "OpenClicky agent = Claude Code + local CPA" — spawn the real
`claude` CLI so you get its actual agentic loop (planning, sub-agents, tool
use), then swap the transport underneath so traffic terminates at aegis-proxy
free-tier Claude instead of Anthropic's paid endpoint.

Five-step flow (`:12-22`):
1. Locate the `claude` binary from a fixed candidate list — GUI-launched apps do not inherit the shell PATH.
2. Start `MirageLocalRelay` on a loopback port.
3. Spawn the process.
4. Parse `stream-json` line-by-line into `MirageAgentEvent(type:raw:)` (`:57-65`).
5. On barge-in cancel: kill process, stop relay.

Environment (`:526-545`) starts from an **empty dict**, not
`ProcessInfo.processInfo.environment`, specifically so the parent app's
`ANTHROPIC_*` / `HTTP_PROXY` do not leak into claude. Set explicitly: `PATH`,
`HOME`, `SHELL`, `LANG`, `TERM`, `ANTHROPIC_BASE_URL` (the relay),
`ANTHROPIC_API_KEY = "sk-mirage-relay-dummy"` (any non-empty value satisfies the
CLI's check; the relay injects the real mirage UUID),
`CLAUDE_CODE_DISABLE_TELEMETRY=1`, `DISABLE_AUTOUPDATER=1`, and
`CLAUDE_CONFIG_DIR` pointing at a freshly materialized scratch home with the
resolved model + effort baked into its `settings.json` (`:588-604`).

Arguments (`:605-621`):

```
claude -p <prompt> --output-format stream-json --verbose --model <effectiveModel>
       [--append-system-prompt-file ~/.claude/override.md]
```

`override.md` is probed at **spawn time** so a user edit between turns takes
effect immediately (`:612-616`).

Model resolution (`:550-580`), highest precedence first: caller-passed `model:`
→ `openClickyMirageAgentModel` UserDefault → `mirage/claude-opus-5`. The
`mirage/` prefix is stripped before handing it to the CLI — that namespace is
OpenClicky's catalog only. `[1m]` is appended when
`openClickyMirageAgentUse1MContext` is set (default true for Opus family) and
the model supports it (`:299-310`); the relay strips the prefix so upstream sees
`claude-opus-5[1m]` (`:271-282`, `:368-380`). Effort follows the same
caller > UserDefault > fallback ladder (`:581-586`).

cwd ladder (`:624-641`): explicit `workingDirectory:` → the
`openClickyMirageAgentWorkingDir` UserDefault → `~/Dev` if it exists → `~`.

stdin is `FileHandle.nullDevice` so claude never blocks waiting for input
(`:648-649`). stdout is bridged with `readabilityHandler` rather than a polling
loop, explicitly matching `CodexProcessManager.swift:165`, so events surface the
moment claude flushes (`:657-675`).

Errors are a UI-facing enum (`ClaudeAgentRunnerError`, `:28-56`):
`.claudeBinaryNotFound` carries the exact install command
(`npm install -g @anthropic-ai/claude-code`), plus `.relayStartFailed`,
`.processStartFailed`, `.processExited(Int32)`, and `.cancelled` (barge-in — "not
an error condition, but callers may want to distinguish").

### C. The dock shim — `CompanionManager+SKIShimBuilder`

`CompanionManager+SKIShimBuilder.swift` (97 lines). Peeky Free's agent turns are
driven by an external CLI, not a `CodexAgentSession`, but the dock/notch UI only
knows how to render `CodexAgentSession`. The shim bridges that gap.

`makeShimForTurn(title:userInstruction:accentTheme:initialStageLabel:) -> (shim: CodexAgentSession, dockID: UUID)`
(`:67-96`): allocates one UUID used as **both** the session id and the dock id,
constructs a `CodexAgentSession(id:title:accentTheme:)`, calls
`shim.forceVisibleForSKIShim()`, registers it via `registerSKIShimAgentSession`
so Chat / MiniChat can look it up, and upserts a `ClickyAgentDockItem` with
`status: .starting`.

`advanceMiragePeekyDock(dockID:shim:title:userInstruction:stageLabel:activityLine:dockStatus:)`
(`:35-65`): idempotent per event, safe to call rapidly. It reflects each streamed
Claude Code CLI event onto the dock bubble as `"🔧 tool_name"` / `"💭 Thinking…"`
/ `"Composing reply"` — the same visual language as real Codex bubbles — and
appends `activityLine` to the shim's rolling activity buffer rendered under the
bubble title.

Design note (`:5-19`): SKI's dock mirror does something very similar inline at
`CompanionManager+SKIModeDockMirror.swift:80-129` and could adopt this builder
once its per-session bookkeeping is refactored. They were kept separate because
SKI's version threads workspace metadata, a persistent id map, and `skiBridge`
coupling that a one-shot mirage turn does not need.

### D. SKI's own agent path — the file bridge

SKI does not spawn from the app at all. `_analyzeVoiceResponseCore` writes the
utterance + context to `.oc/events.jsonl` via
`OpenClickyFileBridge.shared.writeUtteranceAndAwait(workspace:text:context:timeoutSeconds: 0.1)`
(`CompanionManager+AIResponsePipeline.swift:~813-819`) and returns `""`. An
already-running external CLI agent (Claude Code / Codex in a terminal) tails
that file, and its reply comes back through `.oc/commands.jsonl` →
`speakSKIModeAgentReply`. The SKI Mode dock mirror renders that external agent's
state locally.

### Per-profile agent backend

| Profile | Agent backend | Spawned by |
|---|---|---|
| `heyclickyFree` | Codex app-server (`agentModelID: "heyclicky-free"`) | `RouteDispatcher.spawnCodex` via Layer 0 |
| `ski` | none in-app — external CLI over `.oc/*.jsonl` | user, outside the app |
| `mirage-peekyFree` | Claude Code CLI (`agentModelID: "mirage/claude-opus-5"`) through `MirageLocalRelay` | `MiragePeekyOrchestrator.swift:573` |

---

## Extension points

Goal: a frontend multimodal router that hears the audio, sees the screenshot,
and decides answer-self / delegate-to-LLM / spawn-agent.

### Where it slots in cleanly

**Best seam: between STT finalization and `dispatchViaLLMRegistry`.** Concretely,
inside `_analyzeVoiceResponseCore` (`CompanionManager+AIResponsePipeline.swift:667-869`)
just before the `LLMRequest` is built at `:857`, or as a new tier 0 of
`routeFinalVoiceTranscriptActionIfNeeded` (`CompanionManager.swift:7969`).

Three concrete reasons this seam works:
1. **The screenshot is already in hand.** `startPrewarmedScreenshotCaptureIfPossible()` fires at key-down (`CompanionManager.swift:6732`) and `captureAllScreensForVoiceResponseIfAvailable()` (`CompanionManager+AIResponsePipeline.swift:1363`) yields it with an 8 s freshness window. A router placed here gets the image for free with zero added latency.
2. **All three decisions already have call sites here.** answer-self → `onTextChunk(text)` + `return text`, exactly what `handleVoiceProfileSwitch` does (`:608-624`); delegate-to-LLM → fall through to `dispatchViaLLMRegistry`; spawn-agent → `RouteDispatcher.shared.spawnCodex(route:userTranscript:preflight:)` or `MiragePeekyOrchestrator`.
3. **The `""` return contract already exists.** The SKI branch returns `""` to mean "handled elsewhere, do not speak, do not fall back to Claude" (`:836-843`). A router that spawns an agent can reuse it verbatim.

**Second seam (needed for real audio): `BuddyStreamingTranscriptionSession`.**
`BuddyDictationManager` is the only place raw `AVAudioPCMBuffer` exists, and it
is discarded once forwarded (`BuddyDictationManager.swift:806-813`). Any router
that wants acoustics must tap here.

### The protocol it would need to conform to

To ride the existing dispatch machinery unchanged, the router should be an
`LLMClient` (`LLMClient.swift:~64-81`):

```swift
@MainActor
protocol LLMClient: AnyObject {
    var capabilities: LLMCapabilities { get }
    func send(_ request: LLMRequest,
              onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String
}
```

Conforming means it can be returned from `LLMClientRegistry.client(for:hooks:)`
(`LLMClientRegistry.swift:22-45`) and every existing caller works untouched. But
note the registry keys on `OpenClickyModelProvider`, so a router would need
either a new provider case or a wrapper that decorates the resolved client:

```swift
@MainActor
final class MultimodalRouterClient: LLMClient {
    var capabilities: LLMCapabilities { [.images, .audio, .tools] }  // .audio is new
    private let downstream: LLMClient      // resolved via the existing registry
    private let spawnAgent: @MainActor (RouteDecision) -> Void
    func send(_ request: LLMRequest,
              onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        switch await decide(request) {
        case .answerSelf(let text): onTextChunk(text); return text
        case .delegate:             return try await downstream.send(request, onTextChunk: onTextChunk)
        case .spawnAgent(let r):    spawnAgent(r); return ""     // "" = handled elsewhere, per the SKI contract
        }
    }
}
```

The decorator shape is preferable to a new provider case: it composes with all
six existing adapters and keeps the money rule (SDK-first, key-fallback) intact
because it delegates rather than reimplements.

Registration path if a new provider case is added instead: add to
`OpenClickyModelProvider`, add a `case` in `LLMClientRegistry` (`:22-45`), and
**add a field to `LLMDispatchHooks`** (`LLMClientAdapters.swift:29-37`) — the
comment there states this bag is "the ONLY way to add a new provider adapter."

### What has to change in `LLMRequest`

Today (`LLMClient.swift:~24-48`) it is text + images only. Minimum viable change:

```swift
struct LLMRequest {
    let model: String
    let systemPrompt: String
    let conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    let userPrompt: String
    let images: [(data: Data, label: String)]
    let assistantPrefill: String?
    let audio: LLMAudioInput?        // NEW — nil for every existing caller
}

struct LLMAudioInput: Sendable {
    let pcm16: Data                  // mono Int16, matching BuddyPCM16AudioConverter output
    let sampleRate: Int              // 16_000 on every existing STT path
    let durationSeconds: TimeInterval
    let transcript: String?          // STT text when available, nil for audio-first routing
}
```

Consequences to handle:
- **`LLMRequest` has no memberwise-init default today**, so adding a field breaks all six hook closures in `makeLLMDispatchHooks` unless `audio` gets `= nil`. Give it a default.
- **Add `LLMCapabilities.audio`** at the next free bit (`LLMClient.swift:~50-62`, bits 1<<0 … 1<<4 are taken, so 1<<5). Adapters that cannot take audio keep their current value and the router must check `downstream.capabilities.contains(.audio)` before forwarding — the file's own warning about "one adapter ignoring `assistantPrefill`" is the precedent for silent-drop drift.
- **Nothing produces `audio` today.** `BuddyDictationManager` must retain the PCM it already converts. The cheapest change: keep the converted `Data` that providers like `WhisperLocalTranscriptionSession` already accumulate (`WhisperLocalTranscriptionProvider.swift:~118-127` buffers exactly this) and surface it through a new optional on `BuddyStreamingTranscriptionSession`, e.g. `var capturedPCM16: Data? { get }` with a default `nil` so the other eight providers are unaffected.
- **The realtime lanes bypass all of this.** HeyClicky Free's default speech model never constructs an `LLMRequest` — it streams to `HeyClickyRealtimeSession` directly. A router on the `LLMRequest` seam will not see those turns. Covering them means a second hook inside `HeyClickyRealtimeSession.beginPushToTalk` / `endPushToTalk` (`:183`, `:284`).

### Cheapest place to prototype

`SileroVADTrim.speechOnly(_:)` (`SileroVADTrim.swift:41`) already receives the
complete Int16 16 kHz mono clip for the PTT path and is called on exactly one
code path. A prototype router can be invoked from the same call site with the
same buffer plus the prewarmed screenshot, with no protocol changes at all.

---

## Current gaps

Ordered roughly by how much they constrain a multimodal router.

1. **No acoustic end-of-turn detection.** Three mechanisms exist and that is all: key release, energy/probability silence hangover, and a fixed 8 s wall clock on the wake-word path. Specifically:
   - PTT (`heyclickyFree` / `ski` / `mirage` defaults) stops on key-up only (`CompanionManager.swift:6809-6847`).
   - SKI hands-free uses a fixed 2000 ms Silero silence hangover (`SKIModeHandsFreeSession.swift:60-64`) — a hard 2 s penalty on every turn, and it fires mid-sentence on any thoughtful pause.
   - Deepgram `endpointing=300` (`DeepgramStreamingTranscriptionProvider.swift:341`) is server-side energy VAD, not prosody.
   - No pitch/pause/prosody model, no semantic completion check. See `04-smart-turn-port-plan.md`.
2. **Deepgram's turn frames are parsed and thrown away.** `SpeechStarted` and `UtteranceEnd` are decoded and `print`ed with no handler (`DeepgramStreamingTranscriptionProvider.swift:205-209`). These are exactly the signals a turn detector wants, already arriving on the wire, currently free.
3. **No native audio-to-LLM path.** `LLMRequest` has `images` but no audio field (`LLMClient.swift:~24-48`). Every non-realtime provider receives a `String`. The only audio-native lane is `HeyClickyRealtimeSession`, and it bypasses `LLMRequest` entirely.
4. **The STT protocol is lossy by construction.** `BuddyStreamingTranscriptionSession` (`BuddyTranscriptionProvider.swift:75-80`) exposes only `appendAudioBuffer` / `requestFinalTranscript` / `cancel`. Nothing returns word timings, confidences, speaker turns, or the audio itself. Raw buffers are dropped immediately after forwarding (`BuddyDictationManager.swift:806-813`).
5. **The intent classifier is text-only.** `OpenClickyIntentClassifier.classify(_ text: String)` (`:219`) — a BERT embedder over WordPiece tokens. It cannot see the screenshot the app already captured, cannot hear tone, and cannot use the frontmost-app context. Five labels, one of which is a reject class.
6. **Four uncoordinated routers.** Layer 0 keyword chain (`CompanionManager.swift:7969`), routelet ONNX, the Peeky four-tier cascade, and the (now-removed) `[ROUTE]` tag. They do not share a decision record, a confidence scale, or a log line. Adding a fifth without consolidating makes the ordering harder to reason about, not easier.
7. **Layer 0 is pure keyword matching.** ~17 sequential `handleX` predicates, no model, no confidence, first-match-wins. It runs before any LLM sees the utterance, so a misfire silently steals the turn.
8. **Two divergent context assemblers.** Doc 03 calls this "the single biggest source of surprise in the subsystem": `buildSKIUtteranceContext` (`CompanionManager.swift:5783-5926`) and the inline assembly in `_analyzeVoiceResponseCore` (`:667-869`) share sources but not code, and order them differently.
9. **Sentence-cut heuristics are English-shaped.** The abbreviation list is 11 English entries (`ElevenLabsTTSClient.swift:553-555`); `minimumWordsPerSentence = 4` and `minimumWordsBeforePauseCut = 15` are word counts. `wordCount` has a CJK fallback (`:651-665`) but the thresholds themselves were not retuned for CJK.
10. **Keyterms are frozen per session.** Passed once at `startStreamingSession` (`BuddyDictationManager.swift:738`) and never updatable mid-utterance. Three providers discard them entirely; mirage keeps only the first (`MirageDeepgramTranscriptionProvider.swift:38`).
11. **Barge-in is teardown, not turn-taking.** `interruptCurrentVoiceResponse()` (`CompanionManager.swift:17843`) cancels nine subsystems and resets to `.idle`. There is no notion of "user interjected, resume where we left off" — the partial reply is discarded and the next turn starts cold.
12. **Latency is logged but never fed back.** `startupDurationMs`, `providerOpenDurationMs`, `finalizeLatencyMs`, `recordingDurationMs` all land in `OpenClickyMessageLogStore` (`BuddyDictationManager.swift:615`, `:792`, `:762`, `:927`) and nothing reads them. No adaptive timeout, no provider fallback on slowness, no budget.
13. **Batch STT fallback delays are very long.** whisper.cpp 20 s (`WhisperLocalTranscriptionProvider.swift:81`), Parakeet 12 s (`OpenClickyParakeetTranscriptionProvider.swift:214`), OpenAI 8 s (`:60`). These are watchdogs, not expected latencies, but nothing shortens them adaptively when the clip is known to be short.
14. **The Peeky cascade's tier 4 is a blocking network hop.** `claudeClassify` costs one aegis-proxy round trip at ~250-700 ms *before* the real answer starts generating, and it is reached whenever routelet confidence is under 0.85.
15. **Wake-word matching is substring-on-transcript.** Four hardcoded spellings (`OpenClickyWakeWordManager.swift:254-266`) against Apple's running partial. No confidence score, no false-accept tuning knob, and it only works where an on-device recognizer exists for the locale (`:90-92`).
