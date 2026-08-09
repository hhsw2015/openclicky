//
//  AssistAgentSession.swift
//  cursor-buddy
//
//  In-App assist agent session state. Port of
//  heyclicky_agent/agent.py::AgentSession, trimmed to what the App
//  needs (no CLI TUI concerns, no plan-file self-drive markers — that
//  belongs in AssistAgentPlan.swift when Stage 7 lands).
//
//  Marked @MainActor + ObservableObject so the notch / mini-chat / UI
//  can observe live progress without a separate event router.
//

import Foundation
import Combine

@MainActor
public final class AssistAgentSession: ObservableObject, Identifiable {
    public let id: UUID
    public let userTask: String

    /// Step log. Each entry is a completed think→tool→result triple.
    /// Kind/args/result use the same Chinese-JSON canonical shape as
    /// the Python reference so shared prompt templates keep working.
    /// Setter is internal so the compaction pass can rewrite individual
    /// entries in place.
    @Published public internal(set) var steps: [Step] = []

    /// Model-authored summary of steps that were compacted away.
    /// Grows across microcompact rounds; may itself be trimmed when
    /// it bloats past DIGEST_MAX_CHARS.
    @Published public internal(set) var digest: String = ""

    /// steps[0..<compactedBefore] have been folded into `digest`.
    @Published public internal(set) var compactedBefore: Int = 0

    /// Facts that must survive every compaction. Auto-populated by
    /// heuristics (successful writes, key discoveries) plus explicit
    /// pin_memory tool calls. Bounded to 32 entries.
    @Published public internal(set) var pinnedMemory: [String] = []

    /// AIMD adaptive re-baseline interval (see Python
    /// INCREMENTAL_* constants). Every round sends only the delta
    /// steps[serverSyncedSteps..<count]; a full baseline goes out
    /// every `adaptiveResyncInterval` rounds or on memory loss.
    @Published public internal(set) var serverSyncedSteps: Int = 0
    @Published public internal(set) var roundsSinceFullBaseline: Int = 0
    @Published public internal(set) var forceFullNextRound: Bool = true
    @Published public internal(set) var adaptiveResyncInterval: Int = 3
    @Published public internal(set) var consecutiveDeltaSuccesses: Int = 0
    @Published public internal(set) var resyncHistory: [(interval: Int, outcome: String)] = []

    /// Session-rotation state: > 2 consecutive empties at the floor
    /// interval → we cycle the X-Clicky-Session-Id header so a poisoned
    /// server session doesn't ruin the run.
    @Published public internal(set) var consecutiveEmptyAtFloor: Int = 0

    /// Empty streak on the CURRENT session_id only. Reset on successful
    /// reply OR on session_rotate. Drives the "rotate first, hop later"
    /// ladder — docs/ROOT_CAUSE.md finding #12.
    @Published public internal(set) var sameSessionEmptyStreak: Int = 0

    /// Rolling record of recent successful reply lengths. Used to
    /// spot the "output budget decay" pattern where a saturating server
    /// session shrinks the allowed reply size.
    @Published public internal(set) var recentReplyLens: [Int] = []

    /// Circuit-breaker state — refuses to loop on the same
    /// (op_kind, error signature) pair beyond a small threshold.
    @Published public internal(set) var lastErrorSignature: String = ""
    @Published public internal(set) var sameErrorStreak: Int = 0
    @Published public internal(set) var totalRotations: Int = 0

    // MARK: - Plan-driven state (B2-B5, E7)

    /// PROGRESS.md path when driven by `[free-agent-longrun]` header.
    /// nil means the run is ad-hoc (default assist agent mode).
    public internal(set) var planProgressPath: String? = nil
    public internal(set) var planTaskDir: String? = nil
    public internal(set) var planCompletionMarker: String = "LAST_COMPLETED: DONE"

    /// Stashed handoff briefing — consumed exactly once by the next
    /// prior build after an account hop / cross-session resume so
    /// the fresh server session sees complete state continuity.
    /// Python parity: `session._pending_handoff_briefing`.
    public internal(set) var pendingHandoffBriefing: String? = nil

    /// Optional live event tap. AssistAgentLoop pushes here on every
    /// event so consumers (registry, TTS bridge) can subscribe once.
    public let events = PassthroughSubject<AssistAgentEvent, Never>()

    public init(userTask: String, id: UUID = UUID()) {
        self.id = id
        self.userTask = userTask
    }

    /// Parse `[free-agent-longrun]` header out of `task` and return a
    /// session pre-configured for plan-driven mode. When
    /// `tryResumeFromDisk` is true and a saved session with a matching
    /// task exists, its digest + pinned facts + last steps rehydrate
    /// so the new invocation continues where the last one stopped.
    public static func fromTask(_ task: String,
                                tryResumeFromDisk: Bool = true) -> AssistAgentSession {
        let header = AssistAgentPlanDriven.extractHeader(task)

        // Attempt disk resume — same task text hitting the most-recent
        // saved session inherits its state.
        if tryResumeFromDisk, header.cleanedTask.count > 10,
           let sid = AssistAgentHandoff.mostRecentSession(matching: header.cleanedTask),
           let resumed = AssistAgentHandoff.resumeFromDisk(sessionID: sid) {
            if let taskDir = header.taskDir {
                resumed.planTaskDir = taskDir
                resumed.planProgressPath = (taskDir as NSString)
                    .appendingPathComponent("PROGRESS.md")
                resumed.planCompletionMarker = header.progressMarker
            }
            // Attach handoff briefing so the resumed session's first
            // request carries state continuity to the fresh server sid.
            resumed.pendingHandoffBriefing = AssistAgentHandoff.buildBriefing(resumed)
            return resumed
        }

        let session = AssistAgentSession(userTask: header.cleanedTask)
        if let taskDir = header.taskDir {
            session.planTaskDir = taskDir
            session.planProgressPath = (taskDir as NSString)
                .appendingPathComponent("PROGRESS.md")
            session.planCompletionMarker = header.progressMarker
        }
        return session
    }

    // MARK: - Mutations (loop-facing)

    public struct Step: Identifiable, Sendable {
        public let id: UUID
        public let kind: String        // canonical CN op_kind ("读文件", "写入完成", ...)
        public let tool: String        // canonical EN tool name ("read_file", "write_file", ...)
        public let args: [String: String]
        public let why: String
        public let result: String      // compacted summary suitable for prior injection
        public let raw: String         // full raw tool result before compaction
        public let ok: Bool
        public let startedAt: Date
        public let elapsedMs: Int

        public init(kind: String, tool: String, args: [String: String], why: String,
                    result: String, raw: String, ok: Bool,
                    startedAt: Date = Date(), elapsedMs: Int = 0,
                    id: UUID = UUID()) {
            self.id = id
            self.kind = kind
            self.tool = tool
            self.args = args
            self.why = why
            self.result = result
            self.raw = raw
            self.ok = ok
            self.startedAt = startedAt
            self.elapsedMs = elapsedMs
        }
    }

    func appendStep(_ step: Step) {
        steps.append(step)
    }

    func replaceCompacted(newDigest: String, newBoundary: Int) {
        digest = newDigest
        compactedBefore = newBoundary
    }

    func pinMemory(_ fact: String, cap: Int = 32, maxLen: Int = 200) {
        // Python parity: trim, per-entry length cap, dedup, preserve
        // head + drop middle when overflowing.
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = trimmed.count > maxLen
            ? String(trimmed.prefix(maxLen))
            : trimmed
        if pinnedMemory.contains(clipped) { return }
        pinnedMemory.append(clipped)
        if pinnedMemory.count > cap {
            // Preserve index 0 (usually the original user_task nuance
            // — often the most load-bearing fact); drop from the
            // middle. Python parity: agent.py:2296.
            let head = pinnedMemory[0]
            let tail = Array(pinnedMemory.dropFirst().suffix(cap - 1))
            pinnedMemory = [head] + tail
        }
    }

    // MARK: - Adaptive resync bookkeeping

    func recordDeltaSuccess() {
        consecutiveDeltaSuccesses += 1
        roundsSinceFullBaseline += 1
        // AIMD additive-increase — Python `_aimd_grow` (agent.py:3509):
        // grow by +1 only after EVERY 2 consecutive delta successes
        // (probing behavior). Previous Swift impl grew every success,
        // reaching max_resync in ~30 turns; Python takes ~60 turns.
        if consecutiveDeltaSuccesses >= 2 {
            let old = adaptiveResyncInterval
            adaptiveResyncInterval = min(adaptiveResyncInterval + 1,
                                         Self.incrementalMaxResync)
            if adaptiveResyncInterval > old {
                resyncHistory.append((adaptiveResyncInterval, "grow"))
            }
            consecutiveDeltaSuccesses = 0
        }
    }

    func recordDeltaFailure(reason: String) {
        consecutiveDeltaSuccesses = 0
        // AIMD multiplicative-decrease
        adaptiveResyncInterval = max(adaptiveResyncInterval / 2,
                                     Self.incrementalMinResync)
        forceFullNextRound = true
        resyncHistory.append((adaptiveResyncInterval, reason))
    }

    func emit(_ event: AssistAgentEvent) {
        events.send(event)
    }

    /// Record a successful non-empty reply length. Bounded to the last
    /// 8 entries so `_safe_chunk_size` reads a small tail.
    /// Mirrors Python `session.recent_reply_lens.append(len(text))`.
    func recordReplyLength(_ len: Int) {
        recentReplyLens.append(len)
        if recentReplyLens.count > 8 {
            recentReplyLens.removeFirst(recentReplyLens.count - 8)
        }
    }

    /// Recommended max chunk size for the NEXT write. Mirrors Python
    /// `_safe_chunk_size`: min of last 4 reply lengths / 1.5 - 150,
    /// floor 400, cap 1500. 1500 default when no history yet.
    func safeChunkSize() -> Int {
        let tail = Array(recentReplyLens.suffix(4))
        guard let smallest = tail.min() else { return 1500 }
        if smallest == 0 { return 400 }
        return max(400, min(1500, Int(Double(smallest) / 1.5) - 150))
    }

    // MARK: - Static tuning constants (mirror Python)

    public static let incrementalMinResync = 2
    public static let incrementalMaxResync = 30
    public static let incrementalStartResync = 3
}

/// Prior-compression budget constants — chars are approximated as
/// tokens × 4 (Anthropic-family rule of thumb). Mirror the Python
/// _MODEL_CTX_TOKENS / _OUTPUT_RESERVE_TOKENS / _SYSTEM_OVERHEAD_TOKENS
/// so ported code reads the same.
public enum AssistAgentBudget {
    public static let defaultContextTokens = 200_000
    public static let outputReserveTokens = 16_000
    public static let systemOverheadTokens = 12_000
    public static let charsPerToken = 4

    public static func priorCharBudget(for modelID: String?) -> Int {
        let ctx = modelContextTokens[modelID ?? ""] ?? defaultContextTokens
        let working = ctx - outputReserveTokens - systemOverheadTokens
        return max(20_000, working * charsPerToken)
    }

    public static let modelContextTokens: [String: Int] = [
        "claude-fable-5":            200_000,
        "claude-sonnet-5":           200_000,
        "claude-opus-4-7":           200_000,
        "claude-opus-4-8":           200_000,
        "claude-haiku-4-5-20251001": 200_000,
    ]
}
