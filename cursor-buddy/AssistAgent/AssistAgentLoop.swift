//
//  AssistAgentLoop.swift
//  cursor-buddy
//
//  Multi-round think→tool→result loop for the in-App assist agent.
//  Port of heyclicky_agent/agent.py::run(), stripped to the App's
//  needs:
//    · no CLI TUI concerns
//    · no long-run PROGRESS.md driver (that's Stage 7)
//    · no client retry / cold-start throttle (goes through App network stack)
//
//  Depends on:
//    · AssistAgentSession — state
//    · AssistAgentEvent   — progress notifications
//    · AssistAgentJSON    — tolerant JSON parsing
//    · AssistAgentTransport (this file) — pluggable model-call surface
//    · AssistAgentToolDispatcher — stage 2 hook (defined here as protocol only)
//

import Foundation

/// Pluggable model-call surface so tests and prod share one loop.
/// The real implementation (Stage 10) wraps HeyClickyChatToolCallClient
/// to reuse the App's authenticated proxy connection.
public protocol AssistAgentTransport: Sendable {
    /// Send the current prior to the model and return the raw reply.
    /// Called once per round. Non-streaming; the assist loop is
    /// intentionally synchronous.
    func ask(prior: String, priorImage: Data?, systemPrompt: String) async throws -> AssistAgentTransportReply

    /// Cycle the transport's session id. Called by the loop when the
    /// server session appears poisoned (>=3 empty replies at the AIMD
    /// floor). Default: no-op — pure transports that don't carry
    /// server-side session memory don't need it. Returns a short
    /// preview of the NEW session id, for logging.
    func rotateSession() -> String

    /// Swap the credential to a different exported account. Called
    /// after session_rotate alone didn't clear the empty streak.
    /// Returns the new account's email when hopped, "" when no
    /// suitable candidate. Default: no-op.
    func hopAccount() -> String

    /// Feed the per-call outcome into the account quality ledger.
    /// Default: no-op (single-account transports don't rank).
    func recordCallResult(ok: Bool)
}

public extension AssistAgentTransport {
    func rotateSession() -> String { "" }
    func hopAccount() -> String { "" }
    func recordCallResult(ok: Bool) {}
}

public struct AssistAgentTransportReply: Sendable {
    public let text: String
    /// Server-measured elapsed for telemetry; 0 when unknown.
    public let elapsedMs: Int
    public init(text: String, elapsedMs: Int = 0) {
        self.text = text
        self.elapsedMs = elapsedMs
    }
}

/// Injectable dispatcher — stage 2 provides the concrete implementation.
/// Kept as a protocol so the loop compiles independently of the tools.
public protocol AssistAgentToolDispatcher: Sendable {
    /// Execute one tool call and return a compacted user-facing result
    /// suitable for prior injection.
    func dispatch(kind: String, tool: String, args: [String: String]) async throws -> AssistAgentToolOutcome
}

public struct AssistAgentToolOutcome: Sendable {
    public let ok: Bool
    /// Compacted (short) result for prior injection.
    public let summary: String
    /// Full raw result for debug / event stream.
    public let raw: String
    public init(ok: Bool, summary: String, raw: String) {
        self.ok = ok
        self.summary = summary
        self.raw = raw
    }
}

/// Errors the loop surfaces to callers (main dialog / research tool).
public enum AssistAgentLoopError: Error, Sendable {
    case emptyResponseGaveUp        // consecutive empties exceeded threshold
    case maxRoundsExhausted         // stopped without `done` step
    case circuitBreakerTripped      // same-error streak > 3
    case transportFailure(String)   // underlying model call threw
    /// Server-side content filter fired. Retrying is futile —
    /// same body would keep getting filtered. Carries the suspected
    /// path/cmd/pattern so the bridge can tell the user which piece
    /// of context tripped the filter.
    case contentFilterHit(source: String)
}

/// Final result — matches what main-dialog research tool expects.
public struct AssistAgentResult: Sendable {
    public let summary: String
    public let citations: [Citation]
    public let unresolved: [String]
    public let artifactsWritten: [String]
    public let rounds: Int

    public struct Citation: Sendable {
        public let file: String
        public let line: Int?
        public let snippet: String
    }
}

@MainActor
public final class AssistAgentLoop {
    private let session: AssistAgentSession
    private let transport: AssistAgentTransport
    private let dispatcher: AssistAgentToolDispatcher
    private let systemPrompt: String
    private let maxRounds: Int

    /// After N consecutive empty replies with no recovery, throw
    /// `emptyResponseGaveUp`. Matches Python's `if recent_empty >= 1`
    /// give-up branch after the emergency-hop attempt.
    private static let consecutiveEmptyGiveUp = 10

    /// Same-signature error streak that trips the circuit breaker.
    /// Python parity: agent.py CIRCUIT_BREAKER_STREAK = 10. Old value
    /// (3) tripped so early the built-in self-heal layers below
    /// (nudge on 3, force-baseline on 3, then hard fail on 5) didn't
    /// get to run their course.
    private static let sameErrorGiveUp = 10

    /// Python default is 6 (agent.py). We ship 5 so the default assist
    /// invocation stays snappy. The loop auto-extends when the model
    /// hasn't emitted `完成` by the cap — mirrors Python's one-shot
    /// doubling in agent.py:3222-3225.
    private var effectiveMaxRounds: Int

    /// Model id in effect for this run — drives model-aware budgets
    /// (Python parity: `compute_budget_for_model`). Optional; when nil,
    /// falls back to the default 200k-token budget.
    private let modelID: String?

    public init(session: AssistAgentSession,
                transport: AssistAgentTransport,
                dispatcher: AssistAgentToolDispatcher,
                systemPrompt: String,
                maxRounds: Int = 5,
                modelID: String? = nil) {
        self.session = session
        self.transport = transport
        self.dispatcher = dispatcher
        self.systemPrompt = systemPrompt
        self.maxRounds = maxRounds
        self.effectiveMaxRounds = maxRounds
        self.modelID = modelID
    }

    /// Run until the model emits a `完成` (done) step, until max_rounds
    /// hits, or until self-preservation kicks in. Sync-blocking by
    /// design — the main dialog tool call awaits this.
    public func run() async throws -> AssistAgentResult {
        var consecutiveEmpty = 0
        var round = 0
        var extendedOnce = false
        let planDriven = session.planProgressPath != nil
        while true {
            round += 1

            // B3: plan-driven mode — check marker at TOP of every round
            // so an externally-flipped PROGRESS.md exits cleanly. B4:
            // hard cap at 500 to guard against runaway loops.
            if planDriven, let progressPath = session.planProgressPath {
                let progressText = AssistAgentPlanDriven.readProgress(progressPath)
                if AssistAgentPlanDriven.markerReached(
                    progressText: progressText,
                    marker: session.planCompletionMarker) {
                    HeyClickyLog.log("assist_agent.plan_marker_reached",
                                     lane: "agent", direction: "internal",
                                     ["round": round,
                                      "marker": session.planCompletionMarker])
                    session.emit(AssistAgentEvent(kind: .done, round: round))
                    return AssistAgentResult(
                        summary: "Plan complete: marker '\(session.planCompletionMarker)' reached in PROGRESS.md.",
                        citations: [], unresolved: [], artifactsWritten: [],
                        rounds: round)
                }
                if round > 500 {
                    HeyClickyLog.log("assist_agent.plan_hard_cap_hit",
                                     lane: "agent", direction: "error",
                                     ["round": round, "hard_cap": 500])
                    throw AssistAgentLoopError.maxRoundsExhausted
                }
            }
            if try Task.checkCancellation() as Void? == nil {}  // barge-in
            if round > effectiveMaxRounds && !planDriven {
                // Python parity (agent.py:3222-3225): one-shot doubling
                // when the cap is hit but useful progress is still
                // arriving. Only extend once per invocation. Plan-driven
                // mode ignores max_rounds — the marker is the exit.
                if !extendedOnce && session.steps.count >= effectiveMaxRounds / 2 {
                    extendedOnce = true
                    effectiveMaxRounds *= 2
                    session.emit(AssistAgentEvent(
                        kind: .info, round: round,
                        data: ["message": .string("auto_extend max_rounds → \(effectiveMaxRounds)")]))
                } else {
                    // Return partial result instead of throwing — the
                    // main dialog gets something to work with (last
                    // few tool results + best-effort summary). Better
                    // UX than "assist unavailable" placeholder.
                    HeyClickyLog.log("assist_agent.max_rounds_partial",
                                     lane: "agent", direction: "internal",
                                     ["rounds": round - 1,
                                      "steps": session.steps.count])
                    session.emit(AssistAgentEvent(
                        kind: .done, round: round - 1,
                        data: ["reason": .string("max_rounds_partial")]))
                    return AssistAgentResult(
                        summary: buildPartialSummary(),
                        citations: [],
                        unresolved: ["max_rounds_reached_without_done"],
                        artifactsWritten: [],
                        rounds: round - 1)
                }
            }
            session.emit(AssistAgentEvent(kind: .turnStart, round: round))
            HeyClickyLog.log("assist_agent.turn_start", lane: "agent",
                             direction: "internal",
                             ["round": round, "session": session.id.uuidString])

            var prior = buildPrior()

            // M6: round-1 only — inject `.heyclicky/plan.md` + `scratchpad.md`
            // tail so a resumed session picks up cross-conversation state.
            if round == 1 && session.steps.isEmpty && session.digest.isEmpty {
                let ws = workspaceBlock()
                if !ws.isEmpty {
                    prior = ws + "\n\n" + prior
                }
            }

            // E7: plan-driven status prefix — every round shows the
            // unchecked list + orchestrator hint. Python parity:
            // agent.py::_plan_status_block.
            let planBlock = planStatusBlock()
            if !planBlock.isEmpty {
                prior = planBlock + "\n\n" + prior
            }

            // C9 handoff: if the previous round hopped accounts,
            // prepend the stashed briefing so the fresh server session
            // sees full continuity. Consumed exactly once.
            if let briefing = session.pendingHandoffBriefing {
                prior = briefing + "\n\n" + prior
                session.pendingHandoffBriefing = nil
                HeyClickyLog.log("assist_agent.handoff_briefing_sent",
                                 lane: "agent", direction: "internal",
                                 ["round": round,
                                  "briefing_chars": briefing.count])
            }

            // M2: head-alert — inline warnings the model sees BEFORE
            // prior_text. Python parity: agent.py:3301-3341. Buried tail
            // warnings get ignored by Fable in long prompts.
            let headAlerts = buildHeadAlerts(round: round)
            if !headAlerts.isEmpty {
                prior = "!!! IMPORTANT ALERT !!!\n" + headAlerts.joined(separator: "\n")
                    + "\n!!! END ALERT !!!\n\n" + prior
            }
            // Tail hints (round budget + prior-too-long).
            let tailHints = buildTailHints(round: round, priorLen: prior.count)
            if !tailHints.isEmpty {
                prior = prior + "\n\n" + tailHints.joined(separator: "\n")
            }

            // Consume any pending image the previous round's `截屏`
            // or image-file-read produced. The transport reads
            // dimensions back from the JPEG itself — no need to
            // thread them through the protocol.
            var priorImage: Data? = nil
            if let tools = dispatcher as? AssistAgentBuiltInTools {
                priorImage = tools.pendingImage?.jpeg
                tools.pendingImage = nil  // consume once
            }

            // E13: BLOB image offload — for small-context models the
            // vision channel is cheaper than long text prior. When
            // eligible and no image is already queued, render the
            // largest step bodies (read_file / grep / run_shell /
            // http_get > 400 chars) into an ASCII bitmap JPEG and
            // rewrite the text prior to reference `→ BLOB #N` pointers.
            if priorImage == nil, blobOffloadEligible() {
                let offloaded = try? buildBlobOffload(currentPrior: prior)
                if let (jpeg, blobbedPrior) = offloaded {
                    priorImage = jpeg
                    prior = blobbedPrior
                    HeyClickyLog.log("assist_agent.blob_offload",
                                     lane: "agent", direction: "internal",
                                     ["round": round,
                                      "jpeg_bytes": jpeg.count,
                                      "prior_after_chars": prior.count])
                }
            }

            // Round-1 sends the full CN tool menu (~1600 chars).
            // Rounds 2+ send the short reminder (~180 chars) — server-
            // side session memory retains the menu, no need to
            // re-transmit. Nets ~1400 chars saved per continuation
            // round, which is significant across 5-15 rounds.
            // Always send the full tool-menu system prompt, every
            // round. Trying to save tokens by sending only a "you
            // already know the menu" reminder on rounds 2+ relies on
            // server-side session memory that we've seen forget the
            // menu after 1-2 rounds under HeyClicky proxy — the model
            // then says "I don't have those tools" and refuses to use
            // them. Re-transmitting the menu every round costs ~1.5k
            // tokens per round but eliminates the "forgot my tools"
            // failure mode.
            var promptForRound = systemPrompt
            // E14: dynamic MCP menu suffix. Registered MCP tools show
            // as `mcp:<server>:<tool>`; the model uses that string
            // verbatim in `类型`. Fetch fresh every round so hot-loaded
            // servers appear without loop restart. Kept short — max
            // 60 chars per line.
            let mcpLines = await mcpMenuLines()
            if !mcpLines.isEmpty {
                promptForRound += "\n\n# MCP 外部工具 (通过 stdio JSON-RPC 桥接):\n"
                    + mcpLines.joined(separator: "\n")
            }
            let reply: AssistAgentTransportReply
            do {
                reply = try await transport.ask(
                    prior: prior, priorImage: priorImage, systemPrompt: promptForRound
                )
            } catch is CancellationError {
                throw AssistAgentLoopError.emptyResponseGaveUp
            } catch {
                throw AssistAgentLoopError.transportFailure("\(error)")
            }

            // Empty reply — softer recovery than v1:
            //   1. classify cause (ceiling / cold_start / unknown)
            //   2. mark session for full baseline resync
            //   3. rotate session id (via consecutive_empty_at_floor
            //      counter — the transport layer picks it up)
            //   4. only surrender at 10 back-to-back empties
            var replyText = reply.text

            // H6: fast-fail marker (docs/FINDINGS #7: 47/57 empties
            // returned in <5s, 0/133 OKs in <5s). Server-side fast-
            // fail vs slow-legitimate empty look identical to the
            // caller but the response time distinguishes them. Log
            // both so downstream analysis can spot the pattern.
            let elapsedSec = Double(reply.elapsedMs) / 1000.0
            let fastFail = elapsedSec > 0 && elapsedSec < 5.0
                && replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // H1: per-call classification for observability.
            let classification: String = {
                let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return "empty" }
                if AssistAgentDetectors.looksLikeRefusal(t) { return "refusal" }
                if t.count < 40 { return "trivial" }
                if t.count >= 40 && !t.contains("{") && !t.contains("}") { return "prose" }
                return "ok"
            }()
            // Token estimate: 4 chars/token (Anthropic-family rule).
            // Enough signal to build a cost/quality dashboard.
            let inputTokEst = prior.count / AssistAgentBudget.charsPerToken
            let outputTokEst = replyText.count / AssistAgentBudget.charsPerToken
            HeyClickyLog.log("assist_agent.api_call",
                             lane: "agent", direction: "internal",
                             ["round": round,
                              "input_chars": prior.count,
                              "output_chars": replyText.count,
                              "input_tokens_est": inputTokEst,
                              "output_tokens_est": outputTokEst,
                              "elapsed_sec": elapsedSec,
                              "fast_fail": fastFail,
                              "classification": classification,
                              "output_ratio": prior.count > 0
                                ? Double(replyText.count) / Double(prior.count)
                                : 0])
            // PATTERNS finding #8: accounts have persistent quality
            // tiers. Feed every call outcome into the ledger so the
            // hop picker prefers proven accounts.
            transport.recordCallResult(ok: classification == "ok")

            if replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // C3: cold-start grace retry. Round 1 or just-hopped
                // sessions have a 25% first-call empty rate — retry
                // with a modest wait before escalating. Cheap.
                let coldStart = (round == 1 && session.steps.isEmpty)
                if coldStart {
                    for attempt in 0..<2 {
                        let waitSec = UInt64(2 + attempt * 3)
                        try? await Task.sleep(nanoseconds: waitSec * 1_000_000_000)
                        HeyClickyLog.log("assist_agent.cold_start_grace",
                                         lane: "agent", direction: "internal",
                                         ["attempt": attempt, "wait_sec": Int(waitSec)])
                        do {
                            let r2 = try await transport.ask(
                                prior: prior, priorImage: nil,
                                systemPrompt: promptForRound)
                            if !r2.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                replyText = r2.text
                                break
                            }
                        } catch { /* fall through */ }
                    }
                }
                // C4: nudge ladder — after grace retry (or if none was
                // applied), try one more with an explicit JSON reminder.
                if replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let nudge = "\n\n(继续,直接输出一个 JSON 对象,例如: " +
                        "{\"步骤\":\"需要\",\"类型\":\"目录列表\",\"参数\":{\"路径\":\".\"}} " +
                        "或 {\"步骤\":\"完成\",\"答案\":\"...\"}。不要写任何 JSON 以外的文字。)"
                    do {
                        let r3 = try await transport.ask(
                            prior: prior + nudge, priorImage: nil,
                            systemPrompt: promptForRound)
                        if !r3.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            HeyClickyLog.log("assist_agent.nudge_recovered",
                                             lane: "agent", direction: "internal",
                                             ["round": round])
                            replyText = r3.text
                        }
                    } catch { /* fall through */ }
                }
            }

            if replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                consecutiveEmpty += 1
                session.consecutiveEmptyAtFloor += 1
                let cause = AssistAgentDetectors.classifyEmpty(
                    inputChars: prior.count, session: session,
                    query: session.userTask)
                session.recordDeltaFailure(reason: "empty_\(cause.rawValue)")

                // Content-filter heuristic — requires ALL three
                // signals to fire (avoids false positives on generic
                // network/ceiling empties):
                //   1. round >= 2 (round-1 empty is cold-start, not filter)
                //   2. the most recent tool_result raw body is
                //      substantial (>1500 chars — small files aren't
                //      typical filter triggers)
                //   3. this reply came back fast (<5s), matching the
                //      server-side fast-fail signature (FINDINGS #7:
                //      99% of <5s empties are server-side rejects,
                //      not slow legitimate empties)
                let recentBigStep = session.steps.last(where: { $0.ok && $0.kind != "_reminder" })
                let sensitiveHitLikely = round >= 2
                    && (recentBigStep?.raw.count ?? 0) > 1500
                    && fastFail
                let userFacingMsg: String
                if sensitiveHitLikely {
                    let lastStep = session.steps.last { $0.ok && $0.kind != "_reminder" }
                    let path = lastStep?.args["path"]
                        ?? lastStep?.args["cmd"]
                        ?? lastStep?.args["pattern"]
                        ?? "上一步的内容"
                    userFacingMsg = "服务端拦截了这次回答(可能是 `\(String(path.suffix(60)))` 里的内容触发了内容安全过滤)。换个文件或简化问题试试。"
                } else if cause == .ceiling {
                    userFacingMsg = "上下文太长撞到上限,正在自动压缩重试…"
                } else if cause == .refusal {
                    userFacingMsg = "查询里似乎有敏感词,换个说法试试。"
                } else {
                    userFacingMsg = "服务端没响应(第 \(consecutiveEmpty) 次),重试中…"
                }
                session.emit(AssistAgentEvent(
                    kind: .info, round: round,
                    data: ["message": .string(userFacingMsg),
                           "cause": .string(cause.rawValue),
                           "sensitive_suspected": .bool(sensitiveHitLikely)]))
                // On content-filter suspicion, bail immediately —
                // rotate/hop won't bypass a body-content filter. The
                // sooner we return, the sooner the main dialog can
                // tell the user what happened.
                if sensitiveHitLikely {
                    let lastStep = session.steps.last { $0.ok && $0.kind != "_reminder" }
                    let source = lastStep?.args["path"]
                        ?? lastStep?.args["cmd"]
                        ?? lastStep?.args["url"]
                        ?? lastStep?.args["pattern"]
                        ?? "上一步的内容"
                    HeyClickyLog.log("assist_agent.content_filter_giveup",
                                     lane: "agent", direction: "error",
                                     ["round": round,
                                      "source": source,
                                      "last_step_raw_chars": lastStep?.raw.count ?? 0])
                    throw AssistAgentLoopError.contentFilterHit(source: source)
                }
                // Empty-recovery ladder — evidence-backed order
                // (docs/ROOT_CAUSE.md finding #12 + PATTERNS finding #8):
                //
                //   Session poisoning is REAL (49% follow-up empty on
                //   same sid). But aggressive hop AMPLIFIES cold-start
                //   empties (43% first-3-call rate). Therefore:
                //
                //     3 empties on THIS sid  → rotate session_id (cheap,
                //                              no cold-start, fixes 49%
                //                              of session-poison empties)
                //     3 rotations without recovery  → hop account
                //                              (cold-start cost accepted
                //                              only when we've proven
                //                              this account is exhausted
                //                              across multiple session_ids)
                // Bump BEFORE the ladder read so the first-hit-at-3
                // triggers rotate on THIS turn, not the next one.
                session.sameSessionEmptyStreak += 1
                let atFloor = session.consecutiveEmptyAtFloor
                let sameSidStreak = session.sameSessionEmptyStreak
                if sameSidStreak >= 3 && atFloor < 9 {
                    // Try one more session_id on the current account.
                    let newSid = transport.rotateSession()
                    session.totalRotations += 1
                    session.sameSessionEmptyStreak = 0
                    session.serverSyncedSteps = 0
                    session.forceFullNextRound = true
                    HeyClickyLog.log("assist_agent.session_rotate",
                                     lane: "agent", direction: "internal",
                                     ["round": round,
                                      "new_sid": newSid,
                                      "total_rotations": session.totalRotations])
                    session.emit(AssistAgentEvent(
                        kind: .info, round: round,
                        data: ["message": .string("session_rotate → \(newSid)")]))
                } else if atFloor >= 9 && session.totalRotations < 12 {
                    // Multiple session_ids on this account all empty —
                    // the account itself is exhausted. Hop.
                    let newEmail = transport.hopAccount()
                    if !newEmail.isEmpty {
                        session.pendingHandoffBriefing =
                            AssistAgentHandoff.buildBriefing(session)
                        session.totalRotations += 1
                        session.consecutiveEmptyAtFloor = 0
                        session.sameSessionEmptyStreak = 0
                        session.serverSyncedSteps = 0
                        session.forceFullNextRound = true
                        HeyClickyLog.log("assist_agent.account_hop",
                                         lane: "agent", direction: "internal",
                                         ["round": round,
                                          "new_account": newEmail,
                                          "briefing_chars": session.pendingHandoffBriefing?.count ?? 0])
                        session.emit(AssistAgentEvent(
                            kind: .sessionHop, round: round,
                            data: ["to": .string(newEmail),
                                   "reason": .string("empty_streak_at_floor"),
                                   "briefing_chars": .int(session.pendingHandoffBriefing?.count ?? 0)]))
                    }
                }
                // sameSessionEmptyStreak already bumped at ladder entry.
                if consecutiveEmpty >= Self.consecutiveEmptyGiveUp {
                    throw AssistAgentLoopError.emptyResponseGaveUp
                }
                continue
            }
            consecutiveEmpty = 0
            session.consecutiveEmptyAtFloor = 0
            session.sameSessionEmptyStreak = 0  // sid is healthy
            // G3: record reply length so safeChunkSize() sees a
            // moving window of what the server is currently giving us.
            session.recordReplyLength(replyText.count)

            // D5: output-degradation detect. Once we have 6+ replies,
            // if the last 3 avg < 40% of the first 3 avg, the account
            // is exhausted on this dialog. Since single-account assist
            // has no hop path, we log + rotate session_id (best
            // available signal recovery).
            if session.recentReplyLens.count >= 6
                && session.totalRotations < 5 {
                let first3 = Double(session.recentReplyLens.prefix(3).reduce(0, +)) / 3.0
                let last3 = Double(session.recentReplyLens.suffix(3).reduce(0, +)) / 3.0
                if first3 > 100 && last3 < first3 * 0.40 {
                    let newSid = transport.rotateSession()
                    session.totalRotations += 1
                    session.serverSyncedSteps = 0
                    session.sameSessionEmptyStreak = 0
                    session.forceFullNextRound = true
                    session.recentReplyLens = []
                    HeyClickyLog.log("assist_agent.output_degrade",
                                     lane: "agent", direction: "internal",
                                     ["round": round,
                                      "first3": Int(first3), "last3": Int(last3),
                                      "new_sid": newSid])
                    session.emit(AssistAgentEvent(
                        kind: .sessionHop, round: round,
                        data: ["to": .string(newSid),
                               "reason": .string("output_degrade \(Int(first3))→\(Int(last3))"),
                               "briefing_chars": .int(0)]))
                }
            }
            // AIMD success: server memory kept up. Interval grows by 1
            // so next round can safely go delta-only (matches Python
            // agent.py's additive-increase).
            session.recordDeltaSuccess()

            // Memory-loss detector — force a full prior baseline next
            // round so the model gets its history back. Also zero
            // serverSyncedSteps so the next render truly rebuilds
            // from scratch (Python parity: agent.py:3543).
            if AssistAgentDetectors.looksLikeMemoryLoss(replyText) {
                session.recordDeltaFailure(reason: "memory_loss")
                session.serverSyncedSteps = 0
                session.emit(AssistAgentEvent(
                    kind: .info, round: round,
                    data: ["message": .string("memory_loss detected — forcing baseline")]))
            }

            // Refusal detector — nudge next round to answer via 步骤=完成
            // instead of retrying the same tool. Python parity
            // (agent.py:3526-3532): also force a full baseline so the
            // fresh state doesn't inherit the poisoned delta context.
            if AssistAgentDetectors.looksLikeRefusal(replyText) {
                session.recordDeltaFailure(reason: "refusal")
                session.emit(AssistAgentEvent(
                    kind: .info, round: round,
                    data: ["message": .string("refusal detected — nudging + baseline")]))
            }

            // Parse the model's JSON reply.
            guard let obj = AssistAgentJSON.extract(from: replyText) else {
                HeyClickyLog.log("assist_agent.parse_failed", lane: "agent",
                                 direction: "error",
                                 ["round": round,
                                  "preview": String(replyText.prefix(400))])
                session.emit(AssistAgentEvent(
                    kind: .error, round: round,
                    data: ["error": .string("no valid JSON"),
                           "preview": .string(String(replyText.prefix(200)))]))

                // A11-A13: parse-fail recovery ladder. Instead of a
                // silent `continue` (which just re-sends the same
                // prior and burns another round), append a reminder
                // step that shows the model its own bad output and
                // asks for a specific fix. Escalation depends on
                // consecutive fails already logged.
                let openBraces = replyText.filter { $0 == "{" }.count
                let closeBraces = replyText.filter { $0 == "}" }.count
                let looksTruncated = openBraces > closeBraces
                    || (replyText.contains("\"内容\"") && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}"))
                    || (replyText.contains("\"content\"") && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}"))

                // Count trailing _reminder steps with JSON in the error.
                var failsInARow = 0
                for s in session.steps.reversed() {
                    if s.kind == "_reminder"
                        && s.result.contains("JSON") {
                        failsInARow += 1
                    } else {
                        break
                    }
                }

                let reminder: String
                if failsInARow == 0 && !looksTruncated {
                    // Level 0: self-correct hint — show the model its
                    // own bad output so it can fix it.
                    let badPreview = String(replyText.prefix(300))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    reminder = """
                    你上一次的回复不是合法 JSON。以下是你的原始输出片段(供参考):

                    ---原始输出---
                    \(badPreview)
                    ---结束---

                    常见错误自检:(1)字符串里的换行必须写成 \\n 而不是真换行;\
                    (2)不要在 } 或 ] 前留 trailing comma;\
                    (3)只能用英文双引号 \" 和英文冒号 :;\
                    (4)整个回复必须是一个 JSON 对象,前后不要加解释文字。
                    正确示例(选一个填):
                      需要工具:  {"步骤":"需要","类型":"目录列表","参数":{"路径":"."}}
                      已完成:    {"步骤":"完成","答案":"..."}
                    请重新输出一个合法 JSON。
                    """
                } else if looksTruncated && failsInARow < 3 {
                    // Level 1: truncation hint — split writes.
                    reminder = "上一次回复的 JSON 被输出长度截断了(单次输出上限约 2000-4000 字符)。" +
                        "请分多次小段写入:每次调用 append_chunk 并且 chunk 字符数控制在 800 字符以内," +
                        "拆成 3-5 次完成这一步。不要一次性写完整文件内容。"
                } else if failsInARow < 5 {
                    // Level 2: tool-switch hint.
                    reminder = "连续 \(failsInARow + 1) 次 JSON 解析失败。换一个策略:" +
                        "如果在写长文件,改用极小的 append_chunk (<400 字符/次);" +
                        "或者跳过当前 step 试下一个;" +
                        "或者先 read_file 看当前状态,再决定下一步。"
                } else {
                    // Level 3: exhausted.
                    reminder = "JSON 解析连续失败 \(failsInARow + 1) 轮,已耗尽恢复策略。"
                }
                session.appendStep(AssistAgentSession.Step(
                    kind: "_reminder", tool: "_reminder", args: [:], why: "json_parse_fail",
                    result: reminder, raw: reminder, ok: false))
                HeyClickyLog.log("assist_agent.json_recover",
                                 lane: "agent", direction: "internal",
                                 ["round": round,
                                  "fails_in_a_row": failsInARow,
                                  "looks_truncated": looksTruncated,
                                  "level": failsInARow == 0 && !looksTruncated ? "self_correct"
                                    : looksTruncated ? "truncation" : "tool_switch"])
                if failsInARow >= 5 {
                    // Circuit breaker on parse-fail streak — Python
                    // aligned via CIRCUIT_BREAKER_STREAK path.
                    throw AssistAgentLoopError.circuitBreakerTripped
                }
                continue
            }
            HeyClickyLog.log("assist_agent.parsed",
                             lane: "agent", direction: "internal",
                             ["round": round,
                              "keys": obj.keys.sorted().joined(separator: ","),
                              "step": (obj["步骤"] as? String) ?? "?",
                              "kind": (obj["类型"] as? String) ?? "?"])

            // B5: plan-driven mode — if the model tagged step_done on
            // this reply, tick that box in PROGRESS.md before further
            // processing. Independent of whether the JSON is a "call"
            // or "done" — model can report progress on either.
            if let progressPath = session.planProgressPath {
                let stepDoneRaw = (obj["step_done"] as? String)
                    ?? (obj["已完成"] as? String)
                if let stepDone = stepDoneRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !stepDone.isEmpty {
                    let ok = AssistAgentPlanDriven.markStepDone(
                        path: progressPath, stepText: stepDone)
                    HeyClickyLog.log("assist_agent.plan_step_marked",
                                     lane: "agent", direction: "internal",
                                     ["round": round,
                                      "step": String(stepDone.prefix(120)),
                                      "ok": ok])
                }
            }

            // "步骤" == "完成" means the model is done.
            if let step = obj["步骤"] as? String, step == "完成" {
                let answerRaw = (obj["答案"] as? String)
                    ?? (obj["answer"] as? String) ?? ""
                let answer = answerRaw.trimmingCharacters(in: .whitespacesAndNewlines)

                // Answer-quality gate 1: empty answer. Model must give
                // SOMETHING — else the main dialog has nothing to inline.
                // Only reject when we still have >=2 rounds so we don't
                // fight a cornered model near the cap.
                if answer.isEmpty && (effectiveMaxRounds - round) >= 2 {
                    let msg = "答案为空。请用简短一段中文陈述结论,基于你到目前为止查到的信息(引用具体路径/命令/证据)。"
                    session.appendStep(AssistAgentSession.Step(
                        kind: "_reminder", tool: "_reminder", args: [:],
                        why: "done_rejected_empty_answer",
                        result: msg, raw: msg, ok: false))
                    HeyClickyLog.log("assist_agent.done_rejected",
                                     lane: "agent", direction: "internal",
                                     ["round": round, "reason": "empty_answer"])
                    continue
                }

                // Answer-quality gate 2: zero tool calls on a research
                // task. If the user's goal implies gathering context
                // (has read/search/查/看/analyze/review keywords) and
                // the model went to `完成` without a single successful
                // tool call, that's a hallucinated answer.
                let researchKeywords = ["read", "search", "grep", "find",
                                        "analyze", "review", "看", "查",
                                        "读", "找", "检查", "分析", "看下"]
                let taskLC = session.userTask.lowercased()
                let looksLikeResearch = researchKeywords.contains { taskLC.contains($0) }
                let hasSuccessfulTool = session.steps.contains {
                    $0.kind != "_reminder" && $0.ok
                }
                if looksLikeResearch && !hasSuccessfulTool
                    && (effectiveMaxRounds - round) >= 2 {
                    let msg = "任务看起来需要查上下文(读文件/搜索/看目录),但你还没成功调用过任何工具就说完成。请先调用相应工具拿到真实证据,再给出答案。"
                    session.appendStep(AssistAgentSession.Step(
                        kind: "_reminder", tool: "_reminder", args: [:],
                        why: "done_rejected_no_evidence",
                        result: msg, raw: msg, ok: false))
                    HeyClickyLog.log("assist_agent.done_rejected",
                                     lane: "agent", direction: "internal",
                                     ["round": round, "reason": "no_evidence"])
                    continue
                }

                // Answer-quality gate 3: "insufficient info" answers.
                // Model explicitly admits it doesn't know — surface as
                // `unresolved` rather than pretending it succeeded.
                let insufficientPatterns = [
                    "我不知道", "无法确定", "信息不足", "不清楚",
                    "无法回答", "i don't know", "not enough information",
                    "cannot determine", "unclear",
                ]
                let answerLC = answer.lowercased()
                let isInsufficient = insufficientPatterns.contains {
                    answerLC.contains($0.lowercased())
                }
                if isInsufficient {
                    HeyClickyLog.log("assist_agent.done_insufficient",
                                     lane: "agent", direction: "internal",
                                     ["round": round,
                                      "preview": String(answer.prefix(80))])
                    // Don't reject — pass through with `unresolved`
                    // flag so main dialog knows to hedge.
                    var unresolved = (obj["未解决"] as? [String]) ?? []
                    unresolved.append("model_reported_insufficient_info")
                    var patched = obj
                    patched["未解决"] = unresolved
                    let result = buildResult(from: patched, rounds: round)
                    session.emit(AssistAgentEvent(kind: .done, round: round))
                    return result
                }
                // M3: premature-done rejection. If the task text asks
                // for verification (pytest/test/verify/验证/确认) AND
                // the last 5 steps have NO successful run_shell,
                // reject the done and push the model to run tests
                // first. Only apply when we still have >=3 rounds left
                // so we don't fight a genuinely-cornered model.
                let wantsVerify = ["pytest", "test", "跑测试", "verify", "验证", "确认"]
                    .contains(where: taskLC.contains)
                let recentShellOk = session.steps.suffix(5).contains { s in
                    s.kind == "命令输出" && s.ok
                }
                if wantsVerify && !recentShellOk
                    && (effectiveMaxRounds - round) >= 3 {
                    let msg = "任务要求验证/跑测试,但最近 5 步内没有成功的命令输出。请先用 命令输出 跑一次验证再 完成。"
                    session.appendStep(AssistAgentSession.Step(
                        kind: "_reminder", tool: "_reminder", args: [:],
                        why: "done_rejected_missing_verify",
                        result: msg, raw: msg, ok: false))
                    HeyClickyLog.log("assist_agent.done_rejected",
                                     lane: "agent", direction: "internal",
                                     ["round": round, "reason": "missing_verify"])
                    session.emit(AssistAgentEvent(
                        kind: .info, round: round,
                        data: ["message": .string("done rejected: run pytest/verify first")]))
                    continue
                }

                // B7: plan-driven — reject `完成` when PROGRESS.md still
                // has unchecked steps. Otherwise the model quietly
                // gives up half-way and caller thinks the run succeeded.
                if let progressPath = session.planProgressPath {
                    let progressText = AssistAgentPlanDriven.readProgress(progressPath)
                    let remaining = AssistAgentPlanDriven.uncheckedSteps(progressText)
                    if !remaining.isEmpty {
                        let msg = "PROGRESS.md 还有 \(remaining.count) 个未完成步骤(下一个: " +
                                  "\(String(remaining[0].prefix(80))))。请继续执行,不要提前 完成。"
                        session.appendStep(AssistAgentSession.Step(
                            kind: "_reminder", tool: "_reminder", args: [:],
                            why: "done_rejected_plan_incomplete",
                            result: msg, raw: msg, ok: false))
                        HeyClickyLog.log("assist_agent.done_rejected",
                                         lane: "agent", direction: "internal",
                                         ["round": round, "reason": "plan_incomplete",
                                          "remaining": remaining.count])
                        continue
                    }
                    // All checked — stamp the terminal marker so the
                    // top-of-loop check succeeds next round (belt-and-
                    // braces; we also return success here).
                    AssistAgentPlanDriven.markAllDone(
                        path: progressPath, marker: session.planCompletionMarker)
                }

                let result = buildResult(from: obj, rounds: round)
                session.emit(AssistAgentEvent(kind: .done, round: round))
                return result
            }

            // Dup-work detector — if the model is proposing to redo
            // exactly what we already did successfully, skip and nudge.
            // Python parity (agent.py:3557-3562): also AIMD-shrink so
            // the next round sends a fresh baseline showing the model
            // the completed work.
            if AssistAgentDetectors.modelProposingDup(
                rawReply: replyText, session: session) {
                session.recordDeltaFailure(reason: "dup_target")
                session.emit(AssistAgentEvent(
                    kind: .info, round: round,
                    data: ["message": .string("dup detected — resync baseline")]))
                continue
            }

            // Otherwise: tool call.
            let kind = (obj["类型"] as? String) ?? ""
            let cnArgs = (obj["参数"] as? [String: Any]) ?? [:]
            let why = (obj["为什么"] as? String) ?? ""
            let (toolName, args) = mapCNToTool(kind: kind, args: cnArgs)

            guard let tool = toolName else {
                session.emit(AssistAgentEvent(
                    kind: .error, round: round,
                    data: ["error": .string("unknown_kind \(kind)")]))
                continue
            }

            // Include the primary arg (path/cmd/url/pattern) so the UI
            // can show what THIS tool call is actually doing — not
            // just "run_shell" / "read_file" but the concrete target.
            let primaryArg = args["path"] ?? args["cmd"]
                ?? args["url"] ?? args["pattern"] ?? args["query"] ?? ""
            session.emit(AssistAgentEvent(
                kind: .toolCall, round: round,
                data: ["kind": .string(kind), "tool": .string(tool),
                       "why": .string(why),
                       "target": .string(primaryArg)]))
            HeyClickyLog.log("assist_agent.tool_call", lane: "agent",
                             direction: "internal",
                             ["round": round, "kind": kind, "tool": tool,
                              "why": String(why.prefix(80)),
                              "args_preview": String(describing: args).prefix(200)])

            let t0 = Date()
            let outcome: AssistAgentToolOutcome
            do {
                outcome = try await dispatcher.dispatch(kind: kind, tool: tool, args: args)
            } catch {
                outcome = AssistAgentToolOutcome(ok: false,
                                                summary: "dispatch_error: \(error)",
                                                raw: "\(error)")
            }
            let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)

            let newStep = AssistAgentSession.Step(
                kind: kind, tool: tool, args: args, why: why,
                result: outcome.summary, raw: outcome.raw,
                ok: outcome.ok, startedAt: t0, elapsedMs: elapsedMs)
            session.appendStep(newStep)

            // D8: L3 persist — every step lands on disk so query_history
            // can find folded-off / microcompacted steps. Async, non-
            // blocking. Python parity: `_persist_step_to_history`.
            AssistAgentHistory.persistStep(
                sessionID: session.id,
                compactedBefore: session.compactedBefore,
                stepIndex: session.steps.count - 1,
                step: newStep)
            AssistAgentHistory.persistMeta(
                sessionID: session.id,
                userTask: session.userTask,
                digest: session.digest,
                compactedBefore: session.compactedBefore,
                serverSyncedSteps: session.serverSyncedSteps,
                adaptiveResyncInterval: session.adaptiveResyncInterval,
                totalRotations: session.totalRotations,
                consecutiveDeltaSuccesses: session.consecutiveDeltaSuccesses,
                pinnedMemory: session.pinnedMemory,
                stepsCount: session.compactedBefore + session.steps.count)

            // M5: auto-pin high-value facts so long-run compaction
            // doesn't lose the "wrote X" / "grep Y found N" anchors.
            // Python parity: agent.py `_auto_pin_from_step`.
            autoPinFromStep(newStep)

            session.emit(AssistAgentEvent(
                kind: .toolResult, round: round,
                data: ["kind": .string(kind), "tool": .string(tool),
                       "ok": .bool(outcome.ok),
                       "elapsed_ms": .int(elapsedMs),
                       "target": .string(args["path"] ?? args["cmd"]
                            ?? args["url"] ?? args["pattern"]
                            ?? args["query"] ?? ""),
                       "summary": .string(String(outcome.summary.prefix(80)))]))
            HeyClickyLog.log("assist_agent.tool_result", lane: "agent",
                             direction: outcome.ok ? "internal" : "error",
                             ["round": round, "tool": tool,
                              "ok": outcome.ok,
                              "elapsed_ms": elapsedMs,
                              "summary": String(outcome.summary.prefix(120))])

            // Soft circuit breaker — matches Python's approach: same-
            // signature error triggers a nudge round (log an info event
            // + force full baseline) before the hard fail. Only trip
            // after 5 same-sig failures with no progress.
            if !outcome.ok {
                let sig = "\(kind):\(outcome.summary.prefix(80))"
                if sig == session.lastErrorSignature {
                    session.sameErrorStreak += 1
                } else {
                    session.lastErrorSignature = sig
                    session.sameErrorStreak = 1
                }
                if session.sameErrorStreak == Self.sameErrorGiveUp {
                    // Nudge round — force baseline resync + notify.
                    session.recordDeltaFailure(reason: "same_error_streak")
                    session.emit(AssistAgentEvent(
                        kind: .info, round: round,
                        data: ["message": .string("nudge: same error 3× — resync baseline")]))
                }
                if session.sameErrorStreak >= Self.sameErrorGiveUp + 2 {
                    throw AssistAgentLoopError.circuitBreakerTripped
                }
            } else {
                session.lastErrorSignature = ""
                session.sameErrorStreak = 0
            }
        }
    }

    // MARK: - Private helpers

    /// Build the prior with the full layered-compression cascade:
    ///
    ///   1. Render at current tier assignment (assignTiers keeps size
    ///      near SOFT_BUDGET).
    ///   2. If still > MICROCOMPACT_TRIGGER → clear old tool bodies
    ///      in place (microcompact).
    ///   3. If still > MICROCOMPACT_TRIGGER → deep microcompact
    ///      (keep_recent shrunk to KEEP_RECENT_MIN).
    ///   4. If digest > DIGEST_MAX_CHARS → drop the ancient tail.
    ///   5. Re-render.
    ///
    /// The tier assignment inside renderPrior handles the SOFT_BUDGET
    /// tier when session isn't dire enough for microcompact.
    private func buildPrior() -> String {
        // Model-aware tier thresholds — INFINITE_DIALOG.md §0.
        let budget = AssistAgentCompactionConstants.budget(for: modelID)

        let raw = renderPrior()
        // Layered ladder — cheap trims first, expensive later.
        if raw.count >= budget.micro {
            _ = assistCompactionMicrocompactSession(session)
        }
        _ = assistCompactionTrimDigestIfBloated(session)
        let round2 = renderPrior()
        var prior: String = round2
        if round2.count >= budget.micro {
            // Deep rung: shrink kept-recent window.
            _ = assistCompactionMicrocompactSession(
                session,
                keepRecent: AssistAgentCompactionConstants.keepRecentMin)
            prior = renderPrior()
        }

        // Local rotation digest fold. Prior >= hardBudget → fold ALL
        // but the last 3 steps into a dense text digest. Python's
        // `_compact_session` first asks the model to author the
        // digest (agent.py:2763) then falls back to local rotation
        // on empty-response session_rotate (agent.py:3963). We use
        // the local variant unconditionally because:
        //   (a) it's synchronous — no extra model round-trip that
        //       could itself return empty at exactly the moment we
        //       need to trim
        //   (b) empirical: the same server session that produced the
        //       oversized prior tends to return crippled output when
        //       asked to summarise it (agent.py:2740 note)
        //   (c) pinnedMemory + digest carry the anti-forgetting slice
        //       regardless of who wrote the digest
        if prior.count >= budget.hard
            && session.steps.count > 3 {
            let digestNew = buildLocalRotationDigest()
            if !digestNew.isEmpty {
                let combined = session.digest.isEmpty
                    ? digestNew
                    : session.digest + "\n" + digestNew
                let foldCount = session.steps.count - 3
                session.replaceCompacted(
                    newDigest: combined,
                    newBoundary: session.compactedBefore + foldCount)
                session.steps = Array(session.steps.suffix(3))
                _ = assistCompactionTrimDigestIfBloated(session)
                HeyClickyLog.log("assist_agent.local_rotation_digest",
                                 lane: "agent", direction: "internal",
                                 ["folded": foldCount,
                                  "digest_chars": combined.count,
                                  "prior_before": prior.count])
                // INFINITE_DIALOG.md invariant #4: compact boundaries
                // must be visible so the user sees the transcript was
                // folded (not lost). Emit `compact_boundary` for UI
                // to draw a horizontal rule + one-line summary.
                session.emit(AssistAgentEvent(
                    kind: .compactBoundary, round: 0,
                    data: ["compacted_steps": .int(session.compactedBefore),
                           "folded_this_round": .int(foldCount),
                           "digest_chars": .int(combined.count)]))
                prior = renderPrior()
            }
        }

        // G3: output-budget hint — tell model how much room its NEXT
        // write has. Injected as head-of-prior so it's read first.
        let chunkBudget = session.safeChunkSize()
        let recentMin = session.recentReplyLens.suffix(4).min() ?? 0
        if recentMin > 0 {
            let hint = "[output-budget] recent_min_reply=\(recentMin) chars; " +
                "keep this turn's write_file content ≤ \(chunkBudget) chars OR " +
                "switch to append_chunk with chunks ≤ \(chunkBudget) chars each.\n\n"
            prior = hint + prior
        }

        // G1: preemptive shrink — last-ditch middle-cut so prior stays
        // under the empirical empty ceiling.
        let (shrunk, saved) = assistCompactionPreemptiveShrink(prior)
        if saved > 0 {
            HeyClickyLog.log("assist_agent.preemptive_shrink", lane: "agent",
                             direction: "internal",
                             ["before": prior.count, "after": shrunk.count,
                              "saved": saved])
            prior = shrunk
        }

        // G2: hard-ceiling alarm — log if we still exceed empirical
        // empty threshold. Loop continues (this is diagnostic), but
        // caller / log-tail can see when we're in danger zone.
        if prior.count >= AssistAgentCompactionConstants.empiricalEmptyCeiling {
            HeyClickyLog.log("assist_agent.prior_over_ceiling", lane: "agent",
                             direction: "error",
                             ["prior_chars": prior.count,
                              "ceiling": AssistAgentCompactionConstants.empiricalEmptyCeiling])
        }
        return prior
    }

    /// Prior modes — mirrors Python's ROUND1 / DELTA / FULL split
    /// (agent.py::_build_query). Server keeps the previous rounds'
    /// content in session memory keyed by `X-Clicky-Session-Id`, so
    /// on continuation rounds we only need to send:
    ///   · what's NEW since server_synced_steps (delta mode)
    ///   · every `adaptive_resync_interval` rounds, a fresh baseline
    ///     so a session drop / server memory eviction doesn't
    ///     silently lose our history.
    private func renderPrior() -> String {
        // Compute mode: ROUND1 / DELTA / FULL (baseline).
        let isRound1 = session.steps.isEmpty && session.digest.isEmpty
        let useDelta = !isRound1
            && !session.forceFullNextRound
            && session.serverSyncedSteps > 0
            && session.steps.count > session.serverSyncedSteps
            && session.roundsSinceFullBaseline < session.adaptiveResyncInterval

        var parts: [String] = []
        parts.append("任务:\(session.userTask)")

        if useDelta {
            // DELTA — only new steps since server_synced_steps, plus a
            // rollup of the last N completed steps to guard against
            // server-side memory dropouts (anti-amnesia rollup).
            let newSteps = Array(session.steps[session.serverSyncedSteps...])
            let rollupWindow = 6
            let rollupStart = max(0, session.steps.count - newSteps.count - rollupWindow)
            let rollupEnd = session.steps.count - newSteps.count
            if rollupStart < rollupEnd {
                let lines = (rollupStart..<rollupEnd).map { i -> String in
                    let s = session.steps[i]
                    let ok = s.ok ? "✓" : "✗"
                    let cap = s.result.split(separator: "\n").first
                        .map { $0.count > 80 ? $0.prefix(80) + "…" : $0 } ?? ""
                    return "  \(ok) S\(i + 1) [\(s.kind)] \(cap)"
                }
                parts.append("最近步骤(勿重复):\n" + lines.joined(separator: "\n"))
            }
            let deltaLines: [String] = newSteps.enumerated().map { (offset, s) in
                let realIdx = session.compactedBefore + session.serverSyncedSteps + offset + 1
                let body = s.raw == AssistAgentCompactionConstants.microcompactClearedMarker
                    ? s.result
                    : compactForPrior(step: s)
                let whyPart = s.why.isEmpty ? "" : " 原因:\(s.why)"
                return "S\(realIdx) [\(s.kind)]\(whyPart)\n\(body)"
            }
            parts.append("本轮新增:\n" + (deltaLines.isEmpty ? "(尚无新增)"
                                       : deltaLines.joined(separator: "\n\n")))
        } else {
            // ROUND1 or FULL baseline — send everything.
            if !session.digest.isEmpty {
                parts.append("摘要:\n\(session.digest)")
            }
            if !session.pinnedMemory.isEmpty {
                parts.append("要点:\n" +
                    session.pinnedMemory.enumerated()
                        .map { "  \($0.offset + 1). \($0.element)" }
                        .joined(separator: "\n"))
            }
            let stale = assistCompactionStaleReadIndices(session.steps)
            // Compute per-step tier so ancient rollup steps degrade
            // to oneline when prior gets long. `render` closure below
            // has to know the tier to estimate size — pass an inline
            // renderer that mirrors what we emit.
            let tiers = assistCompactionAssignTiers(session) { step, tier in
                assistCompactionRenderStep(step, tier: tier).count + 40
            }
            for (i, s) in session.steps.enumerated()
            where i >= session.compactedBefore && !stale.contains(i) {
                let tier = i < tiers.count ? tiers[i] : .full
                let body: String
                switch tier {
                case .full, .medium:
                    if s.raw == AssistAgentCompactionConstants.microcompactClearedMarker {
                        body = s.result
                    } else {
                        // Per-tool compact + tier cap.
                        let toolCompacted = compactForPrior(step: s)
                        let cap = tier == .full
                            ? AssistAgentCompactionConstants.fullResultChars
                            : AssistAgentCompactionConstants.mediumResultChars
                        body = toolCompacted.count > cap
                            ? String(toolCompacted.prefix(cap)) + "…"
                            : toolCompacted
                    }
                    let whyPart = s.why.isEmpty ? "" : " 原因:\(s.why)"
                    parts.append("S\(i + 1) [\(s.kind)]\(whyPart)\n\(body)")
                case .oneline:
                    let ok = s.ok ? "✓" : "✗"
                    let short = assistCompactionRenderStep(s, tier: .oneline)
                    parts.append("  \(ok) S\(i + 1) [\(s.kind)] \(short)")
                }
            }
        }

        // Bookkeeping — the transport observes this via mode field
        // just so log analysis can see delta vs baseline distribution.
        if useDelta {
            session.roundsSinceFullBaseline += 1
        } else {
            session.serverSyncedSteps = session.steps.count
            session.roundsSinceFullBaseline = 0
            session.forceFullNextRound = false
        }

        HeyClickyLog.log("assist_agent.prior_mode", lane: "agent",
                         direction: "internal",
                         ["mode": useDelta ? "delta" : (isRound1 ? "round1" : "baseline"),
                          "steps_total": session.steps.count,
                          "steps_new": session.steps.count - (useDelta ? session.serverSyncedSteps : 0),
                          "resync_interval": session.adaptiveResyncInterval])
        return parts.joined(separator: "\n\n")
    }

    /// Route a step's raw output through the right compactor for its
    /// kind so we don't waste prior chars on redundant context lines,
    /// noise banners, or huge JSON blobs.
    private func compactForPrior(step: AssistAgentSession.Step) -> String {
        switch step.kind {
        case "命令输出":   // run_shell
            let cmd = step.args["cmd"] ?? ""
            return assistCompactionCompactStdout(cmd: cmd, stdout: step.raw)
        case "差量应用":   // apply_diff
            return assistCompactionCompactDiff(step.raw) ?? step.raw
        case "文件内容":   // read_file
            let path = step.args["path"] ?? ""
            return assistCompactionCompactSource(step.raw, path: path)
        default:
            if let json = assistCompactionCompactJSON(step.raw) {
                return json
            }
            return step.raw
        }
    }

    private func mapCNToTool(kind rawKind: String, args cnArgs: [String: Any])
        -> (tool: String?, args: [String: String])
    {
        // Canonicalise the operation kind first — Fable-5 invents
        // near-synonyms constantly ("写入文件" for "写入完成", etc.).
        let kind = Self.canonicalKind(rawKind)
        // Canonicalise argument keys the same way ("path" → "路径").
        // Two-pass: CN keys win over EN aliases when the model mixes
        // them ({"路径": "/a", "path": "/b"} → keep "/a"). Python has
        // the same order-independence guarantee via _ARG_ALIAS.
        var canonArgs: [String: Any] = [:]
        // Pass 1: put every canonical CN key we recognise.
        for (k, v) in cnArgs where Self.cnKeys.contains(k) {
            canonArgs[k] = v
        }
        // Pass 2: EN aliases fill only the gaps.
        for (k, v) in cnArgs where !Self.cnKeys.contains(k) {
            let ck = Self.argAliases[k]
                ?? Self.argAliases[k.lowercased()]
                ?? k
            if canonArgs[ck] == nil { canonArgs[ck] = v }
        }
        // MCP passthrough — canonical tool names look like `mcp:srv:tool`.
        // No CN alias needed; pass every arg through as string.
        if kind.hasPrefix("mcp:") {
            var out: [String: String] = [:]
            for (k, v) in canonArgs {
                out[k] = String(describing: v)
            }
            return (kind, out)
        }
        guard let (tool, mapping) = Self.cnToTool[kind] else {
            return (nil, [:])
        }
        var out: [String: String] = [:]
        for (cn, en) in mapping {
            if let v = canonArgs[cn] {
                out[en] = String(describing: v)
            }
        }
        return (tool, out)
    }

    /// Canonical kind lookup with `_TYPE_ALIAS` fallback (Python parity).
    static func canonicalKind(_ raw: String) -> String {
        if cnToTool[raw] != nil { return raw }
        let low = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return typeAliases[raw] ?? typeAliases[low] ?? raw
    }

    /// Canonical CN→EN tool table, byte-for-byte match with Python's
    /// `_CN_TO_TOOL` (agent.py:131). Every entry the Python reference
    /// exposes is present so a model's canonical JSON is always routed.
    static let cnToTool: [String: (tool: String, args: [String: String])] = [
        "截屏":        ("screenshot",        [:]),
        "文件内容":    ("read_file",         ["路径": "path", "起始": "offset", "长度": "length"]),
        "文件大纲":    ("file_outline",      ["路径": "path"]),
        "目录列表":    ("list_dir",          ["路径": "path"]),
        "路径匹配":    ("glob",              ["根目录": "root", "模式": "pattern"]),
        "搜索结果":    ("grep",              ["路径": "path", "模式": "pattern", "忽略大小写": "ignore_case"]),
        "命令输出":    ("run_shell",         ["命令": "cmd", "工作目录": "cwd", "超时秒": "timeout", "超时": "timeout"]),
        "网页内容":    ("http_get",          ["网址": "url"]),
        "网络搜索":    ("web_search",        ["查询": "query", "上下文": "context"]),
        "重新获取图片": ("_reupload_image",   ["提示": "hint"]),
        "查历史":      ("query_history",     ["关键词": "query", "查询": "query", "会话": "session_id", "最多": "limit"]),
        "写入完成":    ("write_file",        ["路径": "path", "内容": "content", "模式": "mode"]),
        "局部替换":    ("edit_file",         ["路径": "path", "原文": "old", "新文": "new"]),
        "批量替换":    ("multi_edit",        ["路径": "path", "编辑": "edits_json"]),
        "追加片段":    ("append_chunk",      ["路径": "path", "片段": "chunk", "首块": "first", "更多": "more"]),
        "差量应用":    ("apply_diff",        ["路径": "path", "补丁": "diff"]),
        "分派并行":    ("dispatch_parallel", ["任务": "tasks", "策略": "strategy"]),
        "存记忆":      ("save_memory",       ["内容": "text"]),
        "读记忆":      ("read_memory",       ["最多": "limit"]),
        "钉记忆":      ("pin_memory",        ["内容": "text"]),
        "待办列表":    ("todo_write",        ["任务": "todos_json"]),
        "屏幕历史·搜索":   ("rewind_search",   ["关键词": "query", "查询": "query", "最多": "limit", "语义": "hybrid"]),
        "屏幕历史·帧详情": ("rewind_frame",    ["frame_id": "frame_id", "时间": "at", "at": "at"]),
        "屏幕历史·日汇总": ("rewind_recap",    ["日期": "date", "date": "date"]),
        "屏幕历史·问答":   ("rewind_ask",      ["问题": "question", "query": "question"]),
        "屏幕历史·最近":   ("rewind_recent",   ["分钟": "minutes", "minutes": "minutes"]),
        "屏幕历史·会议":   ("rewind_events",   ["状态": "status"]),
        "屏幕历史·转录":   ("rewind_transcript", ["会话": "segment_id", "segment_id": "segment_id"]),
        "屏幕历史·缩略图": ("rewind_thumbnail", ["frame_id": "frame_id", "id": "frame_id"]),
        "屏幕历史·打开帧": ("rewind_show_frame", ["frame_id": "frame_id", "时间": "at", "at": "at"]),
        "屏幕历史·定位":   ("rewind_locate",   ["frame_id": "frame_id", "关键词": "query", "query": "query"]),
        "xlb·搜主题":     ("xlb_search_topic",       ["关键词": "query", "查询": "query", "最多": "limit"]),
        "xlb·主题内容":   ("xlb_get_topic",          ["browse_cmd": "browse_cmd"]),
        "xlb·主题元信息": ("xlb_get_topic_meta",     ["topic": "topic", "主题": "topic"]),
        "xlb·标签内容":   ("xlb_get_topic_section",  ["topic": "topic", "section": "section", "filter": "filter", "mode": "mode", "最多": "limit", "offset": "offset"]),
        "xlb·图谱":       ("xlb_graph",              ["mode": "mode", "from": "from", "to": "to", "hops": "hops", "最多": "limit"]),
        "xlb·当前视图":   ("xlb_agent_state",        ["with_meta": "with_meta", "consume": "consume"]),
        "xlb·语法帮助":   ("xlb_grammar_help",       [:]),
        "xlb·执行":       ("xlb_execute_command",    ["命令": "command", "command": "command", "browse_cmd": "command"]),
    ]

    /// Model-invented near-synonyms Python-parity table (`_TYPE_ALIAS`).
    static let typeAliases: [String: String] = [
        // write_file
        "写入文件": "写入完成", "文件写入": "写入完成", "保存文件": "写入完成",
        "创建文件": "写入完成", "新建文件": "写入完成",
        // edit_file
        "编辑文件": "局部替换", "修改文件": "局部替换", "替换": "局部替换",
        "文本替换": "局部替换", "局部编辑": "局部替换",
        // run_shell
        "执行命令": "命令输出", "shell命令": "命令输出", "shell": "命令输出",
        "运行命令": "命令输出", "命令": "命令输出", "跑命令": "命令输出",
        "运行shell": "命令输出", "执行": "命令输出",
        // read_file
        "读文件": "文件内容", "读取文件": "文件内容", "查看文件": "文件内容",
        "文件": "文件内容", "读": "文件内容",
        // file_outline
        "大纲": "文件大纲", "文件签名": "文件大纲", "outline": "文件大纲",
        "文件概要": "文件大纲", "概要": "文件大纲",
        // list_dir
        "列出目录": "目录列表", "ls": "目录列表", "列目录": "目录列表",
        // grep
        "搜索": "搜索结果", "查找": "搜索结果", "grep": "搜索结果",
        // glob
        "文件路径": "路径匹配", "find": "路径匹配", "查找文件": "路径匹配",
        // http_get
        "抓取": "网页内容", "网页": "网页内容", "url": "网页内容", "URL 内容": "网页内容",
        // apply_diff
        "应用补丁": "差量应用", "补丁": "差量应用", "diff": "差量应用",
        // legacy Swift-only name
        "历史查询": "查历史",
        // Screen History tools — accept the English tool name the
        // agent sometimes emits verbatim, alongside the canonical
        // "屏幕历史·XXX" keys.
        "rewind_search": "屏幕历史·搜索",
        "rewind_frame":  "屏幕历史·帧详情",
        "rewind_recap":  "屏幕历史·日汇总",
        "rewind_ask":    "屏幕历史·问答",
        "rewind_recent": "屏幕历史·最近",
        "rewind_events": "屏幕历史·会议",
        "rewind_transcript": "屏幕历史·转录",
        "rewind_thumbnail":  "屏幕历史·缩略图",
        "rewind_show_frame": "屏幕历史·打开帧",
        "rewind_locate":     "屏幕历史·定位",
    ]

    /// Canonical CN keys that the tool tables use verbatim. Used by
    /// `mapCNToTool` to give CN wins over EN aliases on mixed input.
    static let cnKeys: Set<String> = [
        "路径", "起始", "长度", "根目录", "模式", "忽略大小写",
        "命令", "工作目录", "超时秒", "超时", "网址", "查询", "上下文",
        "关键词", "会话", "最多", "内容", "原文", "新文", "编辑",
        "片段", "首块", "更多", "补丁", "任务", "策略", "文件",
        "提示",
    ]

    /// CN argument-key aliases — Python `_ARG_ALIAS`.
    static let argAliases: [String: String] = [
        "path": "路径", "file": "路径", "文件": "路径", "文件路径": "路径",
        "content": "内容", "text": "内容", "body": "内容",
        "old": "原文", "旧": "原文", "旧内容": "原文", "search": "原文",
        "new": "新文", "新": "新文", "新内容": "新文", "replace": "新文",
        "cmd": "命令", "command": "命令", "shell": "命令",
        "cwd": "工作目录", "workdir": "工作目录",
        "url": "网址", "link": "网址",
        "pattern": "模式", "glob": "模式", "regex": "模式", "正则": "模式",
        "root": "根目录", "base": "根目录",
        "diff": "补丁", "patch": "补丁",
        "mode": "模式", "append": "模式",
        "offset": "起始", "length": "长度",
        "limit": "最多",
    ]

    /// E13 eligibility: only fire BLOB offload for small-context
    /// models where vision decode < text prior cost. Skip for
    /// Anthropic-family 200k models.
    private func blobOffloadEligible() -> Bool {
        guard let mid = modelID else { return false }
        return AssistAgentCompactionConstants.blobOffloadEligibleModels
            .contains(mid)
    }

    /// E13: pull large step bodies out of the text prior and render
    /// them into a single grayscale JPEG for the vision channel.
    /// Returns nil when there's nothing worth offloading or when the
    /// rendered JPEG exceeds the size cap. Rewrites the text prior
    /// to replace offloaded blobs with `→ BLOB #N` pointers.
    private func buildBlobOffload(currentPrior: String) throws
        -> (jpeg: Data, prior: String)?
    {
        guard currentPrior.count >=
            AssistAgentCompactionConstants.blobOffloadMinPriorChars else {
            return nil
        }
        // Collect big step bodies. Only offload types where the body
        // dominates prior size: read_file, grep, run_shell, http_get.
        let offloadKinds: Set<String> = [
            "文件内容", "命令输出", "搜索结果", "网页内容",
        ]
        var blobs: [String] = []
        var blobIndex = 0
        var replacements: [(String, String)] = []
        let minChars = AssistAgentCompactionConstants.blobOffloadPerStepMinChars
        for (i, s) in session.steps.enumerated() where offloadKinds.contains(s.kind) {
            guard s.raw.count > minChars else { continue }
            let realIdx = session.compactedBefore + i + 1
            let primary = s.args["path"] ?? s.args["cmd"]
                ?? s.args["url"] ?? s.args["pattern"] ?? "?"
            let header = "--- BLOB #\(realIdx) · \(s.kind) · \(String(primary.prefix(80))) ---"
            let body = compactForPrior(step: s)
            let footer = "--- END BLOB #\(realIdx) ---"
            blobs.append("\(header)\n\(body)\n\(footer)")
            blobIndex += 1
            // Replace in text prior the full body with the pointer.
            replacements.append((s.raw, "→ BLOB #\(realIdx) (\(s.raw.count)c)"))
        }
        guard blobIndex >= 2 else { return nil }  // need >=2 to save real cost
        let content = blobs.joined(separator: "\n\n")
        guard let rendered = AssistAgentPriorImage.renderTextToJPEG(
            content, quality: 0.65) else { return nil }
        // Size cap.
        if rendered.jpeg.count >
            AssistAgentCompactionConstants.blobOffloadJPEGMaxBytes {
            return nil
        }
        // Rewrite the text prior. Naive substring replace is safe here
        // because raw bodies are long verbatim slices.
        var slim = currentPrior
        for (needle, ptr) in replacements {
            slim = slim.replacingOccurrences(of: needle, with: ptr)
        }
        // Prepend an explanation of what the image contains.
        let banner = "[Attached image contains \(blobIndex) large tool-result " +
            "blobs referenced below by `BLOB #N`. Read directly from image.]\n\n"
        return (rendered.jpeg, banner + slim)
    }

    /// E14: fetch a compact menu line for every registered MCP tool.
    /// Python parity: `_menu_with_mcp()` (agent.py:1707). One line per
    /// tool, capped to 60 chars — the goal is discovery, not full
    /// schema (model looks up schema via description if it needs it).
    private func mcpMenuLines() async -> [String] {
        let tools = await AssistAgentMCPRegistry.shared.allTools()
        guard !tools.isEmpty else { return [] }
        return tools.map { t in
            let desc = t.description.isEmpty ? "" : "  " + String(t.description.prefix(50))
            return "- 类型 \"\(t.canonicalName)\":\(desc)"
        }
    }

    /// E7: plan-status block — round prefix listing PROGRESS.md
    /// unchecked steps + reference docs so the model always knows
    /// its next concrete action. Python parity: _plan_status_block.
    /// Assist-in-App variant drops the orchestrator/dispatch_parallel
    /// section since sub-agent dispatch is disabled here (M8 shim).
    private func planStatusBlock() -> String {
        guard let progressPath = session.planProgressPath else { return "" }
        let progressText = AssistAgentPlanDriven.readProgress(progressPath)
        if progressText.isEmpty { return "" }
        let unchecked = AssistAgentPlanDriven.uncheckedSteps(progressText)
        let marker = session.planCompletionMarker

        var lines: [String] = ["[plan-driven]"]
        lines.append("progress_file: \(progressPath)")
        lines.append("completion_marker: \(marker)")

        if let taskDir = session.planTaskDir {
            var refDocs: [String] = []
            let proposal = (taskDir as NSString).appendingPathComponent("proposal.md")
            let specsDir = (taskDir as NSString).appendingPathComponent("specs")
            if FileManager.default.fileExists(atPath: proposal) {
                refDocs.append("proposal.md (full original spec/goal)")
            }
            if let files = try? FileManager.default.contentsOfDirectory(atPath: specsDir) {
                let mdFiles = files.filter { $0.lowercased().hasSuffix(".md") }.sorted()
                if !mdFiles.isEmpty {
                    let head = mdFiles.prefix(5).joined(separator: ", ")
                    let more = mdFiles.count > 5 ? ", ..." : ""
                    refDocs.append("specs/ (\(mdFiles.count) files: \(head)\(more))")
                }
            }
            if !refDocs.isEmpty {
                lines.append("reference_docs (in task_dir; read_file when needed):")
                for r in refDocs { lines.append("  - \(r)") }
            }
        }

        if !unchecked.isEmpty {
            lines.append("")
            lines.append("unchecked steps (\(unchecked.count) total, in order):")
            for (i, step) in unchecked.enumerated() {
                lines.append("  \(i + 1). \(step)")
            }
            lines.append("")
            lines.append(
                "When every step is checked off, emit " +
                "{\"步骤\":\"完成\",\"答案\":\"...\"} — the runner will stamp " +
                "`\(marker)` in PROGRESS.md and exit. On any completed step, add " +
                "`\"step_done\":\"<verbatim step text>\"` to your reply so it ticks."
            )
        } else {
            lines.append(
                "No unchecked steps remain. Emit " +
                "{\"步骤\":\"完成\",\"答案\":\"...\"} — the runner will stamp " +
                "`\(marker)` and exit."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// M4: local rotation digest. Dense text summary of ALL steps
    /// (except the last 3, kept intact). Never calls the model —
    /// Python parity: agent.py::_build_local_rotation_digest. The
    /// old session's output is already crippled, so we must NOT ask
    /// it to summarise.
    private func buildLocalRotationDigest() -> String {
        let foldEnd = max(0, session.steps.count - 3)
        guard foldEnd > 0 else { return "" }
        var lines: [String] = []
        lines.append("# 会话摘要 (本地生成 · \(foldEnd) steps, task=\(String(session.userTask.prefix(80))))")
        for i in 0..<foldEnd {
            let s = session.steps[i]
            let idx = session.compactedBefore + i + 1
            let tag = s.ok ? "✓" : "✗"
            let primary = s.args["path"] ?? s.args["cmd"] ?? s.args["url"] ?? s.args["pattern"] ?? ""
            // Pull a compact fact: first result line, first 200 chars.
            var fact = s.result
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map(String.init) ?? ""
            if fact.count > 200 { fact = String(fact.prefix(200)) + "…" }
            lines.append("S\(idx) \(tag) \(s.kind) \(String(primary.prefix(60))): \(fact)")
        }
        return lines.joined(separator: "\n")
    }

    /// M6: `.heyclicky/{plan,scratchpad}.md` tail block. Injected as
    /// the very first section of round-1's prior so a resumed dialog
    /// picks up cross-session state. Python parity: agent.py::_workspace_block.
    private func workspaceBlock() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        var lines: [String] = []
        let files: [(String, String)] = [
            ("plan.md", "计划"),
            ("scratchpad.md", "工作笔记"),
        ]
        for (name, label) in files {
            let p = (cwd as NSString).appendingPathComponent(".heyclicky/\(name)")
            guard FileManager.default.fileExists(atPath: p),
                  let body = try? String(contentsOfFile: p, encoding: .utf8),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let tail = String(body.suffix(2500))
            lines.append("\n=== 项目\(label) (.heyclicky/\(name) 尾部) ===\n\(tail)\n=== \(label)结束 ===")
        }
        if !lines.isEmpty {
            lines.append(
                "\n提示: 你可以调用 局部替换 或 写入完成 维护 .heyclicky/plan.md 和 " +
                ".heyclicky/scratchpad.md,把跨轮次的计划与关键结论写进去。下次启动会自动加载。"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// M2: build the head-alert list. Only checks that map to real
    /// signals in the App's tool set — same-cmd fails, cwd errors,
    /// last-was-web-search. Non-plan features (`round_no > cap - 1`
    /// cap-hint) live in `buildTailHints` instead.
    private func buildHeadAlerts(round: Int) -> [String] {
        var alerts: [String] = []
        // F1: same shell cmd failed twice in a row.
        let failedShells = session.steps.filter { $0.kind == "命令输出" && !$0.ok }
        if failedShells.count >= 2 {
            let lastCmd = failedShells.last!.args["cmd"] ?? ""
            let prevCmd = failedShells.dropLast().last!.args["cmd"] ?? ""
            if !lastCmd.isEmpty && lastCmd == prevCmd {
                let lastErr = String(failedShells.last!.raw.prefix(200))
                alerts.append(
                    "命令 '\(String(lastCmd.prefix(100)))' 已连续失败 2 次。" +
                    "错误摘要: \(lastErr)。请换一种诊断策略(检查 python vs python3、" +
                    "检查 cwd 是否存在、先用 目录列表 确认)。不要再原样重跑。"
                )
            }
        }
        // F2: last shell failed with cwd-related error.
        if let last = session.steps.last, last.kind == "命令输出" && !last.ok {
            let rawLC = last.raw.lowercased()
            if rawLC.contains("cwd") || rawLC.contains("no such file or directory") {
                alerts.append(
                    "上一步 命令输出 因为 工作目录 无效而失败。" +
                    "请忽略 工作目录 参数或用相对路径(默认继承 agent 启动目录)。"
                )
            }
        }
        return alerts
    }

    /// F3-F5: tail hints — appended AFTER prior. Uses same-round
    /// signals: web_search no-op, near cap, heavy prior.
    private func buildTailHints(round: Int, priorLen: Int) -> [String] {
        var hints: [String] = []
        // F4: near cap — prompt to finish soon.
        let remaining = effectiveMaxRounds - round + 1
        if remaining <= 1 {
            hints.append("(提示:剩余轮次 \(remaining),请尽量在本轮或下一轮给出 步骤=完成 的最终答案)")
        }
        // F5: prior heavy — ask for concise answer if it goes done.
        if priorLen > 20_000 {
            hints.append("(提示:上下文较长,如果给出 步骤=完成 的答案请控制在 300 字以内,只输出结论)")
        }
        // F3: last step was 网络搜索 no-op — use built-in web capability.
        if let last = session.steps.last, last.kind == "网络搜索" {
            let q = last.args["query"] ?? ""
            hints.append(
                "(重要:你上一步请求了 网络搜索(查询='\(String(q.prefix(80)))')。" +
                "本工具不会由客户端执行,请你直接用你自带的联网搜索能力," +
                "本轮以 步骤=完成 输出基于最新网络信息的答案。)"
            )
        }
        return hints
    }

    /// M5: automatically pin high-value facts from a completed step so
    /// long-session compaction preserves the "wrote X"/"grep Y ⇒ N hits"
    /// anchors. Python parity: agent.py `_auto_pin_from_step`.
    private func autoPinFromStep(_ step: AssistAgentSession.Step) {
        guard step.ok else { return }
        switch step.kind {
        case "写入完成", "局部替换", "追加片段", "差量应用":
            if let p = step.args["path"], !p.isEmpty {
                session.pinMemory("wrote/edited \(p)")
            }
        case "命令输出":
            if let cmd = step.args["cmd"], !cmd.isEmpty {
                let head = String(cmd.prefix(80))
                session.pinMemory("shell `\(head)` exit=0")
            }
        case "搜索结果":
            if let pat = step.args["pattern"], !pat.isEmpty {
                // Look for a match_count hint inside the result summary
                // (Python summariser emits `找到 N 处匹配`).
                if let range = step.result.range(of: "找到 "),
                   let end = step.result[range.upperBound...].firstIndex(of: " ") {
                    let n = step.result[range.upperBound..<end]
                    let short = String(pat.prefix(60))
                    session.pinMemory("grep `\(short)` ⇒ \(n) hits")
                }
            }
        default:
            break
        }
    }

    /// Salvage a partial summary when max_rounds hits without a `完成`.
    /// The main dialog inlines this so the user gets useful signal
    /// (last few concrete findings) rather than "unavailable".
    private func buildPartialSummary() -> String {
        let successful = session.steps
            .filter { $0.ok && $0.kind != "_reminder" }
            .suffix(5)
        guard !successful.isEmpty else {
            return "达到最大轮次但没有产出可用答案。"
        }
        var lines: [String] = ["未在轮次内给出最终答案。到目前为止查到:"]
        for (i, s) in successful.enumerated() {
            let idx = session.compactedBefore + session.steps.count - successful.count + i + 1
            let arg = s.args["path"] ?? s.args["cmd"] ?? s.args["url"]
                ?? s.args["pattern"] ?? ""
            let head = s.result
                .split(separator: "\n").first
                .map { $0.count > 100 ? $0.prefix(100) + "…" : $0 } ?? ""
            lines.append("  S\(idx) \(s.kind) \(String(arg.prefix(60))): \(head)")
        }
        return lines.joined(separator: "\n")
    }

    private func buildResult(from obj: [String: Any], rounds: Int) -> AssistAgentResult {
        let summary = (obj["答案"] as? String) ?? ""
        // Stage-10 will attach citations from step-log heuristics.
        return AssistAgentResult(
            summary: summary,
            citations: [],
            unresolved: (obj["未解决"] as? [String]) ?? [],
            artifactsWritten: (obj["产出"] as? [String]) ?? [],
            rounds: rounds
        )
    }
}
