# Per-profile Overrides + Panel UI Audit
Date: 2026-08-07
Scope: profile override storage, applyProfile ordering, panel wiring.

## Overrides Correct

- **`applyOverrides` covers all 6 fields** (`OpenClickyProfile.swift:283-303`): stt, tts, responseModel, agentModel, ttsVoice, activationMode all handled. Nothing missed.
- **`agentModelStorageKey` routing** (`OpenClickyProfile.swift:218`): mirage -> `openClickyMirageAgentModel`; others -> `clickyCodexModel`. Both `applyProfile` (Profiles.swift:102-104) and `setAgentModelPreservingOverride` (Profiles.swift:151-156) use the same helper. Consistent.
- **STT preserving setter warms provider**: `setVoiceTranscriptionProviderPreservingOverride` -> `setVoiceTranscriptionProvider` (Profiles.swift:130) -> the raw setter at `CompanionManager.swift:2612-2623` DOES call `MirageDeepgramClient.shared.warm()` for mirageDeepgram. Correct.
- **Override reapply on profile switch back**: `applyProfile` reads `resolvedOverrides(for: profile.id)` at line 84 and merges via `??` before firing setters. Switch heyclickyFree -> peekyFree -> heyclickyFree does restore the recorded agent-model override. Trace confirmed.
- **Profile IDs are stable string constants** across the codebase (`"heyclicky_free"`, `"ski_mode"`, `"mirage"`). No id migration path exists (see Override Bugs #1 for the risk if this ever changes).
- **ChatHeaderBar.selectModel dual write** (`ChatHeaderBar.swift:192-205`): agent-model recorded for every model; response-model (`setSelectedModelPreservingOverride`) only recorded for `.apple` / `.anthropic`. This is correct — codex/openAI/heyclickyFree/mirage response-model selection routes through a different UI (the bubble/notch backend selector + panel model group), not the header.

## Override Bugs

### 1. `applyProfile` fires setters BEFORE overrides are written to UserDefaults on activation (HIGH)
`CompanionManager+Profiles.swift:33` writes `activeProfileDefaultsKey` first, then at line 84 reads `resolvedOverrides(for: profile.id)` and calls in-memory setters (86-96). The overrides ARE overlaid because `applyProfile` reads them via the resolver and merges with `??`. However, `OpenClickyProfileCatalog.apply` (the pure-UserDefaults writer) is NOT called by `applyProfile` — only `resetActiveProfileToDefaults` calls it. That means on profile switch, `UserDefaults` keys like `userTTSProviderDefaultsKey` are written twice: once by `setTTSProvider(...)` inside its `DispatchQueue.main.async` block (CompanionManager.swift:1084-1088), and once … actually, they are only written by the setter. Fine. But note: `setTTSProvider` defers via `DispatchQueue.main.async`, so between `applyProfile` returning and the runloop tick, `selectedTTSProvider` still reflects the OLD profile. Any code that reads `selectedTTSProvider` synchronously in the same turn as `applyProfile(...)` sees stale value. Fix: emit an explicit synchronous invalidation, or move the async guard into the picker call sites only.
- File: `cursor-buddy/CompanionManager.swift:1084-1088`
- Fix: split public `setTTSProvider` into `setTTSProviderSync` (used by `applyProfile`) and the deferred picker variant, OR pre-write the UserDefaults key synchronously before the async block.

### 2. Profile ID renames would orphan all overrides (MEDIUM, latent)
`overridesDefaultsKey = "openClickyProfileOverrides"` is one root dict keyed by profile id string. If `"mirage"` is ever renamed to `"peekyFree"` (product-name migration), every existing override becomes an orphan entry under the old key with no migration hook.
- File: `cursor-buddy/OpenClickyProfile.swift:224`
- Fix: add a versioned migration on first read (`overridesVersion` sidecar key), or freeze id strings with a code comment explicitly forbidding rename.

### 3. `resolvedOverrides` treats empty string `""` as a valid override (MEDIUM)
`ResolvedOverrides` fields are `String?`. Callers use `overrides.stt ?? profile.sttProvider`. If a picker ever writes `""` (e.g. user clears a text field bound to `setVoiceTranscriptionProviderPreservingOverride`), the `??` succeeds with `""` and the downstream setter receives an invalid id.
- File: `cursor-buddy/OpenClickyProfile.swift:260-280`
- Fix: in `resolvedOverrides`, treat empty/whitespace strings as nil: `o[key].flatMap { $0.isEmpty ? nil : $0 }`.

### 4. `resetActiveProfileToDefaults` double-applies (LOW)
`Profiles.swift:166-171` calls `OpenClickyProfileCatalog.apply(profile, applyDefaults: true)` (pure UserDefaults write) THEN `applyProfile(profile)` (live setters). Since overrides were just cleared, the second call re-reads empty overrides and re-fires every setter — harmless but wasteful, plus it triggers `DispatchQueue.main.async` in `setTTSProvider` again.
- Fix: skip the pure-defaults call; `applyProfile` alone reaches a coherent state.

### 5. `setSelectedModelPreservingOverride` records for all models but panel only shows a subset (LOW)
The Peeky panel `modelGroup` binding (`PeekyFreePanelView.swift:159-161`) sets `setSelectedModelPreservingOverride($0)` for every model — including advanced/non-mirage — with the picker declaring `selectedModel` as its `get`. Fine. But `HeyClickyFreePanelView.swift:180` does the same. Result: picking a mirage/… model on the HeyClicky panel records `responseModel = "mirage/..."` under `heyclicky_free`; next switch back to HeyClicky, `applyProfile` re-installs it and users get a mirage response model on the HeyClicky profile. This may be intended ("advanced overrides"), but the copy at Peeky:186-189 confirms this design; HeyClicky panel has no equivalent warning. Verify with product.

## UI Bugs

### 6. `oneMillionContextDisabled` @State drift across panel re-mount (MEDIUM)
`PeekyFreePanelView.swift:601-602` initialises the toggle from `UserDefaults.bool(forKey:)` — returns `false` when key absent = default ON, which matches intent. But `@State` snapshot is a one-shot read at first render. If the user toggles this from a different code path (external control bridge, migration) after the panel is instantiated, the toggle still reads the stale local `@State`, not UserDefaults. The default-ON intent is correct; the drift is the bug.
- File: `cursor-buddy/PeekyFreePanelView.swift:601-611`
- Fix: use `@AppStorage("openClickyMirage1MContextDisabled") private var …: Bool = false` and invert in the binding, dropping the `@State` mirror.

### 7. SKI STT picker reads UserDefaults directly (LOW consistency)
`OpenClickySettingsWindowManager.swift:4040-4048` (SKI panel) reads `UserDefaults.string(...)` in the get, while HeyClicky panel reads `AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey` (same key). SKI panel bypasses any potential future migration wrapper. Cosmetic today, breaks if the key path is ever centralised.

### 8. SKI agent-model picker: default fallback wrong when SKI has an `agentModelID` (LOW)
`OpenClickySettingsWindowManager.swift:4067-4072` fallback is `OpenClickyModelCatalog.defaultCodexActionsModelID`. SKI profile currently has `agentModelID: nil` (OpenClickyProfile.swift line 116 area — nil), so fallback is fine. But if a future SKI default sets `agentModelID`, the picker's `get` won't see it (it only reads `clickyCodexModel` UserDefaults, which `applyProfile` only writes when `profile.agentModelID != nil`). Fine now; brittle if SKI ever gets a preset agent model.

### 9. `bindCartesiaTokenProviderForCurrentProvider` boot ordering (LOW, currently safe)
Called at CompanionManager init line 2848. `selectedTTSProvider` is `@Published var` initialised from UserDefaults at line 951 (property initializer, runs before init body). So the boot call fires AFTER `selectedTTSProvider` is loaded. Safe today. Comment claim at line 979 holds.

### 10. Device UUID file has no permission tightening (LOW)
`MirageBackendClient.swift:104-118`: writes to `~/Library/Application Support/openclicky/mirage_device_id` with default 644 perms. Contains the anonymous rotating UUID seed — mild PII (trial-quota identifier). Load failure falls back to generating a fresh UUID (safe). Write failure is silently ignored via `try?` — if write fails, every app launch regenerates the UUID, wasting the daily quota bucket faster. No crash risk.
- File: `cursor-buddy/MirageBackendClient.swift:113-116`
- Fix (optional): chmod 0600 after write; log write failures at debug.

### 11. In-memory rotation does NOT rewrite the on-disk file (BY DESIGN, verify)
`nextDeviceID()` at line 160-167 mutates `deviceID` in-memory without touching disk. `forceRotate()` at 173-176 same. Persistence file only holds the initial seed. On restart, quota counter resets to zero. This matches the doc-comment on line 84-88 ("seed loaded from disk … in-memory rotation still bumps this off disk"). Intentional. No fix.

## Fix Priority

1. **HIGH — Fix #1**: split synchronous vs deferred `setTTSProvider` so `applyProfile` produces a coherent state within one runloop tick. Otherwise, any code observing `selectedTTSProvider` immediately after a profile switch (e.g. logging, warm-up decisions) sees the previous profile's provider.
2. **MEDIUM — Fix #3**: empty-string guard in `resolvedOverrides`. Cheap defensive fix; prevents downstream setters receiving `""`.
3. **MEDIUM — Fix #6**: swap `@State` for `@AppStorage` on the 1M-context toggle.
4. **MEDIUM — Fix #2**: pin/document profile id strings, add versioned migration hook if renames are ever considered.
5. **LOW — Fixes #4, #5, #7, #8, #10**: cleanup/consistency, not user-visible today.
