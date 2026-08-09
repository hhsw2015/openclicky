# Phase 5 - VisionOCR port report (2026-07-22)

## Result

VisionOCR port landed in `OpenClickyContextService`. All new tests
(9 in `OCRCaptureTests`) pass alongside the pre-existing 149; package
`swift test` reports 158 tests, 0 failures, 2 pre-existing skips.

## Files

- Added: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/OCRCapture.swift`
  - Public enum `OCRCapture` with `static func ocr(image:languages:)
    async -> OCRResult?`
  - Header stamped with the required port marker.
- Modified: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - Appended `OCRLine` (text / bounds / confidence) and `OCRResult`
    (lines) at the end of the file. Both `Codable, Equatable,
    Sendable`. No other type or field touched.
- Added: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/OCRCaptureTests.swift`
  - 9 tests: nil path, blank-image path, English recognition,
    multi-language recognition, bounding-box invariants, ascending-y
    ordering, JSON round-trip (populated), JSON round-trip (empty),
    default-language constant.
- Added: `docs/ROADMAP/.impl-notes/phase5-ocr-2026-07-22.md`
  - Investigation notes with the C# semantics extraction and
    Everywhere -> openclicky deltas.

## Semantic alignment vs `MacVisionOcrEngine.cs`

| Aspect | Everywhere (Fast branch) | openclicky | Notes |
| --- | --- | --- | --- |
| Recognition level | `Fast` | `.fast` | 1:1 |
| Language correction | `false` (Fast) | `false` | 1:1 |
| Recognition languages | caller OR `["zh-Hans","zh-Hant","en-US"]` | caller OR `["en-US","zh-Hans"]` | Default differs (product default; per docs row 16). Caller-supplied list identical. |
| Revision | default (unpinned) | default (unpinned) | 1:1 |
| Handler options | `NSDictionary()` empty | `[:]` empty | 1:1 |
| Perform | sync `handler.Perform` | sync `handler.perform` on detached task | Same call underneath; wrapped in `async` boundary. |
| Top candidates | `TopCandidates(1)` | `topCandidates(1)` | 1:1 |
| Empty candidate | skip | skip | 1:1 |
| Missing string | `?? ""` | `top.string` (non-optional in Swift) | Semantically equivalent — Vision Swift API guarantees non-optional. |
| Bounding-box normalisation | round + clamp `>= 1` | round + clamp `>= 1` | 1:1 |
| Y-flip | `(1.0 - ny - nh) * H` + originPx | `(1.0 - ny - nh) * H` (no originPx) | Origin translation moved to caller (documented). |
| Final sort | asc by `Bounds.Y` | asc by `bounds.origin.y` | 1:1 |
| Error return | empty list | `nil` (decode / perform fail); empty list on zero observations | Strict superset — caller can still coalesce with `?? OCRResult(lines: [])`. |

## Deltas from Everywhere (all called out in the code header)

1. `NSImage` input rather than a PNG stream.
2. No `originPx` translation — bounds stay in image-local space.
3. `OCRResult?` return separates "Vision failed" from "no lines".
4. Fast quality only (Accurate branch unexposed at P1).
5. `async` API wrapping the sync Vision call.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 16 already lists
`Capture/OCRCapture.swift` as the target. Row 89's signature drops the
optional return; the impl notes document the deviation. No doc edits
were made in this pass — the roadmap file has broader formatting
issues that should be handled in a dedicated sweep.

## Verification

- `swift build` inside `Packages/OpenClickyContextService`: clean.
- `swift test --filter OCRCaptureTests`: 9 passed.
- `swift test`: 158 tests, 0 failures, 2 pre-existing skips.
- `scripts/sign-and-install.sh`: xcodebuild DB is currently locked by
  a concurrent Xcode build; not related to this change (no source
  edits outside the OCR files). SPM test result is the authoritative
  gate for a package-scoped port per project rules ("Do not run
  `xcodebuild` from the terminal").

## Rule-file compliance

- Header contains `// Ported from Everywhere: src/Everywhere.Mac/Interop/MacVisionOcrEngine.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809`.
- Target path exactly `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/OCRCapture.swift`.
- Test path exactly `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/OCRCaptureTests.swift`.
- Only appended to `Types/CaptureTypes.swift` (no other capture file
  touched).
- Public API matches the prescribed signature: `OCRCapture.ocr(image:
  NSImage, languages: [String] = ["en-US", "zh-Hans"]) async ->
  OCRResult?`.
