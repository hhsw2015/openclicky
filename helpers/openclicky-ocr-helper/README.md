# openclicky-ocr-helper

Out-of-process Vision OCR + SQLCipher FTS writer for OpenClicky.

## Why it exists

The main OpenClicky app captures screen frames every ~2 s and runs
Vision OCR + SQLite FTS writes inline. Empirically that pinned 60-80 %
CPU every ~15 s and caused the virtual cursor overlay to stutter when
the user scrubbed the mouse: Vision competes with WindowServer for
the ANE, and SQLCipher WAL fsyncs stall the main app's compositor
thread.

This helper moves both jobs into a separate process. The main app pays
only a PNG encode + XPC send, then returns to the runloop. Vision and
SQLite work happen in the helper's address space at background QoS,
CPU-only, so they never compete with the main app for the ANE or the
performance cores.

## Bundle layout

At runtime the helper lives at:

```
OpenClicky.app/
  Contents/
    XPCServices/
      com.jkneen.openclicky.ocr.xpc/
        Contents/
          Info.plist                     (from this directory)
          MacOS/openclicky-ocr-helper    (built by Swift Package Manager)
```

The main app opens the connection via:

```swift
let conn = NSXPCConnection(serviceName: "com.jkneen.openclicky.ocr")
```

`NSXPCConnection(serviceName:)` only resolves services inside the
caller's bundle. launchd starts an instance on first request and
tears it down after ~15 s idle, so resident memory is zero when the
user isn't capturing.

## Building

The helper is an SPM executable. From this directory:

```sh
swift build -c release
```

The compiled binary lands at `.build/release/openclicky-ocr-helper`.

## Wiring into the app bundle

The main `cursor-buddy` target's `Copy OpenClicky App Resources`
build phase is not enough: we need an XPCService bundle, not a bare
binary. Add a **new** shell-script build phase to the `cursor-buddy`
target (`Build openclicky-ocr-helper`) with this script:

```sh
set -euo pipefail

if [ "${CONFIGURATION}" = "Debug" ]; then
    OCR_CONFIG=debug
else
    OCR_CONFIG=release
fi

PACKAGE_DIR="${SRCROOT}/helpers/openclicky-ocr-helper"

xcrun --sdk macosx swift build \
    --package-path "$PACKAGE_DIR" \
    --product openclicky-ocr-helper \
    -c $OCR_CONFIG

XPC_ROOT="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/XPCServices/com.jkneen.openclicky.ocr.xpc"
mkdir -p "$XPC_ROOT/Contents/MacOS"

cp "$PACKAGE_DIR/.build/$OCR_CONFIG/openclicky-ocr-helper" \
   "$XPC_ROOT/Contents/MacOS/openclicky-ocr-helper"
chmod +x "$XPC_ROOT/Contents/MacOS/openclicky-ocr-helper"

cp "$PACKAGE_DIR/Info.plist" "$XPC_ROOT/Contents/Info.plist"

# Sign the XPC bundle with the app's identity + hardened runtime.
if [ "${CODE_SIGNING_ALLOWED}" = "YES" ] \
    && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
             --options runtime \
             --timestamp=none \
             "$XPC_ROOT"
fi
```

Input files:
- `$(SRCROOT)/helpers/openclicky-ocr-helper/Package.swift`
- `$(SRCROOT)/helpers/openclicky-ocr-helper/Sources/openclicky-ocr-helper/main.swift`
- `$(SRCROOT)/helpers/openclicky-ocr-helper/Info.plist`

Output files:
- `$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/XPCServices/com.jkneen.openclicky.ocr.xpc/Contents/MacOS/openclicky-ocr-helper`

The `project.pbxproj` diff registers this new phase; edit it via
Xcode's Build Phases UI if you would prefer.

## Runtime contract

- Vault path is fixed to
  `~/Library/Application Support/OpenClicky/rewind` — must match the
  main app's `OpenRewindStorage.defaultAppSupportName = "OpenClicky/rewind"`.
- The helper reads the SQLCipher key from `<vault>/key` itself. The
  main app never marshals the key across XPC.
- SQLCipher runs in WAL mode: main app and helper may both hold
  read-write handles at the same time.
- The helper opens its SQLite handle lazily on the first request and
  keeps it until the process is torn down by launchd.

## Debugging

To watch the helper's per-frame trace:

```sh
log stream --predicate 'process == "openclicky-ocr-helper"' --style compact
```

Or attach lldb once the service is running:

```sh
lldb -n openclicky-ocr-helper
```
