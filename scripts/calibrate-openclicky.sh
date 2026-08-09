#!/usr/bin/env bash
# calibrate-openclicky.sh — HeyClicky server-side coord calibration test.
#
# Follows the server dev's protocol: fix environment, small stable target,
# 5 repeats, check landing variance. Uses ccline / heyclicky-ask backend
# which reads OpenClicky's live Supabase session automatically.
#
# Usage: bash scripts/calibrate-openclicky.sh [<target-name>]
#   target-name defaults to "the Apple logo in the top-left menu bar"

set -euo pipefail

TARGET_DESC="${1:-the Apple logo in the top-left menu bar}"
SHOT=/tmp/openclicky-calib.jpg
RUNS=5

if ! command -v ccline >/dev/null 2>&1; then
    echo "[calibrate] ccline not on PATH" >&2
    exit 1
fi

echo "[calibrate] target: $TARGET_DESC"
echo "[calibrate] runs: $RUNS"
echo "[calibrate] taking screenshot ..."
screencapture -x -t jpg "$SHOT"
sips -Z 1280 -s formatOptions 75 -s format jpeg "$SHOT" --out "$SHOT" >/dev/null
SIZE=$(sips -g pixelWidth -g pixelHeight "$SHOT" | awk 'NR==2 {w=$2} NR==3 {h=$2} END {print w"x"h}')
echo "[calibrate] screenshot: $SIZE"

Q="I sent you a macOS screenshot at ${SIZE}. Please return ONLY the pixel coordinates (top-left origin) of the CENTER of ${TARGET_DESC} in this image. Format: exactly \"x=<int>, y=<int>\". No prose, no explanation."

echo "[calibrate] running $RUNS iterations ..."
for i in $(seq 1 "$RUNS"); do
    ANS=$(CCLINE_IMAGE="$SHOT" CCLINE_BACKEND=heyclicky ccline "$Q" 2>&1 | tail -1)
    printf '  run %d: %s\n' "$i" "$ANS"
done

echo "[calibrate] done. Variance = server model's per-call jitter."
echo "[calibrate] If x/y drift >5 px between runs, the model itself is imprecise;"
echo "[calibrate] if drift <2 px but openclicky renders wrong, it's a client transform bug."
