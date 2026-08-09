//
//  AssistAgentHistory.swift
//  cursor-buddy
//
//  L3 on-disk history: every step is appended to
//  `~/.heyclicky-agent-history/<session_id>.jsonl`. The `query_history`
//  tool reads this back so folded-off / microcompacted steps are still
//  retrievable. Meta file supports future --resume. Python parity:
//  agent.py::_persist_step_to_history + _persist_session_meta.
//

import Foundation

public enum AssistAgentHistory {

    public static let historyDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".heyclicky-agent-history")

    private static let queue = DispatchQueue(
        label: "assist-agent.history", qos: .utility)

    private static func ensureDir() {
        try? FileManager.default.createDirectory(
            at: historyDir, withIntermediateDirectories: true)
    }

    /// Append one step record to `<sid>.jsonl` and refresh meta. Non-blocking.
    @MainActor
    public static func persistStep(sessionID: UUID,
                                   compactedBefore: Int,
                                   stepIndex: Int,
                                   step: AssistAgentSession.Step) {
        // Snapshot on main thread; write on utility queue.
        let sidStr = sessionID.uuidString.lowercased()
        let rec: [String: Any] = [
            "step_idx": compactedBefore + stepIndex,
            "op_kind": step.kind,
            "tool": step.tool,
            "args": step.args,
            "why": step.why,
            "result": step.result,
            "ok": step.ok,
            "elapsed_ms": step.elapsedMs,
            "ts": ISO8601DateFormatter().string(from: step.startedAt),
        ]
        queue.async {
            ensureDir()
            let path = historyDir.appendingPathComponent("\(sidStr).jsonl")
            guard let data = try? JSONSerialization.data(
                withJSONObject: rec,
                options: [.withoutEscapingSlashes]),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            if let fh = try? FileHandle(forWritingTo: path) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: Data(line.utf8))
                try? fh.close()
            } else {
                // First write — create the file.
                try? Data(line.utf8).write(to: path, options: [.atomic])
            }
        }
    }

    /// Refresh `<sid>.meta.json` — carried across compaction + resume.
    @MainActor
    public static func persistMeta(sessionID: UUID,
                                   userTask: String,
                                   digest: String,
                                   compactedBefore: Int,
                                   serverSyncedSteps: Int,
                                   adaptiveResyncInterval: Int,
                                   totalRotations: Int,
                                   consecutiveDeltaSuccesses: Int,
                                   pinnedMemory: [String],
                                   stepsCount: Int) {
        let sidStr = sessionID.uuidString.lowercased()
        let meta: [String: Any] = [
            "session_id": sidStr,
            "user_task": userTask,
            "digest": digest,
            "compacted_before": compactedBefore,
            "server_synced_steps": serverSyncedSteps,
            "adaptive_resync_interval": adaptiveResyncInterval,
            "total_rotations": totalRotations,
            "consecutive_delta_successes": consecutiveDeltaSuccesses,
            "pinned_memory": pinnedMemory,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
            "steps_count": stepsCount,
        ]
        queue.async {
            ensureDir()
            let metaPath = historyDir.appendingPathComponent("\(sidStr).meta.json")
            let tmpPath  = historyDir.appendingPathComponent("\(sidStr).meta.json.tmp")
            guard let data = try? JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
            try? data.write(to: tmpPath, options: [.atomic])
            _ = try? FileManager.default.replaceItem(
                at: metaPath, withItemAt: tmpPath,
                backupItemName: nil, options: [], resultingItemURL: nil)
        }
    }

    /// List recorded sessions (newest first) for a hypothetical
    /// --list-sessions CLI or debug view.
    public static func listSessions(limit: Int = 50) -> [(id: String, task: String, updatedAt: String, steps: Int)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: historyDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String, String, Int)] = []
        for f in entries where f.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let sid = obj["session_id"] as? String
                ?? f.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
            let task = (obj["user_task"] as? String).map { String($0.prefix(80)) } ?? ""
            let updated = obj["updated_at"] as? String ?? ""
            let steps = obj["steps_count"] as? Int ?? 0
            out.append((sid, task, updated, steps))
        }
        out.sort { $0.2 > $1.2 }
        return Array(out.prefix(limit))
    }
}
