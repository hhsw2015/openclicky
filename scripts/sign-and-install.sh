#!/usr/bin/env bash
# sign-and-install.sh — build OpenClicky.app + sign with a persistent
# self-signed cert + install to /Applications so macOS TCC treats it
# as the same app across rebuilds (no re-authorizing Accessibility /
# Screen Recording / Microphone after every rebuild).
#
# The cert lives in login.keychain-db as CN="OpenClicky Dev Sign".
# Created once by scripts/create-dev-cert.sh (see companion script).
#
# NOTE re AGENTS.md: that doc says "do not run xcodebuild from the
# terminal" for permission testing. This script IS the exception —
# it exists precisely to solve the permission-reset problem. Do NOT
# call bare `xcodebuild` for a build+install; use this wrapper so the
# persistent cert lands. `xcodebuild test` for unit tests is
# unrelated and still permitted via scripts/run-tests.sh.
#
# usage:
#   bash scripts/sign-and-install.sh              # Release (fast, small, default)
#   CONFIG=Debug bash scripts/sign-and-install.sh # Debug (slow, 84M dylib, dev only)
set -euo pipefail

CERT_NAME="OpenClicky Dev Sign"
BUNDLE_ID="com.jkneen.openclicky"
PRODUCT="OpenClicky.app"
SCHEME="cursor-buddy"
PROJECT="cursor-buddy.xcodeproj"
CONFIG="${CONFIG:-Release}"

# Find the DerivedData product path dynamically (avoids hardcoded hash).
DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"

echo "[0/5] verify cert exists in login keychain"
if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "!! Cert '$CERT_NAME' not found in login keychain."
    echo "!! Run: bash scripts/create-dev-cert.sh"
    exit 1
fi

echo "[1/5] xcodebuild"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' -configuration "$CONFIG" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" build 2>&1 | tail -3

APP_PATH=$(find "$DERIVED_ROOT" -type d -name "$PRODUCT" \
    -path "*/Build/Products/$CONFIG/*" -print -quit)
if [ -z "$APP_PATH" ]; then
    echo "!! Could not find built $PRODUCT under DerivedData" >&2
    exit 1
fi
echo "  built: $APP_PATH"

# Sanity check: the openclicky-context-hook helper should have been
# emitted by the "Build openclicky-context-hook" Run Script phase.
# If it's missing the Xcode phase never fired -- likely the pbxproj
# was reverted or the phase was deleted from a stale schema.
HOOK_BIN="$APP_PATH/Contents/Helpers/openclicky-context-hook"
if [ ! -x "$HOOK_BIN" ]; then
    echo "!! Missing $HOOK_BIN" >&2
    echo "!! The Xcode Run Script phase 'Build openclicky-context-hook'" >&2
    echo "!! did not run. Open cursor-buddy.xcodeproj in Xcode and" >&2
    echo "!! verify the phase exists on the cursor-buddy target." >&2
    exit 1
fi
echo "  helper: $HOOK_BIN ($(stat -f%z "$HOOK_BIN") bytes)"

# --- slim: prune fat that ships to /Applications ------------------
# Runs BEFORE codesign so the trimmed layout is what's signed. Every
# action here must be a no-op for functionality on arm64 Macs:
#   - lipo -thin on universal binaries (we only ship arm64)
#   - rm node_modules test/docs dirs (never loaded at runtime)
#   - strip -x on Rust binaries (removes local/debug symbols)
# Safe to run repeatedly; each step is a guard-then-act.
echo "[1.5/5] slim app footprint"
SIZE_BEFORE=$(du -sk "$APP_PATH" | awk '{print $1}')

# 1. Thin universal Rust binaries → arm64 only (~11M off cua-driver).
for bin in \
    "$APP_PATH/Contents/Resources/CuaDriverRuntime/cua-driver" \
    ; do
    if [ -f "$bin" ] && lipo -info "$bin" 2>/dev/null | grep -q "x86_64"; then
        tmp="$bin.arm64"
        if lipo -thin arm64 "$bin" -output "$tmp" 2>/dev/null; then
            mv "$tmp" "$bin"
            chmod +x "$bin"
        fi
    fi
done

# 2. Remove Node dev cruft that never runs (tests, .github, docs).
#    ~200 dirs × a few KB each = MBs saved, zero runtime cost.
find "$APP_PATH/Contents/Resources" \
    \( -type d \) \
    \( -name "test" -o -name "tests" -o -name ".github" \
       -o -name "example" -o -name "examples" \
       -o -name "docs" -o -name "coverage" \) \
    -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP_PATH/Contents/Resources" \
    \( -name "*.map" -o -name "*.ts.map" -o -name "CHANGELOG*" \
       -o -name "HISTORY*" -o -name ".npmignore" \
       -o -name ".eslintrc*" -o -name ".prettierrc*" \
       -o -name "tsconfig*.json" -o -name ".editorconfig" \
       -o -name ".travis.yml" -o -name ".npmrc" \) \
    -type f -delete 2>/dev/null || true
# 2b. Node dev cruft that lives ONLY in node_modules (safe: runtime
#     never reads these). Delete READMEs / TypeScript declarations /
#     lockfiles from every node_modules subtree. Non-node_modules
#     READMEs are runtime skill content (OpenClickyBundledSkills) and
#     stay untouched.
find "$APP_PATH/Contents/Resources" -type d -name "node_modules" -prune -exec sh -c '
    find "$1" -type f \( \
        -iname "README*" -o -iname "Readme*" \
        -o -iname "HISTORY*" -o -iname "AUTHORS*" \
        -o -iname "CONTRIBUTORS*" -o -iname "SECURITY*" \
        -o -iname "GOVERNANCE*" -o -iname "*.markdown" \
        -o -name "*.d.ts" \
        -o -name "package-lock.json" -o -name ".package-lock.json" \
    \) -delete 2>/dev/null
' _ {} \; 2>/dev/null || true

# 3. Strip local symbols from Rust binaries. Keeps public symbols so
#    dyld/link-with still works; removes debug/local ~10-30% typical.
#    Any modification here invalidates the existing signature — the
#    codesign in [2/5] will overwrite anyway, but we record the list
#    so signing order is deep-first (nested binaries before outer).
MODIFIED_BINS=()
for bin in \
    "$APP_PATH/Contents/Resources/CuaDriverRuntime/cua-driver" \
    "$APP_PATH/Contents/Resources/BackgroundComputerUseRuntime/BackgroundComputerUse.app/Contents/MacOS/BackgroundComputerUse" \
    ; do
    if [ -f "$bin" ]; then
        strip -x "$bin" 2>/dev/null || true
        MODIFIED_BINS+=("$bin")
    fi
done

SIZE_AFTER=$(du -sk "$APP_PATH" | awk '{print $1}')
echo "  slimmed: $((SIZE_BEFORE - SIZE_AFTER)) KB removed ($SIZE_BEFORE -> $SIZE_AFTER KB)"

echo "[2/5] codesign with $CERT_NAME"
# Re-sign the nested Rust binaries we modified first. macOS validates
# from the inside out, so if we only re-sign the outer .app the nested
# binaries stay marked "invalid signature (modified)" and any code path
# that inspects them (Gatekeeper on launch of the helper, XPC handshake
# in a hardened context) can fail. Codesigning nested bundles first
# keeps every level valid.
if [ -f "$APP_PATH/Contents/Resources/BackgroundComputerUseRuntime/BackgroundComputerUse.app/Contents/MacOS/BackgroundComputerUse" ]; then
    codesign --force --sign "$CERT_NAME" \
        "$APP_PATH/Contents/Resources/BackgroundComputerUseRuntime/BackgroundComputerUse.app/Contents/MacOS/BackgroundComputerUse" 2>/dev/null || true
    codesign --force --sign "$CERT_NAME" \
        "$APP_PATH/Contents/Resources/BackgroundComputerUseRuntime/BackgroundComputerUse.app" 2>/dev/null || true
fi
if [ -f "$APP_PATH/Contents/Resources/CuaDriverRuntime/cua-driver" ]; then
    codesign --force --sign "$CERT_NAME" \
        "$APP_PATH/Contents/Resources/CuaDriverRuntime/cua-driver" 2>/dev/null || true
fi
codesign --force --sign "$CERT_NAME" --deep \
    --preserve-metadata=entitlements,identifier "$APP_PATH"

# Verify the signature identity landed
SIGN_INFO=$(codesign -dvvv "$APP_PATH" 2>&1 || true)
if ! echo "$SIGN_INFO" | grep -q "Authority=$CERT_NAME"; then
    echo "!! codesign did not apply expected Authority. Rebuild aborted." >&2
    echo "$SIGN_INFO" | head
    exit 1
fi

echo "[3/5] kill running + swap /Applications/$PRODUCT"
pkill -f "/Applications/$PRODUCT/Contents/MacOS/OpenClicky" 2>/dev/null || true
# FIX(zombie-helpers-2026-08-01): rebuild after rebuild leaves Node
# helper subprocesses (boot.js under Contents/Resources/Open*Runtime)
# orphaned to launchd (ppid=1). Over ~15 build cycles this bloats to
# 50+ zombie procs and ~350 MB RSS. Reap them explicitly before spawning
# a fresh app instance.
pkill -f "/Applications/$PRODUCT/Contents/Resources/Open.*Runtime/boot.js" 2>/dev/null || true
sleep 1
# Purge any historical .bak leftovers before we start — they add up to
# ~300 MB per stale copy. macOS Finder occasionally renames removed
# apps to `.bak.app` too; clean both shapes.
find /Applications -maxdepth 1 \
    \( -name "$PRODUCT.bak" -o -name "$PRODUCT.bak.app" \
       -o -name "$PRODUCT.bak.*" \) \
    -exec rm -rf {} + 2>/dev/null || true
# Atomic swap: move current aside, install new, THEN delete the aside.
# This keeps a rollback window during copy but does not leave 300 MB
# of dead weight on disk between builds.
if [ -d "/Applications/$PRODUCT" ]; then
    mv "/Applications/$PRODUCT" "/Applications/$PRODUCT.bak"
fi
cp -R "$APP_PATH" "/Applications/$PRODUCT"
rm -rf "/Applications/$PRODUCT.bak"

echo "[4/5] open"
open "/Applications/$PRODUCT"
sleep 2
pid=$(pgrep -f "/Applications/$PRODUCT/Contents/MacOS/OpenClicky" | head -1 || true)
echo "  openclicky pid=$pid  identifier=$BUNDLE_ID  Authority=$CERT_NAME"

echo "[5/5] done."
