# 07 - Model Provider Abstraction

Audit of the `OpenClickyModelProvider` enum + associated LLM call sites.
Question: is the abstraction well-shaped, or does adding a new provider
require touching N call sites?

Verdict: **not well-shaped**. There is no `LLMClient` protocol; the enum
is used as an ad-hoc dispatch key. Adding a provider requires touching
at least **7 mandatory switch/if sites** across 3 files, plus catalog
edits, plus per-site case coverage for `voiceBackendFamily`, warm-up,
settings UI, pointing resolver, filler gating, and analytics logging.

---

## Sound abstraction

The one thing that works: `OpenClickyModelOption { id, label, provider,
maxOutputTokens }` in `cursor-buddy/OpenClickyModelCatalog.swift:94-106`
is a clean value type. `voiceBackendFamily` on the enum
(`OpenClickyModelCatalog.swift:37-56`) cleanly folds seven providers
into three coarse UI families (`apple / codex / claude`). Model
normalization and lookup helpers (`normalizedModelID`,
`voiceResponseModel(withID:)`, `isSpeechModelID`) at
`OpenClickyModelCatalog.swift:225-315` are correctly centralized — no
call site parses model IDs by hand.

## Leaky abstraction

1. **The provider enum is switched on in six places, each with slightly
   different case coverage.** No exhaustive `LLMClient` protocol forces
   the seven cases to be handled uniformly:
   - `CompanionManager+AIResponsePipeline.swift:845` — dispatch to
     `analyzeVoiceResponse` (7 cases handled).
   - `CompanionManager+AIResponsePipeline.swift:1437` —
     `computerUsePointingResolver`, groups `.apple/.deepgram/.heyclickyFree/.peekyFree`
     as `.unsupported`.
   - `CompanionManager+AIResponsePipeline.swift:1471` — pointing
     backend, groups `.apple/.openAI/.deepgram/.heyclickyFree/.peekyFree`
     as no-op (note `.openAI` is grouped with `.apple` here, but is a
     first-class provider at line 1437; two nearly-parallel switches
     with different fall-through groupings).
   - `CompanionManager.swift:2160` — warm-up on model change.
   - `CompanionManager.swift:2224` — `applyVoiceResponseModelSettings`.
   - `CompanionManager.swift:2780` — startup warm-up.
   - `CompanionManager.swift:6535` — analytics `executionMethod` logging.

   Plus scattered `provider ==` equality checks:
   `CompanionManager.swift:2131/2136/2144`,
   `CompanionManager+AIResponsePipeline.swift:1119/1126/1432/1792/1799`,
   `OpenClickySettingsWindowManager.swift:1091/1098/1106/1304/4909/4913/4921/5112`,
   `ChatHeaderBar.swift:181/185/198/199`. Each is a spot where a new
   provider silently defaults to the wrong branch.

2. **No shared `LLMClient` protocol.** All six clients expose
   `analyze*` with signatures that are almost — but not quite — the
   same:
   - `ClaudeAPI.analyzeImageStreaming` (`ClaudeAPI.swift:131`) →
     `(text, duration)`, takes `assistantPrefill`.
   - `ClaudeAgentSDKAPI.analyzeImageStreaming`
     (`ClaudeAgentSDKAPI.swift:182`) → same, also takes
     `assistantPrefill`.
   - `OpenAIAPI.analyzeImageStreaming` (`OpenAIAPI.swift:147`) →
     `(text, duration)`, **no** `assistantPrefill`.
   - `CodexVoiceSession.analyzeImageStreaming`
     (`CodexVoiceSession.swift:103`) → `(text, duration)`, no prefill.
   - `AppleFoundationModelsVoiceClient.analyzeVoiceResponse`
     (`AppleFoundationModelsVoiceClient.swift:29`) → returns bare
     `String`, static function, no prefill.
   - `HeyClickyChatToolCallClient.analyzeVoiceResponse`
     (`HeyClickyChatToolCallClient.swift:41`) → bare `String`, takes
     `companionManager: CompanionManager` (leaks the manager into the
     client) and an extra `intent:`.
   - Mirage has no public method with this shape at all — it is invoked
     via a private `analyzeMirageResponse`
     (`CompanionManager+AIResponsePipeline.swift:2521`) which then
     calls the very different
     `MirageBackendClient.sendStreamingChunks(body:)`
     (`MirageBackendClient.swift:391`).

   Result: the dispatch switch at line 845 is the *only* place these
   almost-identical signatures get reconciled, and it does so by six
   bespoke argument permutations.

3. **Fallback chain is not encapsulated.** The Claude
   SDK-primary/HTTP-fallback logic lives inline in
   `analyzeClaudeResponse`
   (`CompanionManager+AIResponsePipeline.swift:932-1007`), not inside a
   `ClaudeClient` type. Same for OpenAI: the Codex-app-server-first /
   direct-key-fallback ladder is duplicated inline in
   `analyzeOpenAIOrCodexVoiceResponse`
   (`CompanionManager+AIResponsePipeline.swift:1009-1063`). Analytics
   attribution in `CompanionManager.swift:6542-6583` recomputes which
   branch *would* fire based on `AppBundleConfiguration` key
   availability — this logic is now in two places and can drift.

4. **`analyzeVoiceResponse` is 85 lines of case-by-case argument
   fanout, not a dispatch table.** Every arm calls a differently-shaped
   helper (`analyzeClaudeResponse`,
   `analyzeOpenAIOrCodexVoiceResponse`, `analyzeCodexVoiceResponse`,
   `analyzeMirageResponse`, `HeyClickyChatToolCallClient.shared.analyzeVoiceResponse`,
   `AppleFoundationModelsVoiceClient.analyzeVoiceResponse`). No arm
   uses a common `LLMClient.send(...)` call.

## Over-abstraction

None found. If anything, the abstraction is under-built: `provider` is
a data tag, not a behavior boundary.

## Missing abstraction

1. **`LLMClient` protocol.** Nothing forces Claude / OpenAI / Codex /
   Mirage / Apple / HeyClicky to conform to a single
   `sendStreamingCompletion(request, onDelta:) async throws ->
   Completion` shape.
2. **`ProviderCapabilities`.** Facts like "supports assistant prefill",
   "supports images", "supports tool use", "is realtime-speech", "goes
   through app-server first" are encoded as ad-hoc if-else, not as
   fields on `OpenClickyModelOption` or on the client type.
3. **Streaming abstraction.** Each provider has its own delta parser
   (SSE `text_delta` for Claude/Mirage,
   `response.output_audio.delta` for OpenAI Realtime,
   `agentMessage_delta` for Codex, a single full-text emission for
   Apple, a bespoke tool-call event stream for HeyClicky). There is no
   common `AsyncThrowingStream<LLMDelta, Error>` — the shared surface
   is a lowest-common-denominator `@MainActor (String) -> Void`
   callback of already-flattened plaintext.
4. **Tool-call abstraction.** No provider-agnostic
   `tool_use`/`tool_result` block type. HeyClicky handles tool calls
   inside its own client
   (`HeyClickyChatToolCallClient.swift:41+`); the other clients don't
   expose tools at all. The pipeline can't route tools to Claude even
   though the underlying REST API supports them.
5. **Fallback ladder.** Each provider's SDK-primary / HTTP-fallback
   pattern is inline. There is no
   `FallbackChain<LLMClient>([primary, secondary])` wrapper. Analytics
   at `CompanionManager.swift:6535-6612` even re-derives which branch
   would run, duplicating the decision.

## Recommended refactor

Introduce a client protocol and a capability descriptor. Move fallback
into a chain type. Keep `OpenClickyModelProvider` as the *catalog tag*
but stop switching on it at call sites.

```swift
// New: cursor-buddy/LLMClient.swift
struct LLMRequest {
    let model: String
    let systemPrompt: String
    let history: [(user: String, assistant: String)]
    let userPrompt: String
    let images: [(data: Data, label: String)]
    let assistantPrefill: String?
    let tools: [LLMTool]
    let maxOutputTokens: Int
}

enum LLMDelta {
    case text(String)
    case toolUse(id: String, name: String, input: Data)
    case toolResult(id: String, output: Data)
    case done(usage: LLMUsage?)
}

protocol LLMClient: Sendable {
    var capabilities: LLMCapabilities { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error>
}

struct LLMCapabilities: OptionSet {
    static let images         = LLMCapabilities(rawValue: 1 << 0)
    static let assistantPrefill = LLMCapabilities(rawValue: 1 << 1)
    static let tools          = LLMCapabilities(rawValue: 1 << 2)
    static let realtimeAudio  = LLMCapabilities(rawValue: 1 << 3)
    let rawValue: Int
}

// New: cursor-buddy/LLMClientRegistry.swift
enum LLMClientRegistry {
    @MainActor
    static func client(for provider: OpenClickyModelProvider,
                       companion: CompanionManager) -> LLMClient {
        switch provider {
        case .anthropic:    return FallbackChain([companion.claudeAgentSDKClient,
                                                  companion.claudeHTTPClient])
        case .openAI, .codex: return FallbackChain([companion.codexAppServerClient,
                                                    companion.openAIHTTPClient])
        case .apple:        return companion.appleFoundationClient
        case .peekyFree:    return companion.mirageClient
        case .heyclickyFree: return companion.heyClickyClient
        case .deepgram:     return companion.deepgramSurrogateClient
        }
    }
}
```

Then `analyzeVoiceResponse` collapses to:

```swift
let client = LLMClientRegistry.client(for: model.provider, companion: self)
var full = ""
for try await delta in client.stream(request) {
    if case let .text(t) = delta {
        onTextChunk(t); full += t
    }
}
return full
```

Concrete migration path (touchpoints that go away):

- `CompanionManager+AIResponsePipeline.swift:845` — dispatch becomes
  one call, no switch.
- `CompanionManager.swift:2160/2224/2780/6535` — replaced by
  `client.warmUp()` on the resolved client + `client.description` for
  analytics.
- `CompanionManager+AIResponsePipeline.swift:1437/1471` — replaced by
  `client.capabilities.contains(.pointing)` on a
  `ComputerUsePointingClient` sub-protocol.
- `provider ==` checks in `OpenClickySettingsWindowManager.swift`,
  `ChatHeaderBar.swift`, and the filler gate at
  `CompanionManager+AIResponsePipeline.swift:1119-1128` — replaced by
  capability queries on the resolved client / model option.

After migration, adding a provider is: (1) implement `LLMClient`, (2)
add a catalog entry, (3) add one line to `LLMClientRegistry.client`.
No other file changes.
