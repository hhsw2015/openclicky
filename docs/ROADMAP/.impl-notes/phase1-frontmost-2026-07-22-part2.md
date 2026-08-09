# Phase 1 FrontmostApp — SPM migration (2026-07-22)

Original files landed under `cursor-buddy/ContextService/` (per doc 01). Diagnostics reported "Cannot find type FrontmostAppInfo" and "No such module XCTest" because those files were free-floating without being added to any Xcode target.

## Migration

Moved to new SPM package `Packages/OpenClickyContextService/` (matches openclicky's existing pattern — 5 sibling packages already exist: Core / UI / Memory / Markdown / Browser).

Structure:
```
Packages/OpenClickyContextService/
  Package.swift                                         (SPM manifest)
  Sources/OpenClickyContextService/
    Capture/FrontmostAppCapture.swift
    Types/CaptureTypes.swift
  Tests/OpenClickyContextServiceTests/
    FrontmostAppCaptureTests.swift
```

- `Package.swift` — swift-tools-version 5.9, platforms macOS 26.0 (matches OpenClickyCore)
- Test file: fixed `@testable import cursor_buddy` → `@testable import OpenClickyContextService`

## Verification

- `swift build`: OK (build complete)
- `swift test`: **12 pass, 1 skip** (only `test_capture_matchesFinder_afterActivation` skips when run outside Xcode — `swift test` runs headless, no WindowServer session, `loginwindow` is frontmost, `NSWorkspace.activate` is no-op)

Skip logic: test detects `loginwindow` frontmost and calls `XCTSkip`, so CI + local `swift test` both green.

## Next: add package to Xcode project

TODO (manual, one-time): user opens `cursor-buddy.xcodeproj`, adds local package dep `Packages/OpenClickyContextService/`. Not blocking further Phase 1 work — ports go into the SPM package first, integration into main app happens at Phase 4 (Layer 1 dialog reply parses ROUTE + calls captures).

## Doc updates needed

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`:
- Header path `cursor-buddy/ContextService/` → `Packages/OpenClickyContextService/`
- All `Capture/FooCapture.swift` → `Sources/OpenClickyContextService/Capture/FooCapture.swift` (or shortened as `.../Capture/FooCapture.swift`)

Done in this session.
