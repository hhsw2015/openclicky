#!/usr/bin/env bash
# test-context-hook.sh — end-to-end integration test for
# openclicky-context-hook. Writes a fixture stash to the expected path,
# runs the binary, asserts the stdout JSON envelope, verifies the stash
# file was atomically claimed (rename + unlink), then exercises the
# rejection cases (missing, empty, oversize, wrong prefix, stale mtime).
#
# Ported from Everywhere: tools/everywhere-context-hook/src/main.rs @30e03e9dcfdd4247fd679828ed86e9042f32d809

set -euo pipefail

PKG_DIR="/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService"
STASH_DIR="$HOME/Library/Application Support/OpenClicky"
STASH_PATH="$STASH_DIR/context-stash.json"
BINARY="$PKG_DIR/.build/debug/openclicky-context-hook"

echo "[0/6] build hook binary"
(cd "$PKG_DIR" && swift build --product openclicky-context-hook 2>&1 | tail -3)

if [ ! -x "$BINARY" ]; then
    echo "!! hook binary missing at $BINARY" >&2
    exit 1
fi

mkdir -p "$STASH_DIR"

# Save any pre-existing stash so we don't clobber the user's real state.
BACKUP=""
if [ -f "$STASH_PATH" ]; then
    BACKUP="$STASH_PATH.testbackup.$$"
    mv "$STASH_PATH" "$BACKUP"
fi
restore_backup() {
    rm -f "$STASH_PATH"
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        mv "$BACKUP" "$STASH_PATH"
    fi
    # Sweep any test-created .consumed-* files
    find "$STASH_DIR" -maxdepth 1 -name "context-stash.consumed-*.json" -mmin -5 -delete 2>/dev/null || true
}
trap restore_backup EXIT

fail() {
    echo "!! FAIL: $1" >&2
    exit 1
}

# -----------------------------------------------------------------
# Case 1: happy path — valid payload, hook injects JSON to stdout.
# -----------------------------------------------------------------
echo "[1/6] happy path"
cat > "$STASH_PATH" <<'EOF'
[openclicky-ctx] app=safari title="Home" url=https://example.com/ selection="hi"
[openclicky-hint] If user's question needs pointer, call relevant OpenClicky MCP tool — don't guess.
[openclicky-ctx-json] {"schema_version":1,"captured_at_utc":"2026-07-22T10:00:00.000+00:00","app":"safari"}
EOF

OUT="$("$BINARY" 2>/dev/null)"
echo "  stdout: $OUT" | head -c 200
echo
[[ "$OUT" == *'"hookEventName":"UserPromptSubmit"'* ]] || fail "hookEventName missing"
[[ "$OUT" == *'"additionalContext"'* ]]              || fail "additionalContext missing"
[[ "$OUT" == *'"systemMessage"'* ]]                  || fail "systemMessage missing"
[[ "$OUT" == *'app=safari'* ]]                       || fail "app summary missing"
[[ "$OUT" == *'+selection'* ]]                       || fail "+selection flag missing"
[[ -f "$STASH_PATH" ]] && fail "stash file was not consumed"
if ls "$STASH_DIR"/context-stash.consumed-*.json >/dev/null 2>&1; then
    fail "consumed sibling was not unlinked"
fi
echo "  OK"

# -----------------------------------------------------------------
# Case 2: missing stash — hook exits 0 silently with empty stdout.
# -----------------------------------------------------------------
echo "[2/6] missing stash silent exit"
rm -f "$STASH_PATH"
OUT="$("$BINARY" 2>/dev/null)"
[[ -z "$OUT" ]] || fail "expected empty stdout, got: $OUT"
echo "  OK"

# -----------------------------------------------------------------
# Case 3: empty file — rejected as malformed, stash consumed anyway.
# -----------------------------------------------------------------
echo "[3/6] empty payload rejected"
: > "$STASH_PATH"
OUT="$("$BINARY" 2>/dev/null)"
STDERR="$("$BINARY" 2>&1 >/dev/null || true)"
[[ -z "$OUT" ]] || fail "expected empty stdout, got: $OUT"
# stash file (or the second-run empty replacement) is fine either way;
# main invariant is no JSON emitted.
echo "  OK"

# -----------------------------------------------------------------
# Case 4: oversize file — rejected as malformed.
# -----------------------------------------------------------------
echo "[4/6] oversize payload rejected"
{
    printf '[openclicky-ctx] '
    head -c 65600 /dev/urandom | base64
} > "$STASH_PATH"
OUT="$("$BINARY" 2>/dev/null)"
[[ -z "$OUT" ]] || fail "expected empty stdout, got: $OUT"
echo "  OK"

# -----------------------------------------------------------------
# Case 5: wrong prefix — rejected (not an openclicky envelope).
# -----------------------------------------------------------------
echo "[5/6] wrong prefix rejected"
echo "[everywhere-ctx] app=safari title=\"Home\"" > "$STASH_PATH"
OUT="$("$BINARY" 2>/dev/null)"
[[ -z "$OUT" ]] || fail "expected empty stdout, got: $OUT"
echo "  OK"

# -----------------------------------------------------------------
# Case 6: stale mtime (>5 min) — unlinked without injection.
# -----------------------------------------------------------------
echo "[6/6] stale mtime unlinked"
cat > "$STASH_PATH" <<'EOF'
[openclicky-ctx] app=safari title="Home"
[openclicky-hint] generic
[openclicky-ctx-json] {"schema_version":1,"captured_at_utc":"2026-07-22T10:00:00.000+00:00","app":"safari"}
EOF
# Backdate mtime to 6 minutes ago (macOS touch -t YYYYMMDDhhmm).
SIX_MIN_AGO=$(date -v-6M +"%Y%m%d%H%M")
touch -t "$SIX_MIN_AGO" "$STASH_PATH"
OUT="$("$BINARY" 2>/dev/null)"
[[ -z "$OUT" ]] || fail "expected empty stdout on stale stash, got: $OUT"
[[ -f "$STASH_PATH" ]] && fail "stale stash was not unlinked"
echo "  OK"

echo
echo "all 6 hook integration cases passed"
