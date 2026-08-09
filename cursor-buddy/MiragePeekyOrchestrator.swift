//
//  MiragePeekyOrchestrator.swift
//  cursor-buddy
//
//  Turn-level orchestrator for the Peeky-mirage pipeline. One instance
//  per running turn; runs the 3-tier intent classifier + dispatches to
//  the matching branch (chat / find_action / integration / memory /
//  agent). Ports peeky/src/orchestrator.rs semantics, minus the pieces
//  OpenClicky already handles (audio capture, hotkey, screen capture,
//  TTS playback) — those are provided by the surrounding pipeline
//  through the injected callbacks.
//
//  Classification tiers (matches Peeky orchestrator.rs:133-263):
//    1. Agent cue: transcript starting with "openclicky agent," /
//       "peeky agent," routes straight to Agent with the cue stripped.
//    2. Keyword allowlist (intent.rs port): bare transport commands
//       like "play" / "pause" / "next track" → Integration.
//    3. Claude classifier fallback with a forced tool call.
//
//  Every intent branch shares the same MirageBackendClient + the same
//  screenshot the caller supplied; only the system prompt + tool subset
//  differ. See MiragePrompts and MiragePeekyTools for the exact wire
//  payloads.

import Foundation

enum MirageIntent: String {
    case chat, findAction = "find_action", integration, memory, agent
}

/// Result of a completed orchestrator turn. Carries whichever surface
/// the calling UI needs: streamed text (for chat/agent narration),
/// executed tool calls (for the overlay to visualize), and the raw
/// classifier decision (for logging).
struct MirageTurnResult {
    let intent: MirageIntent
    let text: String
    let toolCalls: [MirageToolCall]
    let error: Error?
}

struct MirageToolCall {
    let name: String
    let input: [String: Any]
    let result: MirageToolResult
}

actor MiragePeekyOrchestrator {
    static let shared = MiragePeekyOrchestrator()

    /// Public entry — one full turn end-to-end. Streams text via
    /// `onTextChunk` so the caller can spool it into TTS as it arrives.
    ///
    /// - Parameters:
    ///   - transcript: user's voice → text (whisper local or mirage
    ///     Deepgram).
    ///   - screenshotJPEGBase64: pre-turn screenshot, resized to the
    ///     Claude-friendly dimensions (see Peeky's pick_declared_resolution).
    ///     Nil for chat/memory paths that don't need the screen; the
    ///     orchestrator will still classify without it.
    ///   - declaredWidth / declaredHeight: coordinate space the computer
    ///     tool should use (matches the resized screenshot).
    ///   - modelForBranches: mirage catalog id used for the branch calls
    ///     (default = user's `openClickyMirageAgentModel`).
    ///   - onTextChunk: streaming callback for text_delta events.
    ///     Called on the caller's queue.
    func runTurn(
        transcript: String,
        screenshotJPEGBase64: String? = nil,
        declaredWidth: Int = 1280,
        declaredHeight: Int = 800,
        modelForBranches: String? = nil,
        contextBrief: String? = nil,
        onTextChunk: @escaping (String) -> Void = { _ in },
        /// Structured event callback for the agent branch. Emits every
        /// Claude Code CLI event (`assistant`, `tool_use`, `tool_result`,
        /// `system`) so the pipeline layer can mirror it into the shim
        /// CodexAgentSession, giving Chat / MiniChat live progress the
        /// same way Codex sessions do. No-op for non-agent branches.
        onAgentEvent: @escaping (MirageAgentEvent) -> Void = { _ in }
    ) async -> MirageTurnResult {
        let intent = await classify(transcript: transcript)

        do {
            switch intent {
            case .chat:
                let text = try await runChat(
                    transcript: transcript,
                    screenshotBase64: screenshotJPEGBase64,
                    model: modelForBranches,
                    contextBrief: contextBrief,
                    onTextChunk: onTextChunk
                )
                return .init(intent: intent, text: text, toolCalls: [], error: nil)

            case .findAction:
                let (text, calls) = try await runFindAction(
                    transcript: transcript,
                    screenshotBase64: screenshotJPEGBase64 ?? "",
                    declaredWidth: declaredWidth,
                    declaredHeight: declaredHeight,
                    model: modelForBranches,
                    contextBrief: contextBrief
                )
                return .init(intent: intent, text: text, toolCalls: calls, error: nil)

            case .integration:
                let (text, calls) = try await runIntegration(
                    transcript: transcript,
                    model: modelForBranches,
                    contextBrief: contextBrief,
                    onTextChunk: onTextChunk
                )
                return .init(intent: intent, text: text, toolCalls: calls, error: nil)

            case .memory:
                let (text, calls) = try await runMemory(
                    transcript: transcript,
                    model: modelForBranches,
                    contextBrief: contextBrief
                )
                return .init(intent: intent, text: text, toolCalls: calls, error: nil)

            case .agent:
                let (text, calls) = try await runAgent(
                    transcript: transcript,
                    screenshotBase64: screenshotJPEGBase64 ?? "",
                    declaredWidth: declaredWidth,
                    declaredHeight: declaredHeight,
                    onAgentEvent: onAgentEvent,
                    model: modelForBranches,
                    contextBrief: contextBrief,
                    onTextChunk: onTextChunk
                )
                return .init(intent: intent, text: text, toolCalls: calls, error: nil)
            }
        } catch {
            return .init(intent: intent, text: "", toolCalls: [], error: error)
        }
    }

    /// Extract a plausible working directory from the context brief. Scans
    /// for absolute paths embedded in the "focused_window:" / "everywhere:"
    /// lines (VS Code / Terminal / iTerm typically show the project path
    /// in their window title, e.g. "openclicky — cmux"). Returns nil when
    /// no valid directory can be identified, letting ClaudeAgentRunner
    /// fall back to its Settings default.
    static func detectFolderInBrief(_ contextBrief: String?) -> URL? {
        guard let brief = contextBrief else { return nil }
        // Look for /Users/... paths in the brief. Coarse but effective —
        // OpenClicky's UtteranceContext lines include app-provided paths
        // when Finder / VSCode / Terminal supply them.
        let pattern = #"(/Users/[^\s"'\)\]]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = brief as NSString
        let matches = regex.matches(in: brief, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let raw = ns.substring(with: match.range)
            // Trim trailing punctuation that regex snagged.
            let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            // Only accept if it's an existing directory. This filters out
            // file paths and paths from other users.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
            // If it's a file, use its parent directory.
            if FileManager.default.fileExists(atPath: path) {
                let parent = (path as NSString).deletingLastPathComponent
                if FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: parent)
                }
            }
        }
        return nil
    }

    /// Merge Peeky's baseline system prompt with the OpenClicky context brief
    /// so the model sees "focused_window / ltm / xlb / clipboard / mcp url"
    /// alongside the Peeky base instructions. Nil brief → return baseline.
    private func mergeSystem(_ base: String, _ contextBrief: String?) -> String {
        guard let brief = contextBrief, !brief.isEmpty else { return base }
        return base + "\n\n" + brief
    }

    // MARK: - Classification (3 tiers)

    /// Confidence threshold for accepting an on-device routelet answer.
    /// Peeky ships this at 0.85 in `tuning.rs::ROUTELET_CONFIDENCE_
    /// THRESHOLD`; below it we defer to Claude. Keeping the same value
    /// preserves the routelet's calibrated accuracy trade-off.
    private static let routeletConfidenceThreshold: Float = 0.85

    /// Four-tier classification, in Peeky orchestrator.rs order:
    ///   1. Agent voice cue ("openclicky agent, X") — sub-µs prefix.
    ///   2. Keyword allowlist — sub-µs exact match for bare transport
    ///      commands ("play" / "pause" / …).
    ///   3. On-device routelet (ONNX embedder + linear head, ~45ms)
    ///      via `OpenClickyIntentClassifier`. Accepted when confidence
    ///      ≥ 0.85 AND the label is not `.none` (reject class).
    ///   4. Claude forced tool call — ~250-700ms, one mirage HTTP
    ///      round-trip. Only reached when tiers 1–3 abstained.
    ///
    /// If everything abstains the failsafe is `.chat` (matches Peeky).
    func classify(transcript: String) async -> MirageIntent {
        if agentCue(transcript) != nil { return .agent }
        if let k = keywordClassify(transcript) { return k }
        if let r = await routeletClassify(transcript) { return r }
        if let c = await claudeClassify(transcript) { return c }
        return .chat
    }

    /// Tier 3 — the local ONNX classifier. Returns nil when the
    /// classifier abstains (low confidence, reject class, or the ONNX
    /// runtime isn't wired yet). The orchestrator falls through to
    /// tier 4 (Claude) on nil. Routelet has no `.agent` output by
    /// design — agent turns go through the voice cue in tier 1.
    func routeletClassify(_ transcript: String) async -> MirageIntent? {
        guard let prediction = await OpenClickyIntentClassifier.shared.classify(transcript) else {
            return nil
        }
        // Reject class → let Claude decide.
        if prediction.intent == .none { return nil }
        // Below threshold → let Claude decide.
        if prediction.confidence < Self.routeletConfidenceThreshold { return nil }
        // Map from OpenClickyIntent (generic) into MirageIntent (mirage-
        // scoped). The two enums share the same string raw values so a
        // rawValue-based bridge is exact.
        return MirageIntent(rawValue: prediction.intent.rawValue)
    }

    /// Bare "openclicky agent, X" / "peeky agent, X" prefix. Returns the
    /// stripped task text if a cue matched (caller may use it), or nil.
    func agentCue(_ transcript: String) -> String? {
        let lower = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["openclicky agent,", "peeky agent,", "openclicky agent ", "peeky agent "] {
            if lower.hasPrefix(prefix) {
                let stripped = String(transcript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped
            }
        }
        return nil
    }

    /// Sub-millisecond allowlist for bare transport commands. Port of
    /// peeky/src/intent.rs::keyword_classify.
    func keywordClassify(_ transcript: String) -> MirageIntent? {
        let lower = transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hits: Set<String> = [
            "play", "pause", "resume", "stop", "mute", "unmute", "skip", "next",
            "next song", "next track", "previous", "previous song", "previous track"
        ]
        return hits.contains(lower) ? .integration : nil
    }

    /// Claude classifier fallback with a forced tool call. Blocks on one
    /// mirage HTTP round-trip (~250-700ms). See MiragePrompts.classifier.
    func claudeClassify(_ transcript: String) async -> MirageIntent? {
        let body: [String: Any] = [
            "model": "mirage/claude-haiku-4-5-20251001",   // cheapest tier
            "max_tokens": 80,
            "stream": false,
            "system": MiragePrompts.classifier,
            "tools": [MiragePeekyTools.classifierTool],
            "tool_choice": ["type": "tool", "name": "classify"],
            "messages": [["role": "user", "content": transcript]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        do {
            let (respData, status) = try await MirageBackendClient.shared.send(body: data)
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else { return nil }
            for block in content {
                if (block["type"] as? String) == "tool_use",
                   let input = block["input"] as? [String: Any],
                   let category = input["category"] as? String {
                    return MirageIntent(rawValue: category)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Branches

    private func defaultModel(_ override: String?) -> String {
        if let m = override, !m.isEmpty { return m }
        return UserDefaults.standard.string(forKey: ClaudeAgentRunner.claudeAgentModelDefaultsKey)
            ?? ClaudeAgentRunner.defaultAgentModelCatalogID
    }

    private func runChat(transcript: String,
                         screenshotBase64: String?,
                         model: String?,
                         contextBrief: String?,
                         onTextChunk: @escaping (String) -> Void) async throws -> String {
        var content: [[String: Any]] = []
        if let img = screenshotBase64, !img.isEmpty {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": img
                ]
            ])
        }
        content.append(["type": "text", "text": transcript])

        let body: [String: Any] = [
            "model": defaultModel(model),
            "max_tokens": 512,
            "stream": true,
            "system": mergeSystem(MiragePrompts.chat, contextBrief),
            "messages": [["role": "user", "content": content]]
        ]
        return try await streamText(body: body, onTextChunk: onTextChunk)
    }

    private func runFindAction(transcript: String,
                               screenshotBase64: String,
                               declaredWidth: Int,
                               declaredHeight: Int,
                               model: String?,
                               contextBrief: String?) async throws -> (String, [MirageToolCall]) {
        let tools = MiragePeekyTools.desktopCore(
            declaredWidthPx: declaredWidth,
            declaredHeightPx: declaredHeight
        )
        let content: [[String: Any]] = [
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshotBase64]],
            ["type": "text", "text": transcript]
        ]
        let body: [String: Any] = [
            "model": defaultModel(model),
            "max_tokens": 512,
            "stream": false,
            "system": mergeSystem(MiragePrompts.findAction, contextBrief),
            "tools": tools,
            "messages": [["role": "user", "content": content]]
        ]
        let (respData, _) = try await sendNonStreaming(body: body)
        let (text, uses) = parseAssistant(respData)
        var executed: [MirageToolCall] = []
        for use in uses {
            let result = await MirageToolAdapter.dispatch(name: use.name, input: use.input)
            executed.append(.init(name: use.name, input: use.input, result: result))
        }
        // find_action's system prompt discourages narration when a tool
        // fires (Peeky ships it that way). When Claude actually returns
        // nothing spoken but a tool DID run, synthesize a minimal
        // confirmation so the caller has speakable text and the notch
        // has something to display.
        //
        // If NO tool ran either (screenshot missing or Claude refused),
        // fall back to a spoken hint instead of silent-fail. Real bug:
        // an empty text + empty tool list is invisible to the user.
        if text.isEmpty {
            if let first = executed.first {
                let synthetic: String
                switch first.result {
                case .ok:
                    synthetic = "Done."
                case .error(let msg):
                    synthetic = "Sorry, that didn't work: \(msg.prefix(80))"
                }
                return (synthetic, executed)
            }
            // No tool ran, no text: most common cause is a missing or
            // low-quality screenshot. Speak a hint so the user knows why.
            return ("I couldn't figure out where to click — try again with a clearer view of the target.", executed)
        }
        return (text, executed)
    }

    /// Port of Peeky's INTEGRATION_MAX_TOOL_CALLS from tuning.rs. Caps the
    /// tool-chain length so "find that pdf then open it" gets both calls
    /// but a runaway loop stops after 3.
    private static let integrationMaxToolCalls = 3

    /// Bounded tool loop matching peeky's Claude::integration:
    ///   * First call: tool_choice=any (Claude must pick a tool).
    ///   * Subsequent calls: tool_choice=auto (chain another tool OR
    ///     emit the spoken summary).
    ///   * If budget spent while still chaining: force tool_choice=none
    ///     so the turn always ends in speech.
    /// Each tool result gets fed back to the model so the next round has
    /// full context.
    private func runIntegration(transcript: String,
                                model: String?,
                                contextBrief: String?,
                                onTextChunk: @escaping (String) -> Void) async throws -> (String, [MirageToolCall]) {
        let availability = MirageMacIntegrations.availability()
        let integrations = MiragePeekyTools.integrationTools(available: availability)
        let modelID = defaultModel(model)
        let system = mergeSystem(MiragePrompts.integration(), contextBrief)

        var messages: [[String: Any]] = [["role": "user", "content": transcript]]
        var spoken = ""
        var executed: [MirageToolCall] = []

        for call in 1...Self.integrationMaxToolCalls {
            let toolChoice: [String: Any] = call == 1
                ? ["type": "any"]
                : ["type": "auto"]
            let body: [String: Any] = [
                "model": modelID,
                "max_tokens": 1024,
                "stream": false,
                "system": system,
                "tools": integrations,
                "tool_choice": toolChoice,
                "messages": messages
            ]
            let (respData, _) = try await sendNonStreaming(body: body)
            let (roundText, uses, toolID) = parseAssistantWithIDs(respData)
            if !roundText.isEmpty {
                spoken += roundText
                onTextChunk(roundText)
            }

            guard let firstUse = uses.first, let useID = toolID else {
                // Text-only response: the chain is done, this was the summary.
                return (spoken, executed)
            }

            let result = await MirageToolAdapter.dispatch(name: firstUse.name, input: firstUse.input)
            executed.append(.init(name: firstUse.name, input: firstUse.input, result: result))

            // Append assistant turn (narration + tool_use) and the tool_result
            // so the next round sees the outcome.
            var assistantContent: [[String: Any]] = []
            if !roundText.trimmingCharacters(in: .whitespaces).isEmpty {
                assistantContent.append(["type": "text", "text": roundText])
            }
            assistantContent.append([
                "type": "tool_use",
                "id": useID,
                "name": firstUse.name,
                "input": firstUse.input
            ])
            messages.append(["role": "assistant", "content": assistantContent])
            messages.append([
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": useID,
                    "content": result.stringValue
                ]]
            ])
            _ = call
        }

        // Budget spent — force a text-only summary so the turn ends in speech.
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 1024,
            "stream": false,
            "system": system,
            "tools": integrations,
            "tool_choice": ["type": "none"],
            "messages": messages
        ]
        let (respData, _) = try await sendNonStreaming(body: body)
        let (finalText, _, _) = parseAssistantWithIDs(respData)
        if !finalText.isEmpty {
            spoken += finalText
            onTextChunk(finalText)
        }
        return (spoken, executed)
    }

    /// Same as parseAssistant but also surfaces the first tool_use's
    /// block id — needed to pair with the follow-up tool_result. Multi-
    /// tool responses collapse to the first block, matching Peeky's
    /// single-pick-per-round behavior.
    private func parseAssistantWithIDs(_ respData: Data)
        -> (text: String, uses: [(name: String, input: [String: Any])], firstToolID: String?)
    {
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            return ("", [], nil)
        }
        var text = ""
        var uses: [(String, [String: Any])] = []
        var firstToolID: String? = nil
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { text += t }
            case "tool_use":
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if !name.isEmpty {
                    uses.append((name, input))
                    if firstToolID == nil { firstToolID = block["id"] as? String }
                }
            default: break
            }
        }
        return (text, uses.map { (name: $0.0, input: $0.1) }, firstToolID)
    }

    private func runMemory(transcript: String,
                           model: String?,
                           contextBrief: String?) async throws -> (String, [MirageToolCall]) {
        let body: [String: Any] = [
            "model": defaultModel(model),
            "max_tokens": 256,
            "stream": false,
            "system": mergeSystem(MiragePrompts.memory, contextBrief),
            "tools": MiragePeekyTools.memoryTools,
            "tool_choice": ["type": "any"],
            "messages": [["role": "user", "content": transcript]]
        ]
        let (respData, _) = try await sendNonStreaming(body: body)
        let (text, uses) = parseAssistant(respData)
        var executed: [MirageToolCall] = []
        for use in uses {
            let result = await MirageToolAdapter.dispatch(name: use.name, input: use.input)
            executed.append(.init(name: use.name, input: use.input, result: result))
        }
        // Memory tools return terse status strings; synthesize a
        // user-friendly spoken confirmation when the model itself
        // returned no summary (typical: `tool_choice: any` = the model
        // fires the tool and nothing else). Peeky's Rust `run_memory`
        // does the equivalent via a canned reply.
        if text.isEmpty, let first = executed.first {
            let synthetic: String
            switch (first.name, first.result) {
            case ("store_fact", .ok):
                synthetic = "Got it, I'll remember that."
            case ("recall_fact", .ok(let value)):
                synthetic = value.hasPrefix("no stored value") ? "I don't have that saved yet." : value
            case ("recall_conversation", .ok(let value)):
                synthetic = value.isEmpty ? "We haven't spoken yet." : value
            case (_, .error(let msg)):
                synthetic = "Memory failed: \(msg.prefix(80))"
            default:
                synthetic = "Done."
            }
            return (synthetic, executed)
        }
        return (text, executed)
    }

    /// Multi-step agent loop. Delegates to the local Claude Code
    /// process (ClaudeAgentRunner) when it's available so we get a
    /// real agentic driver; falls back to a single-turn planning call
    /// when Claude Code isn't installed.
    private func runAgent(transcript: String,
                          screenshotBase64: String,
                          declaredWidth: Int,
                          declaredHeight: Int,
                          onAgentEvent: @escaping (MirageAgentEvent) -> Void = { _ in },
                          model: String?,
                          contextBrief: String?,
                          onTextChunk: @escaping (String) -> Void) async throws -> (String, [MirageToolCall]) {
        // If the Claude Code CLI is on disk, hand off to it — it brings
        // planning + sub-agents + real tool use, and our relay routes
        // its API traffic through mirage. The OpenClicky context brief
        // (LTM / xlb / stash / focused window / clipboard / MCP URL) is
        // prefixed to the prompt so the CLI sees the same signals SKI's
        // file-bridge would supply.
        if let _ = ClaudeAgentRunner.locateClaudeBinary() {
            let runner = ClaudeAgentRunner()
            let promptWithContext: String
            if let brief = contextBrief, !brief.isEmpty {
                promptWithContext = brief + "\n\nUser said: " + transcript
            } else {
                promptWithContext = transcript
            }
            // Auto-derive cwd from context brief when it mentions a
            // folder ("focused_window:" line often has a project path).
            // Falls through to Settings default when nothing detected.
            let detectedCwd = Self.detectFolderInBrief(contextBrief)
            let stream = try await runner.run(
                prompt: promptWithContext,
                model: model,
                workingDirectory: detectedCwd
            )
            var text = ""
            for try await event in stream {
                // Bubble the raw event up so the pipeline layer can
                // mirror it into the shim's transcript (thinking /
                // tool_use / tool_result all flow through here).
                onAgentEvent(event)
                if event.type == "assistant",
                   let msg = event.raw["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "text" {
                        if let t = block["text"] as? String {
                            text += t
                            onTextChunk(t)
                        }
                    }
                }
            }
            return (text, [])
        }

        // Fallback: single-turn planning call with the full agent tool
        // set. No inner loop — the user gets one round of tool_use
        // execution and a spoken summary.
        let tools = MiragePeekyTools.desktopCore(
            declaredWidthPx: declaredWidth,
            declaredHeightPx: declaredHeight
        ) + MiragePeekyTools.integrationTools(available: MirageMacIntegrations.availability())
        let content: [[String: Any]] = [
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshotBase64]],
            ["type": "text", "text": transcript]
        ]
        let body: [String: Any] = [
            "model": defaultModel(model),
            "max_tokens": 4096,
            "stream": false,
            "system": mergeSystem(MiragePrompts.agent, contextBrief),
            "tools": tools,
            "messages": [["role": "user", "content": content]]
        ]
        let (respData, _) = try await sendNonStreaming(body: body)
        let (text, uses) = parseAssistant(respData)
        var executed: [MirageToolCall] = []
        for use in uses {
            let result = await MirageToolAdapter.dispatch(name: use.name, input: use.input)
            executed.append(.init(name: use.name, input: use.input, result: result))
        }
        if !text.isEmpty { onTextChunk(text) }
        return (text, executed)
    }

    // MARK: - Transport helpers

    private func sendNonStreaming(body: [String: Any]) async throws -> (Data, Int) {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await MirageBackendClient.shared.send(body: data)
    }

    /// Small local parser matching Peeky's SSE assistant extraction.
    private func parseAssistant(_ respData: Data) -> (text: String, uses: [(name: String, input: [String: Any])]) {
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            return ("", [])
        }
        var text = ""
        var uses: [(String, [String: Any])] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { text += t }
            case "tool_use":
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if !name.isEmpty { uses.append((name, input)) }
            default: break
            }
        }
        return (text, uses.map { (name: $0.0, input: $0.1) })
    }

    /// Streaming SSE consumer that yields `content_block_delta.text_delta`
    /// values to the caller. Terminates on `message_stop` / stream end.
    private func streamText(body: [String: Any],
                            onTextChunk: @escaping (String) -> Void) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body)
        let (stream, status) = try await MirageBackendClient.shared.sendStreamingChunks(body: data)
        guard status == 200 else {
            var buf = Data()
            for try await c in stream { buf.append(c) }
            throw NSError(domain: "MiragePeekyOrchestrator",
                          code: status,
                          userInfo: [NSLocalizedDescriptionKey: "upstream \(status)"])
        }
        // Shared Anthropic SSE parser handles the wire format; the only
        // caller-specific behavior is `onTextChunk` (routed to caller).
        // Errors surfaced by the parser bubble up unchanged.
        return try await AnthropicSSEStream.drainTextDeltas(
            stream, onTextChunk: onTextChunk)
    }
}
