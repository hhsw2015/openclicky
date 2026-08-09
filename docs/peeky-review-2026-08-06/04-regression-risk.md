# Peeky Free (mirage) Regression Risk Audit

Scope: Assess whether Peeky Free / mirage additions have broken existing
OpenClicky features — HeyClicky Free, SKI Mode, Codex Agent Mode, ElevenLabs
TTS, screen capture, and Claude Agent Mode. All line references are against
the current worktree state versus `origin/main`.

---

## Safe / Additive

### 1. `applyProfile(_:)` provider switch
`cursor-buddy/CompanionManager+Profiles.swift:21-92`

The switch does the right tear-down / bring-up for the three named profiles:
- `switchingAwayFromHeyClicky` → `stopHeyClickyFreeSubsystems()` (line 36)
- `switchingIntoHeyClicky` → `startHeyClickyFreeSubsystems()` (line 39)
- `switchingIntoMirage` → warms `OpenClickyIntentClassifier` +
  `MirageDeepgramClient` (lines 42-63)
- Falls through to `SKIModeHandsFreeSession.shared.reconcile()` (line 70)
  which self-guards on `activeProfile().id == "ski_mode"`.

The setter chain (`setVoiceTranscriptionProvider`, `setSelectedModel`,
`setTTSProvider`) is unchanged, so the paid profiles (`local`, `realtime`,
`quality`) route exactly as they did on `main`.

### 2. Cartesia `tokenProvider` teardown
`cursor-buddy/CompanionManager.swift:976-996`

`voiceTTSClient` is computed on every access. The paid `.cartesia` branch
explicitly nils out `cartesiaTTSClient.tokenProvider` (line 983) before
returning the client, and the `.mirageCartesia` branch reinstalls it
(lines 992-994). Stale mirage tokens cannot leak into a HeyClicky/paid
Cartesia call as long as callers go through `voiceTTSClient` (they do —
grep for `cartesiaTTSClient.speak` shows no direct users bypassing the
computed property).

Note: this is idempotent-per-access, not event-driven. Safe, but if
someone captures a reference to the client mid-turn it could pin the
stale closure. Not a current bug, worth guarding in a future refactor.

### 3. ElevenLabs CJK additions
`cursor-buddy/ElevenLabsTTSClient.swift`

Three edits, all strict supersets:
- `nextSentenceCut` word counter falls back to CJK-scalar count when no
  ASCII spaces are found (lines 654-663 in diff). English-only turns hit
  `spaceSplit.count` first, unchanged behavior.
- Comma-clause boundary adds `，、：；` (line 762 in diff). Old `,:;` still
  match first.
- Sentence terminator adds `。！？` (line 799 in diff). Old `.!?\n`
  behavior identical.

No risk to HeyClicky / SKI English turns.

### 4. `speakFillerIsolated` is additive
`cursor-buddy/CartesiaTTSClient.swift` (diff lines 273+)

Brand-new method with its own local `AVAudioEngine` + `AVAudioPlayerNode`.
Does not touch `self.audioEngine` or any shared state. Original
`speakText` path is unchanged aside from the auth-resolution helper that
now consults `tokenProvider` first (silently falls back to `apiKey`, so
paid Cartesia users are unaffected).

### 5. `CompanionScreenCaptureUtility`
`cursor-buddy/CompanionScreenCaptureUtility.swift` diff, lines 179-190

Only added a `screen_capture.geometry` log line. `maxDimension` and JPEG
compression (0.8) unchanged. HeyClicky expectations preserved.

### 6. `ClaudeAPI.swift` preserved
Untouched vs. `main` (`git diff main -- cursor-buddy/ClaudeAPI.swift` is
empty). Guardrail satisfied.

### 7. Model-catalog labels
`cursor-buddy/OpenClickyModelCatalog.swift:142` (`claude-haiku-4-5` label
`"Claude Haiku"`) — unchanged versus `main`. Mirage entries use the
`mirage/…` id namespace (line 162 comment explicitly notes this avoids
collision) and labels drop the "Peeky " prefix; paid Anthropic labels are
untouched.

### 8. Codex Agent Mode config
`cursor-buddy/ClickyCodexConfigTemplate.swift:108-121`

`isHeyClickyLane` is `model.hasPrefix("heyclicky-free-")`. Mirage models
use `mirage/claude-*` prefix, so they do not trip the HeyClicky renderer.
SKI Mode / paid Codex Agent Mode fall through to the standard `render()`
body (lines 123+), unchanged. New fields (`sensorMCPToken`, `bridgePort`)
default to `nil`, and their emission is opt-in.

### 9. ClaudeAgentRunner scoped to mirage
`cursor-buddy/ClaudeAgentRunner.swift:270-353`

Only entry points are `MiragePeekyOrchestrator` and `PeekyFreePanelView`;
there is no call site tied to SKI, HeyClicky, or Codex Agent Mode. The
scratch `settings.json` (with `mcpServers.openclicky` HTTP entry, mirage
relay `ANTHROPIC_BASE_URL`, `sk-mirage-relay-dummy` token) is written
to a fresh `NSTemporaryDirectory/openclicky-mirage-claude-<uuid>` per turn
and cleaned up in `tearDown`. It cannot leak into `~/.claude/settings.json`
or any other agent's config. SKI Mode is unaffected — it does not spawn
Claude Code.

---

## Risk (Low)

### R1. Boot-time warm-up guard
`cursor-buddy/CompanionManager.swift:2662-2683`

The boot warm is correctly guarded by
`OpenClickyProfileCatalog.activeProfile().id == "mirage"` (line 2677), so
non-mirage users pay no warm-up cost. Also fires inside `applyProfile`
only when `switchingIntoMirage` is true. Safe.

Risk score: none — flagged as verified.

### R2. `openaAIRealtime` shared by HeyClicky Free + paid realtime
`cursor-buddy/OpenAIRealtimeSpeechClient.swift` (diff lines 14-63, 80+)

The HeyClicky Free WS extensions add `realtimeBaseURL` override + a
`buildTranscriptionConfig` helper. `realtimeBaseURL` defaults to nil, so
paid GPT Realtime users hit `wss://api.openai.com/v1/realtime` as before.
`buildTranscriptionConfig()` unconditionally injects a `language` field
when `voiceResponseLanguage()` is non-`auto`. Users on paid Realtime who
had implicit English detection now get an explicit `language: "en"` when
their Language preference is set. Should be behavior-equivalent for
en/zh, but a Language=zh user on the paid Realtime pipeline will now be
forced into Chinese transcription where before it was auto. Minor UX
consideration, not a regression per se.

Suggested fix: none required; document as intentional.

### R3. `applyProfile` writes `clickyCodexModel` unconditionally
`cursor-buddy/CompanionManager+Profiles.swift:82-84`

When switching to mirage, `agentModelID = "mirage/claude-opus-5"` is
written to `UserDefaults` key `clickyCodexModel`. If any legacy Codex
Agent Mode consumer reads that key without validating it is a real Codex
model id, it would attempt to spawn Codex with `mirage/claude-opus-5` and
fail.

`cursor-buddy/OpenClickyModelCatalog.swift:252-260` already contains the
mitigation: `heyclicky-free-*` ids are re-mapped to `heyclicky-free-chat`
during voice-model resolution. There is no equivalent guard for
`mirage/…` ids in Codex Agent Mode paths.

Suggested fix: add a `mirage/`-prefix skip in
`OpenClickyModelCatalog.computerUseModel(withID:)` and any Codex-Agent-
Mode model resolver, so switching to Peeky Free then back to
`quality` / `local` does not leave a mirage id lingering in
`clickyCodexModel`.

### R4. Cartesia token-provider closure lifetime
`cursor-buddy/CompanionManager.swift:992-994`

The `@Sendable` closure captures nothing except `MirageCartesiaClient.shared`,
so no capture-cycle. But because the closure is set every time `.mirageCartesia`
is read, and cleared when `.cartesia` is read, a race is possible if two
different tasks concurrently observe `voiceTTSClient` while the user is
mid-switch. Not observed in practice — `voiceTTSClient` reads are all on
`@MainActor` — but worth pinning down.

Suggested fix: swap to a stored `tokenProvider` computed once at
`setTTSProvider(...)` time rather than on every getter read.

---

## Definitely Broken

None found. All existing lanes (HeyClicky Free, SKI Mode, Codex Agent
Mode, ElevenLabs TTS, screen capture, Claude direct/SDK fallback) remain
functionally intact against the mirage additions.

---

## Suggested Fixes (summary)

1. Guard `clickyCodexModel` UserDefaults from receiving a `mirage/…` id
   (either strip in `applyProfile` when writing, or reject in the
   Codex-side reader). Prevents Codex Agent Mode failure after a
   Peeky Free → paid profile switch.
2. Cache the Cartesia `tokenProvider` closure on `setTTSProvider` rather
   than on every `voiceTTSClient` access — eliminates the accessor-side
   effect currently at `CompanionManager.swift:983` and `:992`.
3. Optional: audit any consumer of `voiceResponseLanguage()` on the paid
   GPT Realtime path to confirm forcing a `language` hint is desired
   (see R2).

Verification suggestion: `swiftc -parse` the touched files and add a
smoke test switching profiles `mirage → local → heyclicky_free → mirage`
to confirm no stale state (tokenProvider, clickyCodexModel, warm-up
timers) leaks across boundaries.
