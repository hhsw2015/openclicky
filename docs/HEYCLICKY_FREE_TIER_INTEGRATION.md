# HeyClicky Free Tier Integration (implementation spec, v4)

**Nature**: Feature spec for the OpenClicky fork. Adds `.heyclickyFree`
as a new provider on 4 lanes (STT / voice-response / TTS / Codex
agent), plus a quota-fallback router.

**Design principle**: **Extend openclicky, do not duplicate.** Every
integration point routes through existing openclicky primitives.
Net-new: 9 files + edits to 8 existing files.

**v4 vs v3**: v3 was too aggressive — dropped features that made the
demo unusable (no voice, no guided-click, agent lane 426s). v4
restores the necessary subset: proxy STT endpoint, agent lease flow,
guided-click follow-up, and free-tier realtime WS.

**AGENTS.md line 46 exemption**: This fork intentionally relaxes the
"no Google login or hosted key sync" rule for `.heyclickyFree` only.
OAuth is scoped to that provider's lifecycle; dormant otherwise.

**Reference sources**:
- Deep openclicky atlas: `docs/HEYCLICKY_INTEGRATION_ATLAS.md`
- Demo code: `/Users/wowdd1/Dev/clicky-mac/leanring-buddy/AgentBackend/`

---

## 1. Files

### 1.1 New files (9)

| # | File | Role | Concurrency |
|---|---|---|---|
| 1 | `HeyClickyProxyClient.swift` | HTTP base + 401 refresh-retry | `nonisolated final class @unchecked Sendable` + private `stateQueue` |
| 2 | `HeyClickyHeaderBuilder.swift` | `x-clicky-*` 6-header builder; JWT-sub decode | `nonisolated final class @unchecked Sendable` |
| 3 | `HeyClickySessionAuthenticator.swift` | Single-flight `/auth/refresh` + `HeyClickyOAuthHandler` (nested struct) | Same |
| 4 | `HeyClickySessionTokenClient.swift` | In-memory cached ephemeral mints (§7) | Same |
| 5 | `HeyClickyChatToolCallClient.swift` | `POST /chat-tool-call`; internal `HigherModelResponse` decode + sixth-arm bridge | `@MainActor` entry; internal dispatch |
| 6 | `HeyClickyProxyTranscriptionProvider.swift` | Conforms to `BuddyTranscriptionProvider`; wraps OpenAI Whisper POST against proxy `/audio/transcriptions` | `nonisolated final class @unchecked Sendable` (matches `OpenAIAudioTranscriptionProvider`) |
| 7 | `HeyClickyTurnLeaseClient.swift` + `HeyClickyTurnLeaseHeartbeat.swift` | Codex-agent lease acquire/heartbeat/complete | Client: `nonisolated`; heartbeat: `@MainActor final class` |
| 8 | `HeyClickyGuidedClickManager.swift` | `[TARGET:x,y,r:label]` overlay + CGEvent click-tap + `guided_click_follow_up` injection back to WS | `@MainActor final class` |
| 9 | `HeyClickyQuotaFallbackRouter.swift` | On 402/429/401, fall back to user-configured BYOK lane OR surface error | `@MainActor final class` |

Realtime WS integration (§5.3) modifies existing
`OpenAIRealtimeSpeechClient` rather than adding a new file — the class
gets a `realtimeBaseURL` property + ephemeral-refresh hook, and
free-tier callers pass proxy-minted tokens through the existing
transport.

### 1.2 Modifications to existing files

| File | Change |
|---|---|
| `OpenClickyModelCatalog.swift` | Add `.heyclickyFree` case to `OpenClickyModelProvider` enum at `:3-8`; `displayName` at `:10-23`; `voiceBackendFamily` at `:27-40`; model entry in `voiceResponseModels` at `:121-133`; model entry in `codexActionsModels` at `:161-168` |
| `CompanionManager+AIResponsePipeline.swift` | Add 6th arm `case .heyclickyFree:` in `analyzeVoiceResponse` switch at `:361-424` |
| `CompanionManager.swift` | Add `case "heyclicky-auth-callback":` in `handleWidgetDeepLink(_:)` at `:2076-2098`; 4 sibling switch sites at `:1822-1835`, `:2284-2321`, `:4243-4308`, `:1864-1887` |
| `BuddyTranscriptionProvider.swift` | Add `.heyclickyFree` case to enum at `:11-18`; label/subtitle at `:21-52`; resolver branch in `resolveProviderSelection` at `:131-258`; gate in `providerIDsForSelectionGrid()` at `:113-122` |
| `AppBundleConfiguration.swift` | 15 new `heyClicky*()` accessors (§6); 2 new entries in `keychainBackedDefaultsKeys` at `:387-395` |
| `MenuBarPanelManager.swift` | Add 2 new `Notification.Name` to existing extension at `:19-24` |
| `OpenClickyProfile.swift` | Add `heyclickyFree` profile to `OpenClickyProfileCatalog` at `:39-80`; `all` list at `:82` |
| `OpenAIRealtimeSpeechClient.swift` | Extend `updateConfiguration(...)` at `:118-124` with `realtimeBaseURL`, `serverInstructions`, `onEphemeralRefreshNeeded` params; thread `realtimeBaseURL` through 4 WS URL sites at `:276, :468, :625, :768`. Add public `bargeIn()` method firing §5.2 sequence. Add `pendingFollowUp: String?` observed on `session.created` (§8) |
| `OverlayWindow.swift` | Bump `animateBezierFlightArc(to:onComplete:)` at `:1415` from `private` to `internal`, OR add public wrapper `flyTo(_:onComplete:)` on `OverlayWindow` that internally calls it. Chosen: **add wrapper** (less risk to internal callers) |
| `OpenClickySettingsWindowManager.swift` | Add "HeyClicky Free" section at end of Advanced Providers with fields: proxy base URL, OAuth authorize URL, "Sign in with Google" button, sign-out button. Uses existing Settings row style |
| `cursor-buddyApp.swift` | On boot, after `companionManager.start()` at `:125`, register `HeyClickyQuotaFallbackRouter.shared.install()` |
| `chrome-ext/background.js` | Bump port range from `3001` → `3011-3021`; walk range on `/health` failure; cache last-working port in `chrome.storage.local` |

### 1.3 Chrome extension + scripts (already at repo root)

- `chrome-ext/` — MV3, port update per above
- `scripts/create-dev-cert.sh`, `scripts/sign-and-install.sh` — TCC preservation

---

## 2. Reuse map (openclicky primitives, VERIFIED via atlas + R1 audit)

The route-of-first-resort for every integration concern:

| Concern | openclicky primitive | file:line | Our action |
|---|---|---|---|
| Provider dispatch (voice) | `analyzeVoiceResponse` 5-arm switch | `+AIResponsePipeline.swift:361-424` | Add 6th arm |
| Provider enum | `OpenClickyModelProvider` (5 cases) | `OpenClickyModelCatalog.swift:3-8` | Add `.heyclickyFree` |
| Conversation history | `voiceConversationHistoryForAPI()` | `CompanionManager.swift:1200-1219` | Pass through |
| History compaction (naive char) | `compactVoiceConversationHistoryIfNeeded` | `CompanionManager.swift:1259-1299` | Reuse verbatim (do NOT invent LLM summarization) |
| POINT tag parsing | `parsePointingCoordinates(from:)` | `CompanionManager+PointTagParsing.swift:70-193` (extension `:21-193`) | Emit `[POINT:x,y:label:screenN]`; downstream handles |
| Trailing-tag fragment strip | `stripTrailingVisualGuidanceTagFragment` | `CompanionManager+PointTagParsing.swift:44-56` | Reuse |
| Cursor flight animation | `OverlayWindow.animateBezierFlightArc(to:onComplete:)` (currently `private`) | `OverlayWindow.swift:1415-1418` | **Modify openclicky**: add public wrapper `flyTo(_:onComplete:)` at same file |
| Multi-monitor overlay | `OverlayWindowManager` (one `OverlayWindow` per `NSScreen`) | `OverlayWindow.swift:3108-3234` | Emit `screenN` in POINT tags |
| Screenshot capture | `CompanionScreenCapture.screenshotWidthInPixels/Height` | `CompanionScreenCaptureUtility.swift:24-25` | Read directly |
| Image-dimension label | Inline string concat | `+AIResponsePipeline.swift:130-132` | Reuse pattern inside `HeyClickyChatToolCallClient` |
| Text injection at cursor | `typeTextUsingSelectedComputerUse(_:)` (`private`; takes `OpenClickyNativeTypeRequest`) | `CompanionManager.swift:7555` | **Modify openclicky**: expose via `internal func typeTextForHeyClickyFree(_ text: String)` wrapper on `CompanionManager` that constructs the request struct |
| Clipboard write | `NSPasteboard.general` | `CompanionManager.swift:15379` | Standard write |
| STT protocol | `BuddyTranscriptionProvider` | `BuddyTranscriptionProvider.swift:63-80` | Implement in `HeyClickyProxyTranscriptionProvider` |
| STT REST reference | `OpenAIAudioTranscriptionProvider` (Whisper POST) | `OpenAIAudioTranscriptionProvider.swift` | Reuse shape; swap endpoint + auth |
| TTS protocol | `OpenClickyTTSClient` | `ElevenLabsTTSClient.swift:1228-1254` | Not needed for `.heyclickyFree` (uses Realtime WS shared with STT); users can also pick keyless `.microsoftEdge` |
| Realtime WS transport | `OpenAIRealtimeSpeechClient` (4 hardcoded WS URLs at `:276, :468, :625, :768`) | `OpenAIRealtimeSpeechClient.swift:104-1400+` | Modify: add `realtimeBaseURL` + ephemeral refresh (§5.3) |
| Realtime tool schema | `realtimeRoutingTools` (3 tools at `:53-102`) | `OpenAIRealtimeSpeechClient.swift:53-102` | Reuse verbatim |
| Codex spawn ceremony | `CodexAgentSession.ensureThread` at `:838-957` | `CodexAgentSession.swift:838` (NOT `:840`) | Interpolate free-tier hooks (§5.4) |
| Codex config.toml provider selection | `ClickyCodexBackend.configuredWorkerBaseURL()` reads env `CLICKY_AGENT_BASE_URL` FIRST (`:230`), then UserDefaults `clickyAgentBaseURL` (`:236`) | `ClickyCodexConfigTemplate.swift:222-283` | Write UserDefaults; env-var priority is user-owned |
| Codex env / OPENAI_API_KEY | `CodexProcessManager.baseEnvironment` at `:99-110`; key read at `:53-58` | `CodexProcessManager.swift` | Route ephemeral through `AppBundleConfiguration.persistSecret(..., defaultsKey: userCodexAgentAPIKeyDefaultsKey)` |
| Circle-select (user gesture) | `CircleSelectSession` | `CircleSelectSession.swift:106-666` | Do NOT touch — user-initiated, distinct from AI-driven guided click |
| Keychain secrets | `AppBundleConfiguration.persistSecret/userDefaultsValue` + `keychainBackedDefaultsKeys` | `AppBundleConfiguration.swift:317-395` | Add heyClicky access/refresh token keys |
| Auth callback | `openclicky://` URL scheme handler `handleWidgetDeepLink(_:)` (host switch: `agents/agent/settings/logs/memory/visual/camera/meeting`) | `CompanionManager.swift:2076-2098` | Add `case "heyclicky-auth-callback":` |
| Log store | `OpenClickyMessageLogStore.shared.append(lane:direction:event:fields:)` | `OpenClickyMessageLogStore.swift:168-238` | Reuse existing lanes (`voice`, `agent`, `system`); provider marked via field |
| Notifications | Extension at `MenuBarPanelManager.swift:19-24` (4 names) | `MenuBarPanelManager.swift:19-24` | Add 2 names here |
| Profile system | `OpenClickyProfileCatalog` (3 profiles: local/realtime/quality) | `OpenClickyProfile.swift:39-80, :82` | Add 4th |
| Picker sites | 4 pickers in Settings | `OpenClickySettingsWindowManager.swift:919-963/990-999/1011-1020/1269-1274` | Adding to catalogs auto-surfaces |
| External-control bridge (32123) | `OpenClickyExternalControlBridgeServer` (NWListener over TCP, hand-parsed HTTP) | `OpenClickyExternalControlBridge.swift:82-115` | Coexist; separate `HeyClickyChromeBridgeServer` on 3011+ |

**Concurrency style**: openclicky has 3 `actor`s in cursor-buddy/
(`OpenClickyAgentFileLeaseCoordinator`, `OpenClickyParakeetModelStore`,
`TripoThreeDProvider`) but shared network clients uniformly use
`nonisolated final class @unchecked Sendable + DispatchQueue`.
`HeyClicky*Client` follows the network-client convention.

---

## 3. Provider registration checklist

### 3.1 STT

Enum + label + subtitle + resolver + picker gate:

- `BuddyTranscriptionProvider.swift:11-18` — add `case heyclickyFree = "heyclicky_free"`
- `:21-35` — label `"HeyClicky Free"`
- `:38-52` — subtitle `"Sign in with Google"`
- `:131-258` — resolver branch:
  ```swift
  case .heyclickyFree:
      HeyClickyProxyTranscriptionProvider(proxyClient: HeyClickyProxyClient.shared)
  ```
- `:113-122` — gate: only include in grid if `AppBundleConfiguration.heyClickySignedIn()`
- Do NOT add to `configuredFallback` at `:260-289` (fallback requires no auth; heyclicky needs OAuth)

STT wire protocol (§5.1).

### 3.2 Voice response

- `OpenClickyModelCatalog.swift:3-8` — add `case heyclickyFree` to `OpenClickyModelProvider`
- `:10-23` — `displayName: "HeyClicky Free"`
- `:27-40` — `voiceBackendFamily: nil`
- `:121-133` — one model entry `id: "heyclicky-free-chat"`, `provider: .heyclickyFree`
- Six switch sites — each adds `case .heyclickyFree:` arm:
  - Real dispatcher `+AIResponsePipeline.swift:361-424` → route to `HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(...)` — see §5.2 for signature
  - `CompanionManager.swift:1822-1835` (setSelectedModel warmup)
  - `:2284-2321` (startup warmup)
  - `:4243-4308` (logging fields)
  - `:1864-1887` (apply settings)
  - `+AIResponsePipeline.swift:902, :932` (pointing dispatch, if applicable)

### 3.3 TTS

Free tier ships voice via realtime WS (§5.3) — user picks
`.openAIRealtime` TTS + `.heyclickyFree` voice-response model, and
`OpenAIRealtimeSpeechClient` will use proxy-minted ephemeral.

No new `OpenClickyTTSProvider` case. Users who want a standalone
free-tier TTS pick `.microsoftEdge` (keyless).

### 3.4 Agent (Codex)

- `OpenClickyModelCatalog.swift:161-168` — extend `codexActionsModels` with
  ```swift
  CodexActionsModel(id: "heyclicky-free-agent", provider: .heyclickyFree, ...)
  ```
- When user selects it, `HeyClickyFreeTierAgentHook.activate()` runs (called
  from lane-picker commit + on profile-switch):
  1. Snapshot current `UserDefaults["clickyAgentBaseURL"]` to
     `heyClickyPreviousAgentBaseURL` UserDefault
  2. Write proxy URL to `clickyAgentBaseURL`:
     `"\(heyClickyProxyBaseURL)/agent/openai/v1"`
  3. Mint Codex ephemeral via `HeyClickySessionTokenClient` (in-memory cached; §7)
  4. Persist to `openClickyCodexAgentAPIKey` via
     `AppBundleConfiguration.persistSecret(...)` (Keychain-backed by existing mechanism)

- `HeyClickyFreeTierAgentHook.deactivate()` runs on lane-switch-away:
  1. Restore `clickyAgentBaseURL` from `heyClickyPreviousAgentBaseURL`
  2. Clear `heyClickyPreviousAgentBaseURL`
  3. Wipe short-TTL Codex ephemeral from `openClickyCodexAgentAPIKey`

**Backup-restore race guard** (per R3 M3): also observe
`OpenClickySettingsWindowManager.commitCodexAgentBaseURLDraft` at
`:1979-1989`. When user commits a new BYOK URL directly while
`.heyclickyFree` is active, treat as an opt-out: clear
`heyClickyPreviousAgentBaseURL` (accept user's new value as the new
baseline).

**Lease flow** — see §5.4 for `HeyClickyTurnLeaseClient` and its
integration in `CodexAgentSession.ensureThread`.

---

## 4. Type declarations (define ALL before implementation)

Concrete Swift declarations. Every type/enum referenced in this spec
lives here. If a name isn't declared here, either update this section
or fix the reference.

```swift
// Shared launch source, used by mint and lease APIs.
public enum HeyClickyLaunchSource: String, Sendable, Codable {
    case voice
    case text
    case codex
}

// Lanes for quota-fallback routing.
public enum HeyClickyLane: String, Sendable {
    case chat, stt, agent
}

// Error taxonomy from proxy.
public enum HeyClickyProxyError: Error, Sendable {
    case unauthorized            // 401
    case quotaExhausted          // 402/429
    case upstreamUnavailable     // 5xx
    case transportError(Error)
    case malformedResponse
}

// Response body types for /chat-tool-call. Internal to
// HeyClickyChatToolCallClient. Not exposed from analyzeVoiceResponse.
struct HigherModelResponse: Sendable {
    let text: String
    let clipboardText: String?
    let typing: String?
    let point: PointCoordinate?
    let widgets: [WidgetPayload]
    let walkthrough: Walkthrough?
    let terminationReason: TerminationReason
}

struct PointCoordinate: Sendable, Codable {
    let x: Double
    let y: Double
    let label: String
    let screen: Int?
}

struct WidgetPayload: Sendable, Codable {
    let kind: String                          // e.g. "gallery", "map"
    let payload: OpenClickyJSONValue          // reused primitive; see below
}

// Standard erased-JSON helper. Since openclicky has no shipped
// AnyCodable, we introduce one small primitive in HeyClickyProxyClient.swift.
public enum OpenClickyJSONValue: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([OpenClickyJSONValue])
    case object([String: OpenClickyJSONValue])
    case null

    // Standard init(from:) / encode(to:) decoding tree.
}

struct Walkthrough: Sendable, Codable {
    let beats: [WalkthroughBeat]
}

struct WalkthroughBeat: Sendable, Codable {
    let kind: String                          // "point" | "circle" | "rect" | "line" | "text"
    let label: String?
    let speech: String?
    let x: Double?
    let y: Double?
    let r: Double?
    let width: Double?
    let height: Double?
    let text: String?
    let screen: Int?
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    let points: [[Double]]?
}

public enum TerminationReason: Sendable {
    case completed
    case quotaExceeded
    case transportError(Error)
}

// Turn lease types (§5.4).
public struct HeyClickyTurnLease: Sendable {
    public let leaseID: String
    public let creditsUsed: Int
    public let includedCredits: Int
}

public enum HeyClickyLeaseStatus: String, Sendable, Codable {
    case completed
    case cancelled
    case failed
}

// Config error.
public enum HeyClickyConfigError: Error, LocalizedError {
    case proxyBaseURLMissing
    case oauthURLMissing
}
```

---

## 5. Wire protocol details

### 5.1 STT (proxy transcription)

**Endpoint**: `POST <proxyBaseURL><transcriptionPath>` (default `/audio/transcriptions`).

`HeyClickyProxyTranscriptionProvider` mirrors `OpenAIAudioTranscriptionProvider`
(REST Whisper transcription):

```swift
public struct HeyClickyProxyTranscriptionProvider: BuddyTranscriptionProvider {
    static var isConfigured: Bool { AppBundleConfiguration.heyClickySignedIn() }

    public func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (BuddyFinalTranscript) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return HeyClickyProxyTranscriptionSession(
            client: HeyClickyProxyClient.shared,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}
```

Session buffers PCM16 audio; on `requestFinalTranscript()`, POSTs
multipart form-data with:
- `file`: audio bytes (WAV or `audio/webm`)
- `model`: `"whisper-1"` (server rewrites as needed)
- `response_format`: `"json"`

Headers per §5.5. On response, invoke `onFinalTranscriptReady` with
the returned text. If 401 → refresh via
`HeyClickySessionAuthenticator` and retry once; if 402/429 → notify
`HeyClickyQuotaFallbackRouter.shared.handleProxyError(.quotaExhausted, lane: .stt)`.

Streaming intermediate results NOT supported (Whisper REST is one-shot).
`onTranscriptUpdate` fires once with the final text right before
`onFinalTranscriptReady`, matching Apple's non-streaming pattern.

### 5.2 Chat-tool-call (voice-response)

**Endpoint**: `POST <proxyBaseURL><chatToolCallPath>` (default `/chat-tool-call`).

**Request body** — field names verified against demo
`HigherModelClient.swift:132-141`:

```json
{
  "query": "...user prompt... (image dimensions: WxH pixels)",
  "screenshotBase64": "...",
  "screenshotWidthInPixels": 3840,
  "screenshotHeightInPixels": 2160,
  "mimeType": "image/jpeg",
  "client_capabilities": ["clipboard_copy", "type_text", "guided_click"],
  "frontmost_app_bundle_id": "com.apple.Safari",
  "environment": { "locale": "en_US", "timezone": "..." },
  "session_id": "<same UUID as x-clicky-Session-Id header>"
}
```

**No `conversationHistory` field**. Demo's chat-tool-call is one-shot
per user turn; per-turn context is carried by proxy-side session
state keyed on `session_id`. History plumbing on our side stays in
`voiceConversationHistoryForAPI()` (§3.2 pipeline), which is only
consumed by BYOK arms.

**Response body**:
```json
{
  "text": "...",
  "clipboardText": "...?",
  "typing": "...?",
  "point": {"x": 100.0, "y": 200.0, "label": "...", "screen": 0},
  "widgets": [...],
  "walkthrough": {"beats": [...]}
}
```

**Sixth-arm signature** (matches actual `analyzeVoiceResponse` shape
at `+AIResponsePipeline.swift:361-368`):

```swift
private func analyzeHeyClickyFreeVoiceResponse(
    images: [(data: Data, label: String)],       // labeled tuple, not [(Data, String)]
    model: String,
    systemPrompt: String,
    conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
    userPrompt: String,
    assistantPrefill: String?,
    onTextChunk: @MainActor @Sendable @escaping (String) -> Void
) async throws -> String
```

**Bridging steps**:

1. `[earlier OpenClicky voice context]` placeholder in
   `conversationHistory[0]` — pass through untouched. Openclicky
   trusts this string in every provider today (`CompanionManager.swift:1204-1207`);
   proxy hardening is proxy-side concern.
2. Read `(width, height)` from the caller's `CompanionScreenCapture`
   (dimensions on struct at `CompanionScreenCaptureUtility.swift:24-25`);
   inline label per `+AIResponsePipeline.swift:130-132`.
3. Call `HeyClickyChatToolCallClient.shared.send(body:)` → `HigherModelResponse`.
4. Fire `onTextChunk(response.text)` in one call on `@MainActor`.
5. `response.typing`: call new wrapper `companionManager.typeTextForHeyClickyFree(text)`
   (see §2 reuse map — thin internal wrapper on `CompanionManager` that
   constructs `OpenClickyNativeTypeRequest` and calls existing
   `typeTextUsingSelectedComputerUse(_:)` at `:7555`).
6. `response.clipboardText`: `NSPasteboard.general` write (pattern at `CompanionManager.swift:15379`).
7. If `response.point != nil`: append **`[POINT:x,y:label:screenN]`** to
   the returned text. **Emit EITHER `[POINT]` OR one `[RECT]`/`[SCRIBBLE]`
   per response**, never both — openclicky's regex is `\s*$` anchored
   at `CompanionManager+PointTagParsing.swift:79/120/151` and won't
   parse multiple visual tags in one turn.
8. If `response.walkthrough` present AND the FIRST beat has
   `kind == "circle" && r != nil`: append **`[TARGET:x,y,r:label:screenN]`**
   instead of `[POINT]`. `HeyClickyGuidedClickManager` (§5.5) picks this
   up. Additional beats render as `[RECT]`/`[SCRIBBLE]` in follow-up
   turns after user click.
9. Return `response.text` (plus at-most-one visual tag suffix).

**Termination handling**:
- `.completed`: normal return
- `.quotaExceeded`: return `partial_text + "\n[interrupted: quota_exceeded]"`
  and notify `HeyClickyQuotaFallbackRouter.shared.handleProxyError(.quotaExhausted, lane: .chat)`
- `.transportError`: return `partial + "\n[interrupted: transport]"` and
  notify fallback router with `.transportError`

### 5.3 Realtime WS (free-tier voice)

Free tier supports full voice by extending `OpenAIRealtimeSpeechClient`
(the existing openclicky class). Callers select `.openAIRealtime` TTS
+ `.heyclickyFree` model; `updateConfiguration(...)` receives proxy
ephemeral instead of BYOK key.

**Extended signature** (at `OpenAIRealtimeSpeechClient.swift:118`):

```swift
func updateConfiguration(
    apiKey: String,
    voiceID: String,
    realtimeBaseURL: URL? = nil,                    // nil = wss://api.openai.com/v1/realtime
    serverInstructions: String? = nil,               // nil = client default; explicit "" = clear
    onEphemeralRefreshNeeded: (@Sendable () async throws -> (String, Int?))? = nil
) async
```

**4 hardcoded WS URL sites** at `:276, :468, :625, :768` — thread
`realtimeBaseURL` through each.

**Free-tier caller flow**:
1. `HeyClickySessionTokenClient.shared.mintRealtimeToken()` → `(ephemeral, expiresAt)`
2. `openAIRealtimeSpeechClient.updateConfiguration(apiKey: ephemeral, voiceID: current, realtimeBaseURL: nil, serverInstructions: baked, onEphemeralRefreshNeeded: { ... })`
3. Timer at `expiresAt - 10s` fires refresh via closure (§7 in-memory cache serves it)

**5-tool schema**: use existing `realtimeRoutingTools` at
`OpenAIRealtimeSpeechClient.swift:53-102` verbatim (3 tools:
`openclicky_use_computer`, `openclicky_use_screen_context`,
`openclicky_start_background_agent`). Do NOT install a different
tool set for free tier.

**Barge-in** (new public method `bargeIn()` on `OpenAIRealtimeSpeechClient`):

```
transport.send({"type": "response.cancel"})
transport.send({"type": "input_audio_buffer.clear"})
transport.send({
    "type": "conversation.item.truncate",
    "item_id": currentAssistantItemId,
    "content_index": 0,
    "audio_end_ms": playedAudioMs
})
audioEngine.playbackNode.stopPlayback()
currentAssistantItemId = nil
playedAudioMs = 0
```

`playedAudioMs = bytesPlayed / 48` at 24kHz PCM16 mono. Track via
`AVAudioPlayerNode.playedSampleTime`. Guard: skip truncate if
`currentAssistantItemId == nil`.

Trigger: `CompanionManager.startPushToTalk()` observes existing
`isAssistantSpeaking == true` and calls `openAIRealtimeSpeechClient.bargeIn()`.

**Auto-reconnect**: on WS error `ws_receive` / `timed out` /
`not connected` / `cancelled`:
- `attempt = min(current+1, 5)`
- `delay = min(2^attempt, 15)` seconds
- reopen WS with fresh ephemeral (in-memory cache; if expired, mint fresh)
- reset `attempt = 0` on healthy `session.created`

### 5.4 Codex agent lane with turn lease

**Endpoints**:
- `POST <proxy><threadLaunchPath>` (default `/codex-thread-launch`)
- `POST <proxy>/agent/record-agent-launch`
- `POST <heartbeat_url>` (returned by lease response)
- `POST <complete_url>` (returned by lease response)

**Thread launch** (fires before Codex spawn, inside
`CodexAgentSession.ensureThread` at `:838`):

```
Body: { "user_prompt": <prompt>, "launch_source": "voice"|"text"|"codex" }
Response: { "session_id": <string, agent thread id>, ... }
```

Persist `session_id` for the Codex process's lifetime; use as
`x-clicky-Agent-Thread-Id` header.

**Lease acquire**:

```
Body: { "session_id": <thread id>, "launch_source": ... }
Response: {
  "lease_id": String,
  "credits_used": Int,
  "included_credits": Int,
  "heartbeat_url": String,
  "complete_url": String
}
```

On 402/429: `HeyClickyQuotaFallbackRouter.handleProxyError(.quotaExhausted, lane: .agent)`.

**Heartbeat** (`HeyClickyTurnLeaseHeartbeat`, @MainActor):

```
POST <heartbeat_url>          Body: {}       Interval: 30s
```

On 4xx: mark lease invalid, cancel Codex, notify user.

**Complete** (on Codex `turnCompleted` or process exit):

```
POST <complete_url>           Body: {"status": "completed"|"cancelled"|"failed", "reason": String?}
```

**Interception in `CodexAgentSession.ensureThread` at `:838`**:

```swift
if selectedModel.id.hasPrefix("heyclicky-free-") {
    // 1. Wait for reset barrier (§8.3 lifecycle)
    await HeyClickyQuotaFallbackRouter.shared.awaitBarrier()

    // 2. Launch thread
    let threadInfo = try await HeyClickyProxyClient.shared.launchThread(
        userPrompt: prompt, launchSource: launchSource(for: self)
    )
    HeyClickyHeaderBuilder.shared.setAgentThreadID(threadInfo.sessionID)

    // 3. Acquire lease
    let lease = try await HeyClickyTurnLeaseClient.shared.acquire(
        sessionID: threadInfo.sessionID,
        launchSource: launchSource(for: self)
    )
    self.currentHeyClickyLease = lease

    // 4. Mint ephemeral
    let token = try await HeyClickySessionTokenClient.shared.mintCodexToken(
        launchSource: .codex
    )

    // 5. Snapshot + set overrides
    HeyClickyFreeTierAgentHook.activate(ephemeral: token)

    // 6. Start heartbeat
    HeyClickyTurnLeaseHeartbeat.shared.start(
        leaseID: lease.leaseID,
        heartbeatURL: lease.heartbeatURL
    )
}

// ... existing ensureThread ceremony continues with UserDefaults now
// pointing at proxy + ephemeral in Keychain ...
```

On turn completion / process exit:

```swift
if let lease = self.currentHeyClickyLease {
    Task {
        try? await HeyClickyTurnLeaseClient.shared.complete(
            completeURL: lease.completeURL,
            status: .completed,
            reason: nil
        )
    }
    HeyClickyTurnLeaseHeartbeat.shared.stop()
    HeyClickyHeaderBuilder.shared.setAgentThreadID(nil)
    HeyClickyFreeTierAgentHook.deactivate()   // restore backup, wipe ephemeral
    self.currentHeyClickyLease = nil
}
```

### 5.5 `[TARGET:x,y,r:label:screenN]` guided-click

`HeyClickyGuidedClickManager` (@MainActor final class) handles the
demo's guided-click flow — NOT covered by openclicky's RECT/SCRIBBLE
(which are passive visual overlays only, per R2 M2 audit).

**Regex** (parse from response text):

```
\[TARGET:(?<x>[0-9.]+),(?<y>[0-9.]+),(?<r>[0-9.]+):(?<label>[^:\]]*)(?::screen(?<screen>[0-9]+))?\]\s*$
```

`\s*$` anchor matches openclicky's POINT/RECT/SCRIBCH regex convention.
`HeyClickyChatToolCallClient` runs this parser AFTER openclicky's
POINT/RECT/SCRIBBLE parser (call order: openclicky first, HeyClicky
last). Only ONE visual tag per response per §5.2 step 7.

**Flow**:

1. `arm(x, y, r, label, screen)`:
   - Locate the correct `OverlayWindow` from `OverlayWindowManager` by screen
   - Draw a blue circle at `(x, y)` radius `r` (new `NSView` overlay drawn
     via `Path` in `HeyClickyGuidedClickOverlayView`)
   - Install `CGEvent` tap via `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown])`
     to detect user click position
2. On click event:
   - If `pointInCircle(clickLocation, center: (x,y), radius: r)`:
     - `disarm()` — remove overlay + tap
     - If Realtime WS active: inject synthetic user message via
       `openAIRealtimeSpeechClient.injectFollowUp("guided_click_follow_up: \(label)")`
       — the WS then continues with the next step
     - Else: store as `pendingFollowUp` on
       `HeyClickyGuidedClickManager`; observed by
       `openAIRealtimeSpeechClient` at next `session.created` (§8 defers
       follow-up until WS available)
   - Else: user clicked outside; leave overlay armed (they may re-click)
3. Auto-disarm timeout: 60s (log `voice.heyclicky.guided_click_timeout`)

**Concurrency**: `@MainActor final class`. Overlay view is `NSView` subclass.

### 5.6 `x-clicky-*` 6 headers

Per demo `XClickyHeaderBuilder.swift:36-49`:

| Header | Value | Lifetime |
|---|---|---|
| `Authorization` | `Bearer <accessToken>` | refresh via `SessionAuthenticator` |
| `<prefix>-Distinct-Id` | Supabase userId (JWT `sub`) | per account |
| `<prefix>-Session-Id` | UUID cached at app launch | per app-launch |
| `<prefix>-Trace-Id` | Fresh UUID per request | per HTTP request |
| `<prefix>-Mode` | `"normal"` | constant |
| `<prefix>-Agent-Thread-Id` | Codex thread session_id (set by §5.4 step 2) | per active Codex thread; nil otherwise |
| `<prefix>-Dictation-Receipt` | `HeyClickySessionTokenClient.mintDictationReceipt()` | per request |

`<prefix>` default `"x-clicky"`; parameterized via
`AppBundleConfiguration.heyClickyHeaderPrefix()`.

Chat body `session_id` MUST equal `x-clicky-Session-Id` header (same
per-app-launch UUID). Codex thread's `session_id` is a DIFFERENT id
served by `x-clicky-Agent-Thread-Id`.

### 5.7 OAuth flow

1. User selects `.heyclickyFree` on any lane. If not signed in, Settings
   HeyClicky section shows "Sign in with Google" button.
2. Button → `HeyClickyOAuthHandler.shared.startSignIn()` (owned by
   `HeyClickySessionAuthenticator.swift` as nested struct — R3 M5 fix):
   ```swift
   var components = URLComponents(url: try AppBundleConfiguration.heyClickyOAuthAuthorizeURL()!, resolvingAgainstBaseURL: false)!
   components.queryItems = (components.queryItems ?? []) + [
       URLQueryItem(name: "redirect_uri", value: "openclicky://heyclicky-auth-callback"),
       URLQueryItem(name: "clicky_auto", value: "1")
   ]
   NSWorkspace.shared.open(components.url!)
   ```
3. Google → Supabase → redirects to `openclicky://heyclicky-auth-callback?code=...`
4. `CompanionManager.handleWidgetDeepLink(_:)` at `:2076-2098` — new
   `case "heyclicky-auth-callback":` extracts `code`, dispatches to
   `HeyClickyOAuthHandler.shared.exchangeCode(code)`
5. Handler exchanges for access + refresh tokens; persists via
   `AppBundleConfiguration.persistSecret(...)`; posts
   `.clickyHeyClickyCredentialsRefreshed`

**Timeout / partial state** (R3 m3 fix): `startSignIn()` writes
`heyClickyPendingSignInStartedAt` UserDefault. If no callback within
10 minutes (checked on next app launch or on new signin attempt),
clear stale state, log `system.heyclicky.oauth_timeout`.

**Transactional persist** (R3 m3 fix): `exchangeCode` writes access +
refresh atomically to Keychain in one operation. On failure, wipes
both (never mixed state).

---

## 6. AppBundleConfiguration accessors

Add to `AppBundleConfiguration.swift` matching `nonisolated enum` style.

```swift
extension AppBundleConfiguration {
    // Required; throws if missing (feature auto-disables per §9.1).
    static func heyClickyProxyBaseURL() throws -> URL
    static func heyClickyOAuthAuthorizeURL() throws -> URL

    // Optional with defaults; precedence UserDefaults > Info.plist > env > secrets.env.
    static func heyClickyHeaderPrefix() -> String                       // default "x-clicky"
    static func heyClickyChatToolCallPath() -> String                   // default "/chat-tool-call"
    static func heyClickyTranscriptionPath() -> String                  // default "/audio/transcriptions"
    static func heyClickyRealtimeEphemeralPath() -> String              // default "/agent/realtime/ephemeral"
    static func heyClickyCodexEphemeralPath() -> String                 // default "/agent/codex-ephemeral"
    static func heyClickyDictationReceiptPath() -> String               // default "/agent/session-token"
    static func heyClickyThreadLaunchPath() -> String                   // default "/codex-thread-launch"
    static func heyClickyRecordAgentLaunchPath() -> String              // default "/agent/record-agent-launch"
    static func heyClickyFallbackChatProvider() -> String?              // default nil (surface error)
    static func heyClickyFallbackSTTProvider() -> String?               // default nil
    static func heyClickyFallbackAgentProvider() -> String?             // default nil
    static func heyClickyBridgePortRange() -> ClosedRange<Int>          // default 3011...3021

    // Keychain-backed (via existing keychainBackedDefaultsKeys).
    static func heyClickySignedIn() -> Bool                             // true iff access token present
    static func heyClickySessionAccessToken() -> String?
    static func heyClickySessionRefreshToken() -> String?

    // Restore state
    static func heyClickyPreviousAgentBaseURL() -> String?
    static func setHeyClickyPreviousAgentBaseURL(_ value: String?)
    static func heyClickyPendingSignInStartedAt() -> Date?
    static func setHeyClickyPendingSignInStartedAt(_ value: Date?)
}
```

### 6.1 Feature disable on missing config

If `heyClickyProxyBaseURL()` throws OR `heyClickyOAuthAuthorizeURL()` throws:
- `.heyclickyFree` entries HIDDEN from all pickers
  (grid predicates check throw)
- Any lane already set to `.heyclickyFree` reverts to previous
  provider on next launch via profile restore
- One-time log `system.heyclicky.disabled_no_proxy_url` or `..._no_oauth_url`

### 6.2 Keychain-backed keys

Add to `keychainBackedDefaultsKeys` at `AppBundleConfiguration.swift:387-395`:
- `heyClickySessionAccessTokenDefaultsKey`
- `heyClickySessionRefreshTokenDefaultsKey`

### 6.3 User-facing configuration

Settings window gains a "HeyClicky Free" subsection under Advanced Providers with editable fields:
- Proxy base URL (writes UserDefault `heyClickyProxyBaseURL`)
- OAuth authorize URL (writes UserDefault `heyClickyOAuthAuthorizeURL`)
- Sign in / Sign out buttons
- Optional: Fallback providers per lane (dropdowns)

Info.plist ships **empty defaults**; users configure via Settings.
This makes the feature usable for redistributed builds without
requiring source patches.

---

## 7. HeyClickySessionTokenClient (in-memory cache + single-flight)

Matches openclicky's shared-network-client convention (`nonisolated
final class @unchecked Sendable` + private DispatchQueue for state).
Concurrent lane mints coalesce into ONE network request via `Task`
single-flight.

```swift
public final class HeyClickySessionTokenClient: @unchecked Sendable {
    public static let shared = HeyClickySessionTokenClient()

    private let queue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.token")
    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private var cachedRealtime: CachedToken?
    private var cachedCodex: CachedToken?
    private var cachedDictationReceipt: CachedToken?
    private var inflightRealtime: Task<(String, Int?), Error>?
    private var inflightCodex: Task<String, Error>?
    private var inflightDictationReceipt: Task<String, Error>?
    private let refreshBuffer: TimeInterval = 10

    public func mintRealtimeToken() async throws -> (value: String, expiresAt: Int?)
    public func mintCodexToken(launchSource: HeyClickyLaunchSource) async throws -> String
    public func mintDictationReceipt() async throws -> String

    /// Cancels in-flight tasks AND clears cache. Called by
    /// HeyClickyQuotaFallbackRouter on .clickyHeyClickyCredentialsRefreshed
    /// or user sign-out.
    public func invalidateAll()
}
```

**invalidateAll semantics** (R3 m5 fix): cancels in-flight Tasks
(they throw `CancellationError`), THEN clears cache. Guarantees
no lane receives a stale token.

**UserDefaults never stores minted ephemerals**. For Codex spawn:
- `mintCodexToken(...)` returns in-memory value
- `AppBundleConfiguration.persistSecret(token, defaultsKey: userCodexAgentAPIKeyDefaultsKey)`
  writes it (Keychain-backed, not plain UserDefaults on disk)
- `CodexProcessManager.baseEnvironment` at `:53-58` reads and puts in
  child env at fork time
- After `processManager.start` returns, the on-disk Keychain entry
  is left in place (Keychain is protected). No manual wipe needed —
  next lane deselection triggers `HeyClickyFreeTierAgentHook.deactivate()`
  which wipes it.

---

## 8. Chrome bridge (Level 2 quota fallback)

Only relevant when the user wants proxy 402/429 to trigger a browser
prompt. Level 1 (default) uses `HeyClickyQuotaFallbackRouter` for
lane fallback and never opens the browser.

If shipped, uses HTTP long-poll on `127.0.0.1:3011` (per demo
`ChromeBridgeServer.swift:10-16`):

```
POST /event    Body: {type, ...}
GET  /cmd      Long-poll 25s → JSON or 204
GET  /health   200 OK
```

Port collision walk: try 3011..3021. Chosen port written to
`~/Library/Application Support/OpenClicky/bridge_port`.

`chrome-ext/background.js` must poll port range on `/health` failure
(caches in `chrome.storage.local`) and pick working port.

Extension only auto-drives tabs with `?clicky_auto=1` query param.
`HeyClickyOAuthHandler.startSignIn()` appends this param.

**Do NOT run WebSocket server** — extension speaks fetch.

---

## 9. Lifecycle rules

### 9.1 Feature auto-disable

If proxy or OAuth URL not configured (§6.1):
- Picker entries hidden
- Existing `.heyclickyFree` selections revert on next launch
- No daemon boots

### 9.2 Provider selection at boot

`cursor_buddyApp.swift` after `companionManager.start()` at `:125`:
- `HeyClickyQuotaFallbackRouter.shared.install()` — observers wired
- If any lane == `.heyclickyFree`, `HeyClickyFreeTierAgentHook.reconcile()` restores state

### 9.3 Reset barrier (Level 2 only)

Between quota-triggered reset and lane token consumption:
- `HeyClickyQuotaFallbackRouter.shared.awaitBarrier()` awaits any in-flight reset
- Max wait 90s via `heyClickyResetBarrierMaxWaitSeconds`; on timeout, force-drain (cancel current lane's turn via barge-in)

### 9.4 Mid-turn provider swap

If any lane provider changes while a turn is in flight: current turn
completes on the previously-selected provider. Change applies at next
`startPushToTalk()` / Codex spawn boundary.

Observed via `CompanionManager.isTurnInFlight` (new
`@Published private(set)` property; set in `startPushToTalk()` / cleared in
`analyzeVoiceResponse` defer) + `CodexAgentSession.isSpawnInFlight`.

### 9.5 Quota fallback (Level 1 default)

`HeyClickyQuotaFallbackRouter.handleProxyError(error, lane)`:

- `.unauthorized`: fire `HeyClickySessionAuthenticator.refresh()`. If refresh fails, mark session expired, surface "Sign in again" UI action, no lane fallback.
- `.quotaExhausted`: read `AppBundleConfiguration.heyClickyFallback<Lane>Provider()`. If set, atomically switch the lane's UserDefault to that provider raw value (write via `AppBundleConfiguration.persistProviderChange(...)`). If unset, surface error on lane's UI ("Quota exhausted. Switch provider in Settings.").
- `.upstreamUnavailable` / `.transportError`: surface transient error UI; no fallback (temporary network issue).

No account deletion. No browser-driven re-provisioning. If the user
wants a fresh HeyClicky account, they do that themselves.

---

## 10. Notifications

Add to existing extension at `MenuBarPanelManager.swift:19-24`:

```swift
extension Notification.Name {
    // existing 4 names...

    // NEW:
    static let clickyHeyClickyResetCompleted =
        Notification.Name("clickyHeyClickyResetCompleted")
    static let clickyHeyClickyCredentialsRefreshed =
        Notification.Name("clickyHeyClickyCredentialsRefreshed")
}
```

No separate notifications file. Matches openclicky's `.clicky*` convention.

---

## 11. Logging

Reuse existing lanes (`voice`, `agent`, `system`, `chat` if opened);
put "heyclicky" in the event verb and as a field, NOT as a new lane:

| Event | Lane | Direction |
|---|---|---|
| `voice.heyclicky.ephemeral_minted` | `voice` | `internal` |
| `voice.heyclicky.quota_exceeded` | `voice` | `error` |
| `agent.heyclicky.thread_launched` | `agent` | `outgoing` |
| `agent.heyclicky.lease_acquired` | `agent` | `outgoing` |
| `agent.heyclicky.lease_completed` | `agent` | `outgoing` |
| `agent.heyclicky.heartbeat_failed` | `agent` | `error` |
| `system.heyclicky.disabled_no_proxy_url` | `system` | `internal` |
| `system.heyclicky.oauth_timeout` | `system` | `error` |
| `system.heyclicky.credentials_refreshed` | `system` | `internal` |
| `chat.heyclicky.higher_model_request` | new `chat` lane OR `voice` | `outgoing` |

All emitted via `OpenClickyMessageLogStore.shared.append(...)`. Fields
include `provider: "heyclicky_free"`, `sessionID`, `traceID`, `leaseID`.

---

## 12. Concurrency

All shared network clients follow openclicky's `nonisolated final
class @unchecked Sendable + DispatchQueue` pattern. `@MainActor` for
UI-owning classes. NO `actor` for shared network state (openclicky
only uses `actor` for narrowly-scoped state — `OpenClickyAgentFileLeaseCoordinator`,
`OpenClickyParakeetModelStore`, `TripoThreeDProvider`).

| Class | Concurrency |
|---|---|
| `HeyClickyProxyClient` | `nonisolated final class @unchecked Sendable` + private queue |
| `HeyClickyHeaderBuilder` | Same |
| `HeyClickySessionAuthenticator` | Same |
| `HeyClickySessionTokenClient` | Same |
| `HeyClickyChatToolCallClient` | Same |
| `HeyClickyProxyTranscriptionProvider` | Same (mirrors `OpenAIAudioTranscriptionProvider`) |
| `HeyClickyTurnLeaseClient` | Same |
| `HeyClickyTurnLeaseHeartbeat` | `@MainActor final class` |
| `HeyClickyGuidedClickManager` | `@MainActor final class` |
| `HeyClickyQuotaFallbackRouter` | `@MainActor final class` |
| `HeyClickyChromeBridgeServer` (Level 2) | `@MainActor final class` for lifecycle; internal queue for NWListener |

---

## 13. Cross-app isolation

OpenClicky and HeyClicky.app coexist in `/Applications`:

- URL scheme: `openclicky://heyclicky-auth-callback` (host `heyclicky-auth-callback`)
- Keychain: all `com.jkneen.openclicky.heyclicky.*`
- Bridge port default `3011` (leaves `3001` to HeyClicky.app)
- Chrome extension: distinct ID from HeyClicky.app's "Clicky Reset Auto"
- Log lanes: reuse OpenClicky's `OpenClickyMessageLogStore` (own directory)

---

## 14. Termination criteria

1. 9 new files compile
2. `scripts/sign-and-install.sh` succeeds; TCC preserved
3. Each lane picker shows "HeyClicky Free" after OAuth sign-in;
   option hidden when signed out
4. Users can select `.heyclickyFree` on any subset of lanes independently
5. `conversationHistory`, `memory.md`, `OpenClickyMessageLogStore`
   unchanged whether via proxy or via BYOK
6. Level 1 round-trip: OAuth → each `.heyclickyFree` lane hits proxy →
   response streams
7. `[POINT:x,y:label:screenN]` overlay renders via existing
   `parsePointingCoordinates` + `OverlayWindow.flyTo(_:onComplete:)`
   (the new public wrapper)
8. `[TARGET:x,y,r:label:screenN]` overlay renders via
   `HeyClickyGuidedClickManager`; user click within radius injects
   `guided_click_follow_up` back to WS
9. Codex agent under `.heyclickyFree` succeeds with proxy
   (thread-launch → lease-acquire → heartbeat → complete round-trip)
10. Realtime WS voice works: STT + TTS via proxy ephemeral, seamless
    swap keeps 60s+ turns connected, barge-in cuts within 200ms
11. Quota fallback: mock 402 → `HeyClickyQuotaFallbackRouter` fires
    → lane switches to configured fallback OR surfaces error
12. Switching every lane back to non-`.heyclickyFree`: no residual
    state (`clickyAgentBaseURL` restored, no daemons)
13. `HeyClickySessionTokenClient` cache: 3 concurrent lane mints →
    1 network request (mock proxy test)
14. `HeyClickyBYOKPreservationTests`: activate `.heyclickyFree` agent,
    change base URL via Settings, deactivate — verify Settings input
    is preserved (not clobbered by restore)
15. Regex tests: response with `[POINT]` + `[RECT]` in same text —
    verify only one visual tag per response invariant is enforced
    (sixth arm test)
16. AGENTS.md exemption honored (documented at top)

---

## 15. Testing

- **L1 unit**: one XCTestCase per new file. Standard `func testFooBar()`.
- **L2 integration**: mock proxy under `cursor-buddyTests/HeyClickyMockServer/`
  using `URLProtocol` stub. Fixtures in `Fixtures/` with `.meta.json` sidecar
  tracking `heyclicky_version`.
- **L3 E2E**: `verify/heyclicky/e2e.sh` launches signed app, exercises each
  lane, verifies request lands on proxy via `OpenClickyMessageLogStore` event.

Named regression tests:
- `HeyClickyQuotaExhaustedTests` — 402 mid-stream, partial recorded, fallback fires
- `HeyClickyEphemeralCacheTests` — 3 concurrent mints → 1 request
- `HeyClickyEphemeralSwapTests` — 60s PTT hold spans expiry, no cutout
- `HeyClickyBargeInTests` — mid-response PTT press cuts audio within 200ms
- `HeyClickyGuidedClickFollowUpTests` — [TARGET] arm → click → follow-up injected
- `HeyClickyLeaseHeartbeatTests` — Codex spawn → lease acquired → heartbeat 30s → complete
- `HeyClickyBYOKPreservationTests` — activate/deactivate, verify user's
  `clickyAgentBaseURL` preserved (per §3.4 race guard)
- `HeyClickyVisualTagInvariantTests` — POINT + RECT in one response →
  only one emitted
- `HeyClickyOAuthTimeoutTests` — startSignIn → no callback in 10 min →
  clean state on next launch

Coverage floor: 80% on new files.

---

## 16. Companion documents

- `docs/HEYCLICKY_INTEGRATION_ATLAS.md` — full openclicky-primitive atlas
- `chrome-ext/README.md` — extension protocol details
- `scripts/sign-and-install.sh` — persistent-cert TCC preservation
- `docs/OpenClickySkillCompatibilityAudit.md` — HeyClicky skill parity
- `docs/APP_UPDATES.md` — Sparkle release flow
- Reference: `/Users/wowdd1/Dev/clicky-mac/leanring-buddy/AgentBackend/`
