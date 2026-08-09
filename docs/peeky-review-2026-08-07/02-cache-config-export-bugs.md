# Peeky Free Mirage Prompt-Cache + Config Export Audit
Date: 2026-08-07
Scope: MirageBodyPipeline, MirageBackendClient, MirageLocalRelay,
ClaudeAgentRunner, PeekyFreePanelView, CompanionManager+AIResponsePipeline.

Reference: `/Users/wowdd1/Dev/CLIProxyAPIPlus/docs/mirage-cache-issue.md`
(any body mutation before a `cache_control` block shifts the Anthropic
cache-prefix hash and yields 100 percent miss).

---

## Cache Path Correct

### 1. Body-mutation inventory in `MirageBodyPipeline.apply`
`/Users/wowdd1/Dev/openclicky/cursor-buddy/MirageBodyPipeline.swift:53-128`

| Function | Runs when cachePrepped? | Cache-safety justification |
|---|---|---|
| `stripContextManagement` (L80/L217) | ALWAYS | Top-level key removal only. Never appears inside `system[*]`, `tools[*]`, or `messages[*].content[*]` — the three arrays Anthropic hashes for cache lookup. Confirmed empirically in CPA `mirage-cache-issue.md`. |
| `normalizeSampling` (L87/L196) | ALWAYS | Removes only top-level `temperature`/`top_p`/`top_k`. Same tier as `context_management`. |
| `disableThinkingIfToolChoiceForced` (L95) | ONLY !cachePrepped | Skipped when caller opted into cache (would touch top-level `thinking` and `output_config` — top-level, but the pipeline still skips defensively). |
| `normalizeThinkingForAdaptiveModels` (L96) | ONLY !cachePrepped | Rewrites `thinking.type` / `budget_tokens`. Skipped in cache mode. |
| `ensureThinkingDisplay` (L97) | ONLY !cachePrepped | Adds `thinking.display`. Skipped in cache mode. |
| `enforceCacheControlLimit` (L115) | ONLY !cachePrepped | Cache-prepped path only logs (L110-113), never trims. Correct. |
| `injectToolsCacheControl` / `injectSystemCacheControl` / `injectMessagesCacheControl` | NEVER (dead) | Only called from `ensureCacheControl` (L249), which has ZERO callers project-wide (`grep -rn ensureCacheControl` returns just the definition). |
| `extractAndRemoveBetas` (L117/L396) | ALWAYS | Removes top-level `betas` field which Claude Code CLI does not emit at all — this is a CPA convention. Even if present, it is a top-level sibling of `system`/`tools`/`messages`, outside the hash prefix. |
| `bodyRequestsExtendedCacheTTL` (L123/L134) | ALWAYS (read-only scan) | Non-mutating. |

**Verdict: cache-prefix hash is preserved in cache-prepped mode.**

### 4. `ensureCacheControl` dead — CONFIRMED
`MirageBodyPipeline.swift:249`. Zero callers. Safe to delete alongside the
three `inject*CacheControl` helpers (or keep as dead code with a `//
UNUSED` marker) — but critically they cannot silently fire in the mirage
codepath.

### 5. 1h beta dedup — CORRECT
`MirageBodyPipeline.swift:123-126` guards `!betas.contains("extended-cache-ttl-2025-04-11")`
before appending. `MirageBackendClient.wireHeaders` (L354-355) then runs
another `Set`-insert dedup across all sources. Double-safe.

### 8. `resolveEffectiveModelID` — all three properties hold
`ClaudeAgentRunner.swift:284-312`.
- Idempotent: `!bareModel.contains("[1m]")` guard at L306.
- `mirage/` prefix: extracted at L290-293, re-attached at L311.
- Env vars get BARE (no `[1m]`): `buildClaudeSettingsDict` L375-380
  strips the suffix via `range(of: "[1m]")` before writing to
  `ANTHROPIC_DEFAULT_*_MODEL`, preserving the `mirage/` prefix.

### 9. `MirageLocalRelay.shared` lifecycle — SAFE
`MirageLocalRelay.swift:52,67`. Singleton `actor` serializes all calls.
Two simultaneous button presses -> both hit `startIfNeeded`. First
awaiter binds listener + sets `port`; second sees `runningBaseURL != nil`
at L68 and returns immediately. No double-bind possible.

### 10. `retryAfterSeconds` nonisolated statics — COMPILES
`MirageBackendClient.swift:511,518`. `static func` on an `actor` is
non-isolated by construction in Swift 6; the explicit `nonisolated`
keyword is redundant but valid. No `nonisolated(unsafe)` needed —
neither reads mutable actor state.

---

## Cache Path Bugs

### 6. Voice API systemPrompt is NOT bit-identical across turns — HIGH
`CompanionManager+AIResponsePipeline.swift:2868-2874` wraps
`systemPrompt` with `cache_control: {type: ephemeral, ttl: "1h"}`.
That contract requires the wrapped `text` field to be byte-stable
across turns. In practice `systemPrompt` is assembled from several
per-turn-mutable sources:

- `currentVoiceResponseSystemPrompt` (`CompanionManager.swift:18586`)
  concatenates:
  - `inlineWebSearchCapabilityPromptIfAvailable()` — depends on
    `selectedModel.provider == .anthropic && claudeAgentSDKAPI != nil`.
    Flips when the user changes provider mid-session.
  - `currentAppSkillContextPrompt()` — depends on
    `OpenClickyAppSkillContext.contextForFrontmostApplication()`. Every
    focused-app change rewrites this block.
  - `visualGuidanceCalibrationPromptSummary` — includes live sample
    counts + offsets per screen. Grows whenever the user calibrates.
  - `runtimeStorageContextForVoicePrompt` — stable (path strings).
  - `codexHomeManager.persistentMemoryContext()` — reflects the current
    memory file; changes on every memory write.
- `AssistAgentBridge.effectiveSystemPrompt` (L691) prepends the
  assist-agent block when enabled; flips on/off via
  `AppBundleConfiguration.assistAgentEnabled()`.
- `currentTutorModeSystemPrompt` (L19022) suffixes app-skill context,
  same volatility.

Result: the cache_control wrapper *shape* is right but the hash will
miss whenever the user changes app focus, calibrates, saves memory, or
toggles assist-agent. Cache hits will occur only for tight-window
repeat turns with no other state changes.

**Fix (in priority order):**
1. Split the system prompt at build time into a `stable_prefix` (identity,
   tool contract, style guide) and a `dynamic_suffix` (frontmost app,
   memory, calibration). Send as two blocks; put `cache_control` on the
   stable prefix only:
   ```swift
   let systemBlocks: [[String: Any]] = [
       ["type": "text", "text": stablePrefix,
        "cache_control": ["type": "ephemeral", "ttl": "1h"]],
       ["type": "text", "text": dynamicSuffix]  // no cache_control
   ]
   ```
   The Anthropic hash prefix stops at the last cache_control block, so
   the volatile tail no longer invalidates the prefix.
2. Add a debug `NSLog` of `sha256(stablePrefix)` per turn so drift is
   immediately visible.
3. File-level location for the split: hoist the stable half into a
   `Self.mirageVoiceStableSystemPrompt` static and drop the dynamic bits
   into the trailing block that already exists as `contextBrief`
   (L2568) — that block is already understood to be per-turn.

### 2. `stripContextManagement` unconditional — LOW (documented)
`MirageBodyPipeline.swift:80`. Runs before the cachePrepped check.
Comment L72-79 acknowledges the empirical (not documented) guarantee.
Verify empirically by:
```swift
// A/B: send request with context_management stripped vs. left in,
// diff `usage.cache_read_input_tokens` on turn 2.
```
Or move inside `!cachePrepped` and rely on aegis-proxy to strip
upstream (comment says aegis already handles it). Low urgency — behavior
is correct today, only the risk model is soft.

### 3. `enforceCacheControlLimit` cache-prepped guard — CORRECT
`MirageBodyPipeline.swift:109-116`. Cache-prepped branch only NSLogs.
No silent trim path. Confirmed no `inject*CacheControl` firing (see #4).

---

## Config Export Bugs

### 7a. `settings["env"]` type-cast lossy — MEDIUM
`ClaudeAgentRunner.swift:381`:
```swift
var env = (settings["env"] as? [String: String]) ?? [:]
```
Anthropic settings env values are conventionally strings, but a user
who wrote e.g. `"PORT": 5432` (JSON number) will have their entire env
dict silently discarded on the fallback. Then the OpenClicky writes
replace it wholesale. All user env keys lost from the exported settings.

**Fix:**
```swift
var env: [String: String] = [:]
if let raw = settings["env"] as? [String: Any] {
    for (k, v) in raw {
        env[k] = String(describing: v is String ? (v as! String) : v)
    }
}
```

### 7b. Model + effortLevel overwrite behavior — CORRECT
`ClaudeAgentRunner.swift:348-349`. Unconditional overwrite of both keys.
If template has `"model": "opus"` or `"effortLevel": "low"`, they get
replaced with OpenClicky's routed values. Documented in prose comment
L345-347.

### 7c. Unreadable templateURL — ROBUST
L337-343: `try?` on both `Data(contentsOf:)` and `JSONSerialization`.
Returns `[:]` on any failure. No crash path. Good.

### 7d. `env["ANTHROPIC_AUTH_TOKEN"] = "sk-mirage-relay-dummy"` — MEDIUM
L383 unconditionally overrides the user's real Anthropic key. Users
who paste the exported config into `~/.claude/settings.json` will lose
their existing Claude CLI auth for non-mirage traffic. When the relay
is stopped or the user reverts `ANTHROPIC_BASE_URL`, the dummy token
remains and their CLI is now broken.

**Fix:** print a copy-paste header warning in the UI, or emit the
override as a `# NOTE:` comment in shell exports and a distinguishable
placeholder in the JSON.

### 7e. `CLAUDE_CODE_ATTRIBUTION_HEADER=false` unconditional — LOW
L388. User preference override; harmless but worth surfacing.

---

## Fix Priority

1. **HIGH — Voice API cache_control split (#6).** Right now the wrapper
   is placed on a moving target. Two-block system with cache_control on
   the stable prefix only. `CompanionManager+AIResponsePipeline.swift:2868`.
2. **MEDIUM — env dict type-cast (#7a).** Silent user-config loss.
   `ClaudeAgentRunner.swift:381`.
3. **MEDIUM — dummy AUTH_TOKEN warning (#7d).** User-visible breakage
   after they revert `ANTHROPIC_BASE_URL`. `ClaudeAgentRunner.swift:383`.
4. **LOW — empirical verification of `stripContextManagement` (#2).**
   Add A/B log + comment update. `MirageBodyPipeline.swift:80`.
5. **LOW — delete `ensureCacheControl` + three injectors (#4).** Dead
   code; deletion removes any future regression risk.
   `MirageBodyPipeline.swift:249-388`.
