# Peeky Free (mirage) Voice-Dialog Parity Audit
Date: 2026-08-06
Scope: (a) PTT capture, (b) STT, (c) screenshot + resize, (d) LLM + system prompt + history, (e) sentence-pipelined TTS + captions, (f) transcript persistence, (g) notch/dock voice state.

Compared against: HeyClicky Free (`.heyclickyFree`) and SKI (`ski_mode`) branches inside `analyzeVoiceResponse` / `_analyzeVoiceResponseCore`, plus Peeky Rust reference at `/private/tmp/Peeky/peeky/src/orchestrator.rs`.

---

## Parity Verified

1. **Push-to-talk mic capture, STT bootstrap.** Mirage does not fork the PTT tap; it flows into the same `executeVoiceRequest` shell as SKI/HeyClicky. `MirageDeepgramClient` is warmed on the same lifecycle hooks (`cursor-buddy/CompanionManager.swift:2175, 2679`) and adapted through the shared `BuddyTranscriptionProvider` interface via `cursor-buddy/MirageDeepgramTranscriptionProvider.swift:39-72` — no divergence from the SKI/HeyClicky STT contract.

2. **Screenshot capture + 1280 resize.** Both mirage and SKI/HeyClicky pull frames through `captureAllScreensForVoiceResponseIfAvailable`, which delegates to `CompanionScreenCaptureUtility`. The 1280 max-dimension resize lives in `cursor-buddy/CompanionScreenCaptureUtility.swift:168-175` and `:261-270` (single source). Mirage explicitly comments this at `cursor-buddy/CompanionManager+AIResponsePipeline.swift:2529-2532`. Coordinate mapping is preserved because the same `screenshotWidthInPixels` / `displayWidthInPoints` fields on `CompanionScreenCapture` are populated identically for all lanes (see `cursor-buddy/CompanionManager+AIResponsePipeline.swift:2235-2261`). Mirage also forces screen attach unconditionally for parity with Peeky's `chat.rs` assumption (`cursor-buddy/CompanionManager+AIResponsePipeline.swift:1798-1802`).

3. **Context brief.** `buildMirageContextBrief` (`cursor-buddy/CompanionManager+AIResponsePipeline.swift:2864-2894`) reuses `buildSKIUtteranceContext` (`cursor-buddy/CompanionManager.swift:5726`) verbatim; every SKI signal (focused_window / everywhere / ltm / xlb / stash / openrewind / clipboard / MCP endpoint) is rendered identically as a plain-text block appended to the orchestrator system prompt.

4. **Transcript persistence.** Mirage calls the shared `rememberVoiceExchange` (`cursor-buddy/CompanionManager+AIResponsePipeline.swift:2754-2758`) — same code path SKI/HeyClicky use (`cursor-buddy/CompanionManager.swift:5597, 7545`). Mirage also mirrors into `codexAgentSession.appendRemoteTranscriptEntry` (`:2770-2781`) which is the conversation-sidebar hook HeyClicky uses (see comment referencing `CompanionManager+HeyClicky.swift:1482`).

5. **CJK sentence cut in `StreamingTTSSession`.** ElevenLabs' `nextSentenceCut` handles CJK terminators `。！？` and CJK clause markers `，、：；` explicitly (`cursor-buddy/ElevenLabsTTSClient.swift:770-805`). Cartesia does not implement its own sentence cutter — it shares the same `StreamingTTSSession` class (see `beginStreamingResponse` at `cursor-buddy/CartesiaTTSClient.swift:229-274`), so CJK handling is inherited automatically. This is stricter than Peeky's Rust `find_sentence_end` (`/private/tmp/Peeky/peeky/src/orchestrator.rs:969-979`), which only matches ASCII `.!?` — Swift is a strict superset. No regression risk.

6. **Caption stream to response card.** Mirage's orchestrator relays every `text_delta` back through the caller's `onTextChunk` (`cursor-buddy/MiragePeekyOrchestrator.swift:92, 112, 133, 601, 636, 701`), and `analyzeMirageResponse` hops each chunk to the MainActor at `cursor-buddy/CompanionManager+AIResponsePipeline.swift:2647-2654`. The outer `executeVoiceRequest` closure at `:2089-2114` therefore calls the same `self.updateVoiceResponseCaption(displayed)` and rebuilds `latestVoiceResponseCard` in the exact same code path SKI/HeyClicky exercise.

---

## Gaps

### G1. Double pre-response filler on Cartesia
`analyzeMirageResponse` fires its own `speakFillerIsolated(mirageFillerPhrase())` at `cursor-buddy/CompanionManager+AIResponsePipeline.swift:2583-2591`. However, the outer path has already evaluated `shouldUsePreResponseFiller` at `:1975` and — for a mirage turn (multi-word, screen context, provider `.peekyFree`, TTS `.mirageCartesia`) — will also enqueue a pre-baked filler via `streamingTTSSession.enqueuePrebakedSamples(chosenFiller.samples)` at `:2047`. The user hears two openers back-to-back ("让我看看" then a second cached phrase). SKI and HeyClicky rely on the outer path alone.

### G2. ElevenLabs has no `speakFillerIsolated`
`speakFillerIsolated` exists only on `CartesiaTTSClient` (`cursor-buddy/CartesiaTTSClient.swift:284`). If the user has mirage voice model + ElevenLabs TTS, the mirage-lane filler is silently skipped (`:2588` `as? CartesiaTTSClient` returns nil). Not catastrophic — outer pipeline still fills — but the mirage lane's stated "instant opener while fable-5 spools" behavior is Cartesia-only.

### G3. Heartbeat overwrites `voiceState` on a 1s timer
The heartbeatTask (`cursor-buddy/CompanionManager+AIResponsePipeline.swift:2599-2624`) force-writes `voiceState = .processing / .responding` every second to counter the filler's audio-done callback flipping state to `.idle`. SKI/HeyClicky don't need this because they don't run a second isolated filler engine. Removing G1 also removes the need for the heartbeat state-write; the heartbeat's caption update alone would suffice.

### G4. No `.transcribing` / `.thinking` states in `CompanionVoiceState`
The enum only carries `idle / listening / processing / responding` (`cursor-buddy/CompanionManager.swift:26-31`). All four lanes (SKI, HeyClicky, mirage, Codex) collapse "transcribing" and "thinking" onto `.processing`. This is a shared limitation, not a mirage-specific regression, but worth flagging: the review criteria named five states — the codebase only exposes four.

### G5. Cartesia body hardcodes `"language": "en"`
`cursor-buddy/CartesiaTTSClient.swift:443` pins the request language to English. CJK / ES / FR turns still speak (Sonic Turbo phoneme-transliterates), but pronunciation quality is degraded vs. per-turn language detection. Peeky's Rust `tts_cartesia.rs` has the same pin — mirage matches reference, not a regression, but a shared gap.

### G6. Mirage caption isn't cleared on cancel
`heartbeatTask` cancels in `defer` (`:2625-2628`), but the final "Intent · <intent>" caption written at `:2724` sticks. SKI wires an explicit `scheduleTransientHideIfNeeded()` on completion (`:2502-2504`); mirage doesn't. Cosmetic.

---

## Suggested Fix

1. **Gate the mirage-lane filler behind `shouldUsePreResponseFiller` + provider check.** In `analyzeMirageResponse` around `:2583`, only fire `speakFillerIsolated` when the outer path decided NOT to run a cached filler (i.e., when `chosenFiller` is nil). Cleanest: hoist the filler decision up to `executeVoiceRequest` and let mirage subscribe to a single "opener already played" signal.

2. **Port `speakFillerIsolated` to `ElevenLabsTTSClient`** using the same isolated-engine pattern (`cursor-buddy/CartesiaTTSClient.swift:284-342`). Small copy; unblocks the "instant opener" claim for the second TTS provider.

3. **Drop the 1s `voiceState` re-assert loop** once G1 is fixed. Keep the elapsed-time caption update, but do not touch `voiceState` from the heartbeat — the outer executor already owns state.

4. **Add `.transcribing` and `.thinking` to `CompanionVoiceState`** (`cursor-buddy/CompanionManager.swift:26-31`) if the UI wants distinct notch phases. Backfill call sites in SKI + HeyClicky + mirage; keep `.processing` as fallback.

5. **Call `scheduleTransientHideIfNeeded()` at the mirage completion tail** (after `:2742`) so the intent caption fades the same way SKI's does.

6. **Optional (matches Peeky spec exactly):** in `CartesiaTTSClient.makeRequest` (`:434-446`), detect script from the transcript and set `"language"` accordingly. Peeky reference does not do this, so it's a stretch goal, not parity.
