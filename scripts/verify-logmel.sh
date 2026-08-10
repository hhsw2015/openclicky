#!/usr/bin/env bash
# Verify OpenClickyWhisperLogMel against parlor's Python reference.
#
# The ONNX half of end-of-turn detection is trivial — the app already runs
# ORT. This front-end is the risk: wrong features do not error, they make
# the model return confident nonsense. Four separate mistakes surfaced
# during the port and every one of them looked plausible in review:
#
#   · symmetric Hann instead of periodic (vDSP's built-in gives the wrong one)
#   · vDSP_DFT rejects length 400 — the port plan says it accepts it
#   · missing zero-mean/unit-variance waveform normalisation (plan omits it)
#   · right-hand reflect wing written in reverse order
#
# None is visible by reading. Hence this.
#
# Threshold is on the MODEL'S OUTPUT, not on the mel values. Swift runs
# float32 where the reference promotes to float64, so a small mel delta is
# expected and unavoidable; what matters is whether it moves p(complete).
#
# Usage: bash scripts/verify-logmel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/openclicky-logmel-verify"
PARLOR="${PARLOR_DIR:-/tmp/parlor}"
MODEL="${SMART_TURN_MODEL:-$HOME/models/smart-turn/smart-turn-v3.2-cpu.onnx}"

if [ ! -f "$PARLOR/src/parlor/turn_detector.py" ]; then
    echo "need parlor for the reference implementation:" >&2
    echo "  git clone --depth 1 https://github.com/fikrikarim/parlor $PARLOR" >&2
    exit 2
fi

rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

# Real speech as well as a synthetic sweep. The sweep exercises every mel
# bin; the speech pair proves the port preserves the model's actual job —
# telling a finished sentence from a cut-off one.
say -v Samantha -o complete.aiff "I need you to open the settings window." 2>/dev/null
say -v Samantha -o cutoff.aiff   "I need you to open the" 2>/dev/null
for clip in complete cutoff; do
    ffmpeg -y -loglevel error -i "$clip.aiff" -ar 16000 -ac 1 -f f32le "$clip.raw"
done

python3 - "$PARLOR" <<'PYGEN'
import sys, numpy as np
sys.path.insert(0, sys.argv[1] + "/src")
from parlor.turn_detector import compute_whisper_log_mel_features

N = 128_000
def window(x):
    return x[-N:] if len(x) >= N else np.concatenate([np.zeros(N - len(x), np.float32), x])

t = np.arange(N) / 16_000.0
clips = {"sweep": (0.5 * np.sin(2 * np.pi * (200 + 900 * t / 8.0) * t)
                   + 0.2 * np.sin(2 * np.pi * 3000 * t)).astype(np.float32)}
for name in ("complete", "cutoff"):
    clips[name] = window(np.fromfile(name + ".raw", dtype=np.float32))

for name, wav in clips.items():
    wav.tofile(name + ".f32")
    np.asarray(compute_whisper_log_mel_features(wav), dtype=np.float32).tofile(name + ".mel")
print("reference: %d clips x 80x800 features" % len(clips))
PYGEN

cat > main.swift <<'SWIFT'
import Foundation
for name in ["sweep", "complete", "cutoff"] {
    let wav = try! Data(contentsOf: URL(fileURLWithPath: name + ".f32"))
        .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let start = Date()
    guard let got = OpenClickyWhisperLogMel.features(from: wav) else {
        FileHandle.standardError.write("features() nil\n".data(using: .utf8)!)
        exit(1)
    }
    print(String(format: "swift %-9@ %.0f ms", name as NSString,
                 Date().timeIntervalSince(start) * 1000))
    try! Data(bytes: got, count: got.count * 4)
        .write(to: URL(fileURLWithPath: name + ".swiftmel"))
}
SWIFT

cp "$ROOT/cursor-buddy/OpenClickyWhisperLogMel.swift" .
swiftc -O -o runner OpenClickyWhisperLogMel.swift main.swift
./runner

python3 - "$MODEL" <<'PYCHK'
import sys, numpy as np
try:
    import onnxruntime as ort
except ImportError:
    print("onnxruntime not installed - cannot check the decision"); sys.exit(2)

session = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])

# NO sigmoid. The output tensor is named `logits` but the graph already
# applies one - all-zeros / all-+5 / all--5 return 0.9889 / 0.8341 / 0.9870,
# always inside (0,1), and parlor reads the value straight into
# `probability`. A second sigmoid squashes everything toward 0.5 and makes
# the threshold meaningless while still returning plausible numbers.
def predict(features):
    return float(session.run(None, {"input_features": features})[0].ravel()[0])

ok = True
results = {}
for name in ("sweep", "complete", "cutoff"):
    ref = np.fromfile(name + ".mel", dtype=np.float32).reshape(1, 80, 800)
    got = np.fromfile(name + ".swiftmel", dtype=np.float32).reshape(1, 80, 800)
    p_ref, p_got = predict(ref), predict(got)
    results[name] = p_got

    # Decision agreement, NOT absolute probability. The model is extremely
    # steep near p=0: random mel noise of +-1e-4, smaller than our float32
    # delta, moves p by 0.29 on a cut-off utterance. A tight probability
    # bound would measure the model's sensitivity, not the port's fidelity.
    same = (p_ref > 0.5) == (p_got > 0.5)
    ok = ok and same
    print("%-9s mel max %.6f  p ref %.4f swift %.4f  %s" % (
        name, np.abs(got - ref).max(), p_ref, p_got,
        "agree" if same else "DISAGREE"))

# The property the feature needs: a finished sentence and a cut-off one
# must land on opposite sides, with room to spare.
margin = results["complete"] - results["cutoff"]
print("\ndiscrimination: complete %.4f - cutoff %.4f = %.4f" % (
    results["complete"], results["cutoff"], margin))
ok = ok and margin > 0.5

print("\nPASS - front-end reproduces the reference decisions" if ok else
      "\nFAIL - the port changes what the model decides")
sys.exit(0 if ok else 1)
PYCHK
