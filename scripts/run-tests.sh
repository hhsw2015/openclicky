#!/usr/bin/env bash
# Run the cursor-buddyTests target.
#
# fast-install.sh builds the app target only, so unit tests never execute
# there — a test file can compile-fail or assert-fail indefinitely without
# anyone noticing. This runs the test bundle with the same flags, so it
# reuses fast-install's incremental cache instead of triggering a full
# rebuild.
#
# Signing is disabled exactly as in fast-install.sh: the test bundle is
# never installed, so it does not need the fixed "OpenClicky Dev Sign"
# identity that keeps TCC permissions stable for the real app.
#
# Usage:
#   bash scripts/run-tests.sh                        # whole suite
#   bash scripts/run-tests.sh ClaudeAPICacheSplitTests
#   bash scripts/run-tests.sh ClaudeAPICacheSplitTests/test_split_losesNoContent
set -euo pipefail

SCHEME="cursor-buddy"
PROJECT="cursor-buddy.xcodeproj"
CONFIG="${CONFIG:-Debug}"
TEST_TARGET="cursor-buddyTests"

cd "$(dirname "$0")/.."

ARGS=(-project "$PROJECT" -scheme "$SCHEME"
      -destination 'platform=macOS,arch=arm64' -configuration "$CONFIG"
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
      DEVELOPMENT_TEAM="")

if [ $# -gt 0 ]; then
    for filter in "$@"; do
        ARGS+=(-only-testing:"$TEST_TARGET/$filter")
    done
    echo "running: $*"
else
    echo "running: full $TEST_TARGET suite"
fi

set +e
xcodebuild "${ARGS[@]}" test 2>&1 | tee /tmp/openclicky-tests.log | \
    grep -E "error:|failed|passed|Executed .* test|TEST (SUCCEEDED|FAILED)"
status=${PIPESTATUS[0]}
set -e

echo
if [ "$status" -eq 0 ]; then
    echo "PASS — full log: /tmp/openclicky-tests.log"
else
    echo "FAIL (exit $status) — full log: /tmp/openclicky-tests.log"
fi
exit "$status"
