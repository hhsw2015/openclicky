# SKI Mode Integration Design

Design for a new `.skiMode` voice profile alongside the ship-default
HeyClicky Free Realtime lane. Companion to
`docs/SKI_REVERSE_ENGINEERING.md` and
`docs/OPENCLICKY_VOICE_PIPELINE.md` — read those first.

Overriding constraint: SKI Mode users must not feel a latency cliff.
HeyClicky Free's single-socket S2S starts speaking ~350-700 ms after
end-of-speech; a naive decomposed pipeline (Whisper -> CLI tool loop ->
TTS) can go silent 5-30 s while the agent chases `tool_use` rounds.
The **immediate-ack + async-result** pattern (SKI's own `SKILL.md`
rule) closes the gap and is enforced in `AssistAgentPrompt`.

---

## 0. Two profiles, two personalities

Both profiles co-exist. Users pick per-task; the design makes switching
frictionless.

**HeyClicky Free profile** (current default):
- Best for: short conversational turns, quick UI questions, "point at
  that button", one-shot code lookups, single-sentence facts.
- Backing agent: `/chat-tool-call` — a lightweight assist-agent, NOT a
  real long-horizon agent. Multi-round tool loop hard-capped at 50
  rounds (`AssistAgent/AssistAgentLoop.swift`); server-side session
  state; schema-tuned outputs (walkthrough, point, typing, widgets per
  `HeyClickyTypes.swift`).
- Strengths: 350-700 ms first-audio (per `OPENCLICKY_VOICE_PIPELINE.md`), prosody, barge-in, audio-native
  output, rich UI side effects (walkthrough beats, screen highlights,
  typing at cursor).
- Weaknesses: shallow reasoning depth; no true long context; cannot
  dispatch subagents; can't run for minutes on a complex task.

**SKI Mode profile** (new):
- Best for: multi-round tool-heavy work, complex refactors, "read this
  whole file and rewrite X", codebase-wide investigations, tasks that
  run for minutes.
- Backing agent: the user's own CLI (Claude Code / Codex / Cursor /
  Gemini) — a real long-horizon agent with 200k+ context, unbounded
  tool loop, subagent dispatch, MCP native support, full
  bash+edit+read+write.
- Strengths: reasoning depth, transparency (user sees CLI activity in
  their own terminal and in OpenClicky's Agent Dashboard), zero quota
  burn, offline STT, per-layer swap.
- Weaknesses: ~1.3-2 s worse first-audio P50 (2.0-2.7 s vs 350-700 ms;
  see §4), monotone TTS, no walkthrough / point / typing / widget side
  effects (until SKILL.md v2), no audio-native non-verbal cues, no
  streaming audio during generation, PTT-only until Phase 4. See §4.5
  for the full regression list.

Thesis reframe: SKI Mode is **better on complex work, deliberately
worse on quick-glance turns**. Users pick per session; the design
does not push them one way.

**Switching UX**:
- One-click toggle in the voice bubble / notch — the provider chip in
  `OpenClickyVoiceBackendSelector` grows a profile chip alongside.
- Global default in Settings ("Voice mode: HeyClicky Free / SKI Mode /
  Ask each turn"), stored under `openclicky.voice.profile`.
- Agent Dashboard (`CodexHUDWindowManager`) becomes the unified
  inspection + control point: HeyClicky rounds and CLI-agent activity
  both stream into the same panel.

**Positioning statement.**

> HeyClicky Free is the "quick assistant" — instant, expressive,
> always available for one-shot help. SKI Mode is the "power agent" —
> you delegate a real task to your own CLI, and you're willing to
> wait a second for the real thing. Neither replaces the other; they
> cover different jobs.

---

## 1. Profile shape

Add `OpenClickyVoiceProfile` (nonisolated enum) alongside the existing
`OpenClickyProfile` bundle in
`cursor-buddy/AppBundleConfiguration.swift`:

- `.default` — current behaviour (Realtime WS or decomposed fallback per
  `CompanionManager.shouldRoutePTTToHeyClickyRealtimeSession`,
  `CompanionManager.swift:6024`).
- `.skiMode` — Whisper STT + file-bridge LLM + local/cloud TTS.

UserDefaults key: `openclicky.voice.profile` (default `"default"`).
Read once at app boot, cached on `CompanionManager`; re-applied on
`UserDefaults.didChangeNotification`. Distinct from
`OpenClickyProfileCatalog.activeProfileDefaultsKey =
"openClickyActiveProfileID"` (`OpenClickyProfile.swift:41`) — profiles
tune a matrix of providers; this profile flips the whole pipeline
topology.

Settings UI: new **Voice Profile** section at the top of
`AdvancedProvidersPanelView` (`OpenClickySettingsWindowManager.swift:3913`),
above the existing STT/TTS grid. Two radio rows:

1. Default (HeyClicky Free Realtime) — shows current one-pill collapse.
2. SKI Mode (Local-first decomposed) — expands into
   Whisper/Bridge/TTS sub-rows.

Menu-bar affordance: extend `OpenClickyVoiceBackendSelector`
(`cursor-buddy/OpenClickyVoiceBackendSelector.swift`) with a
"SKI Mode" chip alongside Apple / Codex / Claude, tied to
`OpenClickyProviderDiscovery` (green dot when Whisper weights present
AND at least one CLI agent detected).

---

## 2. SKI Mode component stack

### STT — whisper.cpp large-v3-turbo

- Model: `ggml-large-v3-turbo-q5_0.bin` (~547 MB, multilingual, Metal).
- URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin`
- Storage: `~/Library/Application Support/OpenClicky/models/ggml-large-v3-turbo-q5_0.bin`
  (same layout convention as the Parakeet cache managed by
  `OpenClickyLocalSpeechModelManager`,
  `cursor-buddy/OpenClickyLocalSpeechModelManager.swift`).
- Runtime: OpenClicky currently has **no** whisper.cpp integration —
  hits for "whisper" across `cursor-buddy/*.swift` are labels only; the
  `.openAI` STT case in `OpenAIAudioTranscriptionProvider.swift` uses
  the hosted `whisper-1` HTTP endpoint. We add
  `WhisperCppSTTProvider` wrapping `whisper.cpp` through a small
  C-Swift bridge (either link `whisper.cpp` as a Swift package target
  with `WHISPER_METAL=1`, or vendor `whisper-cli` as a helper binary in
  `AppResources/OpenClicky/OpenCLIRuntime/` and pipe PCM in). SKI itself
  uses `whisper-rs-sys` (Rust FFI, build id `aceeee97ef8ba6f3` per
  `SKI_REVERSE_ENGINEERING.md` §STT); we mirror the same Metal build
  flags.
- Provider enum: add
  `BuddyTranscriptionProviderID.whisperLarge = "whisper_large"`
  (`cursor-buddy/BuddyTranscriptionProvider.swift:11`). Available on all
  profiles — in SKI Mode it becomes the default; in Default profile the
  user can still pick it manually.

### VAD — Silero VAD ONNX (Phase 3, optional)

- Model: `silero_vad.onnx` (~2.3 MB, v4-era per SKI).
- URL: `https://huggingface.co/snakers4/silero-vad/resolve/main/files/silero_vad.onnx`
- Threshold `0.3`, hangover `2000 ms` (matches SKI defaults from
  `src/audio/vad.rs`, `SKI_REVERSE_ENGINEERING.md` §Audio/VAD). Runs on
  a 16 kHz mono stream via ONNX Runtime Swift or a CoreML conversion.
- Until Phase 3 ships, keep PTT half-duplex — the hotkey release still
  drives finalization exactly like today
  (`BuddyDictationManager.swift:806`).

### LLM — File bridge to user's CLI

- Writer path: `<workspace>/.oc/events.jsonl` — append `session.started`,
  `utterance.final`, `screen.captured`, `screen.capture_failed`,
  `tts.done`, `tts.interrupted`, `summarize`.
- Reader path: `<workspace>/.oc/commands.jsonl` — tail for
  `tts.speak`, `tts.cancel`, `voice.set`, `screen.capture`,
  `agent.heartbeat`, `summary.ready`, `summary.failed`. Schema is a
  drop-in of SKI's per-project protocol (`SKI_REVERSE_ENGINEERING.md`
  §D). Rationale: users already running SKI's `SKILL.md` in Claude Code
  or Codex can point it at `.oc/` and it Just Works.
- Presence UDS: `~/.openclicky/agents.sock` (mirrors SKI's
  `~/.ski/agents.sock`). New `OpenClickyAgentsSocketServer.swift`,
  `AF_UNIX` non-blocking listener, hello schema below (§6).
- Project resolution: focused frontmost window -> its file path (via
  `AssistAgentActiveWindow.capture()` used already in
  `CompanionManager+AIResponsePipeline.swift:_analyzeVoiceResponseCore`
  step 4) -> git-root walk (`git rev-parse --show-toplevel`) -> that's
  the workspace. Cached per bundle-id.
- Implementation: `cursor-buddy/OpenClickyFileBridge.swift` (new)
  is a `Sendable` actor with `writeEvent(_:)` + `tailCommands(project:)`
  AsyncStream. `CompanionManager` gets a `fileBridge` field that lifts
  the finalized transcript into `utterance.final` when
  `voiceProfile == .skiMode`, short-circuiting the provider switch in
  `CompanionManager+AIResponsePipeline.swift:_analyzeVoiceResponseCore`
  step 6 (the response pipeline awaits `tts.speak` lines instead of
  calling Claude/OpenAI).

### TTS — dual option

- **Cloud (default in SKI Mode when `voiceResponseLanguage == "zh"`):**
  reuse `OpenAIRealtimeSpeechClient.speakText(...)` (mode 2 in
  `OPENCLICKY_VOICE_PIPELINE.md` §C). Text in, 24 kHz PCM16 out over the
  existing WS. Voice from `openClickyOpenAIRealtimeVoiceID` (default
  `cedar`). This path already accepts assistant text produced by
  non-Realtime LLMs — SKI Mode is just another caller.
- **Local (English default):** Kokoro-en ONNX
  (`resources/kokoro/models/model_quantized.onnx`, 88.1 MB, 24 kHz
  mono f32) driven through ONNX Runtime Swift. Voice files
  (`af_heart`, `am_adam`, `bf_emma`, `bm_george`) are 522,240-byte raw
  f32 tensors, load direct via `Data -> [Float]`. G2P: shell out to
  `espeak-ng` if present on PATH (SKI does not bundle it and neither
  will we — the fallback path is degraded readable-ASCII). Plug into
  `TTSStreamingPlaybackEngine` as a 6th client alongside ElevenLabs /
  Cartesia / Aura / Realtime / Edge (`CartesiaTTSClient.swift:216`
  streaming entry `beginStreamingResponse` shows the exact interface:
  `makeStreamFormat` -> `scheduleSamples` ->
  `waitForPlaybackToDrain`). Kokoro is utterance-scoped per SKI
  (`SKI_REVERSE_ENGINEERING.md` §F), so we chunk on sentence boundaries
  and pipeline into the same session.

Non-goal: Kokoro Chinese. Not available upstream; zh routes to
Realtime TTS only.

---

## 2.5. Context enrichment (parity with HeyClicky Free)

The current HeyClicky Free path injects rich context — LTM, screen
stash, xlb hints, screenshots, focused-window info — directly into the
LLM's `userPrompt` at `_analyzeVoiceResponseCore`
(`CompanionManager+AIResponsePipeline.swift` step 4). In SKI Mode the
CLI agent IS the LLM, so we can't do that at prompt-build time — we
push context through the file bridge instead.

### 2.5.a Extended `events.jsonl` schema

Extend SKI's `utterance.final` event with an OpenClicky-specific
`context` object. SKI's own loop ignores unknown fields
(`SKI_REVERSE_ENGINEERING.md` §D — untagged Serde skip), so the payload
stays forward-compatible with anyone re-using SKI's raw SKILL.md:

```json
{
  "event": "utterance.final",
  "session_id": "...",
  "text": "这个 bug 怎么回事",
  "screenshots": ["/tmp/oc-screenshots/abc.png"],
  "context": {
    "focused_window": "Cursor - main.swift",
    "stash": "<compact recent-screen OCR markdown, last 60s, ~500 tokens>",
    "xlb_suggested_topics": [
      {"name": "Vibe Coding", "browse_cmd": ">Vibe Coding/"},
      {"name": "AI Model", "browse_cmd": ">AI Model/"}
    ],
    "openclicky_mcp_url": "http://127.0.0.1:32123/mcp/sensor",
    "openclicky_mcp_token": "<bridge token from AppBundleConfiguration>"
  },
  "ts": 1234567890.0
}
```

Field sources:

- `focused_window` — existing focus tracker via
  `AssistAgentActiveWindow.capture()`.
- `stash` — output of `OpenClickyContextStashWriter` (already assembled
  today for the HeyClicky lane; `currentStashContextForVoicePrompt()`
  is where we re-tap it — see `OPENCLICKY_VOICE_PIPELINE.md` §C step 4).
- `xlb_suggested_topics` — `XLBTopicIndex.shared.fuzzyLookup(transcript,
  limit: 5)` when `openClickyXLBEnabled` is true.
- `openclicky_mcp_url` — loopback bridge from
  `OpenClickyExternalControlBridge.swift` (port `32123`, env override
  `OPENCLICKY_MCP_PORT`).
- `openclicky_mcp_token` — bearer from
  `openClickyExternalControlBridgeToken`.

### 2.5.b Hybrid strategy

SKILL.md tells the agent to consume `stash`, `focused_window`, and
`screenshots` inline; and to hit `openclicky_mcp_url` on demand for
deeper needs — `xlb_*` tools when the turn touches a suggested topic,
`openrewind.*` for LTM beyond the stash window,
`openclicky.screenshot_take` for a fresh capture,
`openclicky.focused_window_probe` for the AX tree. The bridge
(`OpenClickyExternalControlBridge.swift`) already exposes ~130 sensor
tools per `OPENCLICKY_VOICE_PIPELINE.md` §G, same bearer.

### 2.5.c Token budget

`stash` ≤ 500 tokens; `xlb_suggested_topics` ≤ 5 entries; screenshots
are absolute paths only; total `context` object ≤ 3 KB per event.
Anything larger stays behind the MCP tool wall.

### 2.5.d Writer

`OpenClickyFileBridge.swift` composes `context` via parallel `async
let` fetch (focused-window, stash, xlb fuzzy, sensor URL/token). Merge,
JSON-encode, append one line with `O_APPEND`. Added latency target
< 10 ms; any source over a 5 ms budget is omitted silently — never
fail the utterance. The immediate-ack rule stays pinned above the
context block in SKILL.md so agents don't delay ack to inspect context.

---

## 3. UX parity — immediate-ack + async-result (CRITICAL)

This is the reason SKI Mode is viable. Without it, decomposed feels
broken because the CLI agent goes silent while running tools.

**Prompt-side.** The CLI runs SKILL.md (§7); its top rule mirrors
SKI's "first acknowledge" clause. `AssistAgentPrompt.loopSystemPrompt`
gains a SKI-Mode addendum appended when `voiceProfile == .skiMode`,
and the rule is also written into `session.started.metadata.ack_rule`
so agents bypassing SKILL.md still see it:

```
如果用户请求需要 tool 调用 (read/write file, bash, xlb 搜索, 网页抓取等):
  1. 先立即写一句短确认到 commands.jsonl (`tts.speak`, 例:
     "好, 我看看" / "Let me check that")
  2. 再执行 tool
  3. 完成后写第二条 tts.speak, 内容是实际结果
不要在 tool 执行完前保持沉默 —— 用户会以为系统卡了。
```

Parallels SKI's line ~200 in its own SKILL.md. Kept as a Chinese block
for consistency with the rest of `loopSystemPrompt` (same tool JSON
field-name convention: `步骤 / 需要 / 完成`,
`OPENCLICKY_VOICE_PIPELINE.md` §D).

**Reader-side enforcement.** `OpenClickyFileBridge.tailCommands` fires
each `tts.speak` line into `TTSStreamingPlaybackEngine` **immediately**
— no buffering, no wait for a "response.done" signal (there is none in
this protocol). Each line is a fresh utterance:

- First line ("好, 我看看") reaches speakers ~200-400 ms after write
  because Kokoro and Realtime TTS both stream on first-sentence boundary
  (see `CartesiaTTSClient.beginStreamingResponse` +
  `TTSStreamingPlaybackEngine.scheduleSamples`,
  `CartesiaTTSClient.swift:216`).
- Second line queues behind first: `activeStreamingSession` on the
  engine cancels-and-replaces per
  `OPENCLICKY_VOICE_PIPELINE.md` §F. For SKI Mode we DO NOT cancel —
  we chain; add an `appendUtterance(_:)` method that schedules onto the
  same `AVAudioPlayerNode` without teardown.

`tts.cancel` from the agent (SKI protocol) maps to
`interruptCurrentVoiceResponse()`
(defined at `CompanionManager.swift:16812`; called from many turn-cancel
sites, e.g. `CompanionManager.swift:5656 / 5752 / 5782`), same as
today's turn-cancel.

---

## 4. Latency budget

| Stage | Target | Notes |
|---|---|---|
| User audio done -> Whisper final text | ≤ 800 ms | large-v3-turbo-q5_0 on Metal, M-series. SKI observed similar. |
| Whisper text -> `.oc/events.jsonl` write | ≤ 10 ms | Single append, `O_APPEND` fd. |
| Agent reads event -> first `tts.speak` | 500-1500 ms | Bound by CLI cold-cache (Claude Code / Codex). This is where the "immediate ack" rule earns its keep — the first line is a canned string, not a tool-loop result. |
| `tts.speak` -> audio playback start | ≤ 400 ms (Realtime) / ≤ 200 ms (Kokoro) | Kokoro is faster: no network round-trip. |
| **Total end-to-first-audio** | **~2.0-2.7 s** | Realtime default (`heyclicky-free-speech`) is ~350-700 ms end-of-speech-to-first-audio, matching `OPENCLICKY_VOICE_PIPELINE.md` "Realtime vs decomposed" section. Absolute delta: ~1.3-2 s slower P50. User-perceptible; mitigated (not erased) by the immediate-ack rule below. No quota burn, offline capable. |

If the ack line is dropped by the agent (skill not installed or
ignored), full first-audio latency degrades to 5-30 s depending on tool
count. That is why the installer (§7) matters — the skill file
guarantees the ack.

---

## 4.5. UX regressions we accept

SKI Mode is a deliberate trade. These losses vs the HeyClicky Free
Realtime lane are known and accepted:

- **Prosody / expressiveness.** Kokoro is a fixed-voice read-aloud
  engine; Realtime is context-tuned and can shift tone, emphasise words,
  and match affect. Severity: medium. Addressed: never (structural).
- **Streaming audio during generation.** Realtime chunks audio deltas
  as the model decodes; SKI Mode is utterance-scoped — each
  `tts.speak` line is a complete sentence written after the agent
  chooses to speak. Severity: medium. Mitigated by the immediate-ack
  rule (§3); fully addressed: never.
- **Audio-native non-verbal cues.** Realtime can emit laughs, sighs,
  `hmm`, breath pauses; text -> TTS pipelines cannot. Severity: low.
  Addressed: never (structural).
- **Walkthrough / point / typing / widgets emission.** `/chat-tool-call`
  ships `HigherModelResponse` side effects (WalkthroughBeat,
  PointCoordinate, TypingInstruction, WidgetPayload) that OpenClicky
  renders via overlay + accessibility. SKI Mode drops all of these
  until the SKILL.md contract adds them in v2. Severity: high for
  UI-direction turns ("point at that button"). Addressed: SKILL.md v2
  (post-Phase 4).
- **Silent listening / VAD hands-free.** Realtime has server-side VAD
  and OpenClicky's PTT-only stance is orthogonal; SKI Mode stays
  PTT-only until Phase 4 ships Silero VAD. Severity: low. Addressed:
  Phase 4.

Users routing everything through SKI Mode will notice items 1-4 within
the first session. Positioning (§0) frames the trade honestly.

## 4.6. Missing-skill fallback

If the user's CLI does not load `openclicky-voice/SKILL.md`, ignores
the extended `context` object, or violates the immediate-ack rule, the
utterance can sit in `.oc/events.jsonl` with no `tts.speak` response
ever appearing. Rule: **if 8 s elapses after an `utterance.final`
write with no matching `tts.speak` in `.oc/commands.jsonl`,
OpenClicky itself speaks a canned line and logs a drop.**

- Canned line (localised via `voiceResponseLanguage`):
  - `en`: "Your CLI agent didn't respond. Make sure the
    openclicky-voice skill is installed."
  - `zh`: "CLI 助手没有响应。请确认已安装 openclicky-voice skill。"
- Delivered through the same `voiceTTSClient` used for HeyClicky
  Free replies.
- Log entry: `.oc/events.jsonl` gets a `skill.dropped` event with
  `session_id`, `utterance_id`, `waited_ms=8000`, and a snapshot of
  the connected agents (PID + skill_dir) so the user can see which
  CLI missed it.
- Threshold rationale: 8 s is longer than the 500-1500 ms cold-cache
  budget from §4 but shorter than the impatience threshold observed in
  SKI's own telemetry (~10 s). Setting is user-tunable via
  `openclicky.voice.skiSkillTimeoutSeconds` (default 8).

---

## 5. Model download UX

Reuse `OpenClickyLocalSpeechModelManager` and
`OpenClickyLocalModelDownloadService.swift` (Parakeet already goes
through: URLSession resume-data — Apple's opaque resume mechanism for
`URLSessionDownloadTask`, not a literal HTTP `Range:` header — plus
SHA-256 verify at `OpenClickyLocalModelDownloadService.swift:613`, and
progress publish). Add
enum cases `.whisperLargeV3Turbo` and `.kokoroEn`; extend the existing
panel referenced from `CompanionPanelView.swift:19` (name, size,
language, download button, progress, delete). Silero VAD is small
enough (2.3 MB) to bundle in `AppResources/OpenClicky/` beside
`completion.aiff` — no download UI. Whisper HF publishes per-file
`.sha256`; fetch and verify post-download.

---

## 6. UDS presence protocol

`OpenClickyAgentsSocketServer.swift` (new). Path
`~/.openclicky/agents.sock`. OpenClicky is server; CLI agents connect
via the sidecar Python installed with the skill (§7). Handshake
(client -> server, newline JSON — SKI's hello key `"ski-heartbeat"`
swapped, `SKI_REVERSE_ENGINEERING.md` §D):

```json
{"hello":"openclicky-heartbeat","project_root":"/abs","skill_dir":"/abs/skill","pid":12345}
```

Server acks `{"ok":true,"session_id":"…"}` and keeps the socket open
as a liveness pipe (peer close = agent gone). Auto-bind on connect
writes the workspace into `~/.openclicky/projects.json` (mirrors SKI's
5-entry LRU). Connected agents live in a Combine-published
`[PID: AgentPresence]` dict consumed by
`OpenClickyVoiceBackendSelector`.

---

## 7. Skill installation onboarding

Ship a single skill folder in-repo at
`AppResources/OpenClicky/skills/openclicky-voice/` — fork of SKI's own
`SKILL.md` with OpenClicky paths substituted (`~/.ski/` ->
`~/.openclicky/`, `.ski/events.jsonl` -> `.oc/events.jsonl`) and the
immediate-ack rule pinned to the top.

Installer writes symlinks into every agent home directory it finds:
`~/.claude/skills/openclicky-voice/`, `~/.codex/`, `~/.gemini/`,
`~/.cursor/`, `~/.windsurf/`, `~/.cline/`, `~/.continue/`, `~/.kilo/`,
`~/.agents/`. Ships a `heartbeat.py` sidecar (Python 3, no deps) that
opens the UDS and tails `.oc/events.jsonl` into stdin scoped by
session id — exact SKI parity so SKI users see zero drift.

Settings toggle "**Install voice skill for all detected agents**" sits
below the SKI Mode picker in `AdvancedProvidersPanelView`. Discovery
follows `OpenClickyProviderDiscovery` (dir exists AND writable);
detected-but-not-installed agents show a per-row install button.

---

## 8. Multi-project routing

SKI Mode supports multiple simultaneously-bound projects. The widget
(`OpenClickyNotchCaptureWindowManager`) grows a horizontal chip list —
one per UDS-connected agent. Keyboard focus (⌘⇧D, matching SKI's
`next_project`) or the notch pointer picks the active speak-target;
voice writes to that project's `.oc/events.jsonl` only. Others still
see `session.started` / `tts.done` broadcast events but no
`utterance.final` until refocused.

---

## 9. Phase-by-phase migration

**Phase 1 — Local zh STT** (profile-agnostic; biggest user win).
Ship whisper.cpp bridge + `WhisperCppSTTProvider`; add `.whisperLarge`
case; extend the download UI. User picks it in Advanced Providers
without switching profile; zh privacy win over nova-3 fallback and
Realtime's server-side STT.

**Phase 2 — File bridge writer/reader.**
`OpenClickyFileBridge.swift` (append `.oc/events.jsonl`, tail
`.oc/commands.jsonl`); `TTSStreamingPlaybackEngine.appendUtterance` to
chain consecutive `tts.speak` lines; `heartbeat.py` +
`OpenClickyAgentsSocketServer.swift`; skill installer + provider
discovery.

**Phase 3 — Profile switcher + full SKI Mode.**
`OpenClickyVoiceProfile` enum + `openclicky.voice.profile` UserDefault
+ Settings UI. `.skiMode` = Whisper STT + file-bridge LLM (short-
circuits the provider switch) + user-picked TTS.
`AssistAgentPrompt.loopSystemPrompt` gains the immediate-ack addendum
under `.skiMode`, mirrored in `session.started` metadata.

**Phase 4 — Optional.** Silero VAD (toggle-wake-word / always-listen);
`kAudioUnitSubType_VoiceProcessingIO` capture path for TTS barge-in
(mirrors SKI's `src/audio/vpio.rs`); Kokoro-en local TTS.

---

## 10. Testing plan

- **Phase 1 verification.** Open Advanced Providers, switch STT to
  Whisper (large-v3-turbo), grant download, wait, hotkey-record a
  Chinese sentence. Overlay caption shows transcript. Confirm zero
  outbound requests (Charles Proxy or `nettop` filtered on `heyclicky`
  / `deepgram` / `assemblyai`).
- **Phase 2 verification.** Open `claude` in a git repo, wait for
  "openclicky-voice" skill autoload. Speak "hi". OpenClicky writes
  `utterance.final`; Claude writes `tts.speak "Hey — what's up?"`; audio
  plays. Verify `session.started` written first with matching
  `session_id`.
- **Phase 3 verification.** Flip profile to SKI Mode. Ask a
  tool-triggering question ("What files did I edit today?"). Measure
  end-to-first-audio ≤ 2.7 s (should hear the ack "好, 我看看"), then
  measure end-to-second-audio (the actual answer) ≤ 15 s. If first
  audio > 3 s, the skill's immediate-ack rule isn't firing — inspect
  `.oc/commands.jsonl`.
- **Phase 4 verification.** Toggle "always listen"; interrupt an
  in-flight `tts.speak` by speaking — Silero must flag speech and
  OpenClicky must emit `tts.cancel` to the agent within 300 ms.

---

## 11. Non-goals and risks

- **No AgentCall meeting bot** (`meeting.join_request` in SKI's
  `src/lib.rs:2046`); out of scope.
- **No SKI binary linkage or bundling** — native Swift reimplementation.
  Bundle-id stays `com.jkneen.openclicky`.
- **Whisper 1.5 GB download** is opt-in behind Advanced Providers UI.
- **Kokoro Chinese** not upstream; zh locked to Realtime TTS (which
  burns quota — document).
- **espeak-ng dependency** for Kokoro G2P. First-run toast prompts
  `brew install espeak` when `KOKORO_ESPEAK_NG` unset AND
  `/opt/homebrew/bin/espeak-ng` absent.
- **CLI cold-cache latency (500-1500 ms) dominates** and is not
  OpenClicky's to shrink. The immediate-ack rule is the only knob.
- **Do not delete `ClaudeAPI.swift`** or short-circuit the money-rule
  ordering (`CLAUDE.md` "Inference Routing"). SKI Mode replaces the
  provider switch entirely when active; it yields to it when inactive.

---

## 12. UI presentation via Agent Dashboard

Both HeyClicky Free rounds and SKI Mode CLI-agent activity render into
the existing Agent Dashboard window rather than a new surface.

- **Host.** Reuse `CodexHUDWindowManager`
  (`cursor-buddy/CodexHUDWindowManager.swift`). No new window class.
- **Model.** SKI Mode activity flows in as a synthetic
  `CodexAgentSession`-shaped object appended to
  `AgentDockStore.codexAgentSessions` (`CompanionManager.swift:645`),
  which the HUD already renders. Fields (`id`, `title`, `status`,
  `transcript`) are populated from `.oc/events.jsonl` +
  `.oc/commands.jsonl` tails.
- **Entry point.** The bubble icon in the top-right of the response
  card is the single trigger for opening the dashboard — one door for
  both HeyClicky and SKI Mode sessions.
- **Badge count.** Pending `.oc/commands.jsonl` events since the last
  dashboard view. Cleared on window activation.

### 12.a Extended JSONL event kinds

SKI's protocol is a soft contract (unknown kinds drop silently), so we
add OpenClicky-specific kinds; agents that don't emit them still work
with a coarser dashboard:

- `agent.thinking` — agent started processing.
- `agent.tool_call {name, args}` / `agent.tool_result {name, summary}`
  — `summary` truncated at 2 KB.
- `agent.text_chunk {text}` — streaming partial text (optional).
- `agent.done` — turn complete.
- `agent.interrupt` — user abort, direction dashboard -> agent.

### 12.b Bidirectional interaction

- **Text compose bar** writes `utterance.final` with
  `source="dashboard_text"`, skipping STT.
- **Mic button** runs the same STT pipeline as the global hotkey.
- **Attach screenshot** merges absolute paths into the next
  utterance's `screenshots` array.
- **Stop button** emits `agent.interrupt` and calls
  `interruptCurrentVoiceResponse()` locally.

### 12.c Presence header

One green dot per workspace bound via `agents.sock` (§6); hover shows
`project_root`. Zero dots inlines the §4.6 missing-skill instructions.
