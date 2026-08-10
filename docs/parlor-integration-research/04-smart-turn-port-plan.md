# Smart-Turn-v3 Swift Port Plan

Source: `/tmp/parlor/src/parlor/turn_detector.py` (230 lines, BSD-2 from Pipecat + Apache-2.0 numpy
port of `transformers.WhisperFeatureExtractor`).
Target: `/Users/wowdd1/Dev/openclicky/cursor-buddy/`.
Template: `cursor-buddy/OpenClickyIntentClassifier.swift` (existing ONNX Runtime usage, actor shape).

**One line:** an 8 MB int8 Whisper-Tiny-encoder + linear head that answers "did the speaker finish
their thought?" from the last 8 s of audio in ~12-30 ms on CPU. The ONNX part is trivial (we already
run ORT). The real work is reproducing the Whisper log-mel front-end in Accelerate so the model does
not see garbage.

Infrastructure already present and reusable:

- ORT: `onnxruntime-swift-package-manager` 1.24.2 (`Package.resolved:40-46`), already linked and used
  at `cursor-buddy/OpenClickyIntentClassifier.swift:239-324`.
- Model download: `cursor-buddy/WhisperLocalModelManager.swift:104-180` (simple URLSession +
  Application Support dir) and the heavier
  `cursor-buddy/OpenClickyLocalModelDownloadService.swift:150-175` (HF tree API, sha256 verify).
- VAD: `cursor-buddy/SileroVADTrim.swift:41` (`speechOnly(_:) -> [Int16]`), currently **dead code** —
  `rg speechOnly cursor-buddy/` returns only the definition. No caller.
- PCM: `cursor-buddy/BuddyAudioConversionSupport.swift:11-70` (`BuddyPCM16AudioConverter`, resamples
  any tap format to Int16 mono at a target rate).
- Audio tap: `cursor-buddy/BuddyDictationManager.swift:806` (`installTap(bufferSize: 256)`).
- Activation modes: `cursor-buddy/OpenClickyWakeWordManager.swift:16-50`.

Nothing in the repo imports `Accelerate` today (`rg "import Accelerate" cursor-buddy/` → 0 hits).
This port introduces the first use.

---

## 1. Algorithm breakdown

Constants (`turn_detector.py:20-21`, `:74-79`): `SAMPLE_RATE=16000`, `WINDOW_SECONDS=8`,
`_N_FFT=400`, `_HOP_LENGTH=160`, `_N_MELS=80`, `_MEL_FLOOR=1e-10`, `_NORM_VARIANCE_EPS=1e-7`.
Fixed output shape `[1, 80, 800]`.

### 1.1 Windowing — `turn_detector.py:47-51`

```python
max_samples = 8 * 16000                      # 128000
if len(audio) > max_samples: audio = audio[-max_samples:]
elif len(audio) < max_samples: audio = np.pad(audio, (max_samples - len(audio), 0))
```

Note the pad tuple `(N, 0)` — **left**-padding with zeros, i.e. the utterance is right-aligned so its
end sits at the end of the tensor. This matters: right-align or the classifier reads silence as the
turn ending. (`compute_whisper_log_mel_features` at `:212-215` *also* pads, but on the right; because
`predict` already normalised the length to exactly 128000 that branch is dead in this call path.
Port `predict`'s left-pad, not the extractor's right-pad.)

Swift: a fixed `[Float]` scratch of 128000 with `vDSP.clear` + `memcpy` of the tail slice.

### 1.2 Waveform normalisation — `turn_detector.py:222`

```python
x = (x - x.mean()) / np.sqrt(x.var() + 1e-7)
```

Done in **float32**, *before* the spectrogram (the comment at `:217-220` is explicit that this
ordering mirrors `WhisperFeatureExtractor.__call__`). `np.var` is the *population* variance (ddof=0).

Swift/Accelerate:

```swift
var mean: Float = 0, sd: Float = 0
vDSP_normalize(x, 1, nil, 1, &mean, &sd)   // sd is population stddev (ddof=0)
var scale = 1.0 / (sd * sd + 1e-7).squareRoot()
var negMean = -mean
vDSP_vsadd(x, 1, &negMean, &x, 1, n)
vDSP_vsmul(x, 1, &scale, &x, 1, n)
```

Do **not** use `vDSP_normalize`'s own output (it divides by `sd`, not `sqrt(var + eps)`); take only
its mean/stddev outputs and apply the eps yourself.

### 1.3 Reflect pad + framing — `turn_detector.py:163-171`

```python
pad = 400 // 2                                                  # 200
padded = np.pad(waveform.astype(np.float64), (200, 200), mode="reflect")
windows = sliding_window_view(padded, 400)[::160]
```

`mode="reflect"` (not `symmetric`): `padded[199] == x[1]`, `padded[200] == x[0]`. Off-by-one here is
the single most likely source of a silent mismatch.

Frame count: `(128000 + 400 - 400)//160 + 1 = 801`. The trailing frame is dropped later (`:227`),
giving the 800 the model wants.

Swift: allocate `padded: [Float]` of 128400 once; fill the two reflected wings with
`vDSP_vrvrs`-style reversed copies (or a plain loop — 200 elements each, negligible).

### 1.4 Window + rFFT + power — `turn_detector.py:136-138`, `:172-176`

Window is a **periodic** Hann: `np.hanning(401)[:-1]`, i.e. `w[n] = 0.5 - 0.5*cos(2πn/400)`.
`vDSP_hann_window(&w, 400, Int32(vDSP_HANN_DENORM))` produces the *symmetric* variant — wrong. Build
it explicitly:

```swift
// periodic Hann, matches torch.hann_window / np.hanning(N+1)[:-1]
var hann = [Float](repeating: 0, count: 400)
for i in 0..<400 { hann[i] = 0.5 - 0.5 * cos(2.0 * .pi * Float(i) / 400.0) }
```

Then per frame: multiply by the window, zero-pad 400 → 512, real FFT, magnitude squared.
`_N_FFT=400` is not a power of two, so `vDSP.FFT` (radix-2) cannot take it directly. Two options:

- **(a)** `vDSP_DFT_zrop_CreateSetup(nil, 512, .FORWARD)` on a 512-point zero-padded frame — this is
  *not* equivalent to a 400-point DFT and will produce different bins. Rejected.
- **(b)** `vDSP_DFT_zop_CreateSetup(nil, 400, vDSP_DFT_FORWARD)` — vDSP's DFT accepts any length that
  factors into 2/3/5 (`400 = 2^4 · 5^2`), so 400 is legal and exact. Use the complex-to-complex
  variant with a zero imaginary input, then keep bins `0...200` (`_N_FFT//2 + 1 = 201`). This is the
  correct choice.

```swift
let dft = vDSP_DFT_zop_CreateSetup(nil, 400, .FORWARD)!   // 400 = 2^4·5^2, legal for vDSP DFT
// per frame:
vDSP_vmul(framePtr, 1, hann, 1, &reBuf, 1, 400)
vDSP_vclr(&imBuf, 1, 400)
vDSP_DFT_Execute(dft, reBuf, imBuf, &outRe, &outIm)
// power = re^2 + im^2 over bins 0..<201
vDSP_vsq(outRe, 1, &re2, 1, 201)
vDSP_vma(outIm, 1, outIm, 1, re2, 1, &power, 1, 201)
```

`np.abs(spec)**2` is exactly `re² + im²`; do **not** compute `vDSP_zvabs` then square (that adds an
avoidable sqrt/square round-trip and loses bits).

Reference computes this in **float64** (`:164-165`, "promotes to float64 internally"). Swift will run
float32. See Risks.

Result: `magnitudes[201][801]`, transposed to `(bins, frames)` at `:176`.

### 1.5 Slaney mel filterbank — `turn_detector.py:82-149`

```python
# hz -> mel                                          (:82-91)
mels = 3.0 * freq / 200.0
if freq >= 1000: mels = 15.0 + log(freq/1000) * (27.0/log(6.4))
# mel -> hz                                          (:94-103)
freq = 200.0 * mels / 3.0
if mels >= 15.0: freq = 1000.0 * exp((log(6.4)/27.0) * (mels - 15.0))
```

Then (`:118-133`): 82 mel points linearly spaced over `[mel(0), mel(8000)]`, converted back to Hz;
`fft_freqs = np.linspace(0, 8000, 201)`; triangular up/down slopes; Slaney area normalisation
`enorm = 2.0 / (filter_freqs[2:82] - filter_freqs[0:80])`.

Swift: compute this **once** in `Float64` at first use, then store as a flat `[Float]` of
`80 * 201 = 16080` in the transposed layout `melFilters[mel][bin]` ready for a single GEMM. Keep the
`Double` intermediate math — the filterbank is built once, precision is free here, and rounding the
edge frequencies in Float32 shifts triangle boundaries by up to a full bin.

### 1.6 Mel projection + log + clamp — `turn_detector.py:225-230`

```python
mel_spec = np.maximum(1e-10, _MEL_FILTERS.T @ magnitudes)   # (80, 801)
log_spec = np.log10(mel_spec)
log_spec = log_spec[:, :-1]                                  # drop trailing frame -> (80, 800)
log_spec = np.maximum(log_spec, log_spec.max() - 8.0)        # global max, AFTER the drop
log_spec = (log_spec + 4.0) / 4.0
```

Three ordering traps: the floor is applied *before* log10; the trailing frame is dropped *before* the
dynamic-range clamp; and `log_spec.max()` is a **global** max over all 80×800, not per-frame.

Swift:

```swift
// (80x201) @ (201x801) -> (80x801)
cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
            80, 801, 201, 1.0,
            melFilters, 201, magnitudes, 801, 0.0, &melSpec, 801)
var floor: Float = 1e-10
vDSP_vthr(melSpec, 1, &floor, &melSpec, 1, 80 * 801)   // max(1e-10, x)
// drop trailing frame: copy 800 of every 801-stride row into melSpec800[80*800]
vvlog10f(&logSpec, melSpec800, [Int32(80 * 800)])
var maxV: Float = 0
vDSP_maxv(logSpec, 1, &maxV, 80 * 800)
var lo = maxV - 8.0
vDSP_vthr(logSpec, 1, &lo, &logSpec, 1, 80 * 800)
var four: Float = 4.0, quarter: Float = 0.25
vDSP_vsadd(logSpec, 1, &four, &logSpec, 1, 80 * 800)
vDSP_vsmul(logSpec, 1, &quarter, &logSpec, 1, 80 * 800)
```

`vDSP_vthr` is `max(x, threshold)` — exactly `np.maximum` with a scalar. `vvlog10f` is the vForce
base-10 log; do not substitute `log(x) * (1/ln10)`, the rounding differs.

Output is row-major `(80, 800)` float32 in `[-1, 1]` — the ONNX `input_features` layout with an
added leading batch dim of 1.

### 1.7 ONNX inference + threshold — `turn_detector.py:54-58`

```python
outputs = self._session.run(None, {"input_features": np.expand_dims(log_mel, 0)})
probability = outputs[0][0].item()
return probability > 0.5, probability
```

There is **no sigmoid in the Python** (`rg sigmoid turn_detector.py` → 0 hits). The output is already
a probability, so the sigmoid is baked into the exported graph. The Swift side must not apply one.

Session options (`:33-37`): `ORT_SEQUENTIAL`, inter-op 1, intra-op 2, `ORT_ENABLE_ALL`. Warmup with
one zero-audio `predict` at load (`:41`) — the first run pays graph init.

---

## 2. Swift API sketch

Two files, matching the house split (small focused files, `OpenClickyIntentClassifier` shape):

**`cursor-buddy/OpenClickyWhisperLogMel.swift`** (~200 lines) — pure, synchronous, no ORT dependency
so it is unit-testable on its own:

```swift
import Accelerate

/// numpy-only Whisper log-mel front-end ported from Parlor's
/// `turn_detector.py:152-230` (Apache-2.0, HuggingFace `WhisperFeatureExtractor`).
/// Fixed to smart-turn-v3's shape: 8 s @ 16 kHz -> [80, 800] float32 in [-1, 1].
final class OpenClickyWhisperLogMel {
    static let sampleRate = 16_000
    static let windowSamples = 128_000   // 8 s
    static let nFFT = 400
    static let hopLength = 160
    static let melBands = 80
    static let frames = 800

    /// Precomputed once: periodic Hann + Slaney filterbank + DFT setup.
    init()
    deinit  // vDSP_DFT_DestroySetup

    /// `samples` may be any length; shorter input is LEFT-zero-padded and
    /// longer input keeps its tail (matches `turn_detector.py:47-51`).
    /// Returns 80*800 row-major floats. Not thread-safe: holds scratch buffers.
    func features(from samples: [Float]) -> [Float]
}
```

**`cursor-buddy/OpenClickyTurnDetector.swift`** (~230 lines) — the ORT wrapper, an `actor` exactly
like `OpenClickyIntentClassifier` (`OpenClickyIntentClassifier.swift:63-93`):

```swift
struct OpenClickyTurnPrediction: Sendable {
    let isComplete: Bool      // probability > threshold
    let probability: Float
    let latencyMilliseconds: Double
}

actor OpenClickyTurnDetector {
    static let shared = OpenClickyTurnDetector()

    /// Parlor uses 0.5 (`turn_detector.py:58`). turnbench sweeps
    /// 0.2...0.8; raising it trades dead air for fewer interruptions.
    static let defaultThreshold: Float = 0.5

    private var extractor: OpenClickyWhisperLogMel?
    private var didAttemptLoad = false
    #if canImport(onnxruntime)
    private var ortEnv: ORTEnv?
    private var ortSession: ORTSession?
    #endif

    /// Locates the .onnx (Application Support first, bundle fallback), builds
    /// the ORT session with Parlor's options, runs one zero-audio warmup.
    /// Idempotent; false on any failure so callers degrade to silence-timeout.
    @discardableResult
    func bootstrap() async -> Bool

    /// 16 kHz mono float32. Nil when the model is not ready.
    func predict(_ samples: [Float],
                 threshold: Float = defaultThreshold) async -> OpenClickyTurnPrediction?

    /// Convenience for the Int16 path the dictation tap already produces.
    func predict(pcm16 samples: [Int16],
                 threshold: Float = defaultThreshold) async -> OpenClickyTurnPrediction?
}
```

Model plumbing mirrors `WhisperLocalModelManager` (the lighter of the two download paths — this is a
single 8 MB file, the HF-tree machinery in `OpenClickyLocalModelDownloadService` is overkill):

```swift
// cursor-buddy/OpenClickyTurnDetectorModel.swift (~90 lines)
enum OpenClickyTurnDetectorModel {
    static let fileName = "smart-turn-v3.2-cpu.onnx"
    static let estimatedBytes: Int64 = 8_700_000    // ~8.7 MB int8
    static let downloadURL = URL(string:
        "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/\(fileName)")!
    /// Reuses WhisperLocalModelManager.modelDirectory() —
    /// ~/Library/Application Support/OpenClicky/models  (WhisperLocalModelManager.swift:104-110)
    static func modelURL() -> URL
    static func isInstalled() -> Bool
}
```

At 8.7 MB it is small enough to **bundle** under `AppResources/OpenClicky/smart-turn/` and skip the
download UI entirely — recommended for v1, matching how `mirage-routelet/embedder.onnx` ships
(`OpenClickyIntentClassifier.swift:258-260`). Keep the download path as the fallback for a later
GPU-variant opt-in.

---

## 3. Integration plan

### 3.1 Where the audio comes from

`BuddyDictationManager` currently feeds tap buffers straight to the transcription provider and
throws them away (`BuddyDictationManager.swift:806-818`); nothing retains PCM. The port needs a
rolling 8 s ring.

Add alongside `audioBuffersCapturedBeforeProviderReady`
(`BuddyDictationManager.swift:286`):

```swift
/// Rolling 8 s of 16 kHz mono float32 for the end-of-turn classifier.
/// Written on the audio queue inside the tap, read on the MainActor under
/// `turnDetectorQueue.sync`. 128000 floats = 512 KB, allocated once.
private var turnDetectorRing = OpenClickyAudioRingBuffer(capacity: 128_000)
private let turnDetectorConverter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
private var lastTurnCheckAt: TimeInterval = 0
private var isTurnCheckInFlight = false
```

and one line in the tap closure at `BuddyDictationManager.swift:806-809`, after the existing
`appendAudioBuffer`, gated so it is inert unless the new activation mode is on.

`BuddyPCM16AudioConverter` (`BuddyAudioConversionSupport.swift:25`) already handles the
device-rate → 16 kHz mono conversion; it returns `Data` of Int16, so divide by 32768 into the ring.
`SileroVADTrim.swift:56-59` does the same conversion inline and is the precedent.

### 3.2 Cadence

Parlor does **not** poll — it is event-driven. The chain is:

1. Browser Silero VAD, `redemptionMs: 300`, `minSpeechMs: 300`, `preSpeechPadMs: 300`,
   `positiveSpeechThreshold: 0.5` (`/tmp/parlor/src/parlor/web/static/app.js:771-780`). Speech-end
   fires ~300 ms after the last speech frame.
2. Speech-end sends the utterance; the server runs the detector **once** per turn
   (`/tmp/parlor/src/parlor/server.py:737-742`), off the event loop via `run_in_executor`.
3. On `complete == False` the server holds the audio and replies `turn_incomplete`
   (`server.py:750-756`); the client arms a **2500 ms** flush timer
   (`app.js:437-450`). If no new speech arrives in that window the client sends `{type:'flush'}`
   and the server answers whatever it holds, skipping the detector (`server.py:717`, `:737`).
4. While speaking, ~3 s chunks stream for cache prefill (`app.js:496`, `CHUNK_SECONDS = 3.0`) —
   that is a llama.cpp prefix-cache optimisation, irrelevant to us.

So: **one inference per speech-end, plus a 2.5 s flush fallback.** Not a timer loop. Copy that.
If you want the detector to also run mid-utterance as a debounce, cap it at one call per 250 ms with
`isTurnCheckInFlight` as the mutex — but the event-driven shape is what Parlor validated.

### 3.3 Interaction with SileroVAD

`SileroVADTrim.speechOnly` is currently unreferenced. Two distinct jobs, do not conflate them:

- Silero answers "is there speech in this 36 ms frame" — it is the **trigger**.
- smart-turn answers "was that a complete thought" — it is the **gate**.

Plan: promote `SileroVADTrim` from a batch trimmer into a streaming frame tagger (it already loops
576-sample chunks at `SileroVADTrim.swift:62-76`; expose a `process(chunk) -> Float` passthrough and
a small speech-start/speech-end state machine with Parlor's 300 ms redemption). Silero fires
speech-end → smart-turn reads the ring → complete? finalize : hold + arm the 2.5 s flush.

Crucially smart-turn must see the **untrimmed, un-normalised** tail. `speechOnly` peak-normalises to
±16384 (`SileroVADTrim.swift:113-125`) for Whisper's benefit; that path must not feed the detector,
because smart-turn's own zero-mean/unit-variance step (§1.2) already handles level and the trailing
silence it strips is part of what the classifier reads.

### 3.4 New activation mode

Add a fourth case to `OpenClickyVoiceActivationMode`
(`cursor-buddy/OpenClickyWakeWordManager.swift:16-50`):

```swift
case smartTurn = "smart_turn"          // tap to start, model decides when you're done

var label: String { case .smartTurn: return "Smart turn" }
var subtitle: String { case .smartTurn: return "Tap once, stops when you finish" }
var usesWakeWord: Bool { self != .pushToTalk && self != .smartTurn }
var usesEndOfTurnDetection: Bool { self == .smartTurn }
```

`usesWakeWord` is currently `self != .pushToTalk` (`:42-44`) — that expression must be updated or
the new mode silently arms the wake-word listener. Also touch the settings picker at
`cursor-buddy/OpenClickySettingsWindowManager.swift:681` (it iterates `allCases`, so it picks up the
case for free, but the copy should be reviewed) and the profile defaults in
`cursor-buddy/OpenClickyProfile.swift:53-139`.

Flow in that mode: user taps → `startPersistentDictationFromMicrophoneButton`
(`BuddyDictationManager.swift:341`) → Silero speech-end → detector → `isComplete` calls the existing
`stopPersistentDictationFromMicrophoneButton` (`:391`), which already runs the full
teardown/finalize path via `stopPushToTalk` (`:637-699`). Incomplete → keep recording, arm a 2.5 s
`DispatchWorkItem` flush that force-stops. The `finalizeFallbackWorkItem` pattern at `:677-698` is
the exact idiom to copy.

Surface `probability` through a `@Published private(set) var lastTurnProbability: Float?` so the
notch/bubble can show the hold state the way Parlor's UI does (`p_complete` in `server.py:753`).

---

## 4. Alternative: CoreML with mel baked in

**Approach:** `coremltools.convert(onnx_or_torch)` on smart-turn-v3, prepending the STFT + mel
projection as graph ops. `coremltools` has had `torch.stft` support since 6.x, and the mel filterbank
is a constant `MatMul`.

**Pros**

- Numerical fidelity becomes a *conversion-time* property verified once against PyTorch, not a
  hand-written invariant re-verified on every Accelerate edit. This kills Risk #1 outright — by far
  the strongest argument.
- ANE/GPU eligible. An 8M-param int8 encoder on ANE would land in single-digit ms.
- Drops the ~200 lines of Accelerate and its scratch-buffer lifetime management.
- `SileroVAD` already ships as CoreML in this repo (`SileroVADTrim.swift:17` imports `SileroVAD`), so
  the pattern is familiar.

**Cons**

- One-time offline toolchain (Python, coremltools, PyTorch) plus a converted `.mlpackage` we now own
  and must re-derive whenever Pipecat ships v3.3. The ONNX is a drop-in upgrade; a converted model is
  not.
- `torch.stft` → CoreML conversion is the flaky part. Reflect padding and non-power-of-2 `n_fft=400`
  are exactly the cases where the converter falls back to a decomposed conv-based STFT whose output
  differs in the last bits. You would still need §7's fixture comparison to prove it, so the
  verification burden does not vanish — it moves.
- ANE requires fp16, which is a *larger* numerical departure from the float64 reference than the
  float32 Accelerate path. Likely fine for a 0.5 threshold, but it is an unforced change.
- The model file grows (fp16 unquantized ≈ 16-32 MB vs 8.7 MB int8).

**Recommendation:** ship ONNX + Accelerate first. We already link ORT, already have the exact
reference implementation to port line-by-line, and §7's fixture harness makes the fidelity risk
measurable rather than theoretical. Revisit CoreML only if profiling shows the log-mel dominating,
which at 800 frames × one 400-point DFT is implausible (~1-2 ms).

---

## 5. Effort estimate

| Component | Hours |
|---|---|
| `OpenClickyWhisperLogMel` — Hann, reflect pad, DFT loop, power spectrum | 4 |
| Slaney filterbank builder (`_hertz_to_mel_slaney` ... `_build_mel_filterbank`) | 2 |
| Mel GEMM + log10 + clamp + scale chain | 1.5 |
| Numerical debugging vs numpy fixtures (the real cost — budget generously) | 6 |
| `OpenClickyTurnDetector` actor: ORT session, warmup, predict | 2.5 |
| Model plumbing: bundle resource + Xcode target membership + install check | 1.5 |
| `OpenClickyAudioRingBuffer` + tap wiring in `BuddyDictationManager` | 3 |
| `SileroVADTrim` → streaming speech-start/end state machine | 4 |
| `.smartTurn` activation mode: enum, `usesWakeWord` fix, settings copy, profiles | 2.5 |
| Flush-timer / hold state machine + `lastTurnProbability` surfacing | 3 |
| Test harness: fixture generation + Swift comparison tests | 4 |
| **Total** | **34 h** (~4.5 days) |

Split: ~13.5 h is the feature extractor and its verification; ~12.5 h is dictation/VAD/mode
integration; ~8 h is model plumbing and tests. The extractor half is fully parallelisable with the
integration half — the seam is the `features(from:) -> [Float]` signature.

---

## 6. Risks

**R1 — log-mel fidelity (HIGH, the whole ballgame).** The reference computes the spectrogram in
float64 (`turn_detector.py:164-165`, `:173`); Swift will use float32. Expect ~1e-6 relative drift,
which is harmless. What is *not* harmless is a structural bug: symmetric-vs-periodic Hann, reflect
off-by-one, the trailing-frame drop landing on the wrong side of the max clamp, or a per-frame
instead of global max. Each produces a plausible-looking 80×800 tensor and a silently wrong
probability. Mitigation is entirely §7 — do not write a line of the extractor before the fixture
harness exists.

**R2 — `vDSP_hann_window` is the wrong window.** It emits the symmetric variant. Silent, small, and
it will cost you a day if you assume the framework helper matches numpy. Hand-roll it (§1.4).

**R3 — non-power-of-2 FFT.** `vDSP.FFT` / `vDSP_fft_zrip` cannot do 400 points. Using 512 with
zero-padding is *not* the same transform. Must use `vDSP_DFT_zop_CreateSetup(nil, 400, .FORWARD)`.

**R4 — threading.** The tap closure runs on a realtime audio thread; `predict` must never be called
there. Ring writes are the only audio-thread work; the actor hop plus ~15-30 ms of ORT happens off
it. `OpenClickyWhisperLogMel` holds mutable scratch and is explicitly not thread-safe — keep it
owned by the actor. Follow the existing precedent: `updateAudioPowerLevel`
(`BuddyDictationManager.swift:1085-1139`) does its gating on the audio queue and hops to main only
when needed; that is the model to copy, and its FIX comment at `:1097-1108` documents why.

**R5 — latency budget.** Parlor measures ~20 ms end to end (README:31); Daily's own number is 12 ms
CPU. Budget: log-mel 1-3 ms + ORT 12-25 ms = under 30 ms, well inside the 300 ms Silero redemption,
so the detector adds no perceptible delay. If the p95 in `turnbench`-style measurement exceeds
~60 ms, check that intra-op threads are set to 2 and warmup actually ran.

**R6 — download size.** 8.7 MB int8. Negligible next to the 547 MB Whisper Q5 the app already
downloads (`WhisperLocalModelManager.swift:44-46`). Bundle it.

**R7 — accuracy is in-domain-optimistic.** `turnbench.py:1-40` warns that smart-turn's published
score is measured on its own test split, and that LiveKit's eot-bench "scores smart-turn v3.2 far
more harshly." Also: TTS-synthesized clips always read as finished, so any synthetic evaluation
flatters LLM baselines and punishes the acoustic model. Expect worse-than-paper behaviour on real
users, and keep the 2.5 s flush timer as the safety net — it is what makes a false "incomplete"
merely a delay rather than a hang.

**R8 — non-English.** Parlor's own benchmark defaults to `--langs eng` and notes that for most other
languages every clip in the test set is synthetic (`turnbench.py:32-40`). Treat non-English
end-of-turn quality as unmeasured.

---

## 7. Test plan

### 7.1 Golden fixtures from the Python reference

Generate once, check into the repo as a small binary blob + JSON manifest:

```python
# scratch script, run against the cloned /tmp/parlor
import numpy as np, sys
sys.path.insert(0, "/tmp/parlor/src")
from parlor.turn_detector import compute_whisper_log_mel_features

rng = np.random.default_rng(0)
cases = {
    "silence":    np.zeros(128000, dtype=np.float32),
    "impulse":    np.eye(1, 128000, 64000, dtype=np.float32).ravel(),
    "dc":         np.full(128000, 0.5, dtype=np.float32),
    "sine_440":   np.sin(2*np.pi*440*np.arange(128000)/16000).astype(np.float32),
    "noise":      rng.standard_normal(128000).astype(np.float32) * 0.1,
    "short_1s":   rng.standard_normal(16000).astype(np.float32) * 0.1,   # exercises left-pad
}
for name, x in cases.items():
    x.tofile(f"Tests/fixtures/turn/{name}.f32")
    compute_whisper_log_mel_features(
        np.pad(x, (128000 - x.size, 0)) if x.size < 128000 else x[-128000:],
        do_normalize=True,
    ).astype(np.float32).tofile(f"Tests/fixtures/turn/{name}.mel.f32")
```

Each `.mel.f32` is 80·800·4 = 256 KB; six cases ≈ 1.5 MB checked in. Acceptable.

**Not bit-for-bit.** float64-vs-float32 makes exact equality impossible and chasing it is wasted
effort. Assert instead:

- `max |swift - numpy| < 1e-4` (values live in `[-1, 1]`, so this is ~1e-4 absolute).
- mean absolute error `< 1e-5`.
- shape exactly `80 × 800`.
- `silence` and `dc` must match to `< 1e-6` — they have no cancellation, so any structural bug
  (window shape, pad mode, frame alignment) shows up there loudly while the noisy cases hide it.

Stage the assertions so a failure localises: dump and compare the intermediate tensors too — the
normalised waveform (128000), the padded buffer (128400), the power spectrogram (201×801), the raw
mel (80×801) — each as its own fixture. A mismatch that first appears at the power spectrogram is
a windowing/FFT bug; one that first appears at the mel is a filterbank bug. Without the intermediates
you get one boolean and no direction.

### 7.2 End-to-end parity

Feed each fixture through the full Swift `predict` and compare the probability against Python's
`TurnDetector.predict` on the same bytes. Tolerance `< 0.01` absolute; both run the same ONNX graph,
so anything larger means the features diverged.

### 7.3 Accuracy benchmark, mirroring `turnbench.py`

Methodology from `/tmp/parlor/benchmarks/turnbench.py`:

- Dataset `pipecat-ai/smart-turn-data-v3.2-test`, label column `endpoint_bool`, real human clips only
  (`synthetic=false`), balanced complete/incomplete, resampled to 16 kHz mono WAV
  (`turnbench.py:151-186`; `fixtures.py:19` `TARGET_SR = 16000`).
- Metrics (`turnbench.py:score`): accuracy, `recall_complete` (missing a finished turn = dead air),
  `recall_incomplete`, `interrupt_rate` = `fp / n_incomplete` (cutting in on an unfinished turn — the
  failure users actually hate), plus `ms_p50` / `ms_p95`.
- Threshold sweep over `0.2 … 0.8` (`turnbench.py:sweep_threshold`) so `defaultThreshold` is tuned
  on our audio path rather than inherited.

For the port, the cheap version: run the same cached WAV manifest through both implementations and
assert the Swift confusion matrix is **identical** to Python's. Same model, same clips — any
disagreement is a feature-extraction bug, and this catches drift the six synthetic fixtures miss.

### 7.4 Integration tests

- `.smartTurn` selected → `usesWakeWord == false` (guards the R-item in §3.4).
- Model missing → `bootstrap()` returns false, mode degrades to a plain silence timeout, no crash.
- Ring buffer: writes from a background queue while the actor reads; assert 128000-sample tail
  correctness across the wrap boundary.
- Flush timer: simulate a permanent "incomplete" verdict and assert the session still finalizes at
  2.5 s.

### 7.5 Verification command

Per `CLAUDE.md`, no `xcodebuild` from the terminal:

```sh
swiftc -parse cursor-buddy/OpenClickyWhisperLogMel.swift \
             cursor-buddy/OpenClickyTurnDetector.swift \
             cursor-buddy/OpenClickyTurnDetectorModel.swift
```

Full builds and any TCC-touching runs go through Xcode.

---

## Port log — front-end done, verified numerically (2026-08-10)

`cursor-buddy/OpenClickyWhisperLogMel.swift`, checked against parlor's
Python reference by `scripts/verify-logmel.sh`:

```
swift front-end: 12 ms for 8 s of audio
mel: max 0.001336  mean 0.00001382  (11 of 64000 above 1e-3)
p(complete): reference 0.586003  swift 0.583848  delta 0.0021550
PASS
```

The threshold is on the MODEL'S OUTPUT, not on the mel values. Swift runs
float32 where the reference promotes to float64, so some mel delta is
unavoidable; what matters is whether it moves the decision. A 1-ulp change
to the input waveform already moves the reference by 7.7e-5, which sets
the scale.

### Two corrections to this plan

**§1.4 is wrong about vDSP.** The plan states that `vDSP_DFT_zop` accepts
"any length that factors into 2/3/5, and 400 = 2^4 · 5^2, so 400 is legal
and exact". It is not — `vDSP_DFT_zop_CreateSetup` returns nil for 400.
Probed empirically: 320, 480, 512 and 640 are accepted; 400, 800 and 1200
are rejected. The real rule is f·2ⁿ with f in {1,3,5,15}.

The plan was right to reject zero-padding to 512 (it moves the bin
centres). With both documented options gone, the port computes the 201
needed bins directly via two `cblas_sgemv` calls against precomputed
cos/sin tables. That is ~80k multiply-adds per frame and still lands at
12 ms for the whole 8 s window, so the O(n²) is irrelevant here.

**The plan omits waveform normalisation entirely.** `transformers` runs
`do_normalize=True` — zero-mean, unit-variance over the waveform, before
any of the spectrogram work. Without it every one of the 64000 outputs is
off by a uniform ~0.21, because the whole spectrogram shifts and the
global max used for the dynamic-range clamp shifts with it. A constant
offset everywhere reads like a scaling bug in the final `(x+4)/4` chain,
not like a missing first step, which is what made it expensive to find.

### The traps the plan called correctly

All five, and each cost nothing because it was written down:

* periodic vs symmetric Hann — `vDSP_hann_window` gives the wrong one
* reflect vs symmetric padding, and the off-by-one in the left wing
* global max over all 80×800, not per-frame
* 801 frames computed, trailing one dropped
* sigmoid baked into the ONNX graph — do not add another

### One the plan could not have called

The right-hand reflect wing was written in the correct *values* but
reverse *order*. That preserves the min, max and mean of the padded
buffer, so only the final frame's spectrum differs: 79913 of 80000
outputs still matched, and the error looked like a boundary artefact
rather than a padding bug. Worth noting because "almost everything
matches" was actively misleading here — the diagnosis only landed after
dumping the reference's padded buffer and comparing element by element.

### Inference done too — and one more trap, hit despite being documented

`cursor-buddy/OpenClickySmartTurnDetector.swift`. The verifier now covers
real speech, not just a synthetic sweep:

```
sweep     mel max 0.001336  p ref 0.3475 swift 0.3386  agree
complete  mel max 0.003052  p ref 0.9759 swift 0.9836  agree
cutoff    mel max 0.002208  p ref 0.0353 swift 0.1312  agree

discrimination: complete 0.9836 - cutoff 0.1312 = 0.8525
```

"I need you to open the settings window." scores 0.98; "I need you to open
the" scores 0.13. That gap is the feature working.

**The sigmoid trap, which this plan lists, caught me anyway.** The output
tensor is *named* `logits`, so I applied a sigmoid to it. It is already a
probability: feeding all-zeros, all-+5 and all--5 returns 0.9889, 0.8341
and 0.9870 — always inside (0,1) — and parlor reads the value straight
into `probability`. A second sigmoid squashes everything toward 0.5 and
makes any threshold meaningless, while still returning numbers that look
entirely reasonable. Caught by probing the graph with extreme inputs, not
by reading.

**The acceptance criterion had to change.** An absolute probability bound
was wrong: injecting random mel noise of ±1e-4 — smaller than our float32
delta — moves p by 0.29 on the cut-off clip. The model is that steep near
p=0, so a tight bound measures its sensitivity rather than the port's
fidelity. The verifier now requires decision agreement plus a
discrimination margin above 0.5.

That also corrects a number reported earlier in this log: the "reference
0.586003" figure was itself a double-sigmoid artefact. The true value for
the sweep is 0.3475.

### Remaining

The audio ring buffer and the wiring into `SKIModeHandsFreeSession`, which
currently pays a flat 2 s hangover. Both halves it depends on — features
and inference — are now measured rather than assumed.
