# Parity Fix P1 — Router + Web Search Providers (2026-07-23)

Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809` (informational — OpenClicky-native implementation).

Fixes P1 gaps from parity audits:
- `docs/ROADMAP/.review-notes/parity-domain3-providers-memory-2026-07-23.md` (router MEDIUM)
- `docs/ROADMAP/.review-notes/parity-domain2-mcp-ecosystem-2026-07-23.md` (web search rows 25-29)
- `docs/ROADMAP/.review-notes/parity-domain4-ux-appearance-2026-07-23.md` (settings surface)

## Files created

### `cursor-buddy/OpenClickyRouterSettings.swift` (NEW, 88 lines)
`@MainActor` `ObservableObject` singleton backing three UserDefaults keys under `openclicky.router.*`:
- `routeTagEnabled: Bool` — default `true`. Gates whether `[ROUTE]` tag is honored.
- `confidenceGate: Double` — default `0.60`. Replaces hard-coded gate in dispatcher.
- `defaultCompletionMarker: String` — default `"LAST_COMPLETED: DONE"`. Fallback marker propagated to codex.

Exposes `effectiveDefaultCompletionMarker` that trims whitespace and refuses empty (returns hard-coded fallback).

### `cursor-buddy/OpenClickyWebSearchProvider.swift` (NEW, 96 lines)
- `OpenClickyWebSearchProviderConfig` — `Codable, Equatable, Identifiable` row: `id`, `name`, `endpoint`, `apiKey`, `enabled`.
- `OpenClickyWebSearchSettings` — `@MainActor` `ObservableObject` singleton. Persists `providers: [OpenClickyWebSearchProviderConfig]` as JSON under `openclicky.web.searchProviders`. Seeds three disabled rows on first run: Brave Search, Serper, Tavily. `activeProvider` returns first `enabled` row with non-empty endpoint (nil = not configured).

Storage is plaintext UserDefaults per user directive (Keychain skipped to avoid password prompts).

## Files modified

### `cursor-buddy/OpenClickyRouteDispatcher.swift`
Before (line 65): `if route.confidence < 0.6 {`
After (line 84): reads `let confidenceGate = OpenClickyRouterSettings.shared.confidenceGate` then `if route.confidence < confidenceGate`. Log gains a `"gate"` field.

Added new gate at top of `dispatch(_:userTranscript:preflight:)` (after the `openclicky.route_dispatch` log, before the `switch route.kind`): when `!OpenClickyRouterSettings.shared.routeTagEnabled`, log `openclicky.route_tag_disabled` and route entirely on `classifyFallback` output. This is the correct chokepoint since `HeyClickyChatToolCallClient` is out of scope for this pass; the model may still emit `[ROUTE]` but we ignore it.

Before (line 292): `completionMarker: route.effectiveCompletionMarker ?? "LAST_COMPLETED: DONE",`
After: `completionMarker: route.effectiveCompletionMarker ?? OpenClickyRouterSettings.shared.effectiveDefaultCompletionMarker,`

Untouched sites: `classifyFallback` internal `0.6` / `0.65` values inside `RouteParseResult(...confidence:)` — these are the fallback classifier's own emitted confidences (its return values), not the gate. Left as-is to preserve fallback semantics.

### `cursor-buddy/OpenClickyWebSearchClient.swift`
Before (lines 49-53): unconditional `throw SearchError.providerNotConfigured`.
After: `search(query:maxResults:)` reads `OpenClickyWebSearchSettings.shared.activeProvider` on the main actor. Nil → `providerNotConfigured` (unchanged behavior for unconfigured users). Non-nil → `providerAdapterNotImplemented(name:)` with an explicit TODO explaining that per-provider HTTP shapes (Brave `X-Subscription-Token` header, Serper `X-API-KEY`, Tavily `Authorization: Bearer`, differing request/response schemas) need concrete adapter code before `web_search` can return real hits. Users can distinguish the two error codes in logs.

New error case: `SearchError.providerAdapterNotImplemented(name: String)` → `search_provider_adapter_not_implemented:<name>`.

### `cursor-buddy/OpenClickySettingsWindowManager.swift`
1. Added two `@StateObject` bindings alongside `localInferenceRuntime` (~line 194):
   ```
   @StateObject private var routerSettings = OpenClickyRouterSettings.shared
   @StateObject private var webSearchSettings = OpenClickyWebSearchSettings.shared
   ```
2. Injected two new group calls in `connectionsPanel` (the "System & Logs" section that already hosts MCP servers), positioned between "MCP servers" and "Persistent memory":
   ```
   routerSettingsGroup
   webSearchProvidersSettingsGroup
   ```
3. Added `routerSettingsGroup` and `webSearchProvidersSettingsGroup` computed views immediately before the existing `settingsGroup<Content:>` helper. Router group has: Toggle for `routeTagEnabled` + Slider for `confidenceGate` (0.0-1.0 step 0.05) + TextField for `defaultCompletionMarker`. Web Search group has: `ForEach($webSearchSettings.providers)` rows (enable checkbox + name + endpoint + secure API key + delete button), "Add provider" button, live "Active: X" / "No enabled provider" indicator.

### `cursor-buddy.xcodeproj/project.pbxproj`
No changes required. The project uses `fileSystemSynchronizedGroups` for the `cursor-buddy` group (verified — 3 group entries in pbxproj). New files under `cursor-buddy/` are auto-picked up on next Xcode open/build.

## What was deferred (from the P2 skip list)

Per task constraints, not attempted this pass:
- Named-key registry (multi-account credential rotation) — too invasive to schema.
- Custom assistant/persona list — separate feature gap.
- Per-model capability tags — schema change touching `OpenClickyModelCatalog`.
- Language localization (12 locales) — appearance polish, not a blocker.
- Font-size slider / update channel / telemetry consent — polish.
- Universal hotkey rebind for every hotkey — huge scope; existing hotkey system is untouched.
- Keychain migration for API keys — user rejected (repeated password prompts).
- Concrete HTTP adapters for Brave / Serper / Tavily — surface only. See `providerAdapterNotImplemented`.

Also intentionally untouched: OpenDia / OpenCLI / Connector settings sections (concurrent P0 agent scope), AGENTS.md, capture/overlay/notch code.

## Verification

- `swiftc -parse cursor-buddy/OpenClickyRouterSettings.swift cursor-buddy/OpenClickyWebSearchProvider.swift cursor-buddy/OpenClickyWebSearchClient.swift` — clean.
- `swiftc -parse cursor-buddy/OpenClickyRouteDispatcher.swift cursor-buddy/OpenClickyRouterSettings.swift cursor-buddy/HeyClickyChatToolCallClient.swift` — clean.
- `swiftc -parse cursor-buddy/OpenClickySettingsWindowManager.swift` — clean.
- Grep: `OpenClickyRouterSettings.shared.confidenceGate` present in `OpenClickyRouteDispatcher.swift`.
- Grep: `activeProvider` referenced in `OpenClickyWebSearchClient.swift`.
- `xcodebuild` intentionally NOT run per CLAUDE.md rule 3. Full build must happen in Xcode.

## Test scenario (by inspection)

User opens OpenClicky Settings → **System & Logs**. Scrolls past "MCP servers" and sees:

1. **Router (voice intent classification)**
   - Toggle "Enable [ROUTE] tag parsing" (on by default).
   - Slider "Confidence gate" set to 0.60. User drags to 0.80.
   - Text field "Default completion marker" showing `LAST_COMPLETED: DONE`.

2. **Web search providers**
   - Three seeded rows (Brave / Serper / Tavily) all disabled with empty API keys.
   - "Add provider" button.
   - Status line: "No enabled provider — web_search returns not_configured."

**Confidence-gate walkthrough:** user sets slider to 0.80. Persisted to `UserDefaults` under `openclicky.router.confidenceGate` via the `didSet`. Next voice utterance whose Fable-emitted `[ROUTE]` has confidence 0.70:
- `RouteDispatcher.dispatch` logs `openclicky.route_dispatch`.
- `routeTagEnabled` is true, so proceeds past the tag-disabled early-return.
- Enters `case "short_task"` branch, reads `let confidenceGate = OpenClickyRouterSettings.shared.confidenceGate` = 0.80.
- `0.70 < 0.80` — logs `openclicky.route_confidence_guard` with `"gate":"0.80"`, spawns `classifyFallback`.
- Fallback classifier consults `WorkdirProbe` + `ProjectRegistry` on the preflight/transcript. If either matches strongly, spawns codex with the fallback route; otherwise no-op (safe default `chat`).

**Tag-disabled walkthrough:** user unchecks "Enable [ROUTE] tag parsing". Same utterance:
- `RouteDispatcher.dispatch` logs `openclicky.route_dispatch` then immediately logs `openclicky.route_tag_disabled` with `"action":"ignored_running_fallback_classifier"`.
- Skips all `switch route.kind` branches, spawns `classifyFallback`, uses that result.

**Web-search walkthrough:** user pastes a Brave API key, checks the Enabled box on the Brave row. `activeProvider` returns non-nil. Next `web_search` MCP call:
- Reads `OpenClickyWebSearchSettings.shared.activeProvider` (main-actor hop inside `search`).
- Returns `SearchError.providerAdapterNotImplemented(name: "Brave Search")` — surfaced to the agent as `search_provider_adapter_not_implemented:Brave Search`.
- Distinct from the pre-configure state (`search_provider_not_configured`), so agents/log-readers can tell whether the user needs to configure something or whether the adapter is the blocker.
