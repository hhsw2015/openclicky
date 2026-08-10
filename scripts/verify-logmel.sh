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

python3 - "$PARLOR" <<'PY'
import sys, numpy as np
sys.path.insert(0, sys.argv[1] + "/src")
from parlor.turn_detector import compute_whisper_log_mel_features

# Deterministic 8 s: a sweep plus a fixed tone, so every mel bin sees energy.
n = 128_000
t = np.arange(n) / 16_000.0
wav = (0.5 * np.sin(2 * np.pi * (200 + 900 * t / 8.0) * t)
       + 0.2 * np.sin(2 * np.pi * 3000 * t)).astype(np.float32)
wav.tofile("wav.f32")
np.asarray(compute_whisper_log_mel_features(wav), dtype=np.float32).tofile("mel_ref.f32")
print("reference: 80x800 features from 8 s of audio")
PY

cat > main.swift <<'SWIFT'
import Foundation
let wav = try! Data(contentsOf: URL(fileURLWithPath: "wav.f32"))
    .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
guard let got = OpenClickyWhisperLogMel.features(from: wav) else {
    FileHandle.standardError.write("features() returned nil\n".data(using: .utf8)!)
    exit(1)
}
let start = Date()
_ = OpenClickyWhisperLogMel.features(from: wav)
print(String(format: "swift front-end: %.0f ms for 8 s of audio",
             Date().timeIntervalSince(start) * 1000))
try! Data(bytes: got, count: got.count * 4).write(to: URL(fileURLWithPath: "mel_got.f32"))
SWIFT

cp "$ROOT/cursor-buddy/OpenClickyWhisperLogMel.swift" .
swiftc -O -o runner OpenClickyWhisperLogMel.swift main.swift
./runner

python3 - "$MODEL" <<'PY'
import sys, numpy as np
ref = np.fromfile("mel_ref.f32", dtype=np.float32).reshape(1, 80, 800)
got = np.fromfile("mel_got.f32", dtype=np.float32).reshape(1, 80, 800)

delta = np.abs(got - ref)
print(f"mel: max {delta.max():.6f}  mean {delta.mean():.8f}  "
      f"({(delta > 1e-3).sum()} of 64000 above 1e-3)")

try:
    import onnxruntime as ort
except ImportError:
    print("onnxruntime not installed — skipping the decision check")
    sys.exit(0 if delta.max() < 5e-3 else 1)

session = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
sigmoid = lambda z: 1 / (1 + np.exp(-z))
p_ref = sigmoid(session.run(None, {"input_features": ref})[0].ravel()[0])
p_got = sigmoid(session.run(None, {"input_features": got})[0].ravel()[0])

print(f"p(complete): reference {p_ref:.6f}  swift {p_got:.6f}  delta {abs(p_ref - p_got):.7f}")
same = (p_ref > 0.5) == (p_got > 0.5)
ok = same and abs(p_ref - p_got) < 0.02
print("\nPASS — front-end reproduces the reference" if ok else
      "\nFAIL — the difference changes what the model decides")
sys.exit(0 if ok else 1)
PY
