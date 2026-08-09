# 06 — Adversarial Review of `05-integration-plan.md`

Date: 2026-08-08
Reviewer: adversarial pass against actual code in `/Users/wowdd1/Dev/openclicky`
and `/tmp/parlor`.

**Headline:** Gate A — the plan's own "run this first, it can invalidate
everything" test — cannot produce a meaningful result as described. The
routelet tokenizer has no coverage for the Chinese characters in the plan's own
examples, and the Swift port drops the CJK-splitting normalizer the model was
trained with. See **F1**.

**Second headline:** the plan needs a local multimodal GGUF inference runtime
that does not exist anywhere in this codebase, and §7 never budgets for it.
See **P1**.

---

## Verified Correct

| # | Claim | Evidence |
| --- | --- | --- |
| V1 | Deepgram turn frames decoded, printed, no handler | `cursor-buddy/DeepgramStreamingTranscriptionProvider.swift:206-209` — `case "speechstarted"` / `case "utteranceend"` bodies are a bare `print`. Plan cites `:205-209`; one line off, substance correct. |
| V2 | `SileroVADTrim.speechOnly` is dead code | `cursor-buddy/SileroVADTrim.swift:41` is the only occurrence of the symbol repo-wide. Zero callers. Correct. |
| V3 | `usesWakeWord` is `self != .pushToTalk` | `cursor-buddy/OpenClickyWakeWordManager.swift:42-44`. A new `.smartTurn` case would silently arm the wake-word listener. Correct, and a real trap. |
| V4 | `capturedPCM16` does not exist | Repo-wide grep: zero hits. Correct. Buffers are forwarded to `activeTranscriptionSession.appendAudioBuffer` at `cursor-buddy/BuddyDictationManager.swift:806-813` and not retained; the plan's cited range is exact. |
| V5 | `LLMCapabilities.audio` at `1<<5` is the next free bit | `cursor-buddy/LLMClient.swift:52-57`; highest existing is `realtimeVoiceOnly = 1 << 4`. Correct. |
| V6 | `LLMClient` is decoratable | `cursor-buddy/LLMClient.swift:69-81`: `@MainActor protocol LLMClient: AnyObject` with `capabilities` + one `send`. A `@MainActor final class` wrapping an inner `LLMClient` is trivial; the `@MainActor` isolation is an aid, not an obstacle, since the decorator would call the router on the same actor. |
| V7 | Decorating avoids touching registry branching | `LLMClientRegistry.client(for:hooks:)` (`cursor-buddy/LLMClientRegistry.swift:22-46`) is a pure switch returning `LLMClient`; sole consumer is `dispatchViaLLMRegistry` (`cursor-buddy/CompanionManager+AIResponsePipeline.swift:963-970`). Wrapping the return value is one line. |
| V8 | SKI hands-free pays a flat 2 s hangover | `cursor-buddy/SKIModeHandsFreeSession.swift:60-64` — `silenceHangoverFrames` reads `openclicky.ski.vadSilenceMs`, default `2000`. Citation exact. |
| V9 | Routelet has a `none` reject class | `cursor-buddy/OpenClickyIntentClassifier.swift:50`; `head.json.labels == ["chat","find_action","integration","memory","none"]`. `none` exists and is a reject class. **But see F1** for whether it fires as the plan claims. |
| V10 | App skills are a hardcoded ~10-app Swift table | `cursor-buddy/OpenClickyAppSkillContext.swift` is 386 lines; `static let all` begins at line 97, inline `#"..."#` prompts, no size cap. Plan cites `:97-385`. Correct. |
| V11 | `jpegBase64_1280` has zero consumers | Only four hits repo-wide, all inside the producer `cursor-buddy/OpenRewind/Kit/ContextExtractor.swift` (`:45` decl, `:228` + `:254` populate, `:518` helper). Nothing reads it. Correct, and the plan is right that this is the cheapest multimodal win. |
| V12 | `buildSKIUtteranceContext` is the pointer-style precedent | `cursor-buddy/CompanionManager.swift:5783`. Plan cites `:5783-5926`. Start line exact. |
| V13 | `OverrideField` needs a new case + `applyOverrides` branch | `cursor-buddy/OpenClickyProfile.swift:229-236` — exactly the six cases the plan lists (`stt, tts, responseModel, agentModel, ttsVoice, activationMode`). Correct. |
| V14 | `IMAGE_TOKENS = 300` in `pipeline.py` | `/tmp/parlor/src/parlor/pipeline.py:33`. Plan cites it correctly (see N1 on the 50-vs-300 reconciliation). |
| V15 | Context budgets 6500 / 8100 / 13500 | `03-openclicky-context-injection.md:204-206`. Quoted correctly, with one nuance: 03 says "**~12000-13500**" for worst case; the plan drops the range and states 13500 flat. Minor, directionally honest. |
| V16 | 34 h smart-turn estimate | `04-smart-turn-port-plan.md:454` — "**Total** | **34 h** (~4.5 days)". Quoted correctly. |
| V17 | 0.96 acc @ 19 ms | `01-parlor-capabilities.md:784` ranking row #5. Quoted correctly, and the plan honestly flags at Gate 1 that 04 warns these are the author's own test-split numbers (`04-smart-turn-port-plan.md:494` mentions LiveKit's eot-bench scoring more harshly). Good-faith handling. |
| V18 | 01 ranks native audio input dead last at #17 | `01-parlor-capabilities.md` ranking table, row 17, "Native audio input to the LLM", value LOW-MEDIUM. Correct — and the plan's §10 closing threat ("if delta is small, E4B is only an STT alternative — 01 ranks it dead last") accurately reflects the source. |
| V19 | `[ROUTE]` scope is narrower than it looks | Plan's §4.3 framing is consistent with `cursor-buddy/CompanionManager+AIResponsePipeline.swift:845-855`, which documents the `[ROUTE]` tail as injected only inside `HeyClickyChatToolCallClient`. Note the tag is **not** fully removed — a settings toggle still exists (`cursor-buddy/OpenClickySettingsWindowManager.swift:2211` "Enable [ROUTE] tag parsing") and parsing lives at `cursor-buddy/HeyClickyChatToolCallClient.swift:862-885`. What was removed is `[ROUTE]` **JSON dispatch** (`:606`, `:995`). The plan does not overclaim here, but anyone reading "removed" loosely will be wrong. |

---

## Factual Errors

### F1 — Gate A is unrunnable as described, and on Chinese input would measure noise (CRITICAL)

§10 says Gate A costs "Thirty minutes, no code" and is the one test that can
invalidate the whole plan. Four independent problems:

**(a) The routelet vocab lacks the plan's own example characters.**
`AppResources/OpenClicky/mirage-routelet/tokenizer.json` is a 30 522-entry
English BERT WordPiece vocab containing only 488 CJK characters. Every
character in the plan's §0 table misses:

```
点 → None   这 → None   个 → None   刚 → None   才 → None
那 → None   解 → None   释 → None   报 → None   错 → None
```

**(b) The Swift port drops the CJK normalizer the model was trained with.**
`tokenizer.json`'s normalizer is
`Sequence[Lowercase, BertNormalizer{clean_text, handle_chinese_chars: true, lowercase}]`.
`handle_chinese_chars` inserts spaces around every CJK codepoint.
`MirageRedact.preprocess` (`cursor-buddy/MirageRedact.swift:45-78`) does
lowercase, tail-trim, secret/email/digit redaction — and nothing else. No CJK
spacing. `OpenClickyIntentClassifier.embed` (`:245`) then does
`for word in text.split(separator: " ")`, so a whole Chinese utterance arrives
at the tokenizer as ONE word.

**(c) Result: the entire utterance collapses to a single `[UNK]`.**
`wordpieceTokenize` (`OpenClickyIntentClassifier.swift:330-356`) returns
`[unkID]` for the whole word as soon as any prefix fails to match. Chinese
input therefore embeds as literally `[CLS] [UNK] [SEP]` regardless of content.

Gate A on the plan's own Chinese examples would compare two inputs producing
**byte-identical model input**, report a delta of exactly zero, and the plan
instructs the reader to conclude "E4B's value collapses … whole plan should be
dropped". That conclusion would be a tokenizer artifact, not evidence.

**(d) "No code" is false.** `classify(_:)` requires `bootstrap()` loading
`head.json` + `tokenizer.json` via
`Bundle.main.url(forResource:withExtension:subdirectory:"mirage-routelet")`,
plus a lazily built `ORTSession` over the 127 MB `embedder.onnx`, all behind
`#if canImport(onnxruntime)`. In a plain `swiftc` harness of the
`scripts/run-provider-catalog-tests.sh` shape, `canImport(onnxruntime)` is false
(SPM product unlinked) so `embed` returns `nil` and `classify` returns `nil` for
every input; and `Bundle.main` would point at the CLI executable dir, so the
subdirectory lookup fails regardless. Assets are present on disk
(`embedder.onnx` 127 MB, `head.json` 51 KB, `tokenizer.json` 695 KB) — the
blocker is linkage and bundle path, not missing files.

**Fix:** either (i) port `handle_chinese_chars` and re-measure coverage (still
poor at 488 chars), or (ii) accept routelet as English-only and rewrite Gate A
over English deictic utterances, or (iii) drop Gate A entirely. (iii) is
probably right: the head was trained on Peeky's English intent data, so a
Chinese accuracy number from it is uninformative in either direction.

### F2 — "`LLMRequest.audio` default mandatory — without it all six dispatch hooks break"

Cited at `LLMClient.swift:~24-48`; `LLMRequest` is at `:22-44`, so the range is
roughly right. The reasoning is wrong.

The six hooks (`cursor-buddy/LLMClientAdapters.swift:30-37`) all take
`(LLMRequest, callback) async throws -> String`. They **consume** an
`LLMRequest`; none constructs one. Adding a field cannot break them — they read
`req.images` / `req.model` / `req.systemPrompt` and would simply not read
`req.audio`.

What actually breaks without a default is the memberwise init at the **single**
construction site, `cursor-buddy/CompanionManager+AIResponsePipeline.swift:857`.
Repo-wide grep for `LLMRequest(` returns exactly one hit. One call site, not
six. The recommendation is still fine; the justification is fabricated, which
suggests the structure was inferred rather than read.

### F3 — "A decorator at the `LLMClient` seam reaches mirage only"

Conflates **profile** with **provider**. The registry
(`cursor-buddy/LLMClientRegistry.swift:29-45`) maps *providers*: `.apple`,
`.anthropic`, `.openAI`, `.codex`, `.peekyFree`, `.heyclickyFree` each get a
real adapter; only `.deepgram` gets `UnsupportedLLMAdapter`. All of them flow
through `dispatchViaLLMRegistry`, so a decorator installed there reaches **all
six providers**, not mirage alone.

Two knock-on corrections:

* The provider case is `.peekyFree`, not `.mirage`. `MirageLLMAdapter` serves
  it. The plan's naming will mislead an implementer grepping for `.mirage`.
* `heyclickyFree` has a working registry adapter (`HeyClickyLLMAdapter`). It is
  bypassed only when the selected model is a realtime-speech one
  (`shouldRoutePTTToHeyClickyRealtimeSession`,
  `cursor-buddy/CompanionManager.swift:7049`) — a **model-level** condition, not
  a profile-level one. So "heyclickyFree bypasses the seam" is true for one
  model class and false otherwise.

The `ski` half of the claim holds: `_analyzeVoiceResponseCore` returns `""`
early (`CompanionManager+AIResponsePipeline.swift:~840`, "Return \"\" prevents
Claude Agent SDK fallback") before reaching `LLMRequest`, so ski genuinely does
not traverse the seam.

Net effect: §4.3's "Recommend mirage-only v1" is a self-imposed restriction
justified by a wrong premise. Coverage is better than the plan believes, and
§9's "heyclickyFree / ski router coverage out of scope in v1" is over-broad for
heyclickyFree.

### F4 — `openclicky.xlb.enabled` "false in one place, true in the other" mis-cites

The plan pairs `AppBundleConfiguration.swift:253` against
`CompanionManager.swift:5847`. `CompanionManager.swift:5847` is correct:
`let xlbEnabled = (ud.object(forKey: "openclicky.xlb.enabled") as? Bool) ?? true`
— defaults **true**, with a comment explaining the opt-out pattern.

`AppBundleConfiguration.swift:251-256` is `xlbEnabled()`, which defaults
**false** — but it reads a *different key*
(`userXLBEnabledDefaultsKey`, driven by env var `OPENCLICKY_XLB_ENABLED`), not
`openclicky.xlb.enabled`. These are two distinct settings, not one setting read
inconsistently. There may still be a real bug (two competing xlb switches is its
own problem), but the plan's specific framing — same lane, two defaults — is not
what the code shows. Anyone "fixing" this by aligning the defaults would be
changing unrelated behavior.

### F5 — "the xlb index never populates / topic context has always been empty"

The plan states this as settled fact ("the topic context you believed was being
injected has in fact always been empty") and cites `XLBTopicIndex.swift:1376`.
That file path does not exist. The real paths are
`cursor-buddy/OpenRewind/Bridge/XLBTopicIndex.swift:1376` and a duplicate at
`tools/xlb-diff/Sources/xlb-diff/XLBTopicIndex.swift:1376`; line 1376 in both is
`public func startWatchingIfEnabled()`. The plan's line number happens to land
on the right symbol, but the path is wrong and the duplicate copy is unmentioned
— which matters, because a fix applied to one and not the other silently
diverges. I did not confirm the "never populates" behavioral claim; see U2.

---

## Numbers

### N1 — "screenshot ≈ 50 tokens (01 measured 50, not the 300 stated in `pipeline.py`)" — misattributed

Both numbers are real but they are not competing measurements of the same
thing, and 01 never "measured" 50.

* `300` is `/tmp/parlor/src/parlor/pipeline.py:33` `IMAGE_TOKENS = 300`, a
  **budgeting constant** used by `estimate_tokens` for context-rotation
  decisions. It is deliberately conservative — over-estimating is safe for
  rotation.
* `50` comes from `01-parlor-capabilities.md` ranking row 11
  ("Attach-the-screenshot-every-turn policy … Act on camerabench: 50 tokens +
  600 ms hidden beats a 2.2 s/turn pre-decision"). That is a cited camerabench
  figure about a *policy tradeoff*, not a measurement of this mmproj's image
  token cost. 01 itself at `:84` says "One `IMAGE_TOKENS = 300` budget per
  frame."

So 01 contains **both** numbers without reconciling them, and the plan resolves
the conflict in the direction that flatters its own 650-token budget while
asserting a provenance ("01 measured 50") that 01 does not support. If the true
cost is 300, the §4.1 budget becomes ~900 tokens, not 650 — a 38% overrun before
any implementation slippage. The §4.1 sentence is also visibly truncated
mid-clause ("…not 300 stated in `pipeline.py`'s / ~32 tok/s."), so the
arithmetic was never shown.

**Recommendation:** budget 300 and treat 50 as best case, or measure this
mmproj's actual image token cost directly before committing to 650.

### N2 — "Parlor's ~1.3 s figure for e4b" — plan states a point value the source gives as a range

`01-parlor-capabilities.md:46-48`: the CHANGELOG latency table is "M3 Pro,
`MODEL=e2b`" and the e4b figure is given as "**≈ 1.0-1.7 s**". The plan converts
this to a flat "~1.3 s" (§4.1, §4.5). Midpoint is defensible, but two caveats
are dropped: the table's primary measurements are **e2b**, not e4b, and the
hardware is an M3 Pro. Gate B's "< 1.5 s" target sits inside the source's own
uncertainty band — i.e. the published range straddles the pass/fail line, so
Gate B as written can pass or fail on hardware variance alone. Tighten the gate
or widen it, but do not pretend 1.3 is a measurement.

### N3 — 34 h, 6500/8100/13500, 0.96 @ 19 ms all check out

See V15, V16, V17. Minor: 03 says "12000-13500" and the plan reports 13500.

---

## Unverifiable Claims

| # | Claim | Why unverified |
| --- | --- | --- |
| U1 | "Every Gemma variant scores chance on end-of-turn while costing 0.6-3.6 s" (§1) | Attributed to 01's own benchmarking. No raw data in-repo to re-derive; taken on faith. It is load-bearing for the "keep Layer A independent" decision, which is sound reasoning regardless. |
| U2 | "xlb index never populates" (§3) | Requires runtime observation of `XLBTopicIndex.shared.fuzzyLookup` returning empty against a live index. Not statically decidable. The plan asserts it as fact with no cited evidence beyond a wrong file path (F5). Downgrade to hypothesis until a runtime probe confirms it. |
| U3 | "Camera frames ship at native `.high` while screenshots clamp to 1280" (§3) | Plan's only ref is the bare token "03". Not traced. Plausible but uncited. |
| U4 | E4B Chinese audio quality (Gate C) | Genuinely unmeasured; the plan says so and gates on it. Correctly handled. |
| U5 | "Marginal cost ≈ 0 because E4B runs anyway for routing" (§4.5) | Only true if the router ships AND is enabled. §6 sets the default to None on all three profiles, so for default users the marginal cost of E4B transcription is the **full** E4B cost, not zero. The plan's own defaults contradict its cost argument. |

---

## Missing Prerequisites

### P1 — There is no local GGUF inference runtime, and the plan never budgets for one (CRITICAL)

§6 renders a settings row "Gemma 4 E4B [ Download ] 3.4 GB + mmproj" as if it
were the same shape as the existing Whisper download. It is not. Inventory of
what actually exists:

| Runtime | Present? | Evidence | Can host a Gemma multimodal GGUF? |
| --- | --- | --- | --- |
| whisper.cpp | Yes | Vendored dylibs `Vendors/whisper/lib/libwhisper.dylib`, `libwhisper.1.dylib`, `libwhisper.coreml.dylib`; C shim `Packages/CWhisper/Sources/CWhisper/CWhisper.c`; bound at `cursor-buddy/OpenRewind/Capture/WhisperCppTranscriber.swift:278` via `whisper_init_from_file` | No — ASR only |
| ONNX Runtime | Yes | SPM `onnxruntime-swift-package-manager`; used by routelet + Silero VAD | No — would need a full ONNX export of Gemma + vision tower, which is not what "3.4 GB GGUF + mmproj" describes |
| CoreML | Partial | `import CoreML` only in `cursor-buddy/OpenClickyParakeetTranscriptionProvider.swift` | No |
| FluidAudio | Yes | SPM pin; used by `OpenClickyLocalSpeechModelManager` + Parakeet provider | No — ASR |
| MLX / mlx-swift | **No** | Zero hits for `import MLX`, `MLXLLM`, `mlx-swift`; absent from `Package.resolved` | n/a |
| llama.cpp | **No** | Zero `libllama*` / `libmtmd*` / `*llama*.dylib` anywhere; only textual mentions in `cursor-buddy/OpenRewind/Kit/Public/OpenRewindAIProvider.swift` | n/a |

`OpenClickyLocalModelDownloadService.swift` is a **download/verify** service
(phases: `resolvingManifest`, `downloading`, `verifying`, `completed`) — it
fetches bytes and checksums them. It does not execute models.
`WhisperLocalModelManager.swift` likewise only manages GGML `.bin` downloads
from HuggingFace for a runtime that is already vendored.

So the plan's "Download" button has nowhere to send the bytes. Standing up a
Gemma multimodal GGUF path means one of: vendoring `libllama` + `libmtmd`
(mirroring the whisper.cpp vendoring, incl. universal binaries, signing,
notarization); adding mlx-swift + a VLM port; or spawning `llama-server` as a
child process. Each is a **multi-week subsystem**, comparable to or larger than
the entire 34 h Layer A estimate. §7's phase list has no line item for it, and
§8's risk table rates "Model size / memory" as **Low** while omitting "no
runtime exists" entirely — which should be the single highest-severity risk in
the document.

Parlor itself is unambiguous that a server is required:
`/tmp/parlor/src/parlor/server.py:3` — "LLM inference runs on llama.cpp
(llama-server, spawned as a subprocess)"; `/tmp/parlor/src/parlor/llama.py:102`
shells out to `shutil.which("llama-server")`.

### P2 — Gate 2 assumes a runnable Parlor; the plan does not state the setup cost

§7 Phase 2 says "run Parlor as-is with `REASONER_BASE_URL` pointed at
`MirageLocalRelay`". `REASONER_BASE_URL` is real
(`/tmp/parlor/src/parlor/reasoner.py:17`), so that part is accurate. But
reaching that point requires a working `llama-server` with the E4B GGUF + mmproj
loaded locally (P1's dependency, in its Python form). Phase 2 is billed as
cheap ("Any failure stops [work] having spent half a day") while silently
depending on the same missing infrastructure. Realistically Phase 2 is a
model-download + llama.cpp-install day before any measurement starts.

### P3 — No `LLMAudioInput` type exists

§3 specifies `LLMRequest.audio: LLMAudioInput? = nil`. `LLMAudioInput` is not
defined anywhere. Trivial, but it is listed as a "prerequisite fix" as though
it were an edit rather than a new type + a decision about representation (PCM16
buffer? WAV `Data`? file URL?). That decision interacts with the 300 ms tail
padding (§2 item 6) and with whatever `capturedPCM16` ends up returning.

---

## Policy Assessment (revised)

I initially reviewed this against a "no builds from terminal" reading of
CLAUDE.md. The correction from the coordinator is right and I have re-checked
the actual text.

`/Users/wowdd1/Dev/openclicky/CLAUDE.md:7` says "Do not run `xcodebuild` from
the terminal." The operative reason is signing stability:
`scripts/fast-install.sh` signs with a fixed "OpenClicky Dev Sign" identity so
the bundle signature is stable across rebuilds and macOS TCC does not re-prompt
for mic / screen recording / accessibility. Raw `xcodebuild` with ad-hoc or
changing signing invalidates TCC and forces a human back into System Settings.
CLAUDE.md:88's "Do not launch unsigned or throwaway builds for TCC permission
testing" is the same concern stated directly. So the rule constrains **how** you
build, not **whether** — `bash scripts/fast-install.sh` is the sanctioned
autonomous build+install+relaunch path.

`AppResources/OpenClicky/AGENTS.md` is a runtime instruction file for the
in-product agent (memory/skill/log handling, prefer OpenClicky's own
typing/clicking tools). It contains nothing bearing on sidecars or process
spawning.

**On the llama-server sidecar specifically**, judged on merits rather than by
assuming "sidecar = forbidden":

* **Process spawning is already normal here.** The app ships and spawns
  `AppResources/OpenClicky/CodexRuntime`, `OpenCLIRuntime`, `OpenDiaRuntime`,
  `ClaudeAgentSDKBridge`, `CuaDriverRuntime`, `BackgroundComputerUseRuntime`.
  A child process is an established pattern, not a novel violation.
* **The real constraint is CLAUDE.md's "Do not introduce a hard dependency on a
  Cloudflare Worker for the final app" plus the local-keys/local-config
  posture.** A *bundled, signed* llama-server child is consistent with that
  posture — arguably more so than a hosted call. A sidecar that depends on the
  user running `brew install llama.cpp` is the actual problem: 01 flags exactly
  this at ranking row 17 ("costs a 6 GB model + a Homebrew dependency"), and it
  breaks the shipped-app story.
* **Signing is the genuine cost, not policy.** A spawned child binary must be
  signed, hardened-runtime compatible, and notarized with the app, and it must
  not break the fixed-identity signing that keeps TCC stable. Vendoring
  `libllama`/`libmtmd` as dylibs (mirroring `Vendors/whisper/lib/`) sidesteps the
  child-process signing question entirely and matches existing precedent.

**Verdict:** the sidecar is not a policy violation. It is a large unbudgeted
engineering item (P1) with a real signing/notarization tail. The plan should
say which of the three approaches it is choosing and cost it; §9 currently only
mentions a "local sidecar" in passing as a condition for speculative prefill.

---

## Automation Assessment (revised)

Correction accepted: because `scripts/fast-install.sh` preserves TCC via fixed
identity signing, rebuild+relaunch is autonomous, and runtime E2E testing is
therefore in scope. The drive surfaces are stronger than I first assumed.

**What exists.** `cursor-buddy/OpenClickyExternalControlBridge.swift` (5 701
lines) is explicitly an "Automation-only commands (headless self-test surface)"
(`:42`). Directly relevant commands:

* `openclicky_simulate_voice_turn` (`:1717`) — "Simulate one full PTT voice turn
  end-to-end without touching microphone/STT/WS" (`:74-78`), driving
  `HeyClickyChatToolCallClient.analyzeVoiceResponse` → `chat.request`.
* `openclicky_simulate_ski_utterance` — emits the SKI `UtteranceContext` to
  `.oc/events.jsonl` and "returns the emitted JSON payload so the caller can
  assert on context/hints fields".
* `openclicky_set_profile` — switches profile end-to-end including STT/TTS/model
  keys and subsystem lifecycle hooks, "so automation harnesses can exercise a
  specific lane without a UI click".
* Fault injection (`:66-71`): `kill_codex`, `expire_credentials`,
  `trigger_turn_limit`, `trigger_402_quota`.

Transport is HTTP on `127.0.0.1:32123`
(`scripts/test-external-control-bridge.sh:4`, `OPENCLICKY_BRIDGE_URL`), so any
shell/python harness can drive a running app. Existing harnesses:
`scripts/test-external-control-bridge.sh`, `scripts/test-mcp-sensor.sh` (20 KB),
`scripts/automation-longrun-test.sh`, `scripts/mirage-e2e-test.sh`,
`scripts/run-assist-agent-tests.sh` (26 KB),
`scripts/run-provider-catalog-tests.sh` (pure-`swiftc` pattern, no Xcode).
Plus `cursor-buddyTests/` XCTest/swift-testing suites.

**Per-gate verdict:**

| Gate | Automatable? | How / what blocks it |
| --- | --- | --- |
| Phase 0 §2 items 1-6 | **Yes** | Deepgram handler + tail padding + modes table are unit-testable in `cursor-buddyTests/`. Cache-stable ordering audit is a static grep assertion over prompt assembly. |
| Phase 0 §3 blockers | **Yes** | `usesWakeWord` allowlist and `LLMRequest.audio` default are pure unit tests. `capturedPCM16` needs a fixture buffer, still unit-scope. |
| Gate 1 (Chinese EOT accuracy) | **Partly** | Scoring against a labelled recording set is fully scriptable. **Building the labelled set needs a human once** (someone must mark true end-of-turn on real Chinese audio). After that, regression runs are automated forever. |
| **Gate A** | **No, as written** | Blocked by F1, not by automation. Once the tokenizer question is resolved, the mechanism is scriptable — but it needs the app process (bundle path + linked ONNX), so drive it through the bridge rather than a bare `swiftc` harness. Add a bridge command that exposes `classify(_:)`, and Gate A becomes a one-command scripted test. **This is the highest-value change to the plan.** |
| Gate B (first-token latency) | **Yes** | Wall-clock around a bridge call is exactly what `automation-longrun-test.sh` already does. Fully scriptable once a runtime exists (P1). |
| Gate C (Chinese audio understanding) | **Mostly** | Comparing E4B transcript vs Whisper local on the same clips is scriptable, and WER/CER against a reference is a number, not a judgement. **A human is needed once** to produce reference transcripts for the clip set. Not needed per-run. |
| Gate 3 (zero wrong self-answers) | **Yes, with a caveat** | `openclicky_simulate_voice_turn` injects a transcript and returns the reply, so a scenario table of (utterance → expected/forbidden reply) runs unattended. The caveat is grading: exact-match works for a curated set; open-ended correctness needs an LLM judge, which is itself automatable but introduces its own error floor. Given the gate is "**zero** wrong", bias the judge to flag-for-review rather than auto-pass. |
| Gate 4 (curation must not regress) | **Yes** | A/B the curated vs full-context path over the same scenario set through the bridge, diff the answers. Same judging caveat. |

**Genuinely human-gated, total:** building the Gate 1 label set, producing Gate
C reference transcripts, and (optionally) subjective TTS/prosody quality. That
is three one-time data-collection tasks, not three recurring human gates.
Everything else in §7 can run unattended via
`fast-install.sh` → bridge HTTP → assert.

**Gap:** there is no bridge command exposing `OpenClickyIntentClassifier`. Add
one (e.g. `openclicky_classify_intent`) in Phase 0. It is a few lines, it
unblocks Gate A, and it makes routelet accuracy a permanent regression metric
rather than a one-off spreadsheet.

---

## Recommended Plan Changes

1. **Fix or replace Gate A before running it (F1).** As written it returns a
   guaranteed-zero delta on Chinese input for tokenizer reasons, and the plan
   instructs the reader to kill the project on that result. Decide first whether
   routelet is English-only. If it is, say so in §0 and re-scope: the value
   argument for grounding must then rest on something other than routelet
   accuracy, because routelet cannot see Chinese at all.
2. **Add a Phase 0 line item: `openclicky_classify_intent` bridge command.**
   Unblocks Gate A, converts routelet accuracy into a scripted regression check.
3. **Promote "no local GGUF runtime exists" to the top of §8 at High severity,
   and add an explicit Phase to §7 for it (P1).** Pick one of vendored
   `libllama`+`libmtmd` (precedent: `Vendors/whisper/lib/`), mlx-swift, or a
   bundled signed child process — and cost it. It is plausibly larger than
   everything else in the plan combined. The current §6 "Download" row implies
   parity with Whisper that does not exist.
4. **Correct §4.3.** The decorator reaches all six registry providers, not
   mirage only. Rename `.mirage` → `.peekyFree` throughout. Restate the
   heyclickyFree exclusion as model-level (realtime speech) rather than
   profile-level. Then reconsider §9's blanket "heyclickyFree out of scope".
5. **Re-derive the §4.1 budget with `IMAGE_TOKENS = 300` (N1).** State 650 as
   best case and ~900 as expected, or measure the real cost first. Do not cite
   "01 measured 50" — 01 does not.
6. **Restate the e4b latency as the range 01 gives (1.0-1.7 s), not 1.3 s
   (N2),** and move Gate B's threshold off the middle of that band.
7. **Fix F2's justification** (one construction site at
   `CompanionManager+AIResponsePipeline.swift:857`, not six hooks) and **add
   `LLMAudioInput` as its own design item (P3)** — the representation choice
   couples to `capturedPCM16` and to the 300 ms tail padding.
8. **Split the xlb entry (F4/F5).** `AppBundleConfiguration.xlbEnabled()` and
   `openclicky.xlb.enabled` are different keys, not one key with two defaults.
   Correct the path to `cursor-buddy/OpenRewind/Bridge/XLBTopicIndex.swift` and
   note the `tools/xlb-diff/` duplicate. Downgrade "has always been empty" to a
   hypothesis pending a runtime probe.
9. **Reconcile §4.5's "marginal cost ≈ 0" with §6's default-off (U5).** For
   default users the marginal cost is the full E4B cost. Either default the
   router on after Gate B, or drop the zero-cost framing.
10. **Re-scope §7 around what is actually cheap.** Phase 0 (quick wins, bridge
    command, independent bugs) and Phase 1 (smart-turn, 34 h) are well-founded,
    verifiable, and need no E4B. Phases 2-4 all sit behind P1. Consider shipping
    0 and 1, then re-deciding on E4B once the runtime cost is honestly priced —
    the plan's own three-independent-layers principle already supports this.
