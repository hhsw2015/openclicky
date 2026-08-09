# 04 — Extractions & Shim Bugs

Audit of: `SKIShimBuilder`, `AnthropicSSEStream`, `OpenClickyImagePreprocessor`,
`MirageProxyTokenMinter`, mirage dock advance, LocaleManager i18n.

Deployment target: `MACOSX_DEPLOYMENT_TARGET = 26.0` (`cursor-buddy.xcodeproj/project.pbxproj`).

---

## Extractions Correct

### E1. `MirageProxyTokenMinter.mint` — token recipe extraction
`cursor-buddy/MirageProxyTokenMinter.swift:32-76`.
Wire fingerprint preserved verbatim (header order, UA `reqwest/0.13.4`, `{}` body,
`x-peeky-device-id` from shared UUID pool). Both call sites
(`MirageDeepgramClient.swift:122`, `MirageCartesiaClient.swift:59`) invoke identically
with matching `ttlFallbackSeconds: 60`. Rotation-on-429 preserved
(`MirageBackendClient.shared.forceRotate()`). Correct.

### E2. `makeError` closure — error-type flexibility
`MirageProxyTokenMinter.swift:37` declares `makeError: @Sendable (Int, Data) -> Error`.
Callers return their own enum types (`MirageDeepgramError.tokenMintFailed`,
`MirageCartesiaError.tokenMintFailed`) — both conform to `Error`. No forced NSError
casting. Swift error type, not NSError-shaped. Q7 concern is unfounded.

### E3. `LocaleManager.shortLanguageCode`
`OpenClickyLocaleManager.swift:152-159`. Uses `Locale.language.languageCode?.identifier`
(macOS 13+). Deployment target is macOS 26 — API is fully supported. Fallback
`split(separator: "-")` handles the impossible-in-practice nil branch. Correct.

### E4. `LocaleManager.t(_:in:)` — caption lookup
`OpenClickyLocaleManager.swift:170-174`. `bucket[lang] ?? bucket["en"] ?? key`.
For a Korean user (`shortLanguageCode == "ko"`), `mirageCaptions["thinking"]["ko"]`
is missing → falls back to `"en"` → `"Thinking"`. Fallback path fires as designed.
Correct.

### E5. `advanceMiragePeekyDock` empty activityLine handling
`CompanionManager+SKIShimBuilder.swift:46-49` passes `activityLine ?? ""`.
`CodexAgentSession.updateSKIShimState` (`CodexAgentSession.swift:269`) trims and
short-circuits on empty. Existing buffer preserved. No NaN state, no accidental
overwrite of `activityStatusLines`. Comment at line 45-46 documents intent.
Correct — but see S3 for a readability nit.

### E6. Per-turn UUID isolation
`CompanionManager+SKIShimBuilder.swift:77` (`let dockID = UUID()`). Each turn
mints a fresh UUID; the `defer` block at
`CompanionManager+AIResponsePipeline.swift:2628-2642` captures that turn's
specific `dockID`, so a new turn's shim (different UUID) is not affected by the
old turn's deferred cleanup. Q1 concern unfounded — no cross-turn state
clobber.

---

## Extraction Bugs

### X1. `AnthropicSSEStream.drainTextDeltas` drops trailing partial line — LOW
`cursor-buddy/AnthropicSSEStream.swift:34-64`. Loop only processes lines with a
`\n` boundary. On stream end, any residual data in `lineBuf` is discarded at
line 64 (`return accumulated`). If upstream ever closes the connection after
`data: [DONE]` without the standard `\n\n` framing, the `[DONE]` terminator is
silently dropped and the stream ends with whatever `accumulated` holds.

In practice Anthropic always emits `\n\n` after `[DONE]` and `message_stop`
fires first anyway, so this is an edge-case robustness gap, not a live bug.

Fix (`AnthropicSSEStream.swift:63`, after the `for try await` loop):
```swift
// Flush trailing line if the server closed without a final \n.
if lineBuf.hasPrefix("data: ") {
    let payload = String(lineBuf.dropFirst("data: ".count))
    if payload == "[DONE]" { return accumulated }
}
return accumulated
```
Severity: LOW.

### X2. `AnthropicSSEStream` ignores `message_start` / `content_block_start` — LOW
`cursor-buddy/AnthropicSSEStream.swift:46-61`. Only three event types handled:
`content_block_delta.text_delta`, `message_stop`, `error`. `message_start`
carries usage counters (`input_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`); `content_block_start` carries tool_use kickoff
metadata. Both are silently ignored.

Impact: token/cost accounting for mirage turns is impossible from this parser,
and callers that ever want tool_use over SSE must layer a second parser.
Errors ARE surfaced correctly (line 54-60 throws NSError). Q4 concern about
error surfacing is unfounded; the metadata gap is a real but low-severity
limitation.

Fix: add an optional `onEvent: ((type: String, obj: [String: Any]) -> Void)?`
so callers can observe the raw stream without a fork. Severity: LOW.

### X3. `OpenClickyImagePreprocessor` migration only partial — INFO
`cursor-buddy/OpenClickyImagePreprocessor.swift` is only used by
`HeyClickyChatToolCallClient.downscaleJPEG` wrapper
(`HeyClickyChatToolCallClient.swift:677`) and `AssistAgentTools.swift:248`
(which calls through the wrapper).

Remaining hand-rolled encode sites (`CGImageDestinationAddImage` grep):
- `OpenRewind/Capture/OCRHelperClient.swift:270` — PNG encode, not JPEG resize.
  Different contract. Correctly untouched.
- `OpenRewind/Capture/Chunker.swift:391` — JPEG at fixed `0.85` quality inside
  the chunker. Could delegate; nothing forces it to stay inline.
- `AssistAgent/AssistAgentPriorImage.swift:211` — grayscale JPEG encode. Uses
  `CGColorSpaceCreateDeviceGray` — the preprocessor is RGB-only
  (`CGColorSpaceCreateDeviceRGB` at `OpenClickyImagePreprocessor.swift:51`).
  Would need a colorspace parameter to delegate. Correctly untouched.
- `Packages/OpenClickyContextService/.../ScreenshotCaptureEverywhere.swift:293`
  — inside an SPM package that does NOT depend on `cursor-buddy` target types,
  so it cannot reach `OpenClickyImagePreprocessor`. Correctly untouched.

Audit's "8 sites" number was optimistic. Real reusable migration surface is
~1-2 (`Chunker.swift` is the only true candidate, and only for the RGB path).
Q6 concern: mostly intentional / structural, not missed migrations. Severity:
INFO, no action required unless a shared package for the preprocessor is
carved out.

---

## Shim Bugs

### S1. Dock caption flicker inside a single `assistant` event — MEDIUM
`CompanionManager+AIResponsePipeline.swift:2683-2730`. An Anthropic `assistant`
event's `content` array is iterated block-by-block; each `text`/`tool_use`/
`thinking` block calls `advanceMiragePeekyDock` with its own stage label.

For a content sequence `[text, tool_use, text]` (very common when Claude
narrates before + after a tool), the stage label flips
`"Composing reply"` → `"🔧 <toolname>"` → `"Composing reply"` inside a single
event tick. `upsertSKIModeDockItem` publishes each mutation, so SwiftUI
re-renders the bubble caption 3× per event. Visible as caption flicker on
fast agent turns.

Fix: coalesce per-event — walk `content` first to compute the terminal stage
label + accumulated activity line, then call `advanceMiragePeekyDock` once.
Sketch (`AIResponsePipeline.swift:2683`):
```swift
case "assistant":
    guard let msg = raw["message"] as? [String: Any],
          let content = msg["content"] as? [[String: Any]] else { return }
    var finalStage = "Composing reply"
    var finalActivity: String? = nil
    for block in content {
        // append transcript entries as-is
        // ...
        if let name = block["name"] as? String, block["type"] as? String == "tool_use" {
            finalStage = "🔧 \(name)"
            finalActivity = "Working: \(name)"
        } else if block["type"] as? String == "thinking" {
            finalStage = "💭 Thinking…"
        }
    }
    self.advanceMiragePeekyDock(dockID: dockID, shim: shim, title: dockTitle,
        userInstruction: userPrompt, stageLabel: finalStage,
        activityLine: finalActivity, dockStatus: .running)
```
Severity: MEDIUM (UX polish, not correctness).

### S2. Cleanup Task cannot be cancelled if turn errors out early — LOW
`CompanionManager+AIResponsePipeline.swift:2628-2642`. `defer` schedules a
30-second detached Task that always fires `removeSKIModeDockItem` +
`removeSKIShimAgentSession`. No handle is kept; there is no way to cancel it
if the user starts a new turn using the same shim within 30s.

The dock item IS keyed by `dockID` (per-turn UUID), so the delete is scoped —
no cross-turn corruption. But if a future refactor ever reuses a shim across
turns, the deferred cleanup would silently delete the reused state.

Fix: store the Task handle on `CompanionManager` and cancel it on
`interruptCurrentVoiceResponse` / new-turn entry. Alternatively, guard the
cleanup body on `shim.status != .running` so an active reuse survives.
Severity: LOW (latent regression risk, not a live bug).

### S3. `advanceMiragePeekyDock` passing `""` for "keep buffer" is implicit — LOW
`CompanionManager+SKIShimBuilder.swift:49` passes `activityLine ?? ""` and
relies on `CodexAgentSession.updateSKIShimState`'s trim-and-drop to preserve
the buffer. Correct behaviour but couples the two files: any future change
that makes empty strings meaningful in `updateSKIShimState` silently breaks
this contract.

Fix: pass `activityLine` (already `String?`) straight through, and change
`updateSKIShimState`'s parameter to `String?` at call site — or add a code
comment on the parameter contract. Severity: LOW.

### S4. `MirageError.quotaExhausted` not surfaced as user-facing UX — LOW
`MirageBackendClient.swift:429`/`457` throws `.quotaExhausted(retryAfter:)`
inside `sendStreamingChunks`. The `analyzeMirageResponse` caller at
`CompanionManager+AIResponsePipeline.swift:2884` receives the throw and it
propagates to `speakResponseFailureFallback` → `userFacingResponseFailureMessage`,
which has no case for `MirageError` — falls through to
`"Something went wrong. Check the app log for the exact error."`
(`AIResponsePipeline.swift:1725`).

Meanwhile `MirageLocalRelay.dispatch` (`MirageLocalRelay.swift:250-263`)
DOES pattern-match `.quotaExhausted` and returns HTTP 429 with `retry-after`.
Two consumers, one drops the signal, one propagates it. Q8 concern about the
relay is fine (relay maps correctly). The voice pipeline's error UI is the
weak link.

Fix (`AIResponsePipeline.swift:1707` `userFacingResponseFailureMessage` switch):
```swift
if let mirage = error as? MirageError {
    switch mirage {
    case .quotaExhausted(let retry):
        let s = retry.map { " Retry in \(Int($0))s." } ?? ""
        return "Peeky Free quota exhausted.\(s)"
    case .notConfigured: return "Peeky Free is not configured on this build."
    case .upstreamStatus(let code, _): return "Peeky Free upstream returned HTTP \(code)."
    case .invalidResponse: return "Peeky Free returned an unexpected response."
    }
}
```
Severity: LOW (UX, not correctness).

### S5. Heartbeat + orchestrator race on `.processing`/`.responding` — LOW
`CompanionManager+AIResponsePipeline.swift:2602-2627` ticks the notch caption
every 1s and re-asserts `voiceState = targetPhase` whenever it drifts from the
expected phase. If the orchestrator finishes fast (< 1s) the heartbeat may
never run; if it runs after the reply has ended it can briefly flip
`voiceState` back to `.processing` after the pipeline set it to `.idle`.

The `defer { heartbeatTask.cancel() }` at line 2629 does cancel, but the
task's `while !Task.isCancelled` check races with an in-flight `await` on
`updateBackendStatusCaption`. Worst case: a single trailing caption
`"Replying Ns"` after the reply already landed. Not a bug per se, just a
race window worth documenting.

Fix: after `heartbeatTask.cancel()`, `await heartbeatTask.value` so we know
the last tick drained before the outer function returns. Severity: LOW.

---

## Fix Priority

| # | File:line | Sev | Effort |
|---|-----------|-----|--------|
| S1 | `CompanionManager+AIResponsePipeline.swift:2683-2730` | MEDIUM | small |
| S4 | `CompanionManager+AIResponsePipeline.swift:1707` | LOW | small |
| S2 | `CompanionManager+AIResponsePipeline.swift:2636-2641` | LOW | small |
| X1 | `AnthropicSSEStream.swift:63` | LOW | tiny |
| X2 | `AnthropicSSEStream.swift:24-66` | LOW | small |
| S5 | `CompanionManager+AIResponsePipeline.swift:2628-2629` | LOW | tiny |
| S3 | `CompanionManager+SKIShimBuilder.swift:49` | LOW | tiny |
| X3 | Chunker.swift + colorspace-aware preprocessor | INFO | medium |

**Bugs found, no correctness-critical.** S1 (dock flicker) is the highest
user-visible impact; S4 (quota UX) is the highest failure-mode impact. All
extractions preserve byte-level wire behaviour and pass their audit criteria.
