# Parlor Capability Inventory

Source: `/tmp/parlor` (v2.0.0, 2026-08-03). ~2200 lines Python + ~1900 lines benchmarks.
Upstream: https://github.com/fikrikarim/parlor

**Frame of reference:** OpenClicky already has LLM clients (Claude / OpenAI / Codex / Apple FM / mirage),
TTS (ElevenLabs / Cartesia / Kokoro-ish), STT (Deepgram / Whisper), and Agent runners. So "value" below
is judged strictly on *what Parlor does that OpenClicky cannot do today*.

**What Parlor is, in one line:** a local WebSocket server that owns a *turn loop* — VAD → acoustic
end-of-turn classifier → speculative prefill into a llama.cpp prefix cache → a single multimodal
(audio + image) request to Gemma 4 that emits `###TRANSCRIPT: ...` then the reply → sentence-pipelined
TTS → a *separate* grammar-forced JSON "action head" that decides timers/modes/research.

The interesting part for OpenClicky is almost entirely the **turn loop and its orchestration**, not the
model backends.

---

## 1. Native audio input to the LLM (no STT stage)

### What it does
Parlor never runs a speech-to-text model in the request path. Raw 16 kHz WAV segments are base64'd and
sent as `input_audio` parts directly to Gemma 4's audio encoder via llama-server's OpenAI-compatible
API. The model *is* the ASR: it is instructed to emit a `###TRANSCRIPT: <words>` line first, then answer.
Transcription and understanding are one forward pass over one shared prefix.

### Implementation
- `pipeline.py:44` `audio_part()` — `{"type": "input_audio", "input_audio": {"data": b64, "format": "wav"}}`
- `pipeline.py:58` `user_content(image_b64, audio_b64s)` — canonical part ordering
- `pipeline.py:52` `valid_audio()` — rejects <~100 ms WAVs; "llama-server 400s on empty audio, and one
  bad message in history would poison every later request"
- `pipeline.py:91` `pad_tail_silence()` — appends 300 ms of silence *inside* the same WAV. Comment at
  `pipeline.py:26-29`: audio cut abruptly at the VAD boundary "makes the encoder hallucinate a confident
  completion of the last word". A separate silence part does not fix it; it must be the same WAV.
- `llama.py:145` — llama-server spawned with `--mmproj` (the multimodal projector) which is what enables
  both audio and image.
- `llama.py:84-85` `MIN_BUILD = 9503`, `MODEL_MIN_BUILD = {"12b": 9512}` — Gemma 4 audio needs a very
  recent llama.cpp; older builds abort at mmproj load.

### Dependencies
Gemma 4 E2B / E4B / 12B QAT q4_0 GGUF + matching mmproj (`llama.py:24-31`). E4B is the default at
~6 GB RAM. llama.cpp b9503+. Audio is billed at ~32 tokens/sec of speech (`pipeline.py:32`).

### Measured performance
CHANGELOG latency table (M3 Pro, `MODEL=e2b`, end of utterance → first audio): short question ~0.7 s,
long question ~1.3 s, short + camera ~0.8 s. E4B is "~1.8x E2B latency". `llama.py:21-23`: e2b ≈ 0.6-1.0 s
to first audio, e4b ≈ 1.0-1.7 s.

Transcript-first ordering measured **WER 0.00 leading vs 0.39 trailing** on a clean 33-word utterance
(`pipeline.py:126-129`).

### Portability to Swift/macOS
**HARD.** Not the plumbing — the plumbing is trivial (it is JSON over HTTP). The hard part is that no
model OpenClicky currently routes to accepts raw audio in this shape. Options: (a) spawn llama-server as
a sidecar and talk to it (medium, but ships a 6 GB model and a Homebrew dependency); (b) use OpenAI
Realtime — OpenClicky *already has* this path (`gpt-realtime-2.1-mini`), so the capability partly exists;
(c) Apple Foundation Models is text-only per CLAUDE.md, so no.

### Value to OpenClicky
**LOW-MEDIUM.** OpenClicky already has both STT providers and a native-audio realtime path. What is
genuinely new is only the *offline* native-audio option and the transcript-first trick. The
`pad_tail_silence` finding (300 ms in-WAV) is a real, cheap, portable bug-fix insight for any
audio-to-model path — that single detail is worth more than the rest of this item.

---

## 2. Image / camera input, and camera-as-tool-call

### What it does
A single JPEG frame can be attached to the user turn as an `image_url` data URI, placed *before* the
audio parts so the prefix stays cache-stable. Crucially, Parlor benchmarked whether to attach the camera
on *every* turn versus letting the model *request* a frame, and the mode system carries a `wants_camera`
flag so vision can be disabled per-mode.

### Implementation
- `pipeline.py:40` `image_part()` — `data:image/jpeg;base64,` data URI
- `pipeline.py:61` — image first, then audio oldest-to-newest ("canonical (cache-stable) order")
- `pipeline.py:33` `IMAGE_TOKENS = 300` — cost estimate for rotation
- `modes.py:26` `wants_camera` flag; only `conversation` mode sets it True (`modes.py:32`)
- Camera frames are pushed through `prime_cache()` while the user is still speaking (`pipeline.py:464`)

### Dependencies
Same mmproj as audio. One `IMAGE_TOKENS = 300` budget per frame.

### Measured performance
A frame costs **50 context tokens** (measured from llama-server's own usage counts — not the ~300 that
`pipeline.py:33` estimates) and **~600 ms of prime GPU hidden under speech**; attach-every-turn answers
`1.0` at **1.55 s median** (`camerabench.py:31-33`). Full three-way comparison in §16.

### Portability to Swift/macOS
**EASY.** OpenClicky already captures screenshots via ScreenCaptureKit
(`cursor-buddy/CompanionScreenCaptureUtility.swift`) and every backend it routes to takes base64 images.
The *policy* (when to attach) is the portable part, not the mechanism.

### Value to OpenClicky
**MEDIUM** — for the policy, not the plumbing. OpenClicky attaches screenshots on demand today; the
camerabench result is a decision-quality input for "should the screenshot ride every turn?".

---

## 3. smart-turn-v3 acoustic end-of-turn detection

### What it does
An 8M-parameter ONNX audio classifier (Pipecat, BSD-2) judges *acoustically* whether the speaker finished
their thought — not whether they went silent. It replaces "ask the LLM FINISHED/WAIT". Incomplete
utterances are **held** and merged into the next audio segment rather than answered; a false hold is
flushed and answered anyway after 2.5 s of continued silence. The client is shown live confidence
("sounds unfinished (12%) — still listening").

### Implementation
- `turn_detector.py:24` `TurnDetector` — ONNX Runtime session, `inter_op=1 / intra_op=2`,
  `ORT_ENABLE_ALL`, warmup call at `turn_detector.py:41` to pay graph init up front
- `turn_detector.py:44` `predict(audio) -> (complete, probability)`; threshold `p > 0.5` at
  `turn_detector.py:58`
- `turn_detector.py:21` `WINDOW_SECONDS = 8` — only the last 8 s are judged; shorter audio is
  **left-padded** (`turn_detector.py:51`), longer is tail-cropped
- `turn_detector.py:179` `compute_whisper_log_mel_features()` — a numpy-only reimplementation of
  `transformers.WhisperFeatureExtractor` (80 mels, n_fft 400, hop 160), vendored so `transformers` is not
  a dependency. `turn_detector.py:171` uses `sliding_window_view` + one batched rFFT instead of ~800
  per-frame numpy calls.
- Held/flush turn behaviour: `server.py:214` `FLUSH_FALLBACK`, `server.py:222` `FLUSH_PROMPT` — a
  *dedicated* prompt, because "with a bolted-on suffix the model would sometimes emit the transcript line
  and stop, leaving the turn silent"
- Gated per-mode by `modes.py:22` `uses_smart_turn`

### Dependencies
`pipecat-ai/smart-turn-v3` → `smart-turn-v3.2-cpu.onnx` (`turn_detector.py:18-19`), ~8M params.
`onnxruntime` + `numpy`. No PyTorch, no transformers. 16 kHz float32 mono.

### Measured performance
**0.96 accuracy at 19 ms** on labelled human speech (CHANGELOG, `benchmarks/turnbench.py`). "Every Gemma
variant is at or near chance while costing 0.6-3.6 s." Caveat stated honestly at `turnbench.py:29-32`:
this is smart-turn's *own* test split so the score is optimistic in-domain; LiveKit's eot-bench "scores
smart-turn v3.2 far more harshly". Only non-synthetic clips are scored (`turnbench.py:11-16`) — TTS clips
"read as finished no matter what the words are", flattering the LLM modes.

### Portability to Swift/macOS
**EASY-MEDIUM.** The ONNX model runs fine under `onnxruntime` C/ObjC or can be converted to CoreML. The
log-mel front end is ~150 lines of pure numeric code (`turn_detector.py:74-230`) that maps almost 1:1 to
Accelerate/vDSP (`vDSP_DFT` + a precomputed mel filterbank matrix). No Python needed at runtime. The
model file is small enough to bundle. This is the single most self-contained, most portable thing in the
repo.

### Value to OpenClicky
**HIGH.** OpenClicky's push-to-talk/VAD path decides "user stopped talking" from *silence*, which is the
classic wrong signal — it cuts people off mid-thought and waits too long after short answers. A 19 ms,
0.96-accuracy acoustic completeness signal is a capability OpenClicky has no equivalent of, it is
provider-independent (helps every backend equally), and it is the piece with the best
value-to-effort ratio in the whole project.

---

## 4. Decoupled JSON action head

### What it does
Instead of asking the speaking model to emit control tags inline (`<timer=180>`), Parlor issues a
**second, separate** request over the *same cached prefix* — grammar-forced to a flat JSON schema, at
temperature 0 — asking "what did the user ask the assistant to DO?". The speech stream stays pure speech.
The head sees the model's own reply as evidence, and does duration math itself ("twenty minutes" → 1200)
in any language.

### Implementation
- `actions.py:73` `HEAD_SCHEMA` — `{timer_seconds:int, timer_label:str, mode:enum, research_task:str}`,
  all required
- `actions.py:100` `decide_after(messages, current_mode)` — post-reply, used in conversation mode. The
  message list is "byte-identical to the turn request plus the reply — the whole prefix is already in the
  slot cache, so only the decider prompt pays prefill" (`actions.py:103-106`)
- `actions.py:111` `decide_before(history, content, current_mode)` — pre-reply, used in translate/listen
  where *what the reply is* depends on the decision. Note at `actions.py:117-118`: the decider prompt
  rides the **same user message** as the audio, because "chat templates dislike consecutive same-role
  messages"
- `actions.py:54` `_MODE_CLAUSES` — one prompt variant per mode, so the head knows what "no change" means
- `actions.py:148-150` — mid-translate/listen the only sanctioned transition is *out*; any other target is
  discarded as a misread ("a phantom listen→translate jump would answer aloud mid-listen")
- `actions.py:126-139` — all failures return `NONE`: "a lost decision is a no-op turn, never an exception
  in the turn loop"
- `actions.py:130-133` — `max_tokens=192`, deliberately generous: truncated JSON fails `json.loads` and
  "silently drops an action the reply already promised"
- Grammar enforcement is server-side: `llama.py:185-188` sets `response_format: {type: json_schema}`,
  which llama-server compiles into a GBNF grammar — "the output is structurally guaranteed to parse"

### Dependencies
Requires a backend with (a) prefix caching and (b) constrained/grammar decoding. `actions.py:22-25` is
explicit that the head **must run on the same server as speech**: "a separate model would pay full
prefill of history + audio every turn — the shared prefix cache is what makes deciding cheap."

### Measured performance
`benchmarks/archbench.py` (e4b, 19 spoken cases x 2):
- In-band tags: **recall 0.955**; the one miss was an ack-without-action ("I will be quiet", no tag) — "a
  spoken promise the server never keeps, the worst failure a voice assistant has" (`actions.py:6-9`)
- Decoupled head: **recall 1.0**, misfire **0.062** (one unwanted-but-cancellable timer)
- **Leak** (markup reaching TTS): structurally impossible for the head — there is nothing to excise
- Cost: **~35 JSON tokens, ~2 s GPU on e4b, hidden under TTS playback**, every turn (`actions.py:16-17`)
- A 1-token yes/no pre-gate was measured (`archbench` arm `B_gated`): recall a perfect 1.0, but it answers
  "yes" on nearly every turn *including "how are you"*, so it adds ~0.9 s and then runs the head anyway.
  Rejected (`actions.py:17-21`).
- `archbench.py:347-350`: `gate_recall` must be 1.0 to ship a cascade — a gate miss silently skips a real
  action.

### Portability to Swift/macOS
**MEDIUM.** The *pattern* ports trivially — it is "make a second structured-output call". Every backend
OpenClicky uses supports structured output (Anthropic tool_use / OpenAI json_schema / Apple FM guided
generation). What does *not* port is the economics: Parlor's head is cheap only because it rides a local
prefix cache. Against Claude or OpenAI over HTTP, a second call per turn means a second billed prefill
unless prompt caching is engaged — and OpenClicky's CLAUDE.md money rule (SDK first, REST fallback) makes
that a real design constraint. Prompt caching with a stable prefix is the mitigation.

### Value to OpenClicky
**HIGH.** This is an architecture correction, not a feature. Any voice assistant that asks a model to
emit inline control markup will eventually speak the markup aloud or promise an action it never performs.
Parlor measured both failure modes and shows the decoupled head removes the leak class *structurally*.
For OpenClicky, which routes to several providers of varying instruction-following quality, "the spoken
channel carries only speech; intent is decided out-of-band at temp 0" is directly applicable and
provider-agnostic.

---

## 5. Speculative prefill (cache priming during speech)

### What it does
While the user is still talking, Parlor fires **fire-and-discard** `max_tokens=1` requests containing the
prefix-so-far (camera frame, then each ~3 s speech chunk) at llama-server. This pushes those tokens
through the prefix cache, so when the utterance actually ends, the real request only pays prefill for the
*tail*. Long questions start answering almost as fast as short ones.

### Implementation
- `pipeline.py:464` `prime_cache(messages)` — `llama.chat_blocking(messages, max_tokens=1)` in an
  executor, exceptions swallowed: "Failure is not worth reporting: the turn still works, it just pays
  full prefill"
- `pipeline.py:467-468` — **critical constraint**: "Content must be media-only appends — a trailing text
  block would diverge the prefix and kill reuse." This is why the turn *instruction* is appended last, at
  request time, and never during priming.
- `llama.py:180` `"cache_prompt": True` on every request body
- `llama.py:146` — llama-server started with `-np 1` (single slot), so there is exactly one cache slot and
  no cross-request eviction
- `server.py:5-9` (module docstring) states the whole design: "This server owns the conversation history
  and re-sends it every request; llama-server's prefix cache makes that cheap."

### Dependencies
A backend with a stable, reusable prefix cache and a single serving slot. This is a llama.cpp property.

### Measured performance
CHANGELOG latency table, M3 Pro / e2b, end-of-utterance → first audio:

| Turn | v1.0.0 | v2.0.0 |
| --- | --- | --- |
| Short question (~2 s speech) | ~1.5 s | ~0.7 s |
| Long question (~9 s speech) | ~2.9 s | ~1.3 s |
| Short question + camera | ~1.9 s | ~0.8 s |

The long-question case is the one that shows prefill overlap: 2.9 s → 1.3 s. Camera priming costs ~600 ms
of GPU "hidden under speech" (`camerabench.py:32-33`).

### Portability to Swift/macOS
**HARD against remote APIs, EASY against a local sidecar.** The technique requires you to control the KV
cache. Anthropic and OpenAI prompt caching is *not* the same mechanism — you cannot warm a cache with a
partial user message and then extend it mid-utterance; cache writes are billed and cache breakpoints are
coarse. Against a local llama.cpp/MLX sidecar it ports directly. Against OpenAI Realtime, the equivalent
already exists in the protocol (streaming audio append), and OpenClicky already uses that path.

### Value to OpenClicky
**LOW-MEDIUM.** Genuinely clever, but it is a llama.cpp-specific optimization. OpenClicky's cloud
backends cannot use it, and its realtime path already gets the benefit a different way. Worth knowing if
OpenClicky ever ships a local sidecar. The transferable *idea* is smaller: start work before the user
stops talking.

---

## 6. Sentence-pipelined TTS

### What it does
The LLM decode, sentence splitting, TTS synthesis, and audio playback all run concurrently. As soon as
the parser sees a complete sentence in the streaming response it is pushed to a TTS worker queue and sent
to the client, while the model is still generating the rest.

### Implementation
- `pipeline.py:263` `run_turn(...)` — the orchestrator. Three concurrent stages:
  1. producer thread in an executor running `llama.ChatStream.run` (`pipeline.py:296-306`), pushing deltas
     onto `chunk_q` via `loop.call_soon_threadsafe`
  2. main coroutine consuming `chunk_q`, feeding `StreamParser`, dispatching complete sentences
     (`pipeline.py:388-398`)
  3. `tts_worker()` coroutine (`pipeline.py:311-334`) pulling from `sentence_q`, synthesizing in an
     executor, emitting `audio_start` once then PCM chunks
- `pipeline.py:23` `SENTENCE_END_RE = re.compile(r"[.!?]+\s")` — note the required trailing whitespace, so
  "3.5" does not split
- `pipeline.py:179` `_complete_sentences()` — emits from a moving `_emitted` cursor
- `pipeline.py:316-321` — the worker checks `interrupted` **twice** (before and after synthesis) but
  `continue`s rather than returning, so the queue keeps draining and never deadlocks
- Timings recorded: `prefill_s`, `decode_s`, `llm_time`, `ttfa_s`, `tts_time` (`pipeline.py:395`,
  `409-410`, `430-433`)
- `tts.py:57` `load()` — platform-aware backend: mlx-audio (Apple Silicon GPU) else kokoro-onnx (CPU).
  Both warm up at init (`tts.py:31-32`).

### Dependencies
Kokoro-82M (mlx-community bf16 on Apple Silicon, or `fastrtc/kokoro-onnx` v1.0 elsewhere). 24 kHz output.

### Measured performance
`ttfa_s` is the tracked metric; the CHANGELOG table above is end-to-end. `benchmarks/benchmark_tts.py`
exists for TTS-only numbers.

### Portability to Swift/macOS
**EASY.** Swift Concurrency `AsyncStream` maps directly onto the queue-pair design. OpenClicky already
has streaming TTS clients.

### Value to OpenClicky
**LOW-MEDIUM.** OpenClicky almost certainly already streams TTS. The genuinely reusable details are
narrow but real: the trailing-whitespace sentence regex; the drain-don't-return interrupt handling; and
the `##`-cut guard (`pipeline.py:181-185`) that refuses to speak anything from an imitated markup token
onward.

---

## 7. Barge-in (sustained-voicing gate + server-side abort)

### What it does
The user can interrupt the assistant mid-sentence. Two halves: the client detects genuine speech over
playing TTS using a **sliding-window** voicing gate (not a consecutive-frames counter), and the server
**actually aborts generation** by tearing down the HTTP socket, which llama-server observes.

### Implementation
Client (`web/static/app.js`):
- `app.js:506-509` — `BARGE_WINDOW = 10`, `BARGE_HITS = 6`, `BARGE_SPEECH_P = 0.85`. Comment: "It must be
  SUSTAINED, not a single loud frame, or the mic catching our own TTS interrupts the reply (echo) — but
  real speech dips at every consonant and word boundary, so a consecutive-frames counter never fires on a
  live mic." This is the CHANGELOG's "barge-in actually fires on a live mic" fix.
- `app.js:494` `BARGE_IN_GRACE_MS = 800` — ignore triggers just after TTS starts
- `app.js:512` `handleVadFrame()` — the window is only accumulated while `state === 'speaking'`
- `app.js:~605` `triggerBargeIn()` — stopPlayback, set `ignoreIncomingAudio`, send `{type:'interrupt'}`,
  `goListening(false)` (mic live, so floor is **not** free), prefetch camera frame, start capture
- `app.js:521-540` — **phantom-capture watchdog**: if the VAD never actually enters speech after a
  barge-in (an echo burst in the `(0.85, 0.92]` band can trip the gate alone), ~1 s below 0.25 resets
  state, otherwise the client "would stream silence chunks to the server forever"
- `app.js:~680` — a documented negative result: routing TTS through `MediaStreamDestination` + `<audio>`
  for Chrome's echo canceller (crbug 687574) engages macOS system voice processing, which "audibly colors
  the TTS voice per turn AND suppresses the user's mic while playback is active, killing barge-in."
  Rejected in favour of the gate + grace period + a prompt-level echo rule (`server.py:55-57`).

Server:
- `server.py:347-358` `receiver()` — a dedicated task reading the socket in parallel with the turn, so an
  `interrupt` frame is never blocked behind turn processing. Calls `stream.cancel()`.
- `llama.py:270-278` `ChatStream.cancel()` — `sock.shutdown(SHUT_RDWR)` then close; "cancel() is
  thread-safe and actually aborts generation server-side (the connection close is observed by
  llama-server)". `self.conn` is published *before* the request is sent (`llama.py:225-227`) so a cancel
  landing mid-upload still tears the socket down.
- `pipeline.py:316-321` — TTS worker keeps draining the queue when interrupted rather than returning
- `server.py:825-828` — an interrupted turn produces `decision = actions.NONE`: nothing may act

### Dependencies
Silero VAD in the browser (`@ricky0123/vad-web`) for per-frame `isSpeech` probability. On macOS Swift the
equivalent is `SFSpeechRecognizer`-free: Silero VAD ONNX or `AVAudioEngine` + a voicing estimate.

### Measured performance
Not benchmarked numerically; the CHANGELOG lists it under Reliability as a fixed live-mic bug.

### Portability to Swift/macOS
**MEDIUM.** The gate itself is ~15 lines and trivially portable. Two macOS-specific traps are already
documented for you: (a) enabling `AVAudioSession`/system voice processing kills barge-in by ducking the
mic — the same failure the JS comment describes; (b) you need a per-frame speech probability, so you need
Silero VAD ONNX or equivalent rather than raw RMS. Server-side abort maps onto `URLSessionTask.cancel()`
or Claude SDK cancellation, though whether the provider *stops billing* differs.

### Value to OpenClicky
**HIGH.** Barge-in on a live speaker without headphones is the hardest reliability problem in
speaker-mode voice UI, and Parlor documents both the working design *and* the appealing-but-wrong
alternative (system echo cancellation) with the exact macOS reason it fails. Even if OpenClicky has some
interruption support, the sliding-window-vs-consecutive-frames insight and the phantom-capture watchdog
are directly reusable.

---

## 8. Modes as data

### What it does
A "mode" is a frozen dataclass of six behaviour flags plus a voice, not a branch in the turn loop. The
turn loop consults `mode.<flag>` instead of `if mode == "translate"`. Adding a mode is a new table entry
plus its trigger, not a rewrite.

### Implementation
- `modes.py:20-28` — `Mode(name, uses_smart_turn, allows_delegation, wants_camera, wants_time_note,
  speaks_fallback, tts_voice)`, `@dataclass(frozen=True)`
- `modes.py:30-50` — three modes: `conversation` (all True), `translate` (all False except
  `speaks_fallback`), `listen` (`wants_time_note` + nothing else)
- Consumption sites, all flag lookups: `server.py:~735` `mode.uses_smart_turn`,
  `server.py:~700` `mode.wants_camera`, `server.py:794` `mode.wants_time_note`,
  `server.py:798` `mode.speaks_fallback`, `server.py:~420` `mode.allows_delegation`,
  `server.py:~504` `mode.tts_voice`
- `server.py:118-120` `MODE_PROMPTS` — the one place a mode replaces the instruction *wholesale*: "the
  mode chooses what a turn IS, not just how it's phrased"
- `server.py:~427` `switch_mode()` — clears `frame_image`, `speech_chunks`, `held_audio` on every switch,
  because "a switch through the UI escape hatch can fire with audio held under the OLD mode's gating, and
  translate mode never resolves holds — stale held state would keep `floor_busy()` true and block
  deliveries for the whole session"
- Dual trigger: the action head decides it (`actions.py:78`), and a UI chip sends `set_mode` directly
  (`server.py:~655`) — "the UI action must work even when the model mistranslates the spoken exit command"

### Dependencies
None. Pure data.

### Measured performance
N/A (structural).

### Portability to Swift/macOS
**EASY.** A Swift `struct Mode: Sendable` with `let` flags in a static dictionary is an exact
translation, and fits OpenClicky's existing immutable-value conventions.

### Value to OpenClicky
**HIGH.** Cheapest high-leverage item in the inventory. OpenClicky has several de-facto modes already
(dictation, agent mode, overlay states, backend family selection) and the flag-table pattern with a
clear-state-on-switch rule plus a UI escape hatch that bypasses the model is directly applicable. Note
also which modes each behaviour is gated on — the reasoning in the `modes.py` comments (why an interpreter
must not use a completeness gate; why a listening scribe must have no fallback line) is transferable
product logic, not just code shape.

---

## 9. Background reasoner delegation

### What it does
When the user asks for something current or requiring search, the local voice model does **not** answer.
It says one short "I'll find out" sentence and keeps talking; the action head extracts a self-contained
task; the task goes to a frontier model on any OpenAI-compatible endpoint (OpenRouter + web search by
default) in a **separate thread pool**; when the answer returns it is delivered as a *server-initiated
proactive turn* at the next gap in playback.

### Implementation
- `reasoner.py:48` `ask(task)` — plain `urllib` POST to `{BASE_URL}/chat/completions`
- `reasoner.py:29-31` — OpenRouter web search is requested by appending `:online` to the model id
- `reasoner.py:59-60` — `api.openai.com` needs `max_completion_tokens`, everything else `max_tokens`
- `reasoner.py:35-41` `SYSTEM_PROMPT` — "no markdown, no lists, no headings, no URLs... 2-6 short
  sentences": the answer must already be **speech-shaped** when it comes back
- `reasoner.py:44` `enabled()` — off entirely unless `REASONER_API_KEY` is set; then
  `server.py:80-90` `RESEARCH_NOTE` is simply absent from the system prompt
- `server.py:~450` `run_delegation()` — runs on a **dedicated** `REASONER_POOL`
  (`server.py:~292`, 4 workers) so a 90 s blocking call cannot starve the default executor that serves
  "llama streaming, TTS, turn classifier, cache priming"
- `server.py:~460` — answers over 1500 chars are clamped at a sentence boundary
- `server.py:~474` `spawn_delegation()` — `MAX_PENDING_DELEGATIONS = 3`; tasks under 3 words are dropped
  as fragments
- `server.py:~520` `deliver_delegation()` — the fallback **is the reasoner's own answer**, so if the voice
  model's relay yields nothing speakable, TTS speaks the research result directly. "a delegation must
  never end in silence."
- `server.py:151-160` `DELIVER_PROMPT` — instructs "then the answer itself word-for-word. Never drop or
  change a name, number, place". CHANGELOG: research deliveries "quote the reasoner's answer verbatim
  instead of paraphrasing away the key fact."

### Dependencies
Any OpenAI-compatible endpoint + API key. Default `openai/gpt-5.6-luna` on OpenRouter
(`reasoner.py:20`), 90 s timeout (`reasoner.py:22`).

### Measured performance
Not benchmarked. Two prompt-engineering findings are recorded from e2e runs: `server.py:76-79` — without
the closing "everything else, answer yourself", once history contains one "I'll find out" the model starts
deferring stable general knowledge too; both e2e failures of the first migration were "capital of France"
answered with a deferral.

### Portability to Swift/macOS
**EASY** mechanically. `URLSession` + a detached Task. The scheduling is the interesting part, not the
HTTP.

### Value to OpenClicky
**HIGH — but re-framed.** OpenClicky's whole thesis per the task brief is "frontend multimodal router →
backend LLMs/Agents". Parlor's reasoner *is* that router pattern, already worked out: a fast local model
holds the conversation and hands heavy work to a strong remote model **asynchronously**, with the result
woven back in as speech at a polite moment. Substitute "Claude Agent SDK / Codex run" for "OpenRouter"
and this is precisely OpenClicky's architecture. The transferable pieces are the dedicated executor, the
speech-shaped-answer system prompt, the verbatim-relay delivery prompt, the fragment/cap guards, and the
answer-as-fallback rule.

---

## 10. Floor management and gap delivery (`floor_busy` / `drain_ready`)

### What it does
Parlor never lets a background event (research answer, timer ring) interrupt the assistant mid-sentence or
cut across the user. A single predicate defines "is the conversational floor free?", and every point that
frees the floor calls a drain function that releases exactly one queued event.

### Implementation
- `server.py:~402` `floor_busy()` — True if `held_audio` or `speech_chunks` or `interrupted.is_set()` or a
  reply is (probably) still playing. Playback is tracked by `playing_since["t"]`, set when a turn spoke and
  cleared by the client's `ready` frame — **with a 30 s staleness escape** so "a lost 'ready' can only
  delay a result, never strand it."
- `server.py:~410` `drain_ready()` — **scans** `ready_events` instead of popping the head, because timers
  ring in every mode while research answers wait out translate/listen: "a parked answer must not block a
  timer ringing behind it"
- Called at every floor-freeing point: after a turn (`server.py:838`), on `ready` (`server.py:~648`), on
  mode switch (`server.py:~446`), after a proactive turn (`server.py:~517`), and when a mic glitch yields
  nothing (`server.py:~722`) — "the floor is provably free here"
- `server.py:~648` — the `ready` handler also clears `interrupted`, so "a sticky interrupted flag must not
  strand queued deliveries"
- All background results re-enter through the **same `msg_queue`** as client messages
  (`server.py:~470`, `server.py:~530`), so delivery is serialized with real turns by construction

### Dependencies
None beyond asyncio.

### Measured performance
N/A. CHANGELOG: "Research results and timer rings are delivered only in playback gaps — the assistant
never interrupts itself mid-sentence."

### Portability to Swift/macOS
**EASY.** An `AsyncStream` continuation fed by both the socket and background tasks, plus a
`floorBusy` computed property, is a direct translation to Swift Concurrency and OpenClicky's `@MainActor`
state model.

### Value to OpenClicky
**HIGH.** This is the missing piece in almost every assistant that gains async capability: once anything
can complete in the background (an agent run, a long tool call, a notification), you need a floor
protocol or the assistant talks over itself and over the user. OpenClicky runs Agent Mode jobs that
complete asynchronously — this is exactly the problem it has. Small, self-contained, provider-agnostic.

---

## 11. Server-owned timers

### What it does
Countdown timers are owned by the **server**, not the model: `asyncio.sleep`, then a proactive turn where
the model phrases the announcement. The model only *confirms* the timer aloud; it never keeps time.

### Implementation
- `server.py:~495` `run_timer()` — sleep, then put a `timer_done` event on `msg_queue`. "Cancellation
  during the sleep enqueues nothing."
- `server.py:~503` `spawn_timer()` — caps: `MAX_PENDING_TIMERS = 3`, `MAX_TIMER_S = 8*3600`
  (`server.py:137-138`, "> 8h is a misread, not a timer")
- `server.py:126-131` `TIMER_PROMPT` / `TIMER_FALLBACK` — "Ding — your {label} timer is done." is spoken
  if the model produces nothing
- `server.py:~583` `deliver_timer()` — pops the pending entry; `None` means already cancelled, "only
  about not ringing twice"
- `server.py:~665` `cancel_timer` — the UI chip's ✕ cancels the task **and** purges any already-queued
  `timer_done` from `ready_events`. Like `set_mode`, "a UI action must work regardless of what the model
  believes."
- Duration comes from the action head as integer seconds — `actions.py:11-12`: "the model does the word-
  number math, in any language". `server.py:141` `duration_phrase()` renders it back exactly for the
  prompt ("unlike `elapsed_phrase`, a timer's length is not approximate").
- Timers ring in **every** mode (`server.py:~415`) unlike research deliveries.

### Dependencies
None.

### Measured performance
`benchmarks/timerprobe.py` is the experiment that motivated this. It measures whether the model, told
via the elapsed-time note how much quiet passed, spontaneously announces a due timer on the user's next
utterance. `timerprobe.py:9-12`: "A turn-based system can **never** announce into silence (nothing wakes
the model), so this measures the **best case**: the user happens to speak after the deadline. The result
informs the real feature — ... a server-scheduled proactive turn." It reports `announced/N` and
`time_aware/N` (`timerprobe.py:100-103`). The structural argument — a turn-based model cannot ring into
silence — is the finding, and it is architectural, not statistical.

### Portability to Swift/macOS
**EASY.** `Task.sleep` or `DispatchSourceTimer`; on macOS you would likely also want
`UNUserNotificationCenter` for backgrounded rings.

### Value to OpenClicky
**MEDIUM-HIGH.** Timers themselves are a small feature, but the generalized rule — **anything with a
clock or a deadline must be owned by the host app, never by a turn-based model, and the model's role is
only to phrase the announcement** — applies to every proactive behaviour OpenClicky might want
(reminders, agent-run completion, watch conditions). The proactive-turn mechanism (§12) is the reusable
part.

---

## 12. Proactive (server-initiated) turns

### What it does
A generic mechanism for the assistant to speak without the user having spoken: a synthetic user-role
message containing a "System note (not user audio): ..." prompt runs through the exact same turn pipeline,
with a `proactive=True` flag that suppresses the transcript frame so the client never draws it as
something the user said.

### Implementation
- `server.py:~490` `proactive_turn(prompt, fallback)` — the only entry point; used by both delegation
  delivery and timer rings
- `pipeline.py:283-286` — `proactive` marks it: "the model's transcript line is its own echo, not the
  user's words, so no transcript frame is sent and turn_final carries proactive=True — the client never
  fills a user bubble from it"
- `server.py:~493-497` — `expect_transcript=True` **even though there is no audio**: "the model often
  opens one with an imitated `###TRANSCRIPT:` line, and the transcript parser consumes it and streams the
  real reply; with False the `##`-markup cut would swallow the whole thing (observed live)"
- `server.py:~498` — "Nothing server-initiated ever acts: the action decider only judges real user turns"
- `server.py:149-150` — both proactive prompts lead with "System note (not user audio)" because "the model
  occasionally misread a text-only turn as its own reply playing back and gave the anti-echo response
  instead of the answer (observed live)"
- Instruction-echo suppression is disabled on proactive turns (`pipeline.py:363`), since the delivery
  prompt legitimately embeds the answer being relayed

### Dependencies
None.

### Portability to Swift/macOS
**EASY.**

### Value to OpenClicky
**HIGH.** OpenClicky's Agent Mode produces results asynchronously and its overlay/notch surface is built
to show things unprompted. A single, well-guarded "the app speaks first" primitive — with the anti-echo
prompt prefix, the no-user-bubble flag, the never-act rule, and a fallback line — is exactly the shape
needed, and every one of those four guards exists because a real failure was observed.

---

## 13. Context rotation on real token counts

### What it does
History is rotated (oldest quarter dropped) before llama's context fills, driven by the **real**
`prompt_tokens` llama-server reports rather than an estimate. Whole exchanges are dropped, keeping the
system prompt, so the model never suffers silent mid-history truncation.

### Implementation
- `llama.py:189-192` — `stream_options: {include_usage: true}` so the final SSE chunk carries
  `usage.prompt_tokens`: "the REAL context size, which drives history rotation (estimates drift)"
- `llama.py:222` / `llama.py:249-251` — `ChatStream.prompt_tokens` captured from the usage chunk
- `server.py:274` `rotate_history()` — keeps `history[0]` (system) + the newest 3/4, then **walks back
  until the kept slice starts on a `user` message**: "dropping a user turn while keeping its reply would
  leave an orphaned assistant message about words that no longer exist". Returns unchanged at
  `len(history) <= 3`, because "slicing a bare [system] would duplicate the system prompt".
- `server.py:~271` `CONTEXT_HEADROOM = max(512, min(2000, llama.CTX // 8))` — the clamp exists because a
  fixed 2000 left a near-zero threshold on small `LLAMA_CTX`, rotating on every turn
- `server.py:~630` — trigger: `used = max(estimate, prompt_tokens["last"])`, rotate when
  `used > CTX - 2*CONTEXT_HEADROOM`. Double headroom "because the incoming turn isn't counted yet"; drop a
  quarter not a half "so rotation is barely noticeable". `prompt_tokens["last"] = 0` after rotation
  (stale).
- `pipeline.py:66` `estimate_tokens()` — the fallback estimate: text `len//4`, audio
  `seconds * 32`, image `300`. Note `camerabench.py:32` measured a frame actually costs **50** tokens, not
  300 — the estimate deliberately over-counts.

### Dependencies
A backend that reports prompt token usage.

### Measured performance
CHANGELOG: "32k window, with rotation driven by real `prompt_tokens` from llama-server instead of an
estimate, dropping whole exchanges — no more silent truncation-induced 'forgetting'."

### Portability to Swift/macOS
**EASY.** Anthropic and OpenAI both return `usage.input_tokens` / `prompt_tokens`. The
user-boundary-alignment rule is ~10 lines.

### Value to OpenClicky
**MEDIUM.** OpenClicky presumably has some history trimming already. The two reusable specifics: rotate
on the *provider-reported* count rather than an estimate, and align the cut to a user-message boundary so
no orphaned assistant message survives.

---

## 14. Transcript tag parsing and hostile-output defence

### What it does
The single most defensive part of the codebase. The model's reply is `###TRANSCRIPT: <words>\n<response>`,
parsed **incrementally** off a partially-streamed buffer, with layered guards against every way that
output can be wrong: no-speech annotations, instruction echoes, imitated markup, runaway transcript lines,
truncated streams.

### Implementation
- `pipeline.py:122` `StreamParser` — `feed(delta) -> [complete sentences]`, `finalize() -> (sentences,
  transcript)`
- `pipeline.py:22` `TRANSCRIPT_TAG_RE = r"#{2,}[ \t]*TRANSCRIPT[ \t]*:[ \t]*"` — the colon is **required**
  and only `[ \t]` may follow, with a stated reason (`pipeline.py:17-21`): an optional colon would match
  before the `:` token arrives and leak it into the transcript; `\s*` would let a newline delta terminate
  an empty transcript line. This regex is written specifically to be safe against *partial* input.
- `pipeline.py:164-170` — runaway guard: if no newline arrives within 600 chars, cut at the first sentence
  end "rather than holding TTS hostage"
- `pipeline.py:197-213` `finalize()` — truncated-stream recovery: if the tag was seen but no newline ever
  arrived, the first sentence is the transcript and the rest is the reply, "never swallow it all silently"
- `pipeline.py:148` `_before_tag` — stray text emitted before the tag becomes the response prefix
- `pipeline.py:181-185` — `##`-cut: never speak anything from an imitated markup token onward
- `pipeline.py:228` `NO_SPEECH_RE` — matches a transcript that is *entirely* a bracketed annotation:
  `(no speech)`, `(noise)`, `[Silence]`, `*sigh*`. Length-capped at 40 chars so a genuine parenthesized
  ramble is not swallowed. Applied both to transcripts and to reply sentences (`pipeline.py:380`) — the
  model has been observed *speaking* "(no speech)" at temp 0 in listen mode.
- `pipeline.py:234` `echoes_instruction(transcript, instruction, n=5)` — any run of 5 consecutive
  transcript words appearing verbatim in the instruction is an echo. Double-quoted spans are stripped from
  the instruction first (`pipeline.py:249`), because prompts quote phrases the user is *expected* to say
  ("go back to normal conversation"). Applied at n=6 to individual TTS sentences (`pipeline.py:370`) —
  from a live observation of the assistant reading `"CRIPT: Begin your reply with one line:"` aloud.
- `server.py:~370` `remember()` — the memory-poisoning defences, all with measured provenance:
  - a turn with no output, or a `no_speech` turn, is **never stored**: "one stored echo loop came back as
    invented or copied user words on every turn after it"
  - voice turns keep their **raw audio** in history, never the transcript-as-text: "an experiment storing
    the transcript as user text instead made the model copy the PREVIOUS turn's text as the new turn's
    transcript, **deterministically at temp 0** — user-role text reads as 'what the user said' more
    strongly than the current audio does"
- `server.py:~196` `NO_SPEECH_CLAUSE` — the prompt must *sanction* an out. Measured at temp 0.7 without
  it: a breath came back as "Hi, can you help me with my homework?" (answered), and as "can you translate
  everything I say from now on?" — **which switched mode**.

### Dependencies
None.

### Measured performance
Transcript-first vs transcript-last: **WER 0.00 vs 0.39** on a clean 33-word utterance
(`pipeline.py:126-129`, CHANGELOG). Grammar-forced JSON for the transcript was tried and rejected:
`server.py:~168` records "1-3/3" vs "3/3" — the plain-text leading line wins, "don't go back to structured
output" for the transcript.

### Portability to Swift/macOS
**MEDIUM.** The parser is ~90 lines of pure string handling and ports to Swift directly. The *specific*
tag format only matters if OpenClicky asks a model to transcribe-then-answer; if it keeps a separate STT
stage most of this is unnecessary. What ports regardless is the *defence catalogue*: never store a turn
the model produced nothing for; never store a turn whose transcript was an annotation or a prompt echo;
never speak a sentence that reproduces your own instruction.

### Value to OpenClicky
**MEDIUM-HIGH** — as a hardening checklist rather than as code. Every item is a real observed failure with
its reproduction noted inline. The "don't store degenerate turns, they poison every later request" rule
and the "user-role text outranks current audio as 'what the user said'" finding apply to any assistant
with conversation history, including OpenClicky.

---

## 15. Cache-stable ordering (cross-cutting discipline)

### What it does
Not a feature — a rule obeyed everywhere: any byte that goes into a request must be in a canonical,
reproducible position, so the next request is a prefix extension and hits the cache.

### Implementation
- `pipeline.py:58-63` `user_content()` — "canonical (cache-stable) order: image first, then audio segments
  oldest-to-newest"
- `pipeline.py:467-468` — priming content must be **media-only appends**: "a trailing text block would
  diverge the prefix and kill reuse". This is why the turn instruction is appended only at request time.
- `server.py:~370` `remember()` — "Store a finished turn verbatim (same bytes → full prefix-cache hit on
  the next request)"
- `actions.py:103-105` — the action head's message list is "byte-identical to the turn request plus the
  reply", so only the decider prompt pays prefill
- `server.py:~247` — the elapsed-time note lives in the **per-turn tail**, "never the system prompt:
  that's the prefix-cache prefix". Likewise `SESSION_CLOCK` (`server.py:~246`) is formatted **once at
  connect** and never re-formatted mid-session — a re-rendered clock string would invalidate the entire
  cached prefix every turn.
- `server.py:757-761` — an acknowledged, deliberate violation: tail-padding the final segment diverges it
  from the primed bytes on flush turns (≤3 s re-prefilled). "the honest-transcript win beats that."
- `llama.py:146` `-np 1` — one slot, so there is exactly one cache to keep warm

### Dependencies
A prefix-caching backend.

### Portability to Swift/macOS
**MEDIUM.** The discipline transfers to Anthropic/OpenAI **prompt caching**, where the same rule holds and
the same mistakes are just as costly: a timestamp, a session clock, or a rotating instruction anywhere in
the prefix invalidates the cache on every turn. The mechanism differs (explicit `cache_control`
breakpoints rather than automatic prefix matching), but the "nothing volatile above the cache breakpoint"
rule is identical and directly billable.

### Value to OpenClicky
**HIGH as a rule, zero as code.** Given CLAUDE.md's money rule (SDK-first to use the paid Claude Code
sign-in, REST only as fallback), prompt-cache discipline is directly a cost issue for OpenClicky. The
specific, checkable rules — no clock in the system prompt, per-turn notes in the tail, store turns
verbatim, media-only when warming — are worth adopting verbatim.

---

## 16. Camera-as-tool-call: the measured answer (completes §2)

`benchmarks/camerabench.py:31-41`, measured e4b / M3 Pro / 2026-08-02. Three architectures:

- **A (attach every turn — production, kept):** frame + audio in one request, frame primed during speech.
  A frame costs **50 context tokens** (not the ~300 `pipeline.py:33` estimates) and **~600 ms of prime
  GPU hidden under speech**. `answer_ok = 1.0` at **1.55 s median**.
- **B (head decides first):** decides **perfectly** — `cam_recall 1.0`, `cam_misfire 0.0` — "but its head
  runs before speech can start, adding **~2.2 s to EVERY turn**; vision answers land at **4.2 s**."
- **C (speak first, then decide, then re-answer):** **structurally broken**. The blind first reply "either
  denies having eyes or confidently hallucinates ('the round shape is blue', 'a picture of a cat')", the
  user hears it, and "the head then reads that answered reply as evidence no frame is needed" —
  `cam_recall 0.0`, `answer_ok 0.375`.

The stated conclusion (`camerabench.py:40-41`) is the transferable insight:

> "The speak-first shape that makes timers cheap is exactly what kills on-demand vision: an unanswerable
> question never survives to the head."

**Value to OpenClicky: HIGH.** OpenClicky's screenshot capture is on-demand today, i.e. arch B or C. This
benchmark says the on-demand shapes are the bad ones when the decider runs *after* speech, and quantifies
what "just attach it" actually costs (50 tokens, 600 ms hidden). Directly decision-relevant, since a
screenshot is OpenClicky's camera.

---

## Ranked port list (value ÷ effort)

| # | Capability | Effort | Value | Rationale |
| --- | --- | --- | --- | --- |
| 1 | **Modes as data** (`modes.py`, 50 lines) | trivial | HIGH | A flag table + clear-state-on-switch + a UI escape hatch that bypasses the model. One afternoon; immediately tidies OpenClicky's existing implicit modes. |
| 2 | **Floor management** (`floor_busy` / `drain_ready`) | small | HIGH | ~40 lines that stop the assistant talking over itself and the user. OpenClicky's async Agent Mode has this exact problem today. |
| 3 | **Proactive turn primitive** | small | HIGH | One guarded "app speaks first" path. Four guards, each from an observed failure. Prerequisite for anything async being *spoken*. |
| 4 | **Decoupled action head** | small-medium | HIGH | Measured recall 1.0 vs 0.955, and removes the markup-leak class *structurally*. Every OpenClicky backend supports structured output. Watch the second-call cost against paid APIs — needs prompt caching. |
| 5 | **smart-turn-v3 end-of-turn detection** | medium | HIGH | 0.96 acc @ 19 ms; nothing OpenClicky has resembles it. 8 MB ONNX + ~150 lines of log-mel to port to vDSP/Accelerate. Ranked below the free wins only on effort. |
| 6 | **Barge-in gate + phantom watchdog** | medium | HIGH | Sliding window (6-of-10 @ p>0.85) + 800 ms grace + reset watchdog. Comes with the documented macOS trap (system voice processing kills the mic) already solved. Needs a per-frame VAD probability source. |
| 7 | **Cache-stable ordering discipline** | trivial (audit) | HIGH | Not code — a checklist. No clock in the system prompt; per-turn notes in the tail; store turns verbatim. Directly a billing issue under OpenClicky's SDK-first money rule. |
| 8 | **Hostile-output defences** (`remember`, `NO_SPEECH_RE`, `echoes_instruction`) | small | MEDIUM-HIGH | Adopt as a hardening checklist. "Never store a degenerate turn" and "user-role text outranks current audio" are real, reproducible findings. |
| 9 | **Server-owned timers / deadlines** | small | MEDIUM-HIGH | Small feature, but generalizes: the host owns every clock; the model only phrases the announcement. Depends on #3. |
| 10 | **Reasoner delegation shape** | medium | HIGH value, but partly built | Parlor's fast-local + async-frontier split *is* OpenClicky's stated architecture. Port the shape (dedicated executor, speech-shaped answers, verbatim relay, answer-as-fallback, caps), not the HTTP. |
| 11 | **Attach-the-screenshot-every-turn policy** | small | MEDIUM | Act on camerabench: 50 tokens + 600 ms hidden beats a 2.2 s/turn pre-decision or a hallucinating blind reply. A policy change more than a code change. |
| 12 | **Context rotation on real token counts** | small | MEDIUM | Two specifics only: rotate on provider-reported usage, cut on a user-message boundary. |
| 13 | **300 ms in-WAV tail padding** | trivial | MEDIUM | One-line fix for a real class of end-of-word hallucination in any audio-to-model path. |
| 14 | **Transcript-first ordering** | small | MEDIUM | WER 0.00 vs 0.39, plus the UX win of showing what was heard ~0.3 s in. Only applies where a model does its own ASR. |
| 15 | **Sentence-pipelined TTS details** | trivial | LOW-MEDIUM | OpenClicky already streams TTS. Take only the `[.!?]+\s` regex, the drain-don't-return interrupt handling, and the `##`-cut. |
| 16 | **Speculative prefill** | high | LOW-MEDIUM | Needs KV-cache control. Only viable if OpenClicky ships a local llama.cpp/MLX sidecar; useless against Claude/OpenAI HTTP. |
| 17 | **Native audio input to the LLM** | high | LOW-MEDIUM | OpenClicky already has STT providers and an OpenAI Realtime path. The only new thing is an offline native-audio option, which costs a 6 GB model + a Homebrew dependency. |

---

## What CANNOT be ported

**Browser-only:**
- `getUserMedia` mic/camera capture and the WebAudio graph (`web/static/app.js`) — macOS uses
  AVFoundation / ScreenCaptureKit. Note `server.py:~855`: uvicorn binds `localhost` not `0.0.0.0`
  specifically because browsers only grant a secure context (and therefore `getUserMedia`) to
  `http://localhost`. This entire constraint disappears in a native app.
- `@ricky0123/vad-web` (Silero VAD as a Web Worklet). The Silero ONNX model itself ports; the JS harness
  does not.
- The whole WebSocket wire protocol (`frame`, `speech_chunk`, `flush`, `interrupt`, `ready`, `set_mode`,
  `cancel_timer`, `audio_start`, `text_delta`, `turn_final`, `audio_end`) exists only because client and
  server are separate processes. In OpenClicky they are the same process — this becomes function calls,
  and the `ready` frame / 30 s staleness escape (`server.py:~404`) becomes unnecessary because playback
  state is directly observable.

**Python / llama.cpp-only:**
- **Speculative prefill** (§5) — depends on llama.cpp's single-slot (`-np 1`) prefix cache and
  `cache_prompt: true`. No remote API exposes this.
- **Grammar-forced decoding at zero marginal cost** — `llama.py:185-188` compiles a JSON schema to GBNF
  server-side. Anthropic/OpenAI structured output is comparable in *effect* but not in cost model: the
  action head is cheap in Parlor only because it rides a warm local cache.
- The `transformers`-compatible log-mel extractor (`turn_detector.py:74-230`) is numpy-idiomatic and must
  be **rewritten**, not transliterated, for Accelerate/vDSP. Bit-exactness with the reference matters
  (the code goes out of its way to match float32-before-float64 ordering at `turn_detector.py:217-222`),
  so a Swift port needs a fixture-based equivalence test against the Python output.
- The llama-server process lifecycle (`llama.py:97-164`: binary discovery for both `llama-server` and the
  unified `llama serve`, build-number floor enforcement, `/health` polling) is only relevant if OpenClicky
  ships a local sidecar. Note OpenClicky's CLAUDE.md explicitly says **do not package runtimes** — so this
  is out of scope by project policy, not just by difficulty.
- `benchmarks/` and the pytest e2e suite spawn a real llama-server and drive it over WebSocket with
  synthesized speech. Not portable, but the *fixtures and methodology* (`benchmarks/fixtures.py`,
  degraded-audio cases reproducing live-mic failures) are a good model for how to validate a Swift port.

**Not portable because OpenClicky already has it (skip, don't port):**
- Kokoro TTS backends (`tts.py`) — OpenClicky has ElevenLabs/Cartesia and its own TTS routing.
- The reasoner's HTTP client (`reasoner.py:48-77`) — OpenClicky has Claude/OpenAI/Codex clients with a
  defined SDK-first ordering. Port the *scheduling*, not the transport.
- Gemma 4 model management (`llama.py:24-58`) — OpenClicky has `OpenClickyModelCatalog` and provider
  discovery.
