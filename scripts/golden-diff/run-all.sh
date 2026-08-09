#!/usr/bin/env bash
set -euo pipefail

# Usage: run-all.sh
#
# Iterates fixtures/manifest.txt: setup -> capture-everywhere ->
# capture-openclicky -> diff. Prints aggregate pass/fail and exits 0 iff
# all fixtures pass.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/fixtures/manifest.txt"

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: manifest missing at $MANIFEST" >&2
  exit 1
fi

pass=0
fail=0
failed_ids=()

while IFS= read -r fixture; do
  # Skip blanks and comments.
  [[ -z "$fixture" || "$fixture" =~ ^# ]] && continue
  echo "== fixture: $fixture =="

  if ! "$SCRIPT_DIR/setup-fixture.sh" "$fixture"; then
    echo "setup failed for $fixture" >&2
    fail=$((fail + 1))
    failed_ids+=("$fixture(setup)")
    continue
  fi

  if ! "$SCRIPT_DIR/capture-everywhere.sh" "$fixture"; then
    echo "capture-everywhere failed for $fixture" >&2
    fail=$((fail + 1))
    failed_ids+=("$fixture(everywhere)")
    continue
  fi

  if ! "$SCRIPT_DIR/capture-openclicky.sh" "$fixture"; then
    echo "capture-openclicky failed for $fixture" >&2
    fail=$((fail + 1))
    failed_ids+=("$fixture(openclicky)")
    continue
  fi

  if python3 "$SCRIPT_DIR/diff-fixture.py" "$fixture"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_ids+=("$fixture(diff)")
  fi
done < "$MANIFEST"

echo
echo "== summary =="
echo "pass: $pass"
echo "fail: $fail"
if (( fail > 0 )); then
  printf 'failed: %s\n' "${failed_ids[@]}"
  exit 1
fi
exit 0
