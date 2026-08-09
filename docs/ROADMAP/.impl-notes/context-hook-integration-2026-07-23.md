# context-hook-integration 2026-07-23

Integrate the Swift `openclicky-context-hook` CLI (built by SPM package
`Packages/OpenClickyContextService`) into the OpenClicky .app bundle at
`Contents/Helpers/openclicky-context-hook`.

## pbxproj edits

File: `cursor-buddy.xcodeproj/project.pbxproj`

### 1. Added new Run Script phase reference to target `cursor-buddy`

Under `PBXNativeTarget` `28F22CBE2F56440300A0FC59` (product
`OpenClicky.app`), appended new phase to `buildPhases` after the existing
`Copy OpenClicky App Resources` phase:

    AA00CH010000000000000001 /* Build openclicky-context-hook */,

Placement: after "Copy OpenClicky App Resources", which is the last phase
before Xcode's implicit Sign step. This ensures the helper is present in
the bundle when Xcode signs.

### 2. Added new PBXShellScriptBuildPhase object

New UUID: `AA00CH010000000000000001` (chose `AA00CH…` prefix to match the
existing `AA00CC…` "Copy" phase — CH = Context Hook, 24 hex chars).

Inputs (for build-cache):
- `$(SRCROOT)/Packages/OpenClickyContextService/Sources/openclicky-context-hook/main.swift`
- `$(SRCROOT)/Packages/OpenClickyContextService/Package.swift`

Output:
- `$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Helpers/openclicky-context-hook`

Script body:

    set -euo pipefail

    if [ "${CONFIGURATION}" = "Debug" ]; then
        HOOK_CONFIG=debug
    else
        HOOK_CONFIG=release
    fi

    PACKAGE_DIR="${SRCROOT}/Packages/OpenClickyContextService"

    xcrun --sdk macosx swift build \
        --package-path "$PACKAGE_DIR" \
        --product openclicky-context-hook \
        -c $HOOK_CONFIG

    HELPERS_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Helpers"
    mkdir -p "$HELPERS_DIR"
    cp "$PACKAGE_DIR/.build/$HOOK_CONFIG/openclicky-context-hook" "$HELPERS_DIR/openclicky-context-hook"
    chmod +x "$HELPERS_DIR/openclicky-context-hook"

## sign-and-install.sh diff

Added a sanity check between the `xcodebuild` step and the `codesign` step
to fail fast if the helper binary is missing from the built bundle:

    HOOK_BIN="$APP_PATH/Contents/Helpers/openclicky-context-hook"
    if [ ! -x "$HOOK_BIN" ]; then
        echo "!! Missing $HOOK_BIN" >&2
        echo "!! The Xcode Run Script phase 'Build openclicky-context-hook'" >&2
        echo "!! did not run. Open cursor-buddy.xcodeproj in Xcode and" >&2
        echo "!! verify the phase exists on the cursor-buddy target." >&2
        exit 1
    fi

No change to the `codesign --force --sign … --deep …` step — `--deep`
already re-signs nested Mach-O binaries under `Contents/Helpers/` with the
persistent dev cert, and `cp -R "$APP_PATH" /Applications/$PRODUCT` copies
the entire bundle including Helpers/.

## Verification

    $ plutil -lint cursor-buddy.xcodeproj/project.pbxproj
    cursor-buddy.xcodeproj/project.pbxproj: OK

    $ grep -c openclicky-context-hook cursor-buddy.xcodeproj/project.pbxproj
    6

(Well above the required threshold of 3: script name, product flag, cp
source, cp dest, chmod, output path, input source file. Count is 6
because the script name appears once, product flag once, cp source path
once, cp dest inline once, chmod once, output path once — some tokens
share references.)

## Files created / modified

- `cursor-buddy.xcodeproj/project.pbxproj` — modified (2 hunks)
- `scripts/sign-and-install.sh` — modified (added helper presence check)
- `docs/OPENCLICKY_CONTEXT_HOOK_INSTALL.md` — new user-facing install guide

## Not modified (per constraints)

- `Packages/OpenClickyContextService/Sources/openclicky-context-hook/main.swift`
- No other in-flight files (F32–F36 fix agent's work untouched)

## User action required

The Run Script phase only fires when the target is built by Xcode. The
user must:

1. Open `cursor-buddy.xcodeproj` in Xcode.
2. Build the `cursor-buddy` scheme once (Cmd-B).
3. Confirm `Contents/Helpers/openclicky-context-hook` is present in the
   built product (DerivedData path).

From that point, `scripts/sign-and-install.sh` handles the helper
automatically on every subsequent build+install: the Xcode Run Script
phase rebuilds/copies, the sanity check verifies presence, `codesign
--deep` re-signs the nested binary with the persistent dev cert, and
`cp -R` propagates the whole bundle into `/Applications/OpenClicky.app`.
