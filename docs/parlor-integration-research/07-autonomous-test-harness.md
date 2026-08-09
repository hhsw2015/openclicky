# Autonomous Test Harness for the Parlor → OpenClicky Integration

Date: 2026-08-08
Inputs: `05-integration-plan.md` (gates), `04-smart-turn-port-plan.md` (§7 fidelity
spec), `/tmp/parlor/benchmarks/{fixtures,turnbench}.py`,
`scripts/run-provider-catalog-tests.sh`, `scripts/test-mcp-sensor.sh`,
`cursor-buddy/OpenClickyExternalControlBridge.swift`.

Goal: an AI agent runs every gate in 05 §7 end-to-end, gets a numeric
pass/fail, and iterates with **zero human involvement**.

Contents:

- §0 What the sandbox actually allows (verified on this machine)
- §1 Three tiers, and which gate uses which
- §2 Shared harness conventions
- §3 Gate A — does grounding improve routelet accuracy (Tier 1)
- §4 Gate B — E4B first-token latency (Tier 1 external / Tier 2 in-app)
- §5 Gate C — Chinese audio quality (Tier 1)
- §6 Gate 1 — smart-turn Chinese accuracy (Tier 1)
- §7 Numerical fidelity — log-mel port (Tier 1)
- §8 Gate 3 — self-answer accuracy, zero wrong answers (Tier 2)
- §9 Gate 4 — curation must not regress answer quality (Tier 2)
- §10 Regression suite (Tier 1 + Tier 2)
- §11 CI-style runner
- §12 What still needs a human

---

## 0. What the sandbox actually allows

Verified by running it, not assumed.

### 0.1 Builds are allowed. The thing to protect is TCC

`CLAUDE.md`'s "no `xcodebuild`" rule exists to protect **TCC permission
grants**, not to ban compilation. `scripts/fast-install.sh:8,30` signs with
a *fixed* identity, `"OpenClicky Dev Sign"`, and uses
`--preserve-metadata=entitlements,identifier`. A stable
(cert, bundle-id, entitlements) triple keeps the TCC designated requirement
matching across rebuilds, so microphone / screen-recording / accessibility
grants survive. A raw `xcodebuild` with ad-hoc (`-`) or rotating signing
produces a new signature identity, macOS treats it as a different app, and
every permission needs a human to re-grant.

Consequence for this harness:

- **`bash scripts/fast-install.sh` is the sanctioned autonomous build+install
  path.** It rebuilds Debug incrementally, re-signs with the stable cert,
  swaps `/Applications/OpenClicky.app`, and relaunches. ~15-40 s.
- **Never** call `xcodebuild` directly, and never pass
  `CODE_SIGN_IDENTITY="-"` to a build whose output reaches `/Applications`.
  (`fast-install.sh` builds ad-hoc then *re-signs* at step 2 — that ordering
  is load-bearing, do not "simplify" it.)
- `scripts/sign-and-install.sh` (Release, slim, strip, 2-5 min) is for
  perf measurement runs only.

This means **runtime end-to-end testing is in scope for automation.**

### 0.2 Verified tool inventory

| Capability | Status | Evidence |
| --- | --- | --- |
| `xcrun swiftc` on shipped sources | Works, existing pattern | `scripts/run-provider-catalog-tests.sh:126` |
| `swift build` (SwiftPM, no Xcode project) | **Works, incl. ORT** | probe built `onnxruntime-swift-package-manager` 1.24.2 in 24 s |
| `bash scripts/fast-install.sh` | Sanctioned, TCC-stable | §0.1 |
| Control bridge on `127.0.0.1:32123` | Live drive surface | `scripts/test-mcp-sensor.sh`, `scripts/test-external-control-bridge.sh` |
| `openclicky_simulate_voice_turn` | **Returns `assistantText` + `elapsedMs` synchronously** | `OpenClickyExternalControlBridge.swift:4097-4192` |
| `openclicky_set_profile` | Switches lane end-to-end before a turn | same file:1337-1347 |
| `openclicky_simulate_ski_utterance` | Writes `.oc/events.jsonl` | same file:4196-4231 |
| `whisper-cli` (whisper.cpp 1.9.1) | **Already installed** at `/opt/homebrew/bin/whisper-cli` | reference STT for Gate C, free |
| `say -v` Chinese voices | ~14 zh_CN/zh_TW (Tingting, Meijia, Eddy, Flo, Reed…) | free Chinese TTS with known ground truth |
| `python3` + numpy + onnxruntime 1.22 | Installed | numpy reference for §7 |
| `uv` | `~/.local/bin/uv` — can run `/tmp/parlor` as-is | Gate B/1 |
| `brew`, `ffmpeg` | Installed | — |
| `cursor-buddyTests/` XCTest | Needs `xcodebuild test` → **not used**; port anything valuable into a Tier 1 script | — |

### 0.3 Two facts that unblock Tier 1, both verified

**Bundle resources resolve next to a CLI binary.** `OpenClickyIntentClassifier.bootstrap()`
calls `Bundle.main.url(forResource:…, subdirectory: "mirage-routelet")`. For a
`swiftc`/`swift build` CLI binary, `Bundle.main.resourcePath` is the directory
holding the binary. So:

```sh
ln -sfn "$ROOT/AppResources/OpenClicky/mirage-routelet" "$OUT/mirage-routelet"
```

is enough. Confirmed: `bootstrap: true` against the real 127 MB
`embedder.onnx`. **No change to the shipped classifier needed** — the harness
tests the shipped code path, not a fork.

**The ORT module is named differently under SwiftPM.** The Xcode project
exposes the product as `onnxruntime` (`project.pbxproj:1168`), which is why
the shipped source writes `#if canImport(onnxruntime)`. Under bare `swift build`
the *module* is `OnnxRuntimeBindings`; `canImport(onnxruntime)` is false and
`embed()` silently returns `nil` — the harness would report `bootstrap: true`
and every classification `nil`, looking like a model bug. `-module-alias` and
`moduleAliases:` both fail (ObjC target / `unexpectedCycle`). The working fix
is a one-line `sed` at harness-build time:

```sh
sed -e 's/canImport(onnxruntime)/canImport(OnnxRuntimeBindings)/g' \
    -e 's/^import onnxruntime$/import OnnxRuntimeBindings/' \
    "$ROOT/cursor-buddy/OpenClickyIntentClassifier.swift" \
    > "$PKG/Sources/rt/OpenClickyIntentClassifier.swift"
```

The harness must **assert `canImport` resolved** (see §3.4 guard) so this can
never silently regress into a false negative.

---

## 1. Three tiers

| Tier | Mechanism | Cost | Use for |
| --- | --- | --- | --- |
| **1** | `swiftc` / `swift build` CLI harness over shipped sources + stubs | 2 s - 2 min | Pure logic: routelet accuracy, log-mel fidelity, catalog invariants, offline model probes |
| **2** | `bash scripts/fast-install.sh` then drive `127.0.0.1:32123` | 40 s build + N s/turn | Real runtime: end-to-end latency, self-answer correctness, curation A/B, profile regressions |
| **3** | Human | — | See §12 (short list) |

Tier 1 first, always. A Tier 2 run costs a build and app restart; a Tier 1 run
costs seconds and localises the fault. Tier 2 exists to catch what isolation
cannot: real profile dispatch, real context assembly, real prompt shape.

---

## 2. Shared harness conventions

Everything lives in `scripts/`, matching existing style
(`set -euo pipefail`, `pass()`/`fail()` printers, `PASS`/`FAIL` line prefixes,
`ALL PASSED` terminator, exit 0/1).

### 2.1 Tier 1 skeleton

```sh
#!/usr/bin/env bash
# scripts/lib/tier1-swiftpm.sh — sourced, not run.
# Builds a throwaway SwiftPM CLI over SHIPPED cursor-buddy sources.
# Never invokes xcodebuild; never touches /Applications or TCC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Persistent, NOT $$-suffixed: .build cache turns a 24s ORT build into 2s.
PKG="${TMPDIR:-/tmp}/openclicky-tier1/$HARNESS_NAME"

tier1_init() {          # $@ = shipped source basenames
  mkdir -p "$PKG/Sources/rt"
  for f in "$@"; do
    case "$f" in
      OpenClickyIntentClassifier.swift)
        sed -e 's/canImport(onnxruntime)/canImport(OnnxRuntimeBindings)/g' \
            -e 's/^import onnxruntime$/import OnnxRuntimeBindings/' \
            "$ROOT/cursor-buddy/$f" > "$PKG/Sources/rt/$f" ;;
      *) ln -sfn "$ROOT/cursor-buddy/$f" "$PKG/Sources/rt/$f" ;;
    esac
  done
  cat > "$PKG/Package.swift" <<'P'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "rt", platforms: [.macOS(.v14)],
  dependencies: [.package(
    url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
    exact: "1.24.2")],
  targets: [.executableTarget(name: "rt", dependencies: [
    .product(name: "onnxruntime",
             package: "onnxruntime-swift-package-manager")])]
)
P
}

tier1_build_run() {     # $1 = resource dir to expose as Bundle.main, rest = argv
  local res="$1"; shift
  ( cd "$PKG" && swift build -c release 2>&1 | grep -E 'error:|warning: .*never' ) || true
  [ -x "$PKG/.build/release/rt" ] || { echo "FAIL: harness build failed"; exit 1; }
  [ -n "$res" ] && ln -sfn "$res" "$PKG/.build/release/$(basename "$res")"
  "$PKG/.build/release/rt" "$@"
}
```

Note: `.build` is deliberately **not** deleted on exit. First run pays 24 s for
the ORT xcframework; subsequent runs are ~2 s. If the agent hits
`PCH was compiled with module cache path …`, that is a stale cache from a
copied `.build`; `rm -rf "$PKG/.build/*/release/ModuleCache"` fixes it.

For harnesses with no package dependency (log-mel, catalog), skip SwiftPM and
use the plain `xcrun swiftc` form from `run-provider-catalog-tests.sh:126` —
it is faster.

### 2.2 Tier 2 skeleton

```sh
#!/usr/bin/env bash
# scripts/lib/tier2-app.sh — sourced.
set -euo pipefail
BASE="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123}"
TOKEN="${OPENCLICKY_BRIDGE_TOKEN:-${OPENCLICKY_AUTOMATION_TOKEN:?set token}}"

app_ensure() {          # rebuild+install only when sources are newer
  if [ "${FORCE_BUILD:-0}" = 1 ] || ! curl -sSf -o /dev/null "$BASE/health"; then
    bash "$ROOT/scripts/fast-install.sh"
    for _ in $(seq 1 40); do
      curl -sSf -o /dev/null "$BASE/health" && return 0; sleep 0.5
    done
    echo "FAIL: bridge never came up after fast-install"; exit 1
  fi
}

sensor() {              # $1 tool name, $2 JSON arguments -> inner tool JSON
  curl -sS -X POST "$BASE/mcp/sensor" \
    -H 'Content-Type: application/json' -H "x-openclicky-token: $TOKEN" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
  | sed -n 's/^data: //p' | tail -n1 \
  | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["result"]["content"][0]["text"])'
}

voice_turn() {          # $1 transcript -> {ok, elapsedMs, assistantText, ...}
  sensor openclicky_simulate_voice_turn \
    "$(python3 -c 'import json,sys; print(json.dumps({"transcript": sys.argv[1]}))' "$1")"
}

set_profile() { sensor openclicky_set_profile "{\"profile\":\"$1\"}"; }
```

`openclicky_simulate_voice_turn` is the whole Tier 2 story: it runs the real
profile dispatch (mirage → `MiragePeekyOrchestrator.runTurn`, everything else →
`HeyClickyChatToolCallClient.analyzeVoiceResponse`), applies the real xlb hint
injection, sets `suppressVoiceResponseSideEffects` so nothing persists to
vault/LTM, and returns `{ok, elapsedMs, transcript, assistantText, assistantLen}`.
No microphone, no TTS playback, no vault pollution.

### 2.3 Fixture layout

```
docs/parlor-integration-research/fixtures/
  gate-a/corpus.json            # deictic ↔ grounded pairs + gold intent
  gate-c/manifest.json          # zh clips + ground-truth text
  gate-c/wav/*.wav              # 16 kHz mono, `say` + ffmpeg
  gate-1/manifest.json          # turn clips + complete/incomplete label
  gate-1/wav/*.wav
  logmel/*.f32                  # numpy golden intermediates (04 §7.1)
  scenarios/scenarios.json      # shared Gate 3 / Gate 4 / regression scenarios
  results/*.json                # harness output, git-ignored
```

One shared `scenarios.json` for Gates 3, 4 and the regression suite: same
inputs, different scorers. Avoids three drifting corpora.

---

## 3. Gate A — does grounding improve routelet accuracy? (Tier 1)

**Question (05 §7):** feed raw deictic utterances and hand-grounded versions
through the shipped `OpenClickyIntentClassifier`; if the accuracy delta is
small, E4B collapses to an STT alternative and the plan should be dropped.

**This is the first thing to run.** It is also already partly answered — see
§3.5, which is a real result from running the harness below, not a prediction.

### 3.1 What bootstrap needs

`OpenClickyIntentClassifier.bootstrap()` (`cursor-buddy/OpenClickyIntentClassifier.swift:103-207`)
needs exactly three files, all already in-repo, none downloaded:

| File | Size | Source | Used for |
| --- | --- | --- | --- |
| `AppResources/OpenClicky/mirage-routelet/head.json` | 51 KB | in-repo | `coef[K][384]`, `intercept`, `labels`, `temperature`; `agent` class dropped at load |
| `AppResources/OpenClicky/mirage-routelet/tokenizer.json` | 695 KB | in-repo | WordPiece vocab (30 522) + `added_tokens` |
| `AppResources/OpenClicky/mirage-routelet/embedder.onnx` | 127 MB | in-repo | BERT → `[1, 384]`; ORT session built lazily on first `embed()` |

Plus two shipped Swift files: `OpenClickyIntentClassifier.swift` and
`MirageRedact.swift` (`preprocess` is called first thing in `classify`).
`MirageRedact` imports only Foundation, so the dependency closure is exactly
two files. Nothing else from `cursor-buddy/` is needed.

### 3.2 Script

```sh
#!/usr/bin/env bash
# scripts/run-gate-a-grounding.sh
# Gate A: does deixis-resolution improve routelet accuracy?
# Tier 1 — compiles SHIPPED OpenClickyIntentClassifier + MirageRedact into a
# CLI. No xcodebuild, no app install, no TCC interaction.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_NAME=gate-a
source "$ROOT/scripts/lib/tier1-swiftpm.sh"

CORPUS="${1:-$ROOT/docs/parlor-integration-research/fixtures/gate-a/corpus.json}"
OUT="${GATE_A_OUT:-$ROOT/docs/parlor-integration-research/fixtures/results/gate-a.json}"

tier1_init OpenClickyIntentClassifier.swift MirageRedact.swift
cp "$ROOT/scripts/lib/gate-a-main.swift" "$PKG/Sources/rt/main.swift"
mkdir -p "$(dirname "$OUT")"
tier1_build_run "$ROOT/AppResources/OpenClicky/mirage-routelet" "$CORPUS" "$OUT"
```

`scripts/lib/gate-a-main.swift` (the harness body; ~70 lines):

```swift
import Foundation

struct Case: Codable {
  let id: String
  let raw: String            // deictic, as spoken
  let grounded: String       // deixis resolved against screen
  let gold: String           // chat | find_action | integration | memory
  let lang: String           // "zh" | "en"
}

let corpus = try JSONDecoder().decode([Case].self,
  from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])

let sem = DispatchSemaphore(value: 0)
Task {
  let c = OpenClickyIntentClassifier.shared
  guard await c.bootstrap() else { print("FAIL: bootstrap"); exit(1) }

  // GUARD (see §0.3): if ORT did not link, every classify() returns nil and
  // the gate would read as "grounding does not help". Fail loudly instead.
  guard await c.classify("open spotify and play music") != nil else {
    print("FAIL: classifier returned nil on a control utterance — ORT not linked?")
    exit(1)
  }

  var rows: [[String: Any]] = []
  for k in corpus {
    let r = await c.classify(k.raw), g = await c.classify(k.grounded)
    rows.append([
      "id": k.id, "lang": k.lang, "gold": k.gold,
      "raw_intent": r?.intent.rawValue ?? "nil",
      "raw_conf": r?.confidence ?? 0,
      "grounded_intent": g?.intent.rawValue ?? "nil",
      "grounded_conf": g?.confidence ?? 0,
    ])
  }
  try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    .write(to: outURL)
  print("wrote \(rows.count) rows -> \(outURL.path)")
  sem.signal()
}
sem.wait()
```

Scoring is a separate `scripts/lib/score-gate-a.py` so the corpus can be
re-scored without recompiling. It applies the 0.85 confidence floor documented
at `OpenClickyIntentClassifier.swift:215-218` (below floor ⇒ treated as `none`)
and prints, per language:

```
accuracy_raw, accuracy_grounded, delta,
none_rate_raw, none_rate_grounded,
mcnemar_p            # raw-wrong→grounded-right vs the reverse
```

### 3.3 Corpus: can an LLM generate it?

**Yes, for the utterance text — with one hard rule.** The corpus tests the
*classifier*, not a transcriber, so it needs text pairs, not recordings. Real
user recordings are only required if you also want to measure STT error, which
Gate A explicitly does not.

The trap: if the same LLM writes both columns, it writes the grounded column in
the routelet's training register and inflates the delta. Mitigations, all
scriptable:

1. **Ground from a real screenshot, not from imagination.** Generate the raw
   column first (deictic, ≤8 words, from 05's table shape: 这个/那个/刚才/改成).
   Then ground each one *against an actual captured screenshot* — Tier 2's
   `sensor` surface can pull one, or reuse a checked-in PNG. The grounded text
   must name a UI element visible in that image. This is the one step where an
   LLM is genuinely doing E4B's job, so it is the right proxy.
2. **Gold labels assigned to the pair, not per-column.** One `gold` field. A
   grounded rewrite that changes the intent is a bad rewrite; the scorer flags
   any case where a human-plausible reading of `raw` and `grounded` differ.
3. **Held-out negatives.** ~20 % of cases where grounding should *not* help
   (already-explicit utterances) — the delta on those must be ≈ 0. If it is
   not, the grounded column is leaking register, not information.
4. **Size:** 05 says 20-30; use **60** (30 zh, 30 en), balanced across the four
   classes. Generation is free and the McNemar test is underpowered below ~40.

Corpus format:

```json
[
  {"id": "zh-001", "lang": "zh", "gold": "find_action",
   "raw": "点这个",
   "grounded": "点击右上角的提交按钮",
   "screenshot": "fixtures/gate-a/shots/submit-button.png",
   "explicit_control": false}
]
```

### 3.4 Pass/fail

| Metric | Threshold |
| --- | --- |
| `accuracy_grounded - accuracy_raw` (en) | **≥ 0.20** to proceed; 0.10-0.20 = marginal, escalate; < 0.10 = **Gate A fails, drop Layer B** |
| `none_rate_raw - none_rate_grounded` | ≥ 0.25 (the mechanism 05 §0 predicts) |
| Delta on `explicit_control` cases | ≤ 0.05 (else corpus is leaking) |
| McNemar p | < 0.05 |
| Control utterance classifies non-nil | hard precondition (§3.2 guard) |

Runtime: **~2 s** after the first build (24 s once, for ORT). Measured
per-classify cost 2.3 ms including ORT session reuse. Gate A is essentially
free to re-run, so run it on every corpus edit.

### 3.5 Pilot result — a blocker found before Gate A can be scored

Running the harness above on a 4-pair Chinese pilot:

```
RAW  点这个                        -> none 0.990
GRND 点击右上角的提交按钮            -> none 0.990
RAW  这报错啥意思                   -> none 0.990
GRND 解释 IDE 里的 NullPointerException -> none 0.989
RAW  刚才那个文件                   -> none 0.990
GRND 打开刚才在 Finder 里选中的 MirageBackendClient.swift -> none 0.988
```

Every Chinese input returns `none`, grounded or not. English behaves correctly:

```
RAW  click this                    -> find_action 0.989
RAW  what does that error mean     -> chat 0.990
GRND explain the NullPointerException at line 47 -> find_action 0.988
RAW  that file from before         -> integration 0.974
GRND open MirageBackendClient.swift that was selected in Finder -> find_action 0.989
```

Root cause, confirmed by reading `tokenizer.json`: its normalizer is
`{"type":"BertNormalizer","handle_chinese_chars":true,…}`, which inserts
whitespace around every CJK codepoint before WordPiece. The shipped Swift
tokenizer does not implement that step — `embed()` splits on `" "` only
(`OpenClickyIntentClassifier.swift:245`), so a whole Chinese clause arrives at
`wordpieceTokenize` as one 4-6 char "word", misses the vocab, and returns
`[unkID]` (line 352). The vocab *does* contain 488 CJK single-char tokens, so
the model could handle Chinese — the port drops it.

Two consequences, and they matter more than Gate A's own verdict:

- **Gate A cannot be scored on Chinese until this is fixed.** A zh delta of
  0.00 today is a tokenizer artefact, not evidence about grounding. Fix first,
  then score. The fix is ~10 lines in `wordpieceTokenize`'s caller: split CJK
  (U+4E00-U+9FFF, U+3400-U+4DBF, U+F900-U+FAFF, plus CJK punctuation) into
  individual pseudo-words, matching `BertNormalizer`.
- **This is a live production bug, not a test-only one.** `MiragePeekyOrchestrator`
  and the SKI lane both call `classify()`. Every Chinese utterance in the
  mirage profile currently falls through to the slow Claude classifier. Worth
  filing independently of the Parlor work.

Add a permanent regression case for it (§10): `classify("打开设置")` must not
be `none`.

---

## 4. Gate B — E4B first-token latency (Tier 1 external, then Tier 2)

**Question (05 §7):** first-token latency on a ~650-token router input. Target
**< 1.5 s**.

### 4.1 There is no local LLM runtime in OpenClicky today

Checked all four candidates named in the brief:

| Component | What it actually is | Runs an LLM? |
| --- | --- | --- |
| `OpenClickyLocalModelDownloadService.swift` | Downloader only | **No** |
| `OpenClickyLocalModelCatalog.swift` | Catalog of MLX bundles (`OsaurusAI/gemma-4-{E2B,E4B,12B}-it-qat-MXFP4`). Every entry carries `runtimeRequirement: .externalOpenAICompatibleServer`, whose own `detail` string says *"OpenClicky can install this MLX bundle, but Agent Mode still needs a separate OpenAI-compatible local vMLX/MLX server to run it."* | **No — explicitly delegates** |
| `WhisperLocalModelManager.swift` / `WhisperLocalTranscriptionProvider.swift` | whisper.cpp GGML `.bin` downloader + transcriber | ASR only |
| `OpenClickyLocalSpeechModelManager.swift` | FluidAudio Parakeet STT | ASR only |

Grep for `import MLX` / `CoreML` / `llama` across `cursor-buddy/*.swift` hits
only `OpenClickyParakeetTranscriptionProvider.swift` and `SileroVADTrim.swift`
— both ASR. SPM deps are onnxruntime, silero-vad-swift, swift-transformers,
DynamicNotchKit; **no LLM inference package**.

So Gate B cannot be measured in-app before Layer B is built. It must be
measured **externally first** — which is the correct ordering anyway, since
Gate B's whole purpose is to decide whether to write that Swift at all.

Good news: the E4B numbers OpenClicky would get are the *same numbers Parlor
gets*, because the plan's design (05 §4.1) is llama.cpp-hosted GGUF, exactly
Parlor's `llama.py`. Measuring Parlor measures the decision.

### 4.2 Tier 1 — measure Parlor directly

Prerequisites, all installable autonomously:

```sh
brew install llama.cpp        # verified: stable 10280 available,
                              # Parlor's MIN_BUILD floor is 9503 → passes
```

`llama.py:141-160` spawns `llama-server -m <gguf> --mmproj <mmproj> -ngl 99
--port 8081 -c <CTX> -np 1` and polls `/health` for up to 180 s. Weights are
`google/gemma-4-E4B-it-qat-q4_0-gguf` (`llama.py:24-30`), fetched by
`hf_hub_download` — ~3.4 GB, one-time, no auth.

```sh
#!/usr/bin/env bash
# scripts/run-gate-b-latency.sh
# Gate B: E4B first-token latency at OpenClicky's router context budget.
# Tier 1 — external llama.cpp + /tmp/parlor. Does not build or launch
# OpenClicky, does not touch TCC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARLOR="${PARLOR_DIR:-/tmp/parlor}"
PORT="${GATE_B_PORT:-8099}"          # 8099 like turnbench, so a dev
                                      # llama-server on 8081 can coexist
N="${GATE_B_TRIALS:-20}"
OUT="$ROOT/docs/parlor-integration-research/fixtures/results/gate-b.json"

command -v llama-server >/dev/null || brew install llama.cpp
[ -d "$PARLOR" ] || { echo "FAIL: clone parlor to $PARLOR"; exit 1; }

# 1. Boot llama-server with E4B. Reuse parlor's own launcher so the flags,
#    build-floor check and health poll match the reference exactly.
( cd "$PARLOR" && MODEL=e4b LLAMA_PORT="$PORT" \
  uv run python -c 'from parlor import llama; llama.start(); print("up")' ) \
  || { echo "FAIL: llama-server did not start"; exit 1; }

# 2. Drive it with OpenClicky-shaped router prompts and time first token.
uv run --project "$PARLOR" python "$ROOT/scripts/lib/gate-b-probe.py" \
  --port "$PORT" --trials "$N" --out "$OUT"
```

`scripts/lib/gate-b-probe.py` streams `/v1/chat/completions` with
`stream: true` and stops the clock on the **first non-empty content delta**,
which is what "first token" means for perceived latency. It sweeps four input
shapes so the result is a curve, not a point:

| Shape | Composition | Why |
| --- | --- | --- |
| `text_650` | ~650 tok text only | 05 §4.1's stated router budget |
| `text_650_img` | same + one 1280 px screenshot | 05 §4.1 counts the image at ~50 tok, but *prefill* cost is the vision encoder, not the token count — this is the number that actually decides Gate B |
| `text_650_img_audio` | + 3 s of 16 kHz speech | the real router input per 05 §4.5 |
| `text_6500` | answerer-sized context | proves 05 §4.1's "separate budget, not negotiable" claim with a number |

Audio and image fixtures come straight from Parlor:
`benchmarks/fixtures.load_wav_b64(...)` and `fixtures.make_image_b64(...)`
(`fixtures.py:274,297`) — no new fixture code.

Each shape runs `N=20` trials: **1 warm-up discarded** (first call pays model
load + graph warm), then 19 measured. Report p50 / p90 / max, plus
`tokens_per_second` from the tail.

### 4.3 Pass/fail

| Metric | Threshold |
| --- | --- |
| `text_650_img_audio` **p90** first-token | **< 1.5 s** → pass |
| same, p90 in 1.5-2.5 s | marginal — Layer B viable only with speculative prefill (05 §9 defers it), escalate |
| same, p90 > 2.5 s | **Gate B fails**; router is slower than just asking Claude |
| `text_650` p50 | record for the §4.1 budget claim |
| `text_6500` p50 / `text_650` p50 | expect ≥ 3× — if not, 05 §4.1's separate-budget argument is weaker than stated |

Use **p90, not p50**. A router that is fast on average and occasionally 3 s
produces exactly the "why is it hanging" UX the plan is trying to avoid.

**Machine caveat, must be recorded in the result JSON:** this box is an
**M2 Pro / 16 GB**. E4B q4_0 (~3.4 GB) + mmproj + OpenClicky itself + the
answerer's context is tight but workable; a 12B run would swap and the number
would be meaningless. The harness writes `hw.memsize`,
`machdep.cpu.brand_string` and `llama-server --version` into the output so a
later reader knows which machine produced the verdict. Gate B's answer is
machine-specific by nature — passing here does not mean passing on an 8 GB M1.

Runtime: ~10 min first run (3.4 GB download), ~90 s thereafter.

### 4.4 Tier 2 follow-up, once Layer B exists

After the `LLMClient` decorator ships (05 §4.3, mirage-only), re-measure
in-app so the number includes Swift-side overhead — audio marshalling,
screenshot encode, actor hops — which §4.2 excludes:

```sh
app_ensure
set_profile mirage
for i in $(seq 1 10); do
  voice_turn "点这个" | python3 -c 'import json,sys; print(json.load(sys.stdin)["elapsedMs"])'
done
```

`elapsedMs` from `openclicky_simulate_voice_turn` measures the *whole* turn,
not first token, so this is an upper bound and a regression tripwire, not a
Gate B substitute. Assert **in-app p90 ≤ external p90 + 400 ms**; a larger gap
means the Swift integration, not the model, is the problem.

---

## 5. Gate C — Chinese audio understanding (Tier 1)

**Question (05 §7):** Parlor's author tested English only. Is E4B's Chinese
audio understanding usable? 05 proposes "compare E4B's transcript against
Whisper local on the same clips" — which as written has no ground truth, only
an agreement score. Two models can agree and both be wrong.

The fix is TTS-synthesized fixtures with **known** ground truth. This is
exactly Parlor's own technique (`benchmarks/fixtures.py:1-7`: *"Synthesizes
real spoken audio with the local Kokoro TTS backend (so the Gemma audio
encoder gets actual speech, not sine waves)"*), applied to Chinese.

### 5.1 Fixture synthesis — verified working

macOS `say` ships ~14 Chinese voices; no download, no key, no network:

```sh
say -v Tingting -o out.aiff "打开设置面板"
ffmpeg -loglevel error -y -i out.aiff -ar 16000 -ac 1 -c:a pcm_s16le out.wav
```

Verified end-to-end on this machine: 1.6 s of 16 kHz mono PCM, the exact
format `BuddyStreamingTranscriptionSession` captures. Voices to sweep, so the
score is not one speaker's idiosyncrasy: **Tingting, Meijia (zh_TW), Eddy,
Flo, Reed, Grandma, Grandpa**. `say -r` varies rate (140/180/220 wpm).

Reuse Parlor's degradations verbatim (`fixtures.py:181-196`) — they exist
because clean TTS is unrealistically easy and *"the encoder hallucinates
confident completions on abrupt cuts"*:

| Variant | Parlor kwarg | Simulates |
| --- | --- | --- |
| `_clipped` | `clip_end_s=0.18` | VAD chopping the final word |
| `_noisy` | `snr_db=12` | room noise |
| `_cutoff` | `keep_frac=0.55` | mid-utterance interruption |

Port `_synthesize`'s numpy post-processing (clip / SNR-matched noise /
10 ms fade) as-is into `scripts/lib/zh-fixtures.py`; only the TTS call swaps
Kokoro → `say`.

Corpus: **40 sentences × 7 voices = 280 clips**, drawn from the actual domain
— OpenClicky commands, code identifiers, mixed zh/en ("打开 MirageBackendClient.swift"),
digits and file paths. Mixed-script and identifiers matter most: that is where
an audio LLM degrades and where the router will live.

```json
{"id": "zh-014", "text": "打开右上角的提交按钮",
 "voice": "Tingting", "rate": 180, "variant": "clean",
 "wav": "wav/zh-014-tingting-clean.wav",
 "has_latin": false, "has_digit": false}
```

### 5.2 The scoring metric, and its floor

Word error rate is wrong for Chinese — there are no spaces, and any
segmenter's choices become part of the score. Use **CER** (character error
rate: Levenshtein over characters ÷ reference length) after normalising away
punctuation, full/half-width forms, and whitespace. Report **pinyin-CER** as a
secondary metric (via `pypinyin`, `pip install`-able) so homophone errors —
which are usually recoverable downstream and often *not* meaning-changing —
are visible separately from real content errors.

**Establish the reference floor first, and this is not optional.** Measured on
this machine: `whisper-cli` with the already-downloaded
`~/Library/Application Support/OpenClicky/models/ggml-large-v3-turbo-q5_0.bin`
transcribed the fixture above as **大开设置面板** against ground truth
**打开设置面板** — CER 0.167 on a clean, 6-character clip. The reference STT
is not a ground-truth oracle.

So the harness computes three columns and judges E4B **relative to the floor**,
never against zero:

| Column | Producer | Role |
| --- | --- | --- |
| `cer_whisper` | `whisper-cli -m <turbo-q5_0> -l zh -nt -np` (already installed, on disk) | reference floor |
| `cer_deepgram` | Deepgram nova (only if `DEEPGRAM_API_KEY` present; skip + mark `skipped`, never fail) | second opinion |
| `cer_e4b` | Parlor's `/v1/chat/completions` with the audio part and its `###TRANSCRIPT:` prompt | subject |

`say`'s own pronunciation is itself a source of error (it may read a
identifier oddly). Any clip where **all three** transcribers exceed CER 0.4 is
auto-quarantined as a bad fixture rather than counted against E4B — a
synthesis defect, not a model defect. The quarantine list is written to the
result JSON so it stays visible.

### 5.3 Script

```sh
#!/usr/bin/env bash
# scripts/run-gate-c-chinese-audio.sh
# Gate C: is E4B's Chinese audio understanding usable?
# Tier 1 — say/ffmpeg fixtures + whisper-cli + external llama-server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/docs/parlor-integration-research/fixtures/gate-c"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/Library/Application Support/OpenClicky/models/ggml-large-v3-turbo-q5_0.bin}"

[ -f "$WHISPER_MODEL" ] || { echo "FAIL: whisper model missing: $WHISPER_MODEL"; exit 1; }
command -v whisper-cli >/dev/null || brew install whisper-cpp

python3 "$ROOT/scripts/lib/zh-fixtures.py" --out "$FIX"        # idempotent, ~3 min first run
bash "$ROOT/scripts/lib/ensure-llama-e4b.sh"                    # shared with Gate B
python3 "$ROOT/scripts/lib/score-gate-c.py" \
  --manifest "$FIX/manifest.json" --whisper-model "$WHISPER_MODEL" \
  --port "${GATE_B_PORT:-8099}" \
  --out "$ROOT/docs/parlor-integration-research/fixtures/results/gate-c.json"
```

### 5.4 Pass/fail

| Metric | Threshold |
| --- | --- |
| `median(cer_e4b) - median(cer_whisper)` | **≤ 0.05** → pass (E4B at or near reference) |
| same, 0.05-0.15 | marginal: E4B usable for *grounding* but must not replace STT — forces 05 §4.5's "parallel" default rather than "E4B only" |
| same, > 0.15 | **Gate C fails** for Chinese; ship Layer B English-only or not at all |
| `cer_e4b` on `has_latin` subset | ≤ 0.20 absolute — mixed-script identifiers are the router's bread and butter |
| `no_speech_rate` (E4B omits `###TRANSCRIPT:`, the failure `pipeline.py` documents) | ≤ 0.05; above that, 05 §4.5's STT fallback is load-bearing rather than belt-and-braces |
| Quarantined fixtures | ≤ 10 % of corpus, else the fixture generator is at fault |

Runtime: ~3 min fixture generation (one-time), ~8 min scoring for 280 clips
(whisper-cli was ~11 s/clip cold, faster warm; parallelise with `xargs -P4`).

### 5.5 What this does *not* measure

Synthesized speech has no disfluency, no overlapping speakers, no real room
acoustics, and TTS prosody is regular in a way human speech is not. A pass
here means "E4B decodes clean Chinese as well as Whisper does"; it does not
prove real-mic robustness. That residual is the strongest argument for the
one human check in §12.

---

## 6. Gate 1 — smart-turn Chinese accuracy (Tier 1)

**Question (05 §7 / 04 §R8):** smart-turn-v3's published numbers come from its
own test split; LiveKit's eot-bench scores it far more harshly; and Parlor's
own benchmark defaults to `--langs eng`, noting that for most other languages
*every clip in the test set is synthetic* (`turnbench.py:32-40`). Chinese
end-of-turn quality is unmeasured.

### 6.1 Reuse turnbench's methodology, not its clip source

`benchmarks/turnbench.py` gives us the scoring design for free, and it is a
good one. Port these directly:

- **Balanced sampling.** `fetch_clips` pulls equal `complete` / `incomplete`
  counts per language (`turnbench.py:151-185`) via the HF datasets-server
  `filter` endpoint on `pipecat-ai/smart-turn-data-v3.2-test`.
- **The metric set that matters** (`score()`, `turnbench.py:250-269`):
  `accuracy`, `recall_complete` (missing a finished turn = dead air),
  `recall_incomplete`, and **`interrupt_rate` = fp / n_incomplete** — cutting
  in on an unfinished turn, the failure users actually hate.
- **Threshold sweep** (`sweep_threshold`, `turnbench.py:271-283`) over
  p(complete) ∈ {0.2 … 0.8}. This is the single most valuable output: it tells
  the agent what to set OpenClicky's cutoff to for Chinese, rather than
  inheriting 0.5 from an English-tuned default.
- **`score_by_lang`** so zh and en are never averaged together.
- Latency `ms_p50` / `ms_p95` alongside accuracy.

Two clip sources, run both:

**(a) Real zh clips from the HF test split.** Free, real human speech, already
labelled. Caveat, stated in Parlor's own source: for non-English these may be
synthetic. The harness records `source` per clip (`turnbench.py:178`) and
scores real vs synthetic separately — if the zh split is 100 % synthetic, say
so in the output rather than reporting a number that looks like it came from
humans.

**(b) Locally synthesized zh clips with constructed labels.** Answers the
brief's question directly: yes, complete/incomplete can be labelled by
construction.

- `complete=True`: a full sentence, synthesized whole via `say`.
- `complete=False`: **truncate the audio mid-utterance**, exactly Parlor's
  `keep_frac=0.55` trick (`fixtures.py:180-183`), which exists because
  *"TTS of a trailing-off sentence otherwise sounds politely finished"* —
  i.e. do NOT synthesize a half-sentence's text; synthesize the full sentence
  and cut the waveform. Prosody is what smart-turn reads, and only truncation
  produces genuinely unfinished prosody.
- Chinese-specific `incomplete` forms worth including as their own bucket:
  trailing 然后 / 就是 / 那个 (filled pauses), and utterances ending on a
  measure word or preposition (把、给、跟) where the object is still coming.
  These are where an English-trained acoustic model is most likely to fail,
  and they are cheap to construct.

Truncation `keep_frac` should be swept {0.4, 0.55, 0.7}: a model that only
detects incompleteness at 0.4 is not useful at conversational latency.

### 6.2 Script

```sh
#!/usr/bin/env bash
# scripts/run-gate-1-smartturn.sh
# Gate 1: smart-turn-v3 Chinese end-of-turn accuracy.
# Tier 1 — the ONNX detector runs standalone, no LLM, no app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARLOR="${PARLOR_DIR:-/tmp/parlor}"
RES="$ROOT/docs/parlor-integration-research/fixtures/results"

# (a) real split — needs network; skip cleanly offline rather than fail
( cd "$PARLOR" && uv run python benchmarks/turnbench.py --mode smart \
    --langs zho,eng --per-class 150 --out "$RES/gate-1-real.json" ) \
  || echo "WARN: HF split unavailable, real-clip arm skipped"

# (b) constructed zh clips, same scorer
python3 "$ROOT/scripts/lib/zh-turn-fixtures.py" \
  --out "$ROOT/docs/parlor-integration-research/fixtures/gate-1"
( cd "$PARLOR" && uv run python "$ROOT/scripts/lib/gate-1-score.py" \
    --manifest "$ROOT/docs/parlor-integration-research/fixtures/gate-1/manifest.json" \
    --out "$RES/gate-1-synth.json" )
```

`gate-1-score.py` imports `parlor.turn_detector.TurnDetector` and reuses
`turnbench.score` / `sweep_threshold` verbatim — no reimplementation, so the
Swift port is later compared against the same yardstick.

### 6.3 Pass/fail

05 §7 sets the bar as "opt-in if weak". Concretely:

| Metric (zh) | Threshold |
| --- | --- |
| `accuracy` at the swept-optimal cutoff | **≥ 0.85** → ship Chinese on by default |
| `accuracy` 0.75-0.85 | ship **opt-in**, English default on (05's stated fallback) |
| `accuracy` < 0.75 | do not ship Chinese smart-turn; keep the existing hangover timer |
| `interrupt_rate` | **≤ 0.10 regardless of accuracy** — this is a hard veto. Interruptions are the failure that makes users disable the feature |
| `ms_p95` | ≤ 50 ms (04 budgets under 30 ms) |
| zh accuracy vs en accuracy on the same run | record the gap; > 0.15 means the model is English-specific and the setting must be per-language, not global |

Runtime: ~4 min for 300 real clips (19 ms inference each, download dominates),
~2 min for the synthetic set.

### 6.4 This gate also protects the Swift port

Once §7's log-mel port passes, re-run `gate-1-score.py` with the **Swift**
detector behind the same scorer (a Tier 1 CLI over the ported files, same
manifest). Accuracy must match the Python arm within **0.01**. Any larger gap
is a port bug that fidelity tests missed, and the threshold sweep tells you
whether it is a systematic bias (whole curve shifted) or noise.

---

## 7. Numerical fidelity — the log-mel port (Tier 1)

04 §7.1 specifies `max |swift - numpy| < 1e-4`. This section makes that
scriptable and, more importantly, **staged so a failure localises**.

### 7.1 Dumping numpy intermediates

04's fixture script only dumps the final `(80, 800)` mel. That gives one
boolean and no direction. Dump the intermediates too — reading
`turn_detector.py`, the pipeline has four natural cut points:

| Stage | Shape | Produced by | A mismatch here means |
| --- | --- | --- | --- |
| `norm` | 128000 | `(x - x.mean()) / sqrt(x.var() + 1e-7)`, in **float32** (line ~215; the comment says so explicitly) | normalisation or epsilon wrong |
| `padded` | 128400 | `np.pad(x.astype(float64), (200,200), mode="reflect")` inside `_power_spectrogram:164` | **reflect** padding, not zero — easy to get wrong |
| `power` | 201 × 801 | STFT with `_periodic_hann_window(400) = np.hanning(401)[:-1]`, `_HOP_LENGTH=160`, float64 | window shape or FFT |
| `mel_raw` | 80 × 801 | `_MEL_FILTERS.T @ power`, Slaney-scale filterbank built in float64 | filterbank |
| `mel` | 80 × 800 | `log10`, `[:, :-1]` drop, **global**-max clamp `max(log, log.max() - 8.0)`, `(x + 4)/4` | the clamp (04's trap #4) or the frame drop |

Extend 04's script to write each:

```python
# scripts/lib/dump-logmel-fixtures.py   (run once, output checked in)
import numpy as np, sys
sys.path.insert(0, "/tmp/parlor/src")
import parlor.turn_detector as td

OUT = "docs/parlor-integration-research/fixtures/logmel"
rng = np.random.default_rng(0)
cases = {
    "silence":  np.zeros(128000, np.float32),
    "impulse":  np.eye(1, 128000, 64000, dtype=np.float32).ravel(),
    "dc":       np.full(128000, 0.5, np.float32),
    "sine_440": np.sin(2*np.pi*440*np.arange(128000)/16000).astype(np.float32),
    "noise":    (rng.standard_normal(128000)*0.1).astype(np.float32),
    "short_1s": (rng.standard_normal(16000)*0.1).astype(np.float32),  # left-pad path
    "zh_real":  <one Gate C fixture, resampled>,                       # real speech
}
for name, x in cases.items():
    # LEFT-pad, matching TurnDetector.predict:51 — NOT the right-pad inside
    # compute_whisper_log_mel_features. 04's trap #1.
    x8 = np.pad(x, (128000 - x.size, 0)) if x.size < 128000 else x[-128000:]
    x8.astype(np.float32).tofile(f"{OUT}/{name}.input.f32")

    n = ((x8 - x8.mean()) / np.sqrt(x8.var() + td._NORM_VARIANCE_EPS)).astype(np.float32)
    n.tofile(f"{OUT}/{name}.norm.f32")
    np.pad(n.astype(np.float64), (200, 200), mode="reflect") \
      .astype(np.float32).tofile(f"{OUT}/{name}.padded.f32")
    p = td._power_spectrogram(n, td._HANN_WINDOW, td._N_FFT, td._HOP_LENGTH)
    p.astype(np.float32).tofile(f"{OUT}/{name}.power.f32")
    (td._MEL_FILTERS.T @ p).astype(np.float32).tofile(f"{OUT}/{name}.mel_raw.f32")
    td.compute_whisper_log_mel_features(x8, do_normalize=True) \
      .astype(np.float32).tofile(f"{OUT}/{name}.mel.f32")

    ok, prob = td.TurnDetector().predict(x8)          # for §7.3
    print(name, prob)
```

Sizes: `power` is 201·801·4 = 644 KB per case, `padded` 514 KB. Seven cases
≈ 9 MB total. More than 04's 1.5 MB estimate but still fine, and the
localisation is worth it. Store `power`/`padded` for **three** cases only
(`silence`, `sine_440`, `zh_real`) if size is a concern — those three cover
structural, spectral and realistic.

Note the two padding modes are different and both matter: `predict` **left**-pads
the 8 s window with zeros; `_power_spectrogram` **reflect**-pads ±200 samples.
Conflating them is the most likely single bug in the port.

### 7.2 Swift side

Plain `xcrun swiftc` — the log-mel port imports only Accelerate, no package,
so it uses the `run-provider-catalog-tests.sh:126` form directly:

```sh
#!/usr/bin/env bash
# scripts/run-logmel-fidelity-tests.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/openclicky-logmel-$$"; mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --show-sdk-path --sdk macosx)"; TARGET="arm64-apple-macos15.0"

xcrun swiftc -O -sdk "$SDK" -target "$TARGET" -o "$OUT/logmel_tests" \
  "$ROOT/cursor-buddy/SmartTurnLogMel.swift" \
  "$ROOT/scripts/lib/logmel-main.swift"

exec "$OUT/logmel_tests" "$ROOT/docs/parlor-integration-research/fixtures/logmel"
```

`logmel-main.swift` loads each `.input.f32`, runs the Swift stage functions,
and compares against the corresponding `.f32` — reporting `PASS`/`FAIL` per
(case, stage) in the house style, and **stopping at the first failing stage
per case** so the output names the culprit instead of cascading.

### 7.3 Pass/fail

Per 04 §7.1, staged:

| Stage | Tolerance |
| --- | --- |
| `norm`, `padded` | max abs < 1e-6 (pure float32 arithmetic, should be near-exact) |
| `power` | max rel < 1e-5 (float64 in numpy vs float32 Accelerate; use **relative** here, magnitudes span decades) |
| `mel_raw` | max abs < 1e-4 |
| `mel` | **max abs < 1e-4, MAE < 1e-5, shape exactly 80×800** |
| `mel` for `silence` and `dc` | **< 1e-6** — no cancellation, so any structural bug shows loudly (04's point) |
| end-to-end `p(complete)` vs Python | **< 0.01 absolute** (04 §7.2) |

The `silence`/`dc` sub-1e-6 rows are the highest-signal assertions in the whole
document: they fail on window shape, pad mode and frame alignment while the
noisy cases hide all three.

Runtime: **< 5 s**. Runs on every commit touching the port.

---

## 8. Gate 3 — self-answer accuracy, **zero** wrong answers (Tier 2)

**Question (05 §7):** self-answer accuracy on the scenario set and — more
important — zero wrong self-answers. *"One confidently wrong spoken reply is
worse than ten unnecessary Claude calls."*

Two distinct things must be scored, and conflating them is the trap:

1. **Routing decision** — should E4B have answered this at all, or deferred?
2. **Answer correctness** — given that it answered, was it right?

Gate 3's hard criterion lives in the intersection: `answered ∧ wrong` must be
**zero**. `deferred ∧ could-have-answered` is merely inefficient.

### 8.1 Scenario fixture

Shared with Gates 4 and §10. Each scenario carries a `defer_expected` label
assigned from 05 §4.4's own rule (E4B handles one-step chat/ack/interruption;
defers on multi-step reasoning, long context, any tool use) — so the routing
half is scored against the spec, not against a judge's opinion:

```json
{"id": "sa-007",
 "utterance": "现在几点了",
 "lang": "zh",
 "category": "simple_factual",
 "defer_expected": false,
 "reference": "The current local time.",
 "must_not_contain": ["I cannot", "as an AI"],
 "verifiable": "clock"}
```

`verifiable` is the important field. Wherever possible, prefer scenarios whose
correctness is checkable **without a judge at all** — clock, current app name,
window title, selected text, file existence, arithmetic. All of these are
readable through the sensor tools the bridge already exposes, so the harness
can compute ground truth at run time rather than trusting an LLM. Aim for
**≥ 40 %** of scenarios `verifiable`; those carry the zero-wrong criterion,
which must not rest on a judge's word.

Target 60 scenarios: 24 verifiable, 36 judged; ~40 % `defer_expected: true`.

### 8.2 Driving it

```sh
#!/usr/bin/env bash
# scripts/run-gate-3-selfanswer.sh
# Gate 3 — Tier 2: real app, real profile dispatch, via the control bridge.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/tier2-app.sh"

app_ensure
set_profile mirage                      # 05 §4.3: decorator reaches mirage only

python3 "$ROOT/scripts/lib/run-scenarios.py" \
  --scenarios "$ROOT/docs/parlor-integration-research/fixtures/scenarios/scenarios.json" \
  --arm frontend_router_on \
  --out "$ROOT/docs/parlor-integration-research/fixtures/results/gate-3.json"
```

`run-scenarios.py` calls `openclicky_simulate_voice_turn` per scenario. That
handler (`OpenClickyExternalControlBridge.swift:4097-4192`) runs the real
`MiragePeekyOrchestrator.runTurn`, applies the real xlb hint injection, sets
`suppressVoiceResponseSideEffects = true` so nothing is written to vault or
LTM, and returns `{ok, elapsedMs, transcript, assistantText, assistantLen}`.
Clean, repeatable, no microphone, no vault pollution.

**One prerequisite this gate needs from Layer B:** the response must expose
whether E4B self-answered or deferred, and its confidence. Today the envelope
does not carry it. Add two fields to the `sensorTextEnvelope` in that handler
when the frontend router is active — `"router": {"selfAnswered": bool,
"confidence": double, "groundedTranscript": string}`. Without it the harness
can only infer routing from latency, which is fragile. This is a ~5-line
change and should be part of the Phase 3 work, not bolted on later.

### 8.3 Judging

For non-`verifiable` scenarios, LLM-as-judge through the backend Claude the
app already talks to — no new key, and it inherits the SDK-first money rule
(`CLAUDE.md`: Claude Agent SDK primary, direct REST fallback only). Two ways
to reach it, prefer the first:

1. **Through the app**, via the sensor `tools/call` path that reaches the
   Claude client. Keeps billing on the existing sign-in.
2. Direct `ANTHROPIC_API_KEY` from `AppBundleConfiguration.anthropicAPIKey()`
   only if (1) is unavailable — mark the run `judge_path: "direct_rest"` in
   the output so a cost-conscious reader can see it.

Judge design, deliberately conservative:

- **Three labels, not a score**: `correct` / `wrong` / `unsupported`.
  `unsupported` = the answer makes a claim the judge cannot verify from the
  provided context. It counts as **wrong** for Gate 3's zero-wrong criterion —
  a confidently unverifiable spoken claim is exactly the failure mode 05 fears.
- **The judge sees the reference and the context, never which arm produced
  the answer.** Arm labels stripped and answer order shuffled.
- **Triple-run with different seeds; require unanimity.** Any scenario where
  the three judgements disagree is `flagged`, excluded from the numerator, and
  listed in the output. If `flagged > 15 %`, the rubric is too vague — fix the
  rubric, do not tune the threshold.
- **Judge calibration set**: 6 hand-labelled scenarios (3 obviously correct,
  3 obviously wrong) injected into every judge run. If the judge misses any of
  those, the whole run is void. This catches a degraded or misconfigured judge
  before it silently passes a bad build.

### 8.4 Pass/fail

| Metric | Threshold |
| --- | --- |
| `wrong_self_answers` (answered ∧ (wrong ∨ unsupported)) | **exactly 0** — hard gate, 05's own wording |
| `wrong_self_answers` among `verifiable` scenarios | **exactly 0**, judged mechanically (this is the criterion that does not depend on an LLM) |
| Routing precision on `defer_expected: true` | ≥ 0.95 (it deferred when it should) |
| Self-answer rate on `defer_expected: false` | ≥ 0.50 — below this the router adds latency and buys nothing |
| Judge calibration set | 6/6, else run void |
| `flagged` (judge disagreement) | ≤ 0.15 |

Runtime: 60 scenarios × ~2 s + 40 s build ≈ **4 min**; +2 min for triple
judging.

---

## 9. Gate 4 — curation must not regress answer quality (Tier 2)

**Question (05 §7):** run both curated and full-context paths on the same
scenarios and compare. The risk (05 §5) is curation blinding the backend.

### 9.1 A/B through the same bridge

Same scenarios, same `openclicky_simulate_voice_turn`, two arms toggled by the
Layer C switch:

```sh
for arm in full_context curated; do
  sensor openclicky_set_setting "{\"key\":\"frontendCuration\",\"value\":\"$arm\"}"
  python3 scripts/lib/run-scenarios.py --arm "$arm" --out "results/gate-4-$arm.json"
done
python3 scripts/lib/judge-pairwise.py \
  --a results/gate-4-full_context.json --b results/gate-4-curated.json \
  --out results/gate-4.json
```

(If no such setting key exists yet, Layer C must add one — an A/B-able switch
is a requirement of the gate, not an extra.)

### 9.2 Pairwise judging, blinded

Absolute scoring drifts between runs; pairwise does not. For each scenario the
judge sees the question, both answers in **randomised order**, no arm labels,
and returns `A_better` / `B_better` / `tie`. The harness un-blinds afterwards.

**Position-bias control:** run every pair twice with the order swapped. A pair
where the judge prefers whichever answer came first is a `tie`, not a win.
Without this, LLM judges reliably favour position A and curation will look
better or worse than it is.

Also score, mechanically and without a judge:

- **Information loss:** entities (file names, numbers, identifiers, app names)
  present in the full-context answer but absent from the curated one. This is
  05 §5's "curation blinds the backend" failure made countable, and it needs
  no LLM.
- **Token delta:** input tokens per arm — curation's whole justification. A
  curated arm that is not materially cheaper has no reason to exist.
- **Latency delta:** `elapsedMs` per arm.

### 9.3 Pass/fail

| Metric | Threshold |
| --- | --- |
| `curated_worse` rate (after position-bias control) | **≤ 0.05** |
| `curated_better - curated_worse` | ≥ 0 (net non-regression; 05 asks only "must not regress") |
| Entity-loss rate | ≤ 0.10, and **zero** on scenarios tagged `entity_critical` |
| Input-token reduction | ≥ 30 %, else curation is not earning its complexity |
| Any scenario where curated answer is `wrong` and full-context is `correct` | **hard fail**, regardless of aggregate |

That last row is the one that matters. An aggregate "no regression" can hide
a handful of catastrophic single-scenario regressions, which is precisely the
shape of the risk 05 §5 describes.

Runtime: 2 arms × 60 × ~2 s + 2 × 60 pairwise judgements ≈ **8 min**.

---

## 10. Regression suite — don't break the shipped profiles

The Parlor work touches shared seams: `LLMRequest` gains an `audio` field,
`LLMCapabilities` gains a bit, `usesWakeWord` changes from a negation to an
allowlist, an activation-mode case is added. 05 §3 already flags that
`LLMRequest.audio` **must** carry a default value or "all six dispatch hooks
break". That is a regression the agent will cause and must be able to detect
in seconds, not after a manual smoke test.

### 10.1 Tier 1 — fast, runs on every edit (< 30 s)

`scripts/run-parlor-regression-tier1.sh` composes existing and new checks:

| Check | Mechanism |
| --- | --- |
| Existing catalog/discovery/auto-hide invariants | `bash scripts/run-provider-catalog-tests.sh` unchanged |
| Syntax of every touched file | `swiftc -parse` (blessed by `AGENTS.md:16`) over the changed set |
| `LLMRequest(...)` still constructible with **no** `audio:` argument | a 5-line Tier 1 CLI that constructs one positionally; fails to compile if the default is dropped — 05 §3's named blocker, caught at compile time |
| `usesWakeWord` allowlist | assert `.smartTurn` (and every future case) is **not** wake-word-armed by default; the old `self != .pushToTalk` form would silently arm it (`OpenClickyWakeWordManager.swift:42`) |
| Routelet: English intents unchanged | golden file of ~30 utterance→intent pairs captured **before** any change; byte-compare |
| Routelet: Chinese not `none` | `classify("打开设置") != .none` — the §3.5 bug, pinned so it cannot silently return |
| Log-mel fidelity | §7, ~5 s |

The two routelet rows share the Gate A harness binary, so this costs one
`swift build` (cached, ~2 s).

### 10.2 Tier 2 — per-profile smoke (< 5 min)

`scripts/run-parlor-regression-tier2.sh`: after `fast-install.sh`, walk every
profile and assert each still completes a turn. The bridge exposes exactly the
needed switch (`openclicky_set_profile`, valid ids `local, realtime, quality,
heyclicky_free, ski_mode, mirage`):

```sh
app_ensure
for p in local realtime quality heyclicky_free ski_mode mirage; do
  set_profile "$p" >/dev/null
  r=$(voice_turn "what time is it")
  ok=$(echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')
  len=$(echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assistantLen",0))')
  [ "$ok" = "True" ] && [ "$len" -gt 0 ] && pass "$p turn ok" || fail "$p turn broken"
done
```

Two lane-specific extras, because 05 §4.3 warns these bypass the main path:

- **`ski_mode`**: use `openclicky_simulate_ski_utterance` and assert
  `.oc/events.jsonl` gained a well-formed `utterance.final` with a non-empty
  hint block. `ski` returns `""` from `_analyzeVoiceResponseCore`, so
  `assistantLen > 0` is the *wrong* assertion for this lane and will produce a
  false failure.
- **`heyclicky_free`**: on its default speech model this routes straight to the
  24 kHz WebSocket via `shouldRoutePTTToHeyClickyRealtimeSession`, bypassing
  `BuddyDictationManager`/`LLMRequest` entirely. Assert only that the turn
  completes; do not assert on router fields that this lane never sees.

Follow the existing `scripts/mirage-e2e-test.sh` convention for tolerated
non-failures: a lane that returns a structured "not configured" error still
counts as a valid pipeline traversal (that script does exactly this when
`MirageSecrets.upstreamBaseURL` is empty). Distinguish *"pipeline ran, upstream
absent"* from *"pipeline broken"* — otherwise the agent will chase missing API
keys as if they were regressions.

### 10.3 Golden capture

Before touching anything, `bash scripts/capture-parlor-baseline.sh` records
current behaviour into
`docs/parlor-integration-research/fixtures/baseline/` — routelet outputs on the
30-utterance golden set, per-profile smoke results, `elapsedMs` p50 per
profile. Regressions are then diffs against a real recorded state rather than
against the agent's memory of how things worked.

Latency baselines get a **±40 % band**, not equality — `elapsedMs` on a shared
dev machine is noisy and a tight bound produces flaky failures the agent will
learn to ignore.

---

## 11. CI-style runner

One entry point. Ordered cheapest-and-most-decisive first, so the agent
learns of a fatal problem in seconds rather than after a 20-minute suite.

```sh
#!/usr/bin/env bash
# scripts/run-parlor-suite.sh [--tier1|--all|--gate X]
# Autonomous gate runner. Prints PASS/FAIL per gate, exits non-zero on any
# hard failure. Never calls xcodebuild directly; Tier 2 goes through
# fast-install.sh so TCC grants survive.
set -uo pipefail        # NOT -e: we want every gate to run and report
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/docs/parlor-integration-research/fixtures/results"; mkdir -p "$RES"
declare -a NAMES=() STATES=()

run_gate() {  # $1 label, $2 tier, $3.. command
  local label="$1" tier="$2"; shift 2
  if [ "${TIER_MAX:-2}" -lt "$tier" ]; then
    NAMES+=("$label"); STATES+=("SKIP(tier)"); return
  fi
  local t0=$SECONDS
  if "$@" > "$RES/$label.log" 2>&1; then s=PASS; else s="FAIL($?)"; fi
  NAMES+=("$label"); STATES+=("$s $((SECONDS-t0))s")
  printf '%-22s %s\n' "$label" "${STATES[-1]}"
}

# --- Tier 1: seconds, no app, no network ------------------------------
run_gate regression-tier1 1 bash "$ROOT/scripts/run-parlor-regression-tier1.sh"
run_gate logmel-fidelity  1 bash "$ROOT/scripts/run-logmel-fidelity-tests.sh"
run_gate gate-a-grounding 1 bash "$ROOT/scripts/run-gate-a-grounding.sh"

# --- Tier 1, heavy: local model / network ------------------------------
run_gate gate-b-latency   1 bash "$ROOT/scripts/run-gate-b-latency.sh"
run_gate gate-c-zh-audio  1 bash "$ROOT/scripts/run-gate-c-chinese-audio.sh"
run_gate gate-1-smartturn 1 bash "$ROOT/scripts/run-gate-1-smartturn.sh"

# --- Tier 2: builds + installs + drives the app ------------------------
run_gate regression-tier2 2 bash "$ROOT/scripts/run-parlor-regression-tier2.sh"
run_gate gate-3-selfanswer 2 bash "$ROOT/scripts/run-gate-3-selfanswer.sh"
run_gate gate-4-curation   2 bash "$ROOT/scripts/run-gate-4-curation.sh"

echo; printf '%-22s %s\n' "GATE" "RESULT"
fails=0
for i in "${!NAMES[@]}"; do
  printf '%-22s %s\n' "${NAMES[$i]}" "${STATES[$i]}"
  case "${STATES[$i]}" in FAIL*) fails=$((fails+1));; esac
done
python3 "$ROOT/scripts/lib/suite-summary.py" "$RES"   # decision table, see below
[ "$fails" -eq 0 ] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
```

Design points that make it usable by an agent rather than a human:

- **`set -uo pipefail`, not `-e`.** Every gate runs even if an earlier one
  fails, so one invocation yields the full picture. Iteration loops are
  expensive; partial results are not.
- **Per-gate logs** under `results/<gate>.log`, machine-readable JSON beside
  them. The agent reads the JSON, not the console.
- **`TIER_MAX=1`** for the tight edit loop (no build, no app restart);
  `TIER_MAX=2` before declaring a phase done.
- **`--gate X`** to re-run one gate after a fix.
- **`suite-summary.py` prints the decision table**, mapping results back to
  05 §7's sequencing so the agent knows what to do next, not merely what
  broke:

  ```
  Gate A  delta=0.31   PASS  -> Layer B justified, proceed to Phase 1
  Gate B  p90=1.21s    PASS  -> router fast enough on M2 Pro/16GB
  Gate C  d_cer=+0.09  WARN  -> parallel STT mandatory; do NOT offer "E4B only"
  Gate 1  acc=0.79     WARN  -> ship zh smart-turn opt-in, en default on
  Gate 3  wrong=0      PASS
  Gate 4  not run      SKIP  -> requires Phase 3 stable
  ```

- **Every gate result records provenance**: git SHA, machine
  (`hw.memsize`, `machdep.cpu.brand_string`), `llama-server --version`, model
  IDs, fixture-corpus hash. A gate verdict without provenance is not
  reproducible, and Gate B in particular is machine-specific (§4.3).

Total runtime: **Tier 1 ~15 min cold / ~3 min warm; full suite ~30 min cold.**
The edit loop the agent will actually live in (`TIER_MAX=1`, Gate A + logmel +
regression) is **under 30 s**.

---

## 12. What still needs a human

Shorter than it first appears. Because `fast-install.sh` preserves TCC grants,
the app can be rebuilt, relaunched and driven autonomously, so most of what
looks like "needs a person" is really "needs the app running" — which is
automatable.

Genuinely not automatable:

1. **First-time TCC grants.** A human must click Allow **once** for
   microphone, screen recording and accessibility, and must have created the
   `"OpenClicky Dev Sign"` certificate (`scripts/create-dev-cert.sh`). After
   that, `fast-install.sh` preserves them indefinitely. If the cert is ever
   rotated or the bundle identifier changes, a human is needed again. The
   suite should assert grants are present at startup and fail with a clear
   instruction rather than producing mysterious empty-audio results.

2. **Real-microphone acoustic validation.** Everything in §5 and §6 uses
   synthesized speech. Synthesis has no disfluency, no overlapping speakers,
   no room reverb, no mic-specific frequency response, and regular prosody.
   Smart-turn in particular reads prosody, so a synthetic-only pass is
   *weaker evidence than it looks* — 04 §R8 and `turnbench.py:32-40` both say
   the non-English data is largely synthetic anyway. One session of a real
   Chinese speaker reading 30 utterances into the real mic, recorded once and
   then checked into fixtures, converts this from a permanent human dependency
   into a one-time one. **Recommend doing exactly that.**

3. **Subjective voice quality.** Whether the spoken reply sounds natural,
   whether the TTS voice mispronounces a Chinese name, whether barge-in feels
   responsive. CER and latency numbers do not capture "this feels wrong".

4. **The marginal-verdict calls.** When Gate A lands at delta 0.15, or Gate C
   at +0.09 CER, the number is real but the decision is a product judgement
   about how much risk to accept. The harness should surface `WARN` and stop,
   not pick a side. An agent that resolves its own marginal gates in favour of
   proceeding is not validating anything.

5. **Whether the grounded corpus is realistic.** §3.3 mitigates LLM-generated
   register leakage but cannot eliminate it. A human spot-checking 10 of 60
   pairs and confirming they sound like things a person would actually say is
   ~5 minutes and materially raises confidence in Gate A — the gate on which
   05 says the entire plan turns.

Notably **not** on this list, though it would have been under the assumption
that builds require a human: end-to-end runtime testing, per-profile
regression, self-answer scoring, curation A/B, and latency measurement. All of
those run through `fast-install.sh` plus the control bridge with no person in
the loop.
