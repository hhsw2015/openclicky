#!/usr/bin/env bash
# Fast iteration wrapper: Debug build (uses SwiftCompile incremental
# cache), skips slim + custom re-sign of every internal binary. Use
# when you need turnaround under 15 s for testing UI changes.
# For a shipping build (small, stripped, Release-optimized), use
# `sign-and-install.sh` instead.
set -euo pipefail
CERT_NAME="OpenClicky Dev Sign"
PRODUCT="OpenClicky.app"
SCHEME="cursor-buddy"
PROJECT="cursor-buddy.xcodeproj"
CONFIG="${CONFIG:-Debug}"

cd "$(dirname "$0")/.."

echo "[1/3] xcodebuild $CONFIG (incremental)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' -configuration "$CONFIG" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" build 2>&1 | \
    grep -E "error:|warning:|BUILD" | head -20

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -type d \
    -name "$PRODUCT" -path "*/Build/Products/$CONFIG/*" -print -quit)
if [ -z "$APP_PATH" ]; then
    echo "  build failed: $PRODUCT not found in DerivedData"; exit 1
fi

echo "[2/3] codesign (outer only)"
codesign --force --sign "$CERT_NAME" --deep \
    --preserve-metadata=entitlements,identifier "$APP_PATH" 2>&1 | tail -3

echo "[3/3] swap + launch"
pkill -x "${PRODUCT%.app}" 2>/dev/null || true
rm -rf "/Applications/$PRODUCT"
cp -R "$APP_PATH" "/Applications/$PRODUCT"
open -n "/Applications/$PRODUCT"
sleep 0.5
echo "  pid=$(pgrep -x "${PRODUCT%.app}" | head -1)"
