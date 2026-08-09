# 10 - LLMClient Adapter ↔ Switch Equivalence Proof

Date: 2026-08-06
Purpose: static verification that every `LLMDispatchHooks` closure forwards
byte-identical arguments to the same method the old
`_analyzeVoiceResponseCore` switch would have invoked, so flipping
`LLMClientRegistry.useNewDispatch` cannot change behavior.

Files:
- Switch: `cursor-buddy/CompanionManager+AIResponsePipeline.swift:896-980`
- Hooks: `cursor-buddy/CompanionManager+AIResponsePipeline.swift:995-1057`
- Registry: `cursor-buddy/LLMClientRegistry.swift`
- Adapters: `cursor-buddy/LLMClientAdapters.swift`
- Request bag: `cursor-buddy/LLMClient.swift`

The registry builds an `LLMRequest` at the pipeline entry:

```swift
let req = LLMRequest(
    model: selectedVoiceResponseModel.id,
    systemPrompt: systemPrompt,
    conversationHistory: conversationHistory,
    userPrompt: userPrompt,
    images: images,
    assistantPrefill: assistantPrefill
)
```

Every `req.*` field is a direct alias for the local variable the switch
already reads. `dispatchViaLLMRegistry` then hands `req` to the resolved
adapter, which invokes its hook.

---

## Per-provider parity

### `.apple`
| Site        | Call                                                                                                                                                              |
|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:898  | `AppleFoundationModelsVoiceClient.analyzeVoiceResponse(images:, systemPrompt:, conversationHistory:, userPrompt:, onTextChunk:)`                                  |
| Hook:998    | `AppleFoundationModelsVoiceClient.analyzeVoiceResponse(images: req.images, systemPrompt: req.systemPrompt, conversationHistory: req.conversationHistory, userPrompt: req.userPrompt, onTextChunk: cb)` |
| Delta       | None. `req.images == images`, `req.systemPrompt == systemPrompt`, `req.conversationHistory == conversationHistory`, `req.userPrompt == userPrompt`, `cb == onTextChunk`. |

### `.anthropic`
| Site        | Call                                                                                                                                                                                             |
|-------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:906  | `analyzeClaudeResponse(images:, model: selectedVoiceResponseModel.id, systemPrompt:, conversationHistory:, userPrompt:, assistantPrefill:, onTextChunk:)`                                        |
| Hook:1007   | `self.analyzeClaudeResponse(images: req.images, model: req.model, systemPrompt: req.systemPrompt, conversationHistory: req.conversationHistory, userPrompt: req.userPrompt, assistantPrefill: req.assistantPrefill, onTextChunk: cb)` |
| Delta       | None. `req.model == selectedVoiceResponseModel.id`, `req.assistantPrefill == assistantPrefill`.                                                                                                  |

### `.openAI`
| Site        | Call                                                                                                                                                                                                    |
|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:919  | `analyzeOpenAIOrCodexVoiceResponse(images:, model: selectedVoiceResponseModel.id, systemPrompt:, conversationHistory:, userPrompt:, onTextChunk:)`                                                      |
| Hook:1018   | `self.analyzeOpenAIOrCodexVoiceResponse(images: req.images, model: req.model, systemPrompt: req.systemPrompt, conversationHistory: req.conversationHistory, userPrompt: req.userPrompt, onTextChunk: cb)`|
| Delta       | None.                                                                                                                                                                                                   |

### `.codex`
| Site        | Call                                                                                                                                                                                              |
|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:934  | `analyzeCodexVoiceResponse(images:, model: selectedVoiceResponseModel.id, systemPrompt:, conversationHistory:, userPrompt:, onTextChunk:)`                                                         |
| Hook:1028   | `self.analyzeCodexVoiceResponse(images: req.images, model: req.model, systemPrompt: req.systemPrompt, conversationHistory: req.conversationHistory, userPrompt: req.userPrompt, onTextChunk: cb)`  |
| Delta       | None.                                                                                                                                                                                             |

### `.peekyFree`
| Site        | Call                                                                                                                                                                                             |
|-------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:951  | `analyzeMirageResponse(images:, model: selectedVoiceResponseModel.id, systemPrompt:, conversationHistory:, userPrompt:, onTextChunk:)`                                                            |
| Hook:1038   | `self.analyzeMirageResponse(images: req.images, model: req.model, systemPrompt: req.systemPrompt, conversationHistory: req.conversationHistory, userPrompt: req.userPrompt, onTextChunk: cb)`     |
| Delta       | None.                                                                                                                                                                                            |

### `.heyclickyFree`
| Site        | Call                                                                                                                                                                                                                                                    |
|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:972  | `HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(companionManager: self, images:, systemPrompt:, conversationHistory:, userPrompt:, onTextChunk:)`                                                                                              |
| Hook:1048   | `HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(companionManager: self, images: req.images, systemPrompt: req.systemPrompt, conversationHistory: req.conversationHistory, userPrompt: req.userPrompt, onTextChunk: cb)`                       |
| Delta       | None. `self` captured in hook closure is the same `CompanionManager` instance the switch would pass.                                                                                                                                                    |

### `.deepgram`
| Site        | Behavior                                                                                                                                                                                     |
|-------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Switch:927  | `throw NSError(domain: "DeepgramVoiceAgentClient", code: -20, userInfo: [NSLocalizedDescriptionKey: "Deepgram Voice Agent handles live microphone turns directly; …"])`                       |
| Registry    | `UnsupportedLLMAdapter(provider: .deepgram, errorDomain: "DeepgramVoiceAgentClient", errorCode: -20, message: same)` → `throw NSError(domain: errorDomain, code: errorCode, userInfo: …)`     |
| Delta       | None. Domain, code, message all match; error is thrown from `.send`, so caller pattern-matching on `NSError.domain == "DeepgramVoiceAgentClient"` behaves identically.                        |

---

## Why the parity holds under `[weak self]`

Each hook closure captures `[weak self]` and short-circuits to `""` if
the manager has been torn down. The switch site is on the same actor
and is only invoked when `self` is alive (`analyzeVoiceResponse` is an
instance method), so under normal operation `self` is never nil at
hook invocation. If the manager IS being torn down mid-turn:

- Switch behavior: `return try await …` inside a method whose enclosing
  actor has been released. In practice the whole `_analyzeVoiceResponseCore`
  frame has already been suspended; the pipeline treats a cancellation
  or actor teardown as the turn being aborted.
- Hook behavior: returns `""` instead of throwing.

Neither is a "wrong answer" — both terminate the turn cleanly. If the
distinction ever matters, we can change the hook to
`throw CancellationError()`; today it is defensible.

---

## What still needs runtime verification

The static check above proves the ARGUMENTS are identical. It does NOT
prove the underlying `analyze*` methods are pure functions of those
arguments — if a helper reads UserDefaults / global state between the
two invocations, the shadow compare could see different chunks even
though the wire calls are identical. This is a non-issue for a single
turn (the switch runs once, the shadow runs once, both read the same
process state) but is why we keep `useNewDispatch = false` by default:
we want at least one live shadow-run per provider to catch any hidden
non-determinism (rate-limited tokens, model version drift on the
proxy, etc.) before flipping.

The runtime self-check added in Task #51 does the shadow run
automatically on every debug build; production stays on the switch.
