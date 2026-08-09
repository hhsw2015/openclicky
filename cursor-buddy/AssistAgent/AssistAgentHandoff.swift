//
//  AssistAgentHandoff.swift
//  cursor-buddy
//
//  Cross-session continuity: handoff briefing + resume-from-disk.
//  Python parity:
//    · _build_handoff_briefing (agent.py:2332)
//    · load_session_from_disk  (agent.py:2164)
//    · list_saved_sessions     (agent.py:2217)
//
//  Assist agent uses these on:
//    · SESSION ROTATE — after 3 back-to-back empties, briefing gets
//      prepended to the next round's prior so the fresh server session
//      inherits state.
//    · RESUME — when the App re-opens a task with the same userTask,
//      `AssistAgentSession.resumeFromDisk(taskHint:)` pulls the last-
//      touched matching session and pre-fills digest + pinnedMemory +
//      last N steps.
//
//  Single-account variant: no account_hop, but the SAME briefing
//  logic lets us survive session_rotate + cross-invocation gaps.
//

import Foundation

public enum AssistAgentHandoff {

    /// Handoff briefing — a compact, self-contained prior that carries
    /// pinned facts + digest + last-3 steps. Prepended to a fresh
    /// server session's first round so the model doesn't restart cold.
    /// Python parity: agent.py::_build_handoff_briefing (2332).
    @MainActor
    public static func buildBriefing(_ session: AssistAgentSession) -> String {
        var parts: [String] = []
        parts.append("=== 交接说明 (Session Handoff) ===")
        parts.append(
            "上一个会话上下文接近满,切换到新 session 继续。" +
            "以下是必须携带的连贯状态,请基于这些继续之前的工作,不要重新开始。"
        )
        parts.append("")
        parts.append("[原始任务]\n\(session.userTask)")
        parts.append("")
        if !session.pinnedMemory.isEmpty {
            parts.append("[固定记忆 (\(session.pinnedMemory.count) 条 · 永不遗忘)]")
            for m in session.pinnedMemory { parts.append("  · \(m)") }
            parts.append("")
        }
        if !session.digest.isEmpty {
            parts.append("[早期进展摘要 · 已折叠 \(session.compactedBefore) 步]")
            parts.append(session.digest)
            parts.append("")
        }
        // Last 3 concrete step results — preserve "just did X" context.
        let handoffLastN = 3
        if !session.steps.isEmpty {
            let recent = session.steps.suffix(handoffLastN)
            parts.append("[最近 \(recent.count) 步 (未折叠)]")
            let baseIdx = session.compactedBefore + (session.steps.count - recent.count)
            for (i, s) in recent.enumerated() {
                let idx = baseIdx + i + 1
                let tag = s.ok ? "✓" : "✗"
                let primary = s.args["path"] ?? s.args["cmd"] ?? s.args["url"] ?? s.args["pattern"] ?? ""
                let body: String = {
                    var b = s.result
                    if b.count > 500 { b = String(b.prefix(500)) + "…" }
                    return b
                }()
                parts.append("S\(idx) \(tag) \(s.kind) \(String(primary.prefix(80)))")
                parts.append("  → \(body)")
            }
        }
        parts.append("")
        parts.append("[如何获取更早的历史]")
        parts.append(
            "  · 早期步骤都在本地 .jsonl 归档;调用 查历史 工具即可检索。" +
            "  · 例如: {\"步骤\":\"需要\",\"类型\":\"查历史\",\"参数\":{\"关键词\":\"...\"}} 返回匹配的旧步骤。"
        )
        parts.append("")
        parts.append(
            "继续工作: 从最近步骤的自然延伸开始,不要重新读已读过的文件、" +
            "不要重复已完成的步骤,除非当前状态需要重新验证。"
        )
        parts.append("=== 交接结束 ===")
        return parts.joined(separator: "\n")
    }

    // MARK: - Disk resume

    /// Look up the most-recently-updated saved session whose task
    /// contains `taskHint` (case-insensitive substring). Returns nil
    /// when nothing matches — caller should start fresh.
    public static func mostRecentSession(matching taskHint: String) -> String? {
        let sessions = AssistAgentHistory.listSessions(limit: 100)
        let needle = taskHint.lowercased()
        for s in sessions where s.task.lowercased().contains(needle) {
            return s.id
        }
        return sessions.first?.id  // else fall back to most-recent regardless
    }

    /// Rebuild a session from disk. Loads meta.json + the last `keepRecent`
    /// step records from `<sid>.jsonl`. Older steps stay on disk (query_history
    /// still finds them). Returns nil when files missing/corrupt.
    /// Python parity: load_session_from_disk (agent.py:2164).
    @MainActor
    public static func resumeFromDisk(sessionID: String,
                                      keepRecent: Int = 10) -> AssistAgentSession? {
        let dir = AssistAgentHistory.historyDir
        let metaURL = dir.appendingPathComponent("\(sessionID).meta.json")
        let jsonlURL = dir.appendingPathComponent("\(sessionID).jsonl")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        else { return nil }

        let userTask = (meta["user_task"] as? String) ?? ""
        let digest = (meta["digest"] as? String) ?? ""
        let compactedBefore = (meta["compacted_before"] as? Int) ?? 0
        let resync = (meta["adaptive_resync_interval"] as? Int) ?? AssistAgentSession.incrementalStartResync
        let totalRot = (meta["total_rotations"] as? Int) ?? 0
        let deltaSucc = (meta["consecutive_delta_successes"] as? Int) ?? 0
        let pinned = (meta["pinned_memory"] as? [String]) ?? []

        // Parse a stable UUID out of the string when possible so
        // subsequent persist calls append to the same jsonl.
        let uuid = UUID(uuidString: sessionID) ?? UUID()
        let session = AssistAgentSession(userTask: userTask, id: uuid)
        session.digest = digest
        session.compactedBefore = compactedBefore
        session.adaptiveResyncInterval = resync
        session.totalRotations = totalRot
        session.consecutiveDeltaSuccesses = deltaSucc
        for m in pinned { session.pinMemory(m) }

        // Rehydrate the last `keepRecent` steps from jsonl.
        if let text = try? String(contentsOf: jsonlURL, encoding: .utf8) {
            var stepsAll: [AssistAgentSession.Step] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard let data = s.data(using: .utf8),
                      let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let step = AssistAgentSession.Step(
                    kind: (rec["op_kind"] as? String) ?? "",
                    tool: (rec["tool"] as? String) ?? "",
                    args: (rec["args"] as? [String: String]) ?? [:],
                    why: (rec["why"] as? String) ?? "",
                    result: (rec["result"] as? String) ?? "",
                    raw: (rec["result"] as? String) ?? "",
                    ok: (rec["ok"] as? Bool) ?? true,
                    startedAt: Date(),
                    elapsedMs: (rec["elapsed_ms"] as? Int) ?? 0)
                stepsAll.append(step)
            }
            let tail = Array(stepsAll.suffix(keepRecent))
            session.steps = tail
            // Anything older on disk is treated as folded into digest.
            let dropped = stepsAll.count - tail.count
            if dropped > 0 {
                session.compactedBefore = compactedBefore  // trust meta value
            }
        }

        // Fresh server session — even resumed, we send full baseline.
        session.serverSyncedSteps = 0
        session.forceFullNextRound = true
        return session
    }
}

