# 01 - LLMClient Cutover Bug Audit

Date: 2026-08-07
Scope: post-cutover state of `_analyzeVoiceResponseCore` -> `dispatchViaLLMRegistry` -> `LLMClientRegistry.client(for:hooks:).send(...)`.

Files audited:
- cursor-buddy/CompanionManager+AIResponsePipeline.swift (dispatch entry ~L857, `makeLLMDispatchHooks` L878-940, `dispatchViaLLMRegistry` L945-952, private `analyze*` L954-1105, `analyzeMirageResponse` L2543-2897)
- cursor-buddy/LLMClient.swift
- cursor-buddy/LLMClientAdapters.swift
- cursor-buddy/LLMClientRegistry.swift
- cursor-buddy/MirageBodyPipeline.swift
- cursor-buddy/MirageBackendClient.swift (L267-357)
- cursor-buddy/AppleFoundationModelsVoiceClient.swift (L29-35)
- cursor-buddy/HeyClickyChatToolCallClient.swift (L41-49)

---

## Confirmed Bugs

### C1. Stale post-cutover comments claim shadow-compare mode still exists (LOW)

File / line: `cursor-buddy/CompanionManager+AIResponsePipeline.swift:871-877, 942-944`
`cursor-buddy/LLMClientRegistry.swift:7-13`
`cursor-buddy/LLMClient.swift:11-13`

Evidence:
- L942-944: "Registry-based dispatch. Called by the shadow-compare path today ... eventually the whole switch once verified."
- L871-877 header for `makeLLMDispatchHooks` is correct ("old provider switch deleted"), but the block that follows (L942-944 above) contradicts it.

Reproduction: `grep -n "shadow-compare\|useNewDispatch\|enabledProviders" cursor-buddy/`. Zero live references — only comments. The switch is gone; comments imply it isn't.

Proposed fix (diff):
```diff
-    /// Registry-based dispatch. Called by the shadow-compare path today
-    /// and eventually the whole switch once verified. Isolated in one
-    /// method so tests / debug callers can invoke directly.
+    /// Registry-based dispatch. Every voice-response turn goes through here
+    /// after the switch was removed. Isolated in one method so tests / debug
+    /// callers can invoke it directly.
```

Severity LOW: no behavior impact; future reader misled.

---

## Suspected Bugs (need runtime verify)

### S1. `[weak self]` silently returns "" for 5 of 6 hooks — swallows error path (MEDIUM)

File / line: `cursor-buddy/CompanionManager+AIResponsePipeline.swift:888-889, 899-900, 909-910, 919-920, 931-932` (anthropic / openAI / codex / mirage / heyclicky).

```
anthropic: { [weak self] req, cb in
    guard let self else { return "" }
```

Old switch had no `weak self` guard — it was inline in an instance method. Under normal `await` propagation the enclosing frame retains a strong `self` for the lifetime of the suspended call, so `self` cannot become nil mid-turn in practice. The equivalence proof (`docs/peeky-review-2026-08-06/10-llmclient-equivalence.md` §"parity holds under weak self") explicitly accepts this as intentional.

Risk: if the manager were ever torn down (e.g. via a test/injection path or a future refactor that runs the pipeline off-actor), the caller receives an empty String rather than an error. Voice pipeline treats `""` as a valid empty reply (Apple-provider suppression contract), so the failure would silently produce a "no-response" turn instead of surfacing.

Reproduction: not reachable in current code paths; only reachable if `_analyzeVoiceResponseCore` gets called on a non-owning actor or `self` gets nulled by test infrastructure.

Proposed fix (diff) if paranoid safety is preferred:
```diff
-            anthropic: { [weak self] req, cb in
-                guard let self else { return "" }
+            anthropic: { [weak self] req, cb in
+                guard let self else { throw CancellationError() }
                 return try await self.analyzeClaudeResponse(
```
Apply to all 5 hooks. Severity MEDIUM (behavior-preserving today, silent-failure risk if invariants change).

### S2. `MirageBackendClient.shared` per-turn state (`pendingBodyBetas`, `pendingModelForBeta`) races on overlapping turns (MEDIUM — pre-existing, not cutover-introduced)

File / line: `cursor-buddy/MirageBackendClient.swift:286-288, 297-301, 345-352`.

`normalizeBody` sets `pendingBodyBetas` / `pendingModelForBeta`; `wireHeaders` reads and clears them. Both are instance properties on the shared singleton. Single-turn `send` -> `normalize` -> `wireHeaders` is sequential and safe. But if two turns run concurrently (Peeky Free + a background retry, or two dispatches in flight), turn B's `normalizeBody` overwrites the pending state before turn A's `wireHeaders` reads it, so turn A sends turn B's betas.

The LLMClient cutover doesn't cause this; `dispatchViaLLMRegistry` still serialises via the awaited instance method, so single-user voice flow is fine. Flagging so the reviewer knows the state is not race-safe if any future call site parallelises Peeky turns.

Proposed fix: thread the betas through a local return-tuple instead of instance state, or wrap the pair in an actor.

### S3. `analyzeMirageResponse` sets `cache_control: {ephemeral, ttl:"1h"}` on system, and `MirageBodyPipeline.apply` enters `cachePrepped=true`, which skips thinking mutators (LOW — verify against fable-5 with pinned effort)

File / line:
- Cache marker written: `CompanionManager+AIResponsePipeline.swift:2868-2874`
- cachePrepped gate: `MirageBodyPipeline.swift:89-98` (skips `disableThinkingIfToolChoiceForced`, `normalizeThinkingForAdaptiveModels`, `ensureThinkingDisplay`)
- 1h beta appended: `MirageBodyPipeline.swift:123-126` → returned as beta → `MirageBackendClient.swift:284-287, 350` → written to `anthropic-beta` wire header at `MirageBackendClient.swift:357` (correct, header not body).

Risk chain:
1. `MirageBackendClient.normalizeBody` runs `MirageThinkingSuffix.parse(effectiveModel).apply(...)` (L267-270) BEFORE `MirageBodyPipeline.apply` (L284). If the user pins `openClickyMirageDialogEffort=low..max` on an Opus-4.7 model, `MirageThinkingSuffix` injects `thinking.type=enabled` + `budget_tokens`.
2. Now `MirageBodyPipeline.apply` sees `cachePrepped=true` (because the system block has cache_control), so `normalizeThinkingForAdaptiveModels` is skipped (`MirageBodyPipeline.swift:96`). The body ships to aegis with `thinking.type=enabled` unadapted, and Opus 4.7 (adaptive-only) rejects it — comment at `MirageBodyPipeline.swift:174-176` says exactly this.
3. Same path also skips `ensureThinkingDisplay`, so `thinking.display` never defaults to `"summarized"` for the cache-prepped voice turn.

Reproduction: switch model to `claude-opus-4-7` variant, pin effort to `high` in Peeky settings, ask a voice question. Expect upstream 400 or empty thinking text. Default effort (`""` / `adaptive` / `dynamic`) does not trigger `MirageThinkingSuffix` so the default voice path is unaffected — that's why this is LOW / conditional.

Proposed fix (diff) — reorder or gate:
```diff
-        let cachePrepped = countCacheControls(body) > 0
-        if !cachePrepped {
-            disableThinkingIfToolChoiceForced(&body)
-            normalizeThinkingForAdaptiveModels(&body, model: model)
-            ensureThinkingDisplay(&body)
-        }
+        // These three touch `thinking.*` / `output_config.effort` — fields that
+        // sit OUTSIDE the cacheable prefix (system/tools/messages). Safe to run
+        // even in cache-prepped mode. Verified against docs/mirage-cache-issue.md
+        // (top-level metadata is not hashed).
+        disableThinkingIfToolChoiceForced(&body)
+        normalizeThinkingForAdaptiveModels(&body, model: model)
+        ensureThinkingDisplay(&body)
+        let cachePrepped = countCacheControls(body) > 0
```
Only apply after verifying that `thinking` sits outside the cache-hash scope (the TODO at `MirageBodyPipeline.swift:72-79` documents the same open question).

---

## False Alarms Cleared

### F1. Parameter drift — assistantPrefill and companionManager forward correctly

- Anthropic hook forwards `req.assistantPrefill` verbatim: `CompanionManager+AIResponsePipeline.swift:896`.
- HeyClicky hook passes `companionManager: self` (not nil): `CompanionManager+AIResponsePipeline.swift:932`.
- Apple/openAI/codex/mirage hooks correctly OMIT `assistantPrefill` from their forwarded arg lists (the private helpers don't accept it): `CompanionManager+AIResponsePipeline.swift:881-937`. Matches `LLMClient.swift:42-43` documented "non-supporting adapters must ignore silently."

### F2. Error propagation

Each hook is `async throws`, adapters are thin `try await hook(...)`, registry is `try await client.send(...)`, and pipeline site at `CompanionManager+AIResponsePipeline.swift:865-868` uses `try await dispatchViaLLMRegistry`. No `catch` in the dispatch chain. Adapter/registry never wrap or transform the thrown NSError, so pattern-matchers on `NSError.domain == "ClaudeAgentSDKAPI"` etc. still work.

### F3. Deepgram error domain

`LLMClientRegistry.swift:39-43` → `UnsupportedLLMAdapter` throws `NSError(domain: "DeepgramVoiceAgentClient", code: -20, message: ...)`. Matches the old switch per `docs/peeky-review-2026-08-06/10-llmclient-equivalence.md` §.deepgram line 82.

### F4. cachePrepped detection order — `stripContextManagement` first is safe

`MirageBodyPipeline.swift:80` runs `stripContextManagement` before `countCacheControls` at L89. But `stripContextManagement` (L217-219) only removes the top-level key `context_management`; `countCacheControls` (L257-273) scans `system` / `tools` / `messages` arrays for `cache_control` fields. No overlap, hash unaffected.

### F5. 1h beta lifts to wire header, not body

Chain verified: `MirageBodyPipeline.swift:123-126` returns beta string -> `MirageBackendClient.swift:284-287` stashes in `pendingBodyBetas` -> `MirageBackendClient.swift:350` merges into `betas` array -> L357 emits as `("anthropic-beta", dedup.joined(...))`. Body no longer carries `betas` (extracted at L117, removed by `extractAndRemoveBetas` L396-411).

### F6. Shadow flags dead code

`grep -rn "useNewDispatch\|shadowCompare\|enabledProviders" cursor-buddy/` returns 0 matches. Cleanup complete except for the stale comments in C1.

### F7. Race in dispatch (per-turn adapter allocation)

`dispatchViaLLMRegistry` at `CompanionManager+AIResponsePipeline.swift:945-952` calls `makeLLMDispatchHooks()` per invocation and constructs a fresh adapter via `LLMClientRegistry.client(for:hooks:)`. All adapters are `@MainActor final class`, hold only their `hook` closure, and are dropped when `send` returns. Every underlying provider (`ClaudeAPI`, `MirageBackendClient.shared`, `HeyClickyChatToolCallClient.shared`, etc.) is already a singleton — the adapter is just a call trampoline. No actor-boundary issue. Minor per-turn allocation, negligible.

### F8. Apple hook has no `[weak self]` — correct

`CompanionManager+AIResponsePipeline.swift:880-887`. `AppleFoundationModelsVoiceClient.analyzeVoiceResponse` is `static`, so no capture needed. Not a bug.

---

## Suggested Fix Priority

1. C1 — LOW, 30 seconds — update stale comments at `CompanionManager+AIResponsePipeline.swift:942-944` and `LLMClientRegistry.swift:7-13` so future readers stop looking for a shadow path that no longer exists.
2. S3 — LOW/conditional — before shipping any prompt-cache regression tests, verify that Opus-4.7 + pinned effort still normalises thinking correctly. Reorder `MirageBodyPipeline.swift:89-98` only after confirming `thinking.*` is outside the cache hash (the file's own TODO at L72-79 flags the same uncertainty).
3. S1 — MEDIUM/defensive — swap `guard let self else { return "" }` for `throw CancellationError()` in the 5 instance hooks so the "silent empty turn on torn-down manager" edge case surfaces as an error rather than a fake success.
4. S2 — MEDIUM/pre-existing (not caused by cutover) — thread `pendingBodyBetas` / `pendingModelForBeta` through the call return instead of instance state on the singleton, before any code path parallelises Peeky turns.

No HIGH-severity cutover bugs found. Adapters forward byte-identical arguments to the private helpers, matching the equivalence proof (`docs/peeky-review-2026-08-06/10-llmclient-equivalence.md`).
