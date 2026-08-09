//
//  AssistAgentBridge.swift
//  cursor-buddy
//
//  Ties the assist agent into the main dialog. Two entry points:
//
//    · `effectiveSystemPrompt(base:)` — call before every dispatch to
//      inject the [ASSIST] contract into the base system prompt when
//      the user has enabled the assist agent. This is what makes the
//      main dialog model AWARE of the tool.
//
//    · `handleModelReply(_:)` — pass the model's final reply through
//      this before showing to the user. If it carries an [ASSIST]
//      invocation, we run the assist agent inline, replace the marker
//      with the summary, and hand the transformed text back.
//
//  Barge-in: `cancelActive()` stops any live assist run. Wire this to
//  the hotkey handler and the voice-input-onset event in
//  CompanionManager.
//

import Foundation
import Combine

@MainActor
public final class AssistAgentBridge {
    public static let shared = AssistAgentBridge()

    /// The CompanionManager currently driving the main dialog. Set
    /// once during app boot in CompanionManager.init(). Used as the
    /// LLM transport for the assist agent's rounds.
    weak var companion: CompanionManager?

    /// True while an assist-agent round is running its transport. The
    /// pipeline hook checks this and skips re-injecting the [ASSIST]
    /// contract so the marker doesn't recursively re-fire.
    public var isReentrantRound: Bool = false

    private var activeTask: Task<Void, Never>?
    private var activeSession: AssistAgentSession?
    private var subscriptions = Set<AnyCancellable>()

    private init() {}

    /// Wrap the base system prompt with the [ASSIST] contract when
    /// the user has enabled the assist agent. Called by
    /// CompanionManager+AIResponsePipeline before every model
    /// dispatch.
    public static func effectiveSystemPrompt(_ base: String) -> String {
        AssistAgentPrompt.effectiveSystemPrompt(base: base)
    }

    /// Inspect a model reply. If it carries an [ASSIST] invocation,
    /// run the assist agent (blocking), then return the transformed
    /// reply with the assist summary inlined. Otherwise return the
    /// input unchanged. Called by the AI response pipeline just
    /// before the final text is spoken / displayed.
    public func handleModelReply(_ reply: String,
                                userPrompt: String? = nil,
                                progressChannel: ((String) -> Void)? = nil
    ) async -> String {
        guard AppBundleConfiguration.assistAgentEnabled() else { return reply }
        _ = userPrompt  // kept for future intent inspection
        guard let invocation = AssistAgentPrompt.parseInvocation(from: reply) else {
            return reply
        }
        progressChannel?("Consulting assist agent…")
        let result = await runInline(invocation, progress: progressChannel)
        return Self.inlineResult(reply: reply, result: result)
    }

    /// Ultra-short TTS beats (2-4 characters). Audio channel is shared
    /// with the main dialog TTS, so a long assist phrase can either
    /// cut off the main reply or get cut off by it. Detail lives in
    /// the notch badge; TTS only fires a rhythmic "still working"
    /// beat so the user knows the loop is alive.
    static func spokenPhrase(kind: String, tool: String) -> String {
        switch kind {
        case "文件内容", "文件大纲":       return "读文件"
        case "目录列表", "路径匹配":       return "找文件"
        case "搜索结果":                   return "搜代码"
        case "命令输出":                   return "跑命令"
        case "网页内容", "网络搜索":       return "查网页"
        case "查历史", "读记忆":           return "翻记录"
        case "写入完成", "局部替换",
             "批量替换", "追加片段", "差量应用": return "改文件"
        case "存记忆":                     return "记一笔"
        default:                           return "查一下"
        }
    }

    /// Cancel any in-flight assist run. Wire this to user barge-in
    /// (hotkey / voice onset). Non-blocking.
    public func cancelActive() {
        activeTask?.cancel()
        if let session = activeSession {
            session.emit(AssistAgentEvent(
                kind: .info, round: 0,
                data: ["message": .string("cancelled by user barge-in")]))
        }
    }

    // MARK: - Private

    /// Run the assist agent inline. Returns a text summary safe to
    /// splice back into the main model's reply. When the loop is
    /// cancelled or throws, returns a short "unavailable" message
    /// so the main dialog can still finish gracefully.
    private func runInline(_ invocation: AssistAgentPrompt.Invocation,
                          progress: ((String) -> Void)?
    ) async -> String {
        // Fresh session per invocation. Disk resume was too eager —
        // it fired on any substring match with a past task and
        // stamped that task's pinnedMemory + digest onto the new
        // request, poisoning the model with unrelated context.
        // Resume is still available via AssistAgentSession.fromTask(
        // tryResumeFromDisk: true) for callers who explicitly opt in.
        let session = AssistAgentSession.fromTask(
            invocation.goal, tryResumeFromDisk: false)
        self.activeSession = session
        defer { self.activeSession = nil }

        AssistAgentRegistry.shared.bindEventStream(
            session, label: "research", email: currentAccountEmail())
            .store(in: &subscriptions)

        // Audio vs UI split (user rule):
        //   · IMPORTANT (state transitions the user must know) → TTS
        //   · ROUTINE (per-round progress) → notch UI only
        //
        // Important events:
        //   · turn_start round 1 — "已经开始查了" (short)
        //   · sessionHop — "换会话重试"
        //   · error (non-content-filter) — "出错了,已停下"
        //   · content-filter — handled in outcome switch with FULL
        //     phrase explaining why (bypasses throttle)
        //   · done — handled in outcome switch with "好了" (short)
        //
        // Routine events (UI only via registry, not spoken):
        //   · every toolCall — notch shows the tool phrase
        //   · toolResult — notch shows ✓/✗ + phrase
        //   · info (empty/nudge/rotate progress) — notch text updates
        //   · compactBoundary — notch shows "压缩了 N 步"
        // Audio channel is contended with realtime speech mode —
        // if realtime plays its own quick acknowledgement, our TTS
        // beats will overlap and sound like double-speech. So we
        // do NOT play per-round beats at all. Notch UI covers
        // routine progress. Only TERMINAL failure states speak —
        // they matter enough that the user must hear them even at
        // the cost of momentary overlap.
        // Unified voice channel: only ONE speaker at a time.
        // Realtime already owns the audio channel for the voice
        // scene (plays "好的,我看看屏幕" ack + eventually the
        // final answer). Assist agent progress goes UI-only via
        // AssistAgentRegistry → notch badge. TTS is fully silent
        // during the loop, including terminal errors — those show
        // as an orange badge in the notch that stays 15 seconds.
        //
        // The bridge's `progress?()` calls in the outcome switch
        // below (filter / failed) still fire, but those go through
        // the same TTS pipeline that's already gated by realtime
        // busy-state.
        session.events.sink { _ in
            // Silent — notch UI is the sole progress surface during
            // an assist run. Avoids audio-channel contention with
            // realtime.
        }.store(in: &subscriptions)

        // Wrap the loop result with distinct outcomes so we can tell
        // the user WHY it stopped, not just that it did.
        enum RunOutcome { case ok(AssistAgentResult)
                          case filtered(String)
                          case failed(Error) }
        let task = Task { [invocation] () -> RunOutcome in
            do {
                let loop = try makeLoop(session: session, invocation: invocation)
                return .ok(try await loop.run())
            } catch let AssistAgentLoopError.contentFilterHit(source) {
                return .filtered(source)
            } catch {
                return .failed(error)
            }
        }
        // Store cancellation handle. The inner `task` is what does the
        // work; a wrapper Task<Void,Never> lets `cancelActive()` reach
        // through to it via cancel.
        self.activeTask = Task { _ = await task.value }
        let outcome = await task.value
        self.activeTask = nil
        switch outcome {
        case .ok(let result):
            var payload = result.summary
            if !result.citations.isEmpty {
                let refs = result.citations.prefix(6)
                    .map { c in "\(c.file)\(c.line.map { ":\($0)" } ?? "")" }
                    .joined(separator: ", ")
                payload += "\n[refs: \(refs)]"
            }
            if !result.unresolved.isEmpty {
                payload += "\n[unresolved: \(result.unresolved.joined(separator: "; "))]"
            }
            progress?("好了")
            return payload
        case .filtered(let source):
            // User-facing explanation: what was blocked + suggested
            // next action. Emit to (a) TTS via progress channel,
            // (b) notch registry via .error event so the message stays
            // pinned to the badge instead of fading with "done".
            let short = "内容被服务端过滤 · \(String(source.suffix(40)))"
            let full = "内容被服务端过滤了。原因很可能是 `\(String(source.suffix(80)))` 里含有敏感内容(比如后门/密码/子进程执行等模式)。换一个中性文件或简化问题再试。"
            progress?(full)
            session.emit(AssistAgentEvent(
                kind: .error, round: 0,
                data: ["error": .string(short),
                       "kind": .string("content_filter"),
                       "source": .string(source)]))
            return full
        case .failed(let err):
            // Non-filter failures still deserve a user-visible reason
            // (network / cold-start-give-up / circuit breaker / etc.)
            // — salvage what we have AND explain why we stopped.
            let reasonPhrase: String = {
                if let loopErr = err as? AssistAgentLoopError {
                    switch loopErr {
                    case .emptyResponseGaveUp:
                        return "服务端连续没响应,先给你目前查到的"
                    case .maxRoundsExhausted:
                        return "达到最大轮次,先给你目前查到的"
                    case .circuitBreakerTripped:
                        return "同样的错误反复出现,已停下"
                    case .transportFailure(let s):
                        return "网络出错:\(String(s.prefix(60)))"
                    case .contentFilterHit:
                        return "内容被过滤"  // shouldn't reach here
                    }
                }
                return "助理没查到有用信息"
            }()
            let partial = Self.salvagePartial(session)
            progress?(reasonPhrase)
            session.emit(AssistAgentEvent(
                kind: .error, round: 0,
                data: ["error": .string(reasonPhrase)]))
            return partial.isEmpty
                ? "\(reasonPhrase),先直接答吧。"
                : "\(reasonPhrase):\n\(partial)"
        }
    }

    private func makeLoop(session: AssistAgentSession,
                         invocation: AssistAgentPrompt.Invocation) throws -> AssistAgentLoop {
        // Reuse the main-dialog's selected provider so the assist agent
        // inherits its auth + quota + streaming stack.
        guard let cm = companion else {
            throw NSError(domain: "AssistAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "companion not bound"])
        }
        // Direct-transport: assist loop rounds hit /chat-tool-call
        // directly with the Python-parity body shape (query + tool
        // menu + prior). Bypasses HeyClickyChatToolCallClient's
        // preflight + UI-action decoding, since the assist loop
        // wants raw model text to JSON-extract.
        let transport = AssistAgentDirectTransport()
        _ = cm  // companion no longer needed for LLM transport

        let tools = AssistAgentBuiltInTools()
        let system = AssistAgentPrompt.loopSystemPrompt(
            goal: invocation.goal,
            workdir: invocation.workdir,
            maxRounds: invocation.maxRounds)
        return AssistAgentLoop(
            session: session, transport: transport, dispatcher: tools,
            systemPrompt: system, maxRounds: invocation.maxRounds)
    }

    private func currentAccountEmail() -> String {
        AppBundleConfiguration.heyClickyReadKeychainSecret(
            forKey: AppBundleConfiguration.heyClickySessionUserEmailDefaultsKey) ?? ""
    }

    /// Best-effort text extract from a session when the loop threw.
    /// Same shape as AssistAgentLoop.buildPartialSummary but static
    /// so it works after the loop object is gone.
    private static func salvagePartial(_ session: AssistAgentSession) -> String {
        let successful = session.steps
            .filter { $0.ok && $0.kind != "_reminder" }
            .suffix(5)
        guard !successful.isEmpty else { return "" }
        var lines: [String] = ["助理探索中止,已查到:"]
        for s in successful {
            let arg = s.args["path"] ?? s.args["cmd"] ?? s.args["url"]
                ?? s.args["pattern"] ?? ""
            let head = s.result
                .split(separator: "\n").first
                .map { $0.count > 100 ? String($0.prefix(100)) + "…" : String($0) } ?? ""
            lines.append("  \(s.kind) \(String(arg.prefix(60))): \(head)")
        }
        return lines.joined(separator: "\n")
    }

    private static func inlineResult(reply: String, result: String) -> String {
        // Strip the [ASSIST] {...} line entirely and append the result
        // as an "[assist-agent] …" block the caller can render.
        guard let markerRange = reply.range(of: AssistAgentPrompt.requestMarker) else {
            return reply + "\n\n[assist-agent]\n" + result
        }
        // Find the line containing the marker + strip through the closing brace.
        let head = reply[..<markerRange.lowerBound]
        let tail = reply[markerRange.upperBound...]
        var afterJSON = tail
        if let braceStart = afterJSON.firstIndex(of: "{") {
            var depth = 0
            var end = braceStart
            var i = braceStart
            while i < afterJSON.endIndex {
                let c = afterJSON[i]
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = afterJSON.index(after: i); break }
                }
                i = afterJSON.index(after: i)
            }
            afterJSON = afterJSON[end...]
        }
        return String(head).trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n[assist-agent]\n" + result
            + "\n" + String(afterJSON).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Companion-backed transport (default)

/// Concrete transport that routes each round through
/// `CompanionManager.analyzeVoiceResponse` — reuses whatever model the
/// user has selected for the main dialog. That way the assist agent
/// automatically inherits the same auth / quota / provider stack.
final class CompanionAssistTransport: AssistAgentTransport, @unchecked Sendable {
    // weak on MainActor-isolated instance — captured through a
    // MainActor hop below.
    private weak var companion: CompanionManager?

    init(companion: CompanionManager) { self.companion = companion }

    public func ask(prior: String, priorImage: Data?, systemPrompt: String)
        async throws -> AssistAgentTransportReply
    {
        let started = Date()
        let text = try await MainActor.run { [weak companion] () -> Task<String, Error> in
            let cm = companion
            return Task { @MainActor in
                guard let cm else {
                    throw NSError(domain: "AssistAgent", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "companion manager gone"])
                }
                AssistAgentBridge.shared.isReentrantRound = true
                defer { AssistAgentBridge.shared.isReentrantRound = false }
                return try await cm.analyzeVoiceResponse(
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: prior,
                    assistantPrefill: nil,
                    onTextChunk: { _ in })
            }
        }.value
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        return AssistAgentTransportReply(text: text, elapsedMs: elapsedMs)
    }
}
