#!/usr/bin/env bash
# Gate A — measure routelet (OpenClickyIntentClassifier) accuracy across four
# input arms, to decide whether a multimodal frontend that rewrites utterances
# is worth building, and in which language it should rewrite them.
#
# Arms, all scored against the same gold intent:
#   1 zh-raw        deictic Chinese, as actually spoken
#   2 zh-grounded   Chinese with referents resolved
#   3 en-grounded   English with referents resolved   <- the candidate design
#   4 en-raw        untouched routelet holdout lines  <- sanity control
#
# Arm 4 is load-bearing. The classifier is only reachable when SwiftPM's ONNX
# module name is patched (see below); without that patch every arm scores zero
# and the run looks like "rewriting doesn't help" rather than "the harness is
# broken". If arm 4 does not clear 60% the script exits non-zero and refuses to
# interpret the rest.
#
# Runs against SHIPPED sources — they are re-copied on every invocation, so a
# change to the classifier is picked up here automatically.
#
# Usage:  bash scripts/run-gate-a-routelet-tests.sh [corpus.json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/gate-a"
ASSETS="$ROOT/AppResources/OpenClicky/mirage-routelet"
CORPUS="${1:-$HARNESS/corpus.json}"

for f in head.json embedder.onnx tokenizer.json; do
    [ -f "$ASSETS/$f" ] || { echo "missing model asset: $ASSETS/$f" >&2; exit 2; }
done

# Copy the shipped classifier, rewriting only the ONNX module name.
#
# The Xcode target links ONNX Runtime as `onnxruntime`; SwiftPM exposes the
# same binary as `OnnxRuntimeBindings`. Left alone, `#if canImport(onnxruntime)`
# is false here, `embed()` returns nil for every input, and the harness reports
# a uniform zero. `-module-alias` and Package.swift `moduleAliases:` were both
# tried and neither reaches a binaryTarget, so a build-time rewrite it is.
sed -e 's/canImport(onnxruntime)/canImport(OnnxRuntimeBindings)/g' \
    -e 's/^import onnxruntime$/import OnnxRuntimeBindings/' \
    "$ROOT/cursor-buddy/OpenClickyIntentClassifier.swift" \
    > "$HARNESS/Sources/gatea/OpenClickyIntentClassifier.swift"
cp "$ROOT/cursor-buddy/MirageRedact.swift" "$HARNESS/Sources/gatea/"

cd "$HARNESS"
swift build 2>&1 | grep -E "error:|warning: .*never used|Compiling|Build complete" || true

# A CLI binary's Bundle.main.resourcePath is its own directory, so the model
# assets have to sit beside the executable for the unmodified bootstrap path
# (Bundle.main.url(forResource:subdirectory:)) to find them.
ln -sfn "$ASSETS" .build/debug/mirage-routelet

exec ./.build/debug/gatea "$CORPUS"
