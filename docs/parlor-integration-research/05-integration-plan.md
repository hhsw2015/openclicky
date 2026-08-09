# Parlor → OpenClicky Integration Plan

Date: 2026-08-08
Revision: **3** — the model has been run. §0, §1, §4 and §5 are rewritten
against measurement; §12 holds the raw results.

> **What changed in revision 3.** Rev 1 was written before the model
> existed on this machine and rev 2 before it could be driven. Several
> load-bearing claims did not survive.
>
> | rev 1/2 said | measured |
> | --- | --- |
> | native audio is the irreplaceable capability | **false for Chinese** — CER 0.138 vs whisper 0.000, errors propagate into routing |
> | resolving deixis unlocks routelet | **false** — zh-grounded == zh-raw == 0%. The win is *English*, not the referent |
> | 224 px defeats UI reading | **withdrawn** — 14 px glyphs read fine; density is the limit, not size |
> | ~50 tokens per screenshot | **296** measured |
> | E4B should transcribe in parallel with STT | **reversed** — E4B must never transcribe |
>
> Two things rev 2 got right and measurement confirmed: rev 1's Gate A
> design would have killed the project on a tokenizer bug (a control arm
> caught it), and there is still **no local GGUF runtime in OpenClicky** —
> the largest uncosted gap in this plan.
>
> One new argument, absent from both earlier revisions: **granular egress**
> (§12.9).

Inputs: `01-parlor-capabilities.md`, `02-openclicky-voice-pipeline.md`,
`03-openclicky-context-injection.md`, `04-smart-turn-port-plan.md`,
`06-plan-review.md`, `07-autonomous-test-harness.md`.

Decisions locked with the user:

* Frontend model is **Gemma 4 E4B** (MatFormer elastic tier, ~4B effective
  params). Not 12b, not Qwen.
* **No fourth "all-local" profile.** The router is a layer, not a preset.
* ~~Transcription defaults to parallel~~ — **superseded.** STT transcribes,
  E4B translates the resulting text. E4B never receives audio (§4.5).

---

## 0. What E4B is actually for

> **Rev 3 (2026-08-08).** This section has been rewritten against measured
> results. Everything below is now backed by §12; where an earlier revision
> guessed, the guess is marked. Two of revision 1's three headline claims
> did not survive contact with the model.

The one-line role: **translate, and see what OCR cannot.**

It does **not** transcribe (whisper is better), does **not** classify
intent (routelet is better), and does **not** reason (Claude is better).
Its job is the narrow band those three leave uncovered.

### The three things it is for

**1. Cross-language grounding.** A Chinese utterance against an English UI
has no string bridge; deterministic matching cannot span it at any level of
cleverness. Measured 4/4 for E4B, **0/4** for an OCR + fuzzy-match baseline
(§12.5). This is the primary daily case for this user, and the single
strongest argument for the model.

**2. Non-text controls.** Arrows, toggles, unlabelled buttons. These do not
exist to OCR at all. Again 4/4 versus **0/4**.

**3. Granular egress.** Local inference means a turn can be answered with
*nothing leaving the machine*. Today the choice is upload-the-whole-screen
or lose the feature; there is no middle. See §12.9 — and note the claim is
"egress becomes granular", not "data never leaves", because anything E4B
cannot handle must still go to Claude.

Underneath all three: local inference has no per-call cost, so the screen
can be interrogated repeatedly. That is what makes "scan twenty history
frames for the one with an error dialog" tractable at all — Claude cannot
afford it (thousands of tokens, seconds) and OCR cannot do it (no
semantics).

### What earlier revisions got wrong

| claim | verdict |
| --- | --- |
| "Native audio is the irreplaceable capability" | **False for Chinese.** CER 0.138 vs whisper's 0.000, and the errors propagate: 并发 → 病发 → "Swift illness onset" → wrong route (§12.3). |
| "Resolving deixis is what unlocks routelet" | **False.** zh-grounded scored identically to zh-raw, both 0%. The win is emitting *English*, not resolving the referent (§4.2a). |
| "224 px will defeat UI reading" | **Withdrawn.** 14 px glyphs (≈2 px after downscale) read correctly, both scripts. The real limit is text *density* (§12.4). |
| "~50 tokens per screenshot" | **Wrong.** Measured 296. The 50 was a camerabench policy parameter, not a measurement (§12.8). |

### Two hard constraints on how it is used

Both come from observed failures, not caution:

1. **Closed questions only.** Asked to enumerate, it produced 26 labels of
   which 12 were absent — and the invented ones were old macOS menu names.
   It recites priors rather than admitting it cannot see. 54% precision.
2. **Ban dense-text regions by category, not by inspection.** Left to judge
   for itself it "read" a terminal line and returned a command that had
   genuinely been typed minutes earlier — plausible, specific, fabricated.
   A categorical ban took false-positives from 1 to **0** and latency from
   1520 ms to 382 ms.

A third, operational: **`--reasoning off --reasoning-budget 0` is
mandatory**. Default, the model spends its whole budget on a reasoning
trace and returns empty content — 6715 ms versus 470 ms, and it looks
exactly like model incapability (§12.2).

### What it emits, measured

| user says | E4B output | who could also do this |
| --- | --- | --- |
| 「打开蓝牙」 | `Bluetooth` | OCR, via fuzzy match |
| 「我想调无障碍」 | `Accessibility` | **nobody else** — no string bridge |
| 「点那个开关」 | `Toggle switch` | **nobody else** — invisible to OCR |
| 「点这个」 | `General` (a real, prominent element) | OCR, crudely |
| 「读一下终端里的报错」 | `NOT_LEGIBLE` | — correctly declines |

Grounding accuracy on the cases it accepts: **8/8, zero invented elements**
(§12, Gate F). Legibility self-judgement: **zero fabrications** after the
categorical dense-text ban (Gate E).

Note the last row. Declining correctly is as load-bearing as answering
correctly — it is what lets the layer sit in front of Claude safely.

### What Claude cannot do, and why it is not "seeing"

Claude already receives the current screenshot (03: ~8100 tok with one
attached), so vision per se is not the differentiator. The three things it
structurally cannot do:

1. **High-frequency vision.** Twenty history frames is thousands of tokens
   and seconds of latency for Claude; locally it is free. This is what
   makes screen-history search feasible rather than theoretical.
2. **Answer without egress.** Every Claude turn ships the pixels. See
   §12.9.
3. **Gate cheaply.** Deciding whether Claude is needed, before paying the
   round trip.

### The screen-history opportunity

03 found that `ContextExtractor` already produces a `jpegBase64_1280` field
**with zero consumers** — pixels are stored as HEVC chunks addressable by
`frame.videoId` + `videoFrameIndex`, but the prompt only ever receives a
160-character OCR snippet per hit. E4B can consume those frames directly.

This is the largest untapped multimodal win and needs no new capture
infrastructure. It is also, notably, the one use case where **none** of the
three alternatives work: OCR has no semantics ("which frame had an error
dialog?" is not a string match), Claude cannot afford the tokens, and the
data is already on disk so there is no privacy argument for sending it.

Untested so far — the §12 gates covered the live screen, not history
frames. Worth its own gate before building.

---

## 1. Three independent layers

Each ships separately, each has its own switch, none blocks the others.

| Layer | Question it answers | Needs E4B? | Effort |
| --- | --- | --- | --- |
| **A. smart-turn-v3** | When do we stop recording? | No | 34 h (04) |
| **B. E4B translate** | What is this in English? | Yes | small — text-in, 315 ms |
| **C. E4B screen** | Can I see the target, and which element is it? | Yes | small — but needs the runtime |
| **D. E4B curation** | What context does the backend get? | Yes | See §5, unvalidated |

> **Rev 3:** B and C were one layer ("the router") in earlier revisions.
> Splitting them matters because they have different dependencies and
> different value. **B needs no vision at all** — it is text-in, text-out,
> and is what rescues routelet on Chinese (0% → 87.5%). **C** is what OCR
> cannot replace (§12.5). They can ship independently, and B is much the
> cheaper of the two.
>
> D remains speculative. No gate has been run on it.

Keeping A independent matters: 01 measured that **every Gemma variant scores
at chance on end-of-turn while costing 0.6–3.6 s**, versus smart-turn's 0.96
accuracy at 19 ms. Turn-taking is an acoustic problem, not a language one.
Coupling them would mean losing turn detection whenever the router is off.

**All of B, C and D depend on a prerequisite none of them names: OpenClicky
has no local inference runtime.** whisper.cpp is vendored, ONNX and
FluidAudio are linked, but there is no llama.cpp and no MLX;
`OpenClickyLocalModelDownloadService` downloads and checksums, it does not
execute. That gap is larger than any single layer here and is not costed
anywhere in this plan. See §3a.

---

## 2. Quick wins that do not need E4B at all

01's ranked list puts these above everything E4B-related on value ÷ effort.
They should ship regardless of whether the router ever does.

| # | Item | Effort | Why now |
| --- | --- | --- | --- |
| 1 | ~~Modes as data (`modes.py` shape)~~ | — | **DROPPED — already exists.** `OpenClickyProfile` is the flag table; `applyProfile` is the clear-state-on-switch. See §12.11 |
| 2 | Floor management (`floor_busy`/`drain_ready`) | ~40 lines | Async Agent Mode currently talks over itself and the user |
| 3 | Proactive turn primitive | **done** | 3 of 4 guards already existed; the 4th (sticky-flag handling) had two real defects. See §12.12 |
| 4 | Cache-stable ordering audit | trivial | No clock in the system prompt, per-turn notes in the tail. Direct billing impact under the SDK-first money rule |
| 5 | Wire up Deepgram's discarded turn frames | trivial | `SpeechStarted`/`UtteranceEnd` are decoded and `print`ed with no handler (`DeepgramStreamingTranscriptionProvider.swift:205-209`) — free signals already on the wire |
| 6 | ~~300 ms in-WAV tail padding~~ | — | **DROPPED — measured no effect.** See §12.10 |

Items 1–4 are lifted from 01's top 7. Item 5 is an OpenClicky-specific find
from 02. Item 6 becomes load-bearing once E4B receives audio.

---

## 3. Prerequisite fixes

Some are hard blockers for the router; the rest are bugs 02/03 surfaced
along the way. Listed separately so the router's critical path is clear.

### Blockers for Layers B and C (the E4B layers)

| Fix | Why | Ref |
| --- | --- | --- |
| `capturedPCM16` accessor on `BuddyStreamingTranscriptionSession` | Raw buffers are dropped immediately after forwarding — the router has no way to obtain audio today | `BuddyDictationManager.swift:806-813` |
| `LLMRequest.audio: LLMAudioInput? = nil` | Default value is **mandatory** — without it all six dispatch hooks break | `LLMClient.swift:~24-48` |
| `LLMCapabilities.audio` bit at `1<<5` | Lets the pipeline ask whether a client can take audio | 02 extension points |

### Blocker for Layer A

| Fix | Why | Ref |
| --- | --- | --- |
| `usesWakeWord` → explicit allowlist | Currently `self != .pushToTalk`, so a new `.smartTurn` case would silently arm the wake-word listener | `OpenClickyWakeWordManager.swift:42` |

### Independent bugs (ship anytime)

| Bug | Impact | Ref |
| --- | --- | --- |
| xlb index never populates | `startWatchingIfEnabled()` has zero callers and there is no launch sync — `[xlb-context]` is **never produced in production** | `XLBTopicIndex.swift:1376` |
| `openclicky.xlb.enabled` default differs by lane | `false` in one place, `true` in the other | `AppBundleConfiguration.swift:253` vs `CompanionManager.swift:5847` |
| Camera frames not downscaled | Ship at native `.high` while screenshots clamp to 1280 — one frame can cost more than both displays | 03 |
| App "skills" are a hardcoded 10-app Swift table | Bundled skills in `AppResources` have **zero** voice-lane effect; also the only text source with no size cap | `OpenClickyAppSkillContext.swift:97-385` |

The xlb one is worth noting for expectation-setting: topic context you
believed was being injected has in fact always been empty.

---

## 4. Layers B and C — translate, then read the screen

### 4.1 Context budget is separate, and this is not negotiable

03 measured the answerer's context at **6500 tok text-only / 8100 with a
screenshot / 13500 worst case**. Parlor's ~1.3 s figure for e4b was measured
at roughly a tenth of that. Prefill time scales with input, so reusing
`dynamicVoiceResponseSystemContext()` for the router would make triage
slower than simply asking Claude.

The router needs only what triage needs:

| Source | Answerer | Router |
| --- | --- | --- |
| Audio | ✓ | ✓ |
| Current screenshot | ✓ | ✓ |
| Last 2–3 turns | ✓ | ✓ (summarised) |
| LTM 6000 chars | ✓ | ✗ |
| stash | ✓ | ✗ |
| xlb topics | ✓ | ✗ |
| app skill hints | ✓ | ✗ |
| screen-history OCR | ✓ | ✗ (it reads the *pixels* on demand instead) |
| runtime storage map | ✓ | ✗ |

> **Rev 3 correction.** The "~50 tokens per screenshot" figure below was
> wrong. Measured `prompt_tokens: 296` for one image plus a short question
> — matching `pipeline.py`'s own `IMAGE_TOKENS = 300`, not camerabench's
> 50, which turns out to be a policy parameter rather than a measurement.
>
> Also: sending a larger image buys nothing. 3456 px and 1280 px both
> reported 296 tokens, because the server downscales to 224 either way.
> The extra bytes are pure upload cost.

Revised target: **~800-900 tokens** — routing prompt ~300, recent-turn
summary ~200, screenshot **~300**, audio ~32 tok/s.

In practice this budget matters less than feared. The measured latencies
(§12) are 315 ms for text-in translation and 382 ms for a legibility call,
both well inside any reasonable gate, so the constraint that actually binds
is the `--reasoning off` flag rather than context size.

Two further reductions, both from Parlor:

* **Prefix caching** — the routing system prompt is static, so llama.cpp's
  KV cache makes it a one-time cost.
* **Speculative prefill** — push the screenshot and recorded audio segments
  while the user is still speaking; on release only the tail remains. PTT
  suits this naturally. 01 rates this HIGH effort (needs KV-cache control),
  so treat it as a later optimisation, not part of the first cut.

### 4.2a Gate A results (measured 2026-08-08)

Harness: `scripts/run-gate-a-routelet-tests.sh`, corpus
`scripts/gate-a/corpus.json`, n=32 balanced across the four intents. Runs
the shipped `OpenClickyIntentClassifier` unmodified except for a build-time
ONNX module-name rewrite (see the script header for why that rewrite is
mandatory, and why arm 4 exists to catch its absence).

| arm | accuracy | none-rate | mean conf |
| --- | --- | --- | --- |
| 1 zh-raw (deictic Chinese) | **0.0%** | 100% | 0.990 |
| 2 zh-grounded | **0.0%** | 87.5% | 0.980 |
| 3 en-grounded | **81.2%** | 0% | 0.976 |
| 4 en-raw (control) | 84.4% | 0% | 0.988 |

Per-intent, arm 3: chat 75%, find_action 100%, integration 100%,
memory 50%.

**Three findings.**

**Chinese is unsalvageable by rewriting alone.** Arms 1 and 2 both score
zero. Turning 点这个 into 点击 Spotify 播放器里的播放按钮 moves nothing.
The binding constraint is the English vocabulary, not ambiguity. Note arm 1
rejects every single Chinese input at 0.99 confidence — it is confidently
wrong, not uncertain.

**Translating to English works.** 81.2% against an 84.4% control is
within normal variance of the model's own domain. The route the user
proposed — have the frontend emit English — is supported by measurement.

**Rewriting is free.** Arm 3 ≈ arm 4 means the explicit phrasing a
frontend model produces does not confuse the classifier relative to
naturally-written English.

**Consequence for §4.2 below:** E4B's contribution to routing is
**translation**, and grounding rides along at no cost. The section's
framing of E4B as a grounder is retained because grounding is still what
makes the English *correct*, but it is not what unlocks the accuracy.

**Also relevant to the "retrain on a multilingual base" option:** that path
is now optional rather than necessary. routelet's training data lives in a
private Cloudflare R2 bucket (`.dvc/config` → `s3://aegis-routelet-samples`)
with no published credentials, so a retrain means synthesising a corpus from
scratch — 3-5 days, and likely worse than the original 110k-line augmented
set. Revisit only if the E4B dependency proves unacceptable.

**Caveat:** n=32, single author, hand-written Chinese. The zero is
unambiguous, but the 81.2% figure has wide error bars. It should be
re-measured on real transcripts before anything depends on the precise
number.

### 4.2 Division of labour with routelet

E4B **does not emit intent labels.** It is not a classifier: no calibrated
confidence, and output drifts with temperature. routelet is purpose-trained
(4 classes + reject, sub-100 ms) and stays the classifier.

Measured pipeline (§12.7):

```
audio ──→ whisper ──→ accurate Chinese ──→ E4B translate ──→ routelet
            CER 0.000                        8/8, 315 ms      87.5%, <100 ms
                                                                  (intent)
screenshot ──────────────────────────────→ E4B ──→ legible?  + which element
                                                    0 fabrications, 8/8
                                                            │
                                        legible → local     │  not → Claude
```

Two questions go to E4B and they are **orthogonal to intent**, which is
exactly why both layers are needed rather than one:

| utterance | routelet intent | legible? | destination |
| --- | --- | --- | --- |
| 点这个提交按钮 | find_action | yes | local |
| 点终端里那个报错行 | find_action | **no** | Claude |
| 这个按钮干嘛的 | chat | yes | local |
| 这报错什么意思 | chat | **no** | Claude |

Same intent, opposite destination. routelet cannot make that call — it
never sees the screen. E4B cannot make the intent call reliably — it is not
calibrated. Neither subsumes the other.

`none` is *not* the handoff signal it was assumed to be in revision 1. On
Chinese, routelet returns `none` at 0.99 confidence for **every** input
regardless of content (§4.2a), so `none` carries no information until after
translation. Post-translation it becomes meaningful again.

### 4.3 Where it attaches

02's recommendation, which is better than adding a provider case: **decorate
`LLMClient`.** A decorator composes with all six existing adapters and
preserves the SDK-first money rule without touching the registry's branching.

Caveat from 02 that changes the picture: **only `mirage` traverses all eight
stages.** `heyclickyFree` on its default speech model routes straight to a
24 kHz WebSocket (`shouldRoutePTTToHeyClickyRealtimeSession`), bypassing
`BuddyDictationManager`, `LLMRequest`, and `StreamingTTSSession` entirely;
`ski` returns `""` from `_analyzeVoiceResponseCore` and answers through
`.oc/*.jsonl`.

So a decorator at the `LLMClient` seam reaches **mirage only**. Extending to
the other two means either intercepting earlier (before profile dispatch) or
accepting mirage-only for v1. **Recommend mirage-only for v1** — it is the
profile you use for testing anyway, and it avoids touching two lanes that
have their own transports.

### 4.4 Simple-answer boundary

Revision 1 drew this line by guessing which questions are "simple". The
measurements draw it somewhere else: **the boundary is legibility, not
complexity** (§12.4).

E4B answers when the target is a distinct control it can see —
buttons, tabs, menu items, fields, toggles, icons. Measured 8/8 grounding
with zero invented elements.

E4B defers when the target is dense text (terminal, code, logs, stack
traces, paragraphs, fine print), when the question is open-ended
enumeration, or when any reasoning is required.

Two rules, both from observed failures rather than caution:

* **Never ask it to enumerate.** "List everything on screen" produced 26
  labels of which 12 were absent, and the invented ones were old macOS menu
  names — it recites priors instead of admitting blindness. 54% precision.
* **Ban dense-text regions by category, not by inspection.** Told to judge
  for itself, it "read" a terminal line and returned a command genuinely
  typed minutes earlier: plausible, specific, fabricated. The categorical
  ban took false-positives 1 → **0** and latency 1520 ms → **382 ms**.

Bias conservative on the remaining ambiguity: two of twelve legibility
calls were false-*illegible* (punted something it could see). That costs
one round trip. The opposite error costs the user a fabricated spoken
answer, so the asymmetry is correct as tuned.

### 4.5 Transcription: STT transcribes, E4B never does

> **Rev 3: this section is reversed.** Revision 1 defaulted to running both
> in parallel and preferring E4B's transcript for downstream reasoning.
> Measurement says the opposite — E4B's Chinese ASR is materially worse and
> its errors propagate into routing (§12.3).

```
PTT down
  └─ STT (whisper / Deepgram) → accurate Chinese ──→ E4B translate → routelet
       streaming partials to the bubble               315 ms         87.5%
```

E4B receives **text, not audio**. The whole reason:

| | CER | note |
| --- | --- | --- |
| whisper large-v3-turbo | **0.000** | 4/4 exact |
| E4B on the same clips | 0.138 | errors on word-final characters |

And they do not stay local. 并发 → 病发 → "Search Swift illness onset" →
whatever routelet makes of that. One mis-heard character becomes a wrong
route.

Given correct text, E4B's translation was **8/8** and routelet scored the
same 87.5% on its output as on hand-written English. The weakness is its
ears, not its Chinese.

Parlor's 300 ms in-WAV tail padding (`pipeline.py:TAIL_SILENCE_S`) was
tried against this and did not help — that technique fixes VAD-truncated
audio, and these fixtures were complete recordings.

**E4B-as-transcriber should not be offered as a setting.** It is strictly
worse on this language and the failure is silent.

---

## 5. Layer D — context curation

> **Rev 3: renumbered (was Layer C) and downgraded to speculative.** The
> §12 gates covered translation, legibility and grounding on the *live*
> screen. None of them tested curation. Everything in this section is still
> a hypothesis, and the failure mode described below is the reason to treat
> it as one.
>
> Note also that the strongest version of this idea — semantic search over
> screen-history frames — is the one thing here that nothing else can do
> (§0, "The screen-history opportunity"), and it is also completely
> untested. It deserves its own gate before any of this is built.

Once B and C work, E4B's larger contribution is preparing context for the
backend rather than triaging it.

Today every source is injected indiscriminately. Curated:

| Today | After |
| --- | --- |
| Screenshot base64 (Claude looks itself) | "User means the 『提交』 button, top-right, (1240, 88)" |
| 20 screen-history OCR snippets, 160 chars each | "『刚才那个』 = the Figma mock from 8 min ago, showing …" |
| LTM 6000 chars verbatim | "Relevant memory: this project uses SwiftUI (said last week)" |
| Transcript "点这个" | "点击右上角提交按钮" |

### The failure mode to design against

If E4B curates wrongly, Claude is blinded — and *does not know* it is
missing something. That is worse than too much context. Three guards:

1. **Add, don't subtract.** The curated package is appended to existing
   context, not substituted for it. Correctness beats token savings.
2. **Degradable.** Ship a `confidence`; below threshold, fall back to full
   injection.
3. **Pointers, not prose.** Emit "memory entry #47 relevant", not the text.
   Claude fetches via MCP if it wants it.

Guard 3 is the cleanest, and OpenClicky already has the pattern:
`buildSKIUtteranceContext` (`CompanionManager.swift:5783-5926`) ships
pointers plus MCP tool names rather than inlining. Layer D should follow
that assembler, not the inline one in `_analyzeVoiceResponseCore`.

---

## 6. Settings surface

Two places, mirroring how Whisper local already works (its own manager, an
entry in the STT picker, a settings group in the SKI panel).

### New tab: "Local Frontend"

Component-level configuration, profile-independent:

```
Model
  ├─ Gemma 4 E4B          [ Download ]  3.4 GB + mmproj
  ├─ Status / progress                  ← OpenClickyLocalModelStatus
  └─ Memory footprint note

Behaviour
  ├─ Transcription source:  ( ) STT only  ( ) E4B only  (•) Both
  ├─ Allow self-answer:     [x]
  ├─ Self-answer threshold: [────●────]
  └─ Router context budget: [ 650 ] tokens

Multimodal inputs
  ├─ Current screenshot     [x]
  ├─ Camera                 [ ]
  └─ Screen-history frames  [ 0 ]  (0–20)
```

### Per-profile: one picker row

```
Frontend router:  [ None (direct) ▾ ]
                    None (direct)
                    Gemma 4 E4B
```

Defaults: **None** for all three profiles. Opt-in only until Gate B passes.

### Activation mode (all three panels)

smart-turn adds one case, alongside the existing ones:

```
Activation:  [ Tap to talk (auto-stop) ▾ ]
             ├─ Push to talk
             ├─ Tap to talk (auto-stop)   ← new, smart-turn driven
             ├─ Toggle listening
             └─ Always listening

  └ Turn sensitivity  [────●────]      ← only in auto-stop
    Max wait          [ 2.5 s ]        ← Parlor's flush timer
```

### Persistence

The override system built earlier covers this:

```swift
enum OverrideField: String {
    case stt, tts, responseModel, agentModel, ttsVoice, activationMode
    case frontendRouter        // new
}
```

Add the case, add a branch in `applyOverrides`, and copy
`setTTSProviderPreservingOverride` into
`setFrontendRouterPreservingOverride`. Profile-switch persistence is free.

---

## 7. Sequencing and gates

Each phase has a numeric gate. Failing a gate stops the phase — that is the
point of ordering it this way.

### Phase 0 — quick wins + prerequisites (~1 week)

§2 items 1–6, plus the two blockers and the four independent bugs from §3.
None of this depends on E4B, so none of it is wasted if later gates fail.

### Phase 1 — smart-turn-v3 (34 h, plan in 04)

Ships independently of the router. Fixes the known pain: SKI hands-free pays
a flat 2 s hangover every turn (`SKIModeHandsFreeSession.swift:60-64`) and
misfires on any thoughtful pause; PTT requires holding the chord.

Watch the traps 04 catalogued — a naive port hits all five:

* Left-padding (utterance right-aligned), not right
* Periodic Hann window; `vDSP_hann_window` gives the symmetric one
* `n_fft=400` is not a power of two → `vDSP_DFT_zop_CreateSetup`, not `vDSP.FFT`
* Dynamic-range clamp uses a **global** max over 80×800, not per-frame
* Sigmoid is baked into the ONNX graph — do not add another

Also: `SileroVADTrim.speechOnly` (`SileroVADTrim.swift:41`) is dead code with
zero callers and needs promoting to a streaming frame tagger to act as the
trigger.

**Gate 1:** Chinese end-of-turn accuracy on real recordings. 04 flags that
smart-turn's published numbers come from its own test split, LiveKit's
eot-bench scores it far more harshly, and **the non-English clips are almost
entirely synthetic**. Chinese quality is unmeasured. Collect ~50 real Chinese
utterances (including mid-thought pauses) and measure. Below ~0.85 → keep it
opt-in and English-only rather than making it a default.

### Phase 2 — offline validation — **DONE** (2026-08-08)

Ran against the real model rather than Parlor. Full results in §12;
harnesses in `/tmp/gateBC/run3.py` … `run8.py`.

| gate | asked | result |
| --- | --- | --- |
| A | does rewriting help routelet? | **PASS** — but not for the predicted reason. English is the win, deixis is not (§4.2a) |
| B | fast enough? | **PASS** — 315-600 ms, once `--reasoning off` is set |
| C | Chinese audio usable? | **FAIL** — CER 0.138 vs whisper 0.000. Architecture changed in response (§4.5) |
| E | does it admit blindness? | **PASS** — 0 fabrications after the categorical dense-text ban |
| F | grounding correct when it accepts? | **PASS** — 8/8, 0 invented |
| G | worth it vs an OCR baseline? | **PASS** — ~56% of cases only E4B solves |

Gate C failing did not stop the plan; it moved transcription to whisper and
left E4B doing text-in translation, which it does at 8/8.

**Still ungated: screen-history search.** See §10.

### Phase 3 — Layers B and C (mirage only)

Runtime decision first (§10), then blockers from §3, the `LLMClient`
decorator, the settings tab, the per-profile picker.

**Gate 3** is largely pre-satisfied by Gates E and F, which measured
exactly this: zero fabrications, zero invented elements. What remains is
the same measurement on *live* turns rather than fixtures — real
screenshots, real utterances, the actual prompt as shipped.

The bar stays **zero wrong self-answers**. One confidently wrong spoken
reply is worse than ten unnecessary Claude calls.

### Phase 4 — curation

Only after Phase 3 is stable. Start with screen-history frames (the
`jpegBase64_1280` field nobody reads), since that is the biggest win and the
one Claude structurally cannot do.

**Gate 4:** backend answer quality must not regress. Run both curated and
full-context paths on the same scenarios and compare.

---

## 8. Open risks

Rev 3 — resolved risks struck through, new ones added.

| Risk | Severity | Status |
| --- | --- | --- |
| **No local inference runtime exists** | **High** | **OPEN, uncosted.** Larger than anything else here. Blocks Layers B/C/D entirely (§10) |
| Screen-history search unvalidated | **High** | **OPEN.** The strongest remaining argument for the model, never tested (§0) |
| ~~E4B Chinese audio quality unmeasured~~ | ~~High~~ | **Measured, failed.** CER 0.138. Resolved by moving ASR to whisper (§4.5) |
| ~~Grounding may not help routelet~~ | ~~High~~ | **Measured.** Grounding does nothing; *English* does. 0% → 87.5% (§4.2a) |
| Model size / memory | **Medium** | 6.1 GB, not the 3.4 GB rev 1 assumed, plus resident memory alongside the app. Rev 1 rated this Low — wrong |
| smart-turn Chinese accuracy unmeasured | Medium | Gate 1 still pending; opt-in if weak |
| E4B fabricates instead of escalating | Medium | Measured 0 after the categorical ban — but on 12 fixtures. Re-measure on live turns |
| Curation blinds the backend | Medium | Layer D is now explicitly speculative (§5) |
| Spatial reasoning imperfect | Low | "top item in the sidebar" → answered with the window title |
| ~~Prefill slower than Parlor's numbers~~ | ~~Medium~~ | **Measured.** 315-600 ms. The binding constraint was the reasoning flag, not context size |

Both High risks are now *engineering* questions rather than *feasibility*
questions — the concept is validated, the delivery path is not. The runtime
decision should come first because it determines whether the rest is weeks
or months.

---

## 9. What is explicitly out of scope

* **Fourth all-local profile** — user decision. The router is a layer.
* **Replacing any existing LLM / TTS / STT / Agent** — those stay; the router
  sits in front.
* **Speculative prefill** in v1 — needs KV-cache control; revisit if a local
  sidecar ships.
* **Full-duplex** — Parlor's author tried fine-tuning Gemma 4 for it
  (grafting a decision tick + speech head) and failed after multiple
  attempts, then reverted to a classic cascade. Not attempting it.
* **Kokoro TTS** — OpenClicky has six TTS backends already.
* **heyclickyFree / ski router coverage** in v1 — those lanes have separate
  transports (§4.3).

---

## 10. Immediate next step

> **Rev 3: superseded.** Gates A, B, C, E, F and G have all run — see §12.
> The verdict is that the concept holds, with a materially different
> division of labour than this plan originally proposed.

Three things are now blocking, in order:

**1. Decide on the runtime.** OpenClicky cannot host a GGUF today. Nothing
in Layers B, C or D can ship until that is resolved, and it is uncosted
here. The realistic options — vendoring llama.cpp as a dylib (whisper.cpp
sets the precedent), spawning `llama-server` as a bundled sidecar (the app
already spawns six runtimes; `06` found this is *not* a policy violation,
the real cost is signing), or MLX Swift (cleanest, but Gemma 4 audio/vision
projector support is unverified) — differ by weeks of work. This decision
gates everything else.

**2. Gate the screen-history use case.** It is the strongest remaining
argument for the model (§0) and the only one still completely untested. If
E4B can find "the frame with the error dialog" across twenty history JPEGs,
that is a capability nothing else in the stack has. If it cannot, Layer D
should be dropped and the case for 6.1 GB rests on Layers B and C alone.

**3. Ship Phase 0 regardless.** §2's six quick wins and §3's bug fixes have
no E4B dependency, and two of them (the camera downscaling bug, the CJK
tokenizer) are live defects affecting users today.

The Gate A harness (`scripts/run-gate-a-routelet-tests.sh`) should stay in
the repo as a regression test — routelet accuracy is now a measured
property with a known baseline, and the control arm will catch the ONNX
module-name breakage class if it ever recurs.

---

## 11. Runtime findings (2026-08-08, during Gate B/C setup)

Recorded here because several assumptions in §4 and §8 turned out to be
wrong once the model was actually fetched.

### 11.1 A local inference runtime is now installed

`brew install llama.cpp` → build **10280**. Parlor enforces a floor of
b9503 for Gemma 4 audio support (`llama.py:MIN_BUILD`), so this clears it
with room. `llama-server --help` confirms `--mmproj` / `--mmproj-url`
present, i.e. the multimodal path is compiled in.

This does **not** close the gap `06-plan-review.md` raised — OpenClicky
itself still has no way to host a GGUF. It only means the *measurement*
can proceed outside the app.

### 11.2 The mmproj really does carry an audio encoder

Read directly out of the GGUF header rather than trusting documentation:

```
clip.has_vision_encoder = True
clip.vision.projection_dim = 2560, image_size = 224, patch_size = 16,
clip.vision.block_count = 16, projector_type = gemma4v

clip.has_audio_encoder  = True
clip.audio.projection_dim = 2560, embedding_length = 1024,
clip.audio.block_count = 12, num_mel_bins = 128, projector_type = gemma4a
```

Audio is confirmed at the binary level. That was the single capability
with no substitute in OpenClicky's existing stack, so it is the load-
bearing fact for the whole frontend-router idea.

### 11.3 New concern — vision is 224 px, patch 16

`clip.vision.image_size = 224` means a 1280-px screenshot is downscaled to
224×224 before the vision tower sees it. §4.1 budgeted ~50 tokens per
screenshot and treated "it can see the screen" as settled; at 224 px, fine
UI detail (small button labels, code in an editor, dense menus) may simply
not survive.

This matters most for exactly the case the plan leans on hardest —
resolving 点这个 by reading the button caption. **Add to Gate 3: verify
the model can name a specific small UI element from a real screenshot, not
just describe the scene.** If it cannot, the grounding story is weaker
than §0 claims and E4B's value narrows toward audio + translation only.

### 11.4 Model size, corrected

| file | size |
| --- | --- |
| `gemma-4-E4B_q4_0-it.gguf` | 5.15 GB |
| `gemma-4-E4B-it-mmproj.gguf` | 0.99 GB |
| total | **6.1 GB** |

§6 said "3.4 GB + mmproj" and §8 rated model size a *Low* risk. 6.1 GB of
opt-in download, plus the resident memory to run it alongside the app, is
not Low. Revise that row.

(An intermediate figure of 17 GB appeared in the working notes; that was a
measurement error on my side — two `curl` invocations' output concatenated
— not a real size. The authoritative numbers are from the HF blobs API.)

### 11.5 Fetching over a flaky proxy — for whoever automates this

Two download strategies failed in ways worth writing down, because a
download step will eventually live in `OpenClickyLocalModelDownloadService`:

* `curl -C - --retry-all-errors` **truncates on retry**. Observed the file
  go 2.99 GB → 2.13 GB. curl's internal retry can restart from a stale
  offset and rewrite from there. Never combine curl-internal retries with
  `-C -` for large files.
* `huggingface-cli` writes a `.incomplete` temp and moves it atomically —
  good — but **deletes the temp when the connection breaks**, losing all
  progress. Fine on a stable link, wrong for this one.

What works: one `curl -C -` attempt per outer-loop iteration, no internal
retries, `--speed-limit`/`--speed-time` to kill stalled sockets, and an
explicit check that the file never shrinks (abort if it does rather than
ship a corrupt GGUF). Script at `/tmp/dl_e4b.sh` for reference.

Any in-app downloader needs the same shrink guard plus a final size or
hash check — a silently truncated 5 GB GGUF fails at load time with a
confusing error, far from its cause.

---

## 12. Gate results (measured 2026-08-08)

Everything below is from running the real model on this machine, not from
Parlor's published figures. llama.cpp b10280, Gemma 4 E4B q4_0 + mmproj,
`--reasoning off --reasoning-budget 0`, M-series.

Harnesses live in `/tmp/gateBC/` (run3.py … run8.py) and
`scripts/run-gate-a-routelet-tests.sh`.

### 12.1 Summary

| Gate | What it measures | Result |
| --- | --- | --- |
| A | routelet accuracy on English rewrite | **87.5%** — equals the hand-written ideal |
| B | latency, thinking disabled | **315-600 ms** PASS |
| C | Chinese ASR | **CER 0.138** — worse than whisper's 0.000 |
| E | legibility self-judgement | 83%, **0 fabrications** after prompt fix |
| F | grounding accuracy when it accepts | **8/8**, 0 invented elements |
| G | vs deterministic OCR baseline | **~56%** of cases only E4B can solve |

### 12.2 The thinking flag is load-bearing

Default (`--reasoning` unset) the model spends its entire token budget on a
visible reasoning trace before emitting content. Measured 6715 ms mean, and
with `max_tokens: 60` it produced **empty `content` on every clip** — the
budget ran out mid-thought. That looked exactly like "the model cannot do
this" and cost a full debugging cycle.

With `--reasoning off --reasoning-budget 0`: **470 ms**, a 14× difference.

Any integration must set this. It is not tuning, it is the difference
between usable and not.

### 12.3 E4B must not do Chinese ASR

| clip | reference | E4B heard | CER |
| --- | --- | --- | --- |
| 1 | 点击右上角的提交按钮 | 点击右上角的提**焦**按钮 | 0.100 |
| 2 | 这个报错是什么意思 | (exact) | 0.000 |
| 3 | 记一下我喜欢深色模式 | **记住**我喜欢深色模式 | 0.200 |
| 4 | 帮我搜索一下 Swift 并发 | 帮我**收**索一下 Swift **病发** | 0.154 |

whisper large-v3-turbo scored 0.000 on the same four, warm ~1100 ms.

The errors are systematically on word-final characters, and they propagate:
并发 → 病发 → "Search Swift illness onset" → routing garbage. Parlor's
300 ms in-WAV tail padding (`pipeline.py:TAIL_SILENCE_S`) was tried and did
not help — that technique addresses VAD-truncated audio, and these fixtures
are complete.

**Whisper transcribes, E4B translates.** Given correct Chinese text, E4B's
translation was 8/8 and routelet scored the same 87.5% on its output as on
hand-written English. The weakness is its ears, not its Chinese.

### 12.4 Vision works, but only for closed questions

Earlier notes in §11.3 worried that 224 px would defeat UI reading. A
controlled test says otherwise — synthetic button labels at 72/32/**14** px
(≈2 px after downscale) were read correctly, **6/6, both scripts**.

The real split is by question type, not by pixel size:

| Question shape | Result |
| --- | --- |
| "Is there a Bluetooth item?" | correct, and correctly says *no* for absent items |
| "Where is the search box?" | correct position and placeholder |
| "Which element do they mean?" | 8/8 grounding, 0 invented |
| **"List everything on screen"** | **54% precision** — filled the rest from priors |
| **Dense text (terminal, code)** | **fabricates** |

On a real System Settings capture, asked to enumerate, it produced 26
labels of which 12 were not present — and the invented ones were *old macOS
menu names*. It was reciting, not reading.

Two rules follow, and they are hard constraints on any prompt built here:

1. **Closed questions only.** Never ask it to enumerate.
2. **Ban dense-text regions categorically, not by inspection.** Told to
   judge for itself, it "read" a terminal line and returned a command that
   had genuinely been typed minutes earlier — plausible, specific, and
   fabricated. Adding "terminals, consoles, logs and editors are off-limits
   regardless of how readable they look" took false-LEGIBLE from 1 to **0**
   and latency from 1520 ms to **382 ms**.

### 12.5 What E4B is actually worth — vs an OCR baseline

The honest alternative is macOS Vision OCR (text + boxes, zero new
dependency, ~0 ms) plus fuzzy matching. Head-to-head on 16 utterances:

| family | OCR | E4B | |
| --- | --- | --- | --- |
| literal ("click the Wi-Fi row") | 4/4 | 4/4 | baseline suffices |
| **crosslang** (Chinese → English UI) | **0/4** | **4/4** | only E4B |
| spatial ("the one below Wi-Fi") | 3/4 | 4/4 | E4B slightly ahead |
| **nontext** (arrows, toggles, close) | **0/4** | **4/4** | only E4B |

> Scoring correction. The harness initially reported nontext as OCR 4/4 and
> E4B 1/4 — both wrong, in opposite directions. For cases with no fixed
> answer the judge only checked "is this a real on-screen string", so OCR
> passed by returning junk it had matched (`(ctrl+b to run i`, `openclicky`).
> E4B meanwhile answered "Back arrow", "Close button", "Toggle switch" —
> correct descriptions that failed the check precisely *because* they are
> not OCR text. Corrected by hand above.

**~56% of these utterances are solvable only by E4B.** The two structural
wins:

* **Cross-language grounding.** A Chinese utterance against an English UI
  has no string bridge. OCR cannot span it at any level of cleverness. This
  is the primary daily case for this user.
* **Non-text controls.** Icons, toggles, unlabelled buttons simply do not
  exist to OCR.

Add the property that makes high-frequency use viable at all: local
inference has no per-call cost, so the screen can be interrogated
repeatedly. That is what makes "scan 20 history frames for the one with an
error dialog" tractable — Claude cannot afford it (thousands of tokens,
seconds) and OCR cannot do it (no semantics).

Not everything is a win: asked for "the top item in the sidebar" it
answered "System Settings", the window title. Spatial reasoning is
imperfect.

### 12.6 Why Parlor's demo looks better than these numbers

Both are true; the tasks differ.

| | Parlor | here |
| --- | --- | --- |
| vision input | **320 px webcam of a face** | 1280 px screenshot |
| vision task | "describe what you see" | read labels, locate elements |
| language | English | Chinese |

Parlor never asks the model to read small text or find UI controls. At
320 px of a face, 224 px is plenty. Its audio is English, and Gemma 4's
English ASR is a different proposition from its Chinese.

### 12.7 Revised architecture

```
audio ──→ whisper ──────→ accurate Chinese ──→ E4B translate ──→ routelet
                                                     │              (intent)
screenshot ─────────────────────────────────→ E4B ───┤
                                                     └→ legibility + grounding
                                                            │
                                    legible → handle locally │ not → Claude
```

Division of labour, each line backed by a measurement above:

| job | owner | why |
| --- | --- | --- |
| Chinese transcription | whisper | CER 0.000 vs 0.138 |
| Chinese → English | E4B | 8/8, 315 ms |
| intent | routelet | 87.5%, calibrated, <100 ms |
| "can I see the target?" | E4B | 0 fabrications; routelet cannot see |
| grounding a reference | E4B | 8/8; OCR fails cross-language and non-text |
| dense text, reasoning | Claude | E4B fabricates |

Total ≈ 1.8 s, entirely local, no quota.

Note the two E4B questions are **orthogonal to intent**, which is why both
layers are needed rather than one:

| utterance | intent | legible? | goes to |
| --- | --- | --- | --- |
| 点这个提交按钮 | find_action | yes | local |
| 点终端里那个报错行 | find_action | no | Claude |
| 这个按钮干嘛的 | chat | yes | local |
| 这报错什么意思 | chat | no | Claude |

Same intent, opposite destination. routelet cannot make that call — it
never sees the screen.

### 12.8 Corrections to earlier sections

* §4.1's "~50 tokens per screenshot" is **wrong**. Measured
  `prompt_tokens: 296` for one image plus a short question, matching
  `pipeline.py`'s own `IMAGE_TOKENS = 300`. The 50 came from camerabench,
  where it is a policy parameter, not a measurement. Router budgets built
  on 50 need redoing.
* Sending a larger image does not help. 3456 px and 1280 px both reported
  296 prompt tokens — the server downscales to 224 either way, so the extra
  bytes are pure upload cost.
* §11.3's concern that 224 px defeats UI reading is **withdrawn** (see
  §12.4). The limit is text density, not glyph size.

### 12.9 Privacy — a third structural advantage, stated precisely

Local inference is not just cheaper vision, it changes what may be shown to
a model at all. But the claim has to be narrow or it is false.

**Not** "sensitive data never leaves the machine." E4B cannot answer
everything; anything it cannot handle must still go to Claude, or the
utterance goes unanswered. Withholding it is not an option.

**What is actually true:** the *volume and form* of what leaves becomes a
decision rather than an all-or-nothing default.

Today there are two states, and no middle:

| today | consequence |
| --- | --- |
| screenshot attached | the entire screen goes to Claude |
| no screenshot | nothing visual can be answered |

With a local model in front, a third state exists:

| E4B verdict | what leaves the machine |
| --- | --- |
| legible, answerable locally | **nothing** |
| legible, needs reasoning | a one-line description, not pixels |
| not legible (dense text) | the screenshot — unavoidable |

Mapped onto the §12.5 measurements: of those 16 utterances, the 12 in
literal + crosslang + nontext resolve locally with **zero egress**. Only
the dense-text and reasoning cases require the image, and even some of
those can travel as "the user means the Submit button on the login form"
instead of 164 KB of base64.

So the honest framing is **egress becomes granular**, not eliminated. The
third row is a genuine gap and should be documented as one.

#### The use case this unlocks

User-designated private regions — a banking app, a password manager, a DM
window. Inside those, if E4B can answer, it answers and nothing is sent. If
it cannot, the correct behaviour is to *ask*:

> "I can't read that clearly. Send this screen to the cloud model?"

That prompt is the feature. Today the architecture cannot offer it: vision
is either on (whole screen uploaded) or off (feature unavailable). A local
model is what makes a per-turn, per-region choice possible.

Consequences for the design:

* Private-region marking belongs in the settings surface (§6) — per app or
  per window, alongside the existing multimodal input toggles.
* The escalation path needs a user-visible branch when the target region is
  marked private, rather than silently attaching the screenshot.
* The camera downscaling bug from `03-openclicky-context-injection.md`
  (frames ship at native `.high` while screenshots clamp to 1280) is worse
  than a cost bug under this lens — it is the largest single payload
  currently leaving the machine. Fix it regardless of whether the router
  ships.

### 12.10 300 ms tail padding does not transfer (quick win #6, dropped)

Parlor appends 300 ms of silence inside the WAV before inference
(`pipeline.py:TAIL_SILENCE_S`). §2 listed porting it as a one-line quick
win on the theory that it fixes end-of-word hallucination in any
audio-to-model path.

Measured against whisper.cpp large-v3-turbo-q5_0 (the model OpenClicky
actually ships), four Chinese fixtures, three truncation levels:

| condition | raw | +300 ms pad |
| --- | --- | --- |
| complete recording | 4/4 exact | 4/4 exact, **byte-identical** |
| cut 200 ms (simulated tight VAD) | 4/4 exact | identical |
| cut 500 ms | 3/4 — #4 loses 并发 | identical, still loses 并发 |

Zero difference in twelve comparisons. At 500 ms the final word is
genuinely absent from the samples, and padding cannot invent it — the
correct outcome, and evidence the test had teeth.

The reason it does not transfer: whisper.cpp already pads every input to
its 30 s mel window internally, so appending silence changes nothing about
what the encoder sees. Parlor's gain came from Gemma 4's *native audio*
encoder, which has no such window and does react to an abrupt tail.

This also retroactively explains an earlier negative result: the same
technique was tried against E4B's Chinese ASR (§12.3, CER 0.138) and did
not help there either — because those fixtures were complete recordings,
not VAD-truncated ones. Two different reasons, same non-effect.

Note `WhisperLocalTranscriptionProvider.trimTrailingSilence` already exists
and is deliberately bypassed, with a comment saying the Whisper 1.9.1
baseline transcribes raw PCM correctly. That judgement is confirmed.

### 12.11 Modes-as-data already exists (quick win #1, dropped)

§2 proposed porting Parlor's `modes.py` shape — a flag table plus
clear-state-on-switch — on the assumption that OpenClicky's modes were
implicit. They are not.

`OpenClickyProfile` (`OpenClickyProfile.swift:20`) is exactly that table:
`sttProvider`, `responseModelID`, `ttsProvider`, `activationMode`,
`ttsVoiceID`, `agentModelID`, six profiles in the catalog, plus a
`resolvedOverrides(for:)` layer that lets the user override any single
field per profile without forking the profile.

`applyProfile` (`CompanionManager+Profiles.swift:21`) is the switch
handler, and it already does the teardown the plan asked for — that was
FIX(task #310), which fixed exactly the leak this quick win describes:
HeyClicky Free's WebSocket, plan poller and token-refresh loops used to
keep running after a switch to SKI Mode.

The one thing that looks like a gap is the per-id `if switchingInto...`
chain, which has start/stop for HeyClicky but only a start for mirage.
Checked: `MirageDeepgramClient.warm()` and `MirageCartesiaClient.warm()`
pre-mint tokens and pre-open TLS. Neither starts a timer, loop or socket,
so there is nothing to stop. The asymmetry is correct, not an oversight.

Generalising the chain into a protocol would add an abstraction over five
call sites that already work, and would make the (correct) asymmetry harder
to see rather than easier. Not doing it.

### 12.12 Proactive turn — 3 of 4 guards already existed (quick win #3)

Parlor's four guards around server-initiated speech, mapped onto what
OpenClicky already had:

| Parlor guard | OpenClicky | verdict |
| --- | --- | --- |
| `floor_busy()` — held audio / speech chunks / interrupted / still playing | `systemAnnouncementAudioWouldCollideWithVoiceInput` — TTS playing (3 clients), dictation in progress, realtime capture active, voiceState != idle | **exists, broader** |
| 30 s staleness escape so a lost `ready` can only delay, never strand | `waitForSystemAnnouncementSlot(maxWaitSeconds: 30.0)` | **exists, same number** |
| `drain_ready()` scans instead of popping — a parked answer must not block a timer behind it | announcements chain on `await previousTask.result`, but every wait loop re-checks the silenced set each 50 ms tick, so a parked task releases the chain promptly | **exists in effect** |
| `ready` handler clears `interrupted` — a sticky flag must not strand queued deliveries | `silencedAgentSpeechSessionIDs` | **two defects, fixed** |

#### Defect 1 — silencing broke the serialization chain

`silenceAgentSpeech` did `pendingSystemAnnouncementTask?.cancel()` followed
by `pendingSystemAnnouncementTask = nil`. The next announcement chains on
that reference (`await previousTask.result`); with it nilled the link is
gone, so a fresh announcement could begin while a *different* session's
announcement was still speaking — two voices at once, which is the exact
failure the primitive exists to prevent.

Fixed by keeping the reference. A cancelled task's `result` returns
immediately, so the chain costs nothing and stays intact. (The mirror clear
in the completion path is fine — it is guarded by an identity check.)

#### Defect 2 — the tombstone set grew without bound

`silencedAgentSpeechSessionIDs` was inserted into and never removed from —
no `remove`, no `removeAll` anywhere in the codebase. One UUID leaked per
silenced agent task for the life of the process.

Fixed with a 512-entry FIFO. Safe because every wait path gives up after
30 s, so a session silenced 512 tasks ago cannot still have audio parked.

#### Also fixed: SKI agent replies bypassed the floor entirely

`speakSKIModeAgentReply` spoke unconditionally. It is reached from the
`agentDidSpeak` observer, which fires whenever an external CLI writes a
`tts.speak` to `commands.jsonl` — the code comment says "unsolicited agent
turns work too". So agent audio could start on top of the user
mid-dictation.

Added the floor wait, placed **after** the response card and
`rememberVoiceExchange` and before the speaker: the bubble is the user's
feedback that a reply arrived and must not be delayed, and the exchange is
paired against `lastTranscript`, which can change during a 30 s wait. Only
the audio defers.

### 12.13 Gate H — screen-history search (the last untested claim)

§0 called screen-history search "the largest untapped multimodal win" and
"the one use case where none of the three alternatives work". It was also
the only claim never measured. Now measured.

Harness `/tmp/gateH/`: 20 synthetic frames of ordinary work — editors,
browsers, Slack, Mail, Music, Finder — with exactly one error dialog
planted at index 10. Each frame judged independently; precision, recall
and per-frame latency recorded.

#### Result

| query | precision | recall | verdict |
| --- | --- | --- | --- |
| "does this show an error dialog?" | **1.00** | **1.00** | found the one frame in twenty, no false positives |
| "is this a code editor?" | **1.00** | **1.00** | 4/4 exact |
| "is this a terminal?" | 0.43 | 1.00 | **fails** — 4 false positives |

**~1.15 s/frame, so ~23 s to sweep twenty frames.** Local, no quota, no
egress. Claude would be thousands of tokens and comparable wall-clock for
a single pass; OCR cannot answer "which frame had an error" at all.

The headline case works. A user asking "which screen had that error?"
gets the right frame.

#### Two of my own mistakes, corrected mid-gate

Worth recording because both would have been reported as model failures:

1. **Disjunctive questions collapse.** "Is this a terminal **or**
   command-line window?" returned YES for 14/20. The single-clause
   "terminal emulator with a shell prompt" took it to 9/20. Same model,
   same frames — the "or" was doing the damage.
2. **Every fixture rendered in monospace.** `-apple-system` is absent in
   headless Chrome, so all 20 frames fell back to the second font in the
   stack. Monospace is the strongest visual cue for "terminal", so the
   harness built twenty terminal-looking frames and then blamed the model.
   Fixing it moved precision 0.33 → 0.43.

#### The real finding: never ask "is this an X?"

Asked **"what application is this?"**, frame 03 answers `Slack`. Asked
**"is this a terminal?"** about the same frame, it answers `YES`.

Perception is correct; the yes/no framing is not. A leading question gets
agreement. This sharpens §12.4's "closed questions only" — closed is
necessary but not sufficient, and the constraint should read:

> **Ask what something is, then match the answer. Never ask whether it is
> a specific thing.** A yes/no question naming the target invites
> agreement; naming forces commitment.

Switching to naming took terminal precision 0.43 → **0.75** (the one
remaining false positive is a Safari page displaying a `llama-server`
command line — arguably a fair mistake). It costs code-editor precision,
though, because the model returns "text editor" for browsers and notes:
free-text answers need a synonym map, and the categories have to be
mutually exclusive.

#### Verdict

**Ship the error-dialog / distinctive-event case; do not ship generic
category filtering yet.** Finding one unusual frame among many is exactly
what this is good at, and is the use case §0 argued for. Bucketing every
frame by app type needs a fixed label set and a forced choice between
them — untested, and a different prompt shape from what was measured here.

Caveat on fixtures: these are synthetic renders, not real captures. Real
screenshots have window chrome, menu bars, wallpaper and overlapping
windows. The error-dialog result should be re-confirmed against real
`ContextExtractor` frames before building on it.

#### Re-confirmed on real captures

§12.13 ended with a caveat: the fixtures were synthetic renders, and the
result should be re-checked against real screenshots with window chrome,
wallpaper and overlapping windows. Done — eight real windows captured off
this machine by CGWindowID (`screencapture -l`), no activation, downscaled
to 1280.

**7/8 correctly categorised, 1628 ms/frame.** Better than the synthetic
set, not worse. The single miss is a small configuration panel called
"text editor" — genuinely ambiguous, not a perception failure.

Find-one-frame, which is the actual use case:

| query | result |
| --- | --- |
| "which frame was the video site?" | **exactly 1 of 8**, correct, no false positives |
| "which frame is Chinese?" | returned nothing — see below |

The Chinese query looks like a failure and is not. The terminal in
question shows Chinese prose interleaved with English shell output, so
"Mixed" was the honest answer to "mainly Chinese, mainly English, or
mixed?". Asked "what language is the text?" the same frame answers
`Chinese`; asked "does this contain Chinese characters?" it answers `YES`.
My gold label was wrong, not the model.

So both §12.13 corrections hold up on real data, and a third joins them:
**offer the categories the screen can actually be in.** A three-way choice
including "mixed" gets used correctly — which is right, and which means
the caller has to handle that bucket rather than treating it as a miss.

#### Privacy, observed rather than argued

Building this set surfaced the §12.9 argument as a concrete event rather
than a claim. Enumerating windows turned up one titled with a live
Cloudflare tunnel token, and a Finder window listing
`client_secret_...json` among the downloads. Both were dropped before any
inference ran — an OCR pass over each capture, grepping for
credential-shaped strings, was what caught them.

Everything here went to `127.0.0.1:8081`. Nothing left the machine. That
is the property being claimed, demonstrated on the first real screen
capture attempted — and note that the same two windows would have been
uploaded verbatim under today's architecture, which attaches the whole
screen or nothing.

It also argues for a pre-flight redaction pass in the shipping product:
`ContextExtractor` already runs Vision OCR, so the same credential-shaped
grep is nearly free and should gate any frame before it reaches either a
local or a remote model.

### 12.14 Layer B shipped — measured through the real code path

`MiragePeekyOrchestrator.routeletClassify` now translates non-Latin
transcripts before handing them to routelet. Re-measured end to end: the
32-item Gate A corpus translated by the **live local model through the
same helper the app calls**, then classified by the **shipped** routelet.

| arm | accuracy | `none` rate |
| --- | --- | --- |
| 1 zh-raw (before) | **0.0%** | 100% |
| 2 zh-grounded | 0.0% | 100% |
| 3 en, live translation (after) | **78.1%** | 3.1% |
| 4 en-raw control | 84.4% | 0% |

Translation cost **348 ms mean**, local, no quota.

0% → 78.1%, against an 84.4% ceiling set by hand-written English. Every
Chinese turn previously fell through this tier to Claude (tier 4, a
network round-trip); most now resolve locally in ~350 ms.

The 78.1% is slightly below §12's 87.5%, which used hand-written English
for arm 3. The gap is translation phrasing, not classifier drift — the
model returns "Where is the search box?" where the corpus author wrote
"where is the search bar in the Safari toolbar". Worth noting rather than
tuning: arm 4 shows the classifier's own ceiling is 84.4%, so the
remaining headroom is ~6 points.

#### Scope of the trigger

Only non-Latin scripts are translated (CJK, kana, Hangul, Cyrillic,
Hebrew, Arabic, Thai). Proper language detection is its own problem, and
guessing permissively costs ~350 ms on every English turn for nothing.
European languages stay on the old path — they at least share routelet's
alphabet, so its behaviour there is degraded rather than pinned at
`none`, and no measurement exists to justify spending latency on them.

Failure is a no-op by construction: no local model, server down, or an
empty reply all fall back to classifying the original text, which is
exactly the pre-change behaviour.

### 12.15 Screen redaction gate — shipped

§12.13's privacy note recommended a pre-flight redaction pass, on the
grounds that `ContextExtractor` already runs Vision OCR so the marginal
cost is a regex sweep over text the app has computed anyway. Built:
`OpenClickyScreenRedactionGate`.

It answers one question — send this frame, or refuse it. Deliberately not
a redactor: no blurring or masking, because partial redaction invites
"the secret was only half visible" reasoning.

#### What it must not do

The failure mode that makes such a gate worthless is refusing every code
editor. A user who hits that turns the feature off, and then it protects
nothing. So every pattern requires a high-entropy VALUE, never a
credential-adjacent word:

| blocked | allowed |
| --- | --- |
| `export OPENAI_API_KEY=sk-proj-abc123…` | `func anthropicAPIKey() -> String?` |
| `password: hunter2swordfish` | `Enter your password to continue` |
| `eyJhIjoiOGY0NGE5…` | `Settings > Anthropic API key` |
| `client_secret_610.…json` | `let secret = try loadSecret()` |

Filenames are also blocked, because the Finder case leaked no secret —
the listing simply announced which file holds one.

The refusal reason never quotes the match. Echoing a secret into a log or
a spoken caption in order to explain that it must not be sent is
self-defeating.

#### Verified on live captures, not fixtures

14 hand-written cases pass. More usefully, the gate was run over eight
windows captured off this machine at that moment: **7 allowed, 1
blocked** — a real `.pem` private-key filename visible on screen. A true
positive on live data. (The captures were deleted immediately after.)

#### Not yet wired

The gate exists and is tested; no call site consults it. Wiring belongs
with whichever path first sends a frame somewhere — and note it should
gate BOTH destinations, local and remote. The local model is the safer
of the two, not a safe one: it is still a process reading the frame, and
"we only sent it to localhost" is a weaker promise than not reading the
secret at all.
