//
//  SKIModeConversationStore.swift
//  cursor-buddy
//
//  Per-workspace conversation model for SKI Mode. Observes the file
//  bridge (.oc/events.jsonl outbound, .oc/commands.jsonl inbound) and
//  builds a turn-by-turn message log the UI can render as a bubble.
//

import Foundation
import Combine

enum SKIMessageRole: String, Sendable, Codable {
    case user
    case agent
    case system
}

enum SKIMessageKind: String, Sendable, Codable {
    case text
    case ack       // agent's immediate-ack line ("好, 我看看")
    case toolCall  // agent.tool_call event (future — from extended JSONL kinds)
    case toolResult
    case final
    case notice    // "skill.dropped", "session.started", etc.
}

struct SKIMessage: Identifiable, Sendable, Equatable {
    let id: UUID
    let role: SKIMessageRole
    let kind: SKIMessageKind
    let text: String
    let ts: Date
    /// Optional session id from the file-bridge payload for pairing.
    let sessionID: String?

    init(
        id: UUID = UUID(),
        role: SKIMessageRole,
        kind: SKIMessageKind,
        text: String,
        ts: Date = Date(),
        sessionID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.ts = ts
        self.sessionID = sessionID
    }
}

struct SKISession: Identifiable, Sendable {
    let id: String       // UUID from UDS hello ack (or synthesized "typed-<uuid>")
    let workspace: String
    var messages: [SKIMessage]
    let startedAt: Date
    var isActive: Bool

    var title: String {
        let dir = (workspace as NSString).lastPathComponent
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(dir) · \(f.string(from: startedAt))"
    }
}

@MainActor
final class SKIModeConversationStore: ObservableObject {
    static let shared = SKIModeConversationStore()

    /// All sessions in insertion order (newest last).
    @Published private(set) var allSessions: [SKISession] = []
    /// Which session's transcript to show in the primary bubble.
    @Published var focusedSessionID: String?

    /// Currently-active session per workspace. New messages arriving
    /// from a workspace that has an active session append there; a
    /// workspace with no active session gets a fresh one.
    private var activeSessionByWorkspace: [String: String] = [:]

    private var tailTasks: [String: Task<Void, Never>] = [:]

    // Legacy accessors used by older UI callers ------------------------

    /// Convenience: focused session's workspace, if any.
    var focusedWorkspace: String? {
        get {
            guard let sid = focusedSessionID else { return nil }
            return allSessions.first(where: { $0.id == sid })?.workspace
        }
        set {
            // Setting a workspace focuses its most-recent session.
            guard let ws = newValue else { focusedSessionID = nil; return }
            if let session = allSessions.last(where: { $0.workspace == ws }) {
                focusedSessionID = session.id
            }
        }
    }

    func messages(for workspace: String) -> [SKIMessage] {
        // Combined view: all sessions for a workspace, in order.
        allSessions.filter { $0.workspace == workspace }.flatMap { $0.messages }
    }

    func focusedMessages() -> [SKIMessage] {
        guard let sid = focusedSessionID,
              let s = allSessions.first(where: { $0.id == sid }) else { return [] }
        return s.messages
    }

    /// Start a NEW session for this workspace + presenceSessionID.
    /// Called when a CLI agent connects (fresh UDS handshake).
    func beginSession(id: String, workspace: String) {
        // If a session with this exact id already exists (dedup on
        // reconnect races), just re-focus it.
        if allSessions.contains(where: { $0.id == id }) {
            focusedSessionID = id
            activeSessionByWorkspace[workspace] = id
            return
        }
        // FIX(task #324 2026-08-04): on reconnect for the same
        // workspace, drop any lingering inactive session for that
        // workspace so we don't stack two dock bubbles / two shims
        // during the grace window.
        allSessions.removeAll { $0.workspace == workspace && !$0.isActive }
        let s = SKISession(
            id: id,
            workspace: workspace,
            messages: [],
            startedAt: Date(),
            isActive: true
        )
        allSessions.append(s)
        // Cap history to 20 sessions total.
        if allSessions.count > 20 {
            allSessions.removeFirst(allSessions.count - 20)
        }
        activeSessionByWorkspace[workspace] = id
        focusedSessionID = id
        NotificationCenter.default.post(name: SKIModeConversationStore.sessionListDidChange, object: nil)
    }

    static let sessionListDidChange = Notification.Name("com.openclicky.ski.sessionListDidChange")

    /// Mark a session's underlying CLI agent as gone. Keep messages.
    /// Also broadcast `turnDidFinish` so any in-flight UI state (notch
    /// "thinking" caption, isSKITurnInFlight flag) clears — otherwise
    /// killing Claude Code mid-turn leaves the notch pill stuck.
    func endSession(id: String) {
        guard let idx = allSessions.firstIndex(where: { $0.id == id }) else { return }
        let workspace = allSessions[idx].workspace
        allSessions[idx].isActive = false
        if activeSessionByWorkspace[workspace] == id {
            activeSessionByWorkspace.removeValue(forKey: workspace)
        }
        // FIX(task #326 SKI-1): stop the workspace's tail Task once
        // no other active session references it. Prior behaviour
        // spawned a Task.detached per handshake that ran forever.
        let stillActive = allSessions.contains { $0.workspace == workspace && $0.isActive }
        if !stillActive {
            stopTailing(workspace: workspace)
        }
        NotificationCenter.default.post(
            name: SKIModeConversationStore.turnDidFinish,
            object: nil,
            userInfo: [
                "workspace": workspace,
                "sessionID": id,
                "reason": "peer_disconnected"
            ]
        )
    }

    /// Get or synthesize the active session id for a workspace. Used
    /// when the user speaks/types before a CLI has connected.
    func activeSessionID(forWorkspace workspace: String) -> String {
        if let id = activeSessionByWorkspace[workspace] { return id }
        let id = "typed-" + UUID().uuidString
        beginSession(id: id, workspace: workspace)
        return id
    }

    func append(_ message: SKIMessage, workspace: String) {
        let sessionID = activeSessionID(forWorkspace: workspace)
        guard let idx = allSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var msgs = allSessions[idx].messages
        // Dedup exact-string / exact-role within 200ms.
        if let last = msgs.last,
           last.role == message.role,
           last.text == message.text,
           message.ts.timeIntervalSince(last.ts) < 0.2 {
            return
        }
        msgs.append(message)
        // Cap per user preference (Settings → SKI Mode → notch_history_turns).
        // Falls back to 200 when unset, matching the previous default.
        var cap = UserDefaults.standard.integer(forKey: "openclicky.ski.notchHistoryTurns")
        if cap <= 0 { cap = 200 }
        if msgs.count > cap {
            msgs.removeFirst(msgs.count - cap)
        }
        allSessions[idx].messages = msgs
        // Focus the session that just received a message.
        focusedSessionID = sessionID
        // No auto-panel show — SKIModeDockMirror puts a dock bubble
        // in the top-right agent dock; user hovers to see caption and
        // clicks a button to open the conversation panel. Auto-popping
        // the full panel every turn would be intrusive.
    }

    func clear(sessionID: String) {
        if let idx = allSessions.firstIndex(where: { $0.id == sessionID }) {
            allSessions[idx].messages = []
        }
    }


    /// Start tailing `<workspace>/.oc/commands.jsonl` and append every
    /// tts.speak / agent.* line into the store. Idempotent per workspace.
    func startTailing(workspace: String) {
        if tailTasks[workspace] != nil { return }
        let ws = workspace
        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            await self?.tailLoop(workspace: ws)
            return ()
        }
        tailTasks[workspace] = task
    }

    func stopTailing(workspace: String) {
        tailTasks[workspace]?.cancel()
        tailTasks[workspace] = nil
    }

    private nonisolated func tailLoop(workspace: String) async {
        let commandsPath = URL(fileURLWithPath: workspace)
            .appendingPathComponent(".oc/commands.jsonl")
        // Start at current EOF so we don't re-play history from prior
        // sessions; only new lines land in the bubble.
        var offset = fileSize(commandsPath)
        while !Task.isCancelled {
            let size = fileSize(commandsPath)
            if size > offset {
                if let data = readTail(url: commandsPath, from: offset, to: size) {
                    offset = size
                    let text = String(data: data, encoding: .utf8) ?? ""
                    for line in text.split(separator: "\n") where !line.isEmpty {
                        parseAndAppend(line: String(line), workspace: workspace)
                    }
                }
            } else if size < offset {
                // File truncated (rare); reset.
                offset = size
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private nonisolated func parseAndAppend(line: String, workspace: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let cmd = (obj["command"] as? String) ?? (obj["event"] as? String) ?? ""
        let sessionID = (obj["session_id"] as? String)
            ?? ((obj["args"] as? [String: Any])?["session_id"] as? String)
        let rawText = (obj["text"] as? String)
            ?? ((obj["args"] as? [String: Any])?["text"] as? String)
            ?? ""

        let role: SKIMessageRole
        let kind: SKIMessageKind
        var text = rawText
        switch cmd {
        case "tts.speak":
            role = .agent
            kind = looksLikeAck(text) ? .ack : .final
        case "tts.cancel":
            role = .system
            kind = .notice
            if text.isEmpty { text = "reply cancelled" }
        case "agent.thinking":
            role = .agent
            kind = .toolCall
            if text.isEmpty { text = "thinking…" }
        case "agent.tool_call":
            role = .agent
            kind = .toolCall
            let toolName = (obj["name"] as? String)
                ?? ((obj["args"] as? [String: Any])?["name"] as? String)
                ?? "tool"
            let args = (obj["args"] as? [String: Any])?["args"]
                ?? obj["arguments"]
            let argSummary = Self.summariseArgs(args)
            text = argSummary.isEmpty ? "→ \(toolName)" : "→ \(toolName)  \(argSummary)"
        case "agent.tool_result":
            role = .agent
            kind = .toolResult
            let toolName = (obj["name"] as? String)
                ?? ((obj["args"] as? [String: Any])?["name"] as? String)
                ?? "tool"
            let preview = Self.previewText(text, max: 240)
            text = preview.isEmpty ? "← \(toolName) (ok)" : "← \(toolName)  \(preview)"
        case "agent.text_chunk":
            role = .agent
            kind = .text
        case "agent.done":
            // Codex uses `progressStage=.completed` (no chat bubble) to
            // mark a turn done. Broadcast a NotificationCenter event so
            // SKIModeDockMirror can flip the shim state — do NOT push
            // a "done" system bubble into the transcript, that's just
            // visual noise not present in the Codex path.
            NotificationCenter.default.post(
                name: SKIModeConversationStore.turnDidFinish,
                object: nil,
                userInfo: [
                    "workspace": workspace,
                    "sessionID": sessionID ?? ""
                ]
            )
            return
        case "screen.capture":
            // FIX(task #309 2026-08-04): the CLI-side skill writes
            // `{"command":"screen.capture"}` to commands.jsonl expecting
            // OpenClicky to shoot the main display and write back a
            // `screen.captured` event. Previously we only logged a
            // notice and never fired the actual capture — the CLI hung
            // waiting. Reuse the same capture path Ctrl+Shift+S uses.
            NotificationCenter.default.post(
                name: Notification.Name("com.openclicky.ski.captureScreenRequested"),
                object: nil
            )
            return
        case "voice.set":
            // SKI-parity: the skill can request a TTS voice change.
            // We broadcast a notification so CompanionManager can update
            // its preferred voice UserDefault; no transcript bubble.
            let requested = (obj["voice"] as? String)
                ?? ((obj["args"] as? [String: Any])?["voice"] as? String)
                ?? ""
            if !requested.isEmpty {
                NotificationCenter.default.post(
                    name: SKIModeConversationStore.voiceChangeRequested,
                    object: nil,
                    userInfo: ["voice": requested, "workspace": workspace]
                )
            }
            return
        default:
            return
        }

        let msg = SKIMessage(
            role: role,
            kind: kind,
            text: text.isEmpty ? cmd : text,
            ts: Date(),
            sessionID: sessionID
        )
        // Diagnostic: log every non-tts event so we can see whether
        // agent.tool_call / tool_result / thinking / done actually
        // flow into the store.
        if cmd != "tts.speak" {
            let previewCopy = String(text.prefix(80))
            let cmdCopy = cmd
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "openclicky.ski.tail_saw_agent_event",
                fields: ["cmd": cmdCopy, "preview": previewCopy, "workspace": workspace]
            )
        }
        Task { @MainActor [weak self] in
            self?.append(msg, workspace: workspace)
            // Also broadcast tts.speak lines so CompanionManager (or
            // any listener) can play audio + surface a response card
            // even when the reply arrived UNSOLICITED (agent proactively
            // wrote to commands.jsonl without a matching utterance).
            if cmd == "tts.speak" && !text.isEmpty {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "openclicky.ski.tail_saw_tts_speak",
                    fields: ["preview": String(text.prefix(60)), "workspace": workspace]
                )
                NotificationCenter.default.post(
                    name: SKIModeConversationStore.agentDidSpeak,
                    object: nil,
                    userInfo: [
                        "text": text,
                        "workspace": workspace,
                        "sessionID": sessionID ?? ""
                    ]
                )
            }
        }
    }

    static let agentDidSpeak = Notification.Name("com.openclicky.ski.agentDidSpeak")

    /// Fired when the CLI agent writes `agent.done`. Consumers can
    /// clear "thinking" captions or flip shim progress state, but no
    /// transcript bubble should be added.
    static let turnDidFinish = Notification.Name("com.openclicky.ski.turnDidFinish")

    /// Fired when the CLI agent writes `voice.set { voice: "..." }`.
    /// CompanionManager listens for this and updates the TTS voice.
    static let voiceChangeRequested = Notification.Name("com.openclicky.ski.voiceChangeRequested")

    /// Compact single-line render of tool arguments for the badge text.
    /// Prefers a `file_path`/`path`/`command`/`query` key when present.
    private nonisolated static func summariseArgs(_ raw: Any?) -> String {
        guard let raw = raw else { return "" }
        if let dict = raw as? [String: Any] {
            let priorityKeys = ["file_path", "path", "command", "query", "url", "pattern", "name"]
            for key in priorityKeys {
                if let value = dict[key] {
                    return previewText(stringify(value), max: 120)
                }
            }
            if let first = dict.first {
                return "\(first.key)=\(previewText(stringify(first.value), max: 80))"
            }
            return ""
        }
        return previewText(stringify(raw), max: 120)
    }

    private nonisolated static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }

    /// Trim to a single-line snippet capped at `max` chars.
    private nonisolated static func previewText(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= max { return flat }
        return String(flat.prefix(max)) + "…"
    }

    private nonisolated func looksLikeAck(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Short + ends with typical ack shape.
        if trimmed.count > 30 { return false }
        let acks = ["let me check", "on it", "looking", "checking", "one sec",
                    "好", "看看", "稍等", "让我", "在看"]
        let lower = trimmed.lowercased()
        return acks.contains { lower.contains($0.lowercased()) }
    }

    private nonisolated func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private nonisolated func readTail(url: URL, from: UInt64, to: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        let length = Int(to - from)
        return try? handle.read(upToCount: length)
    }
}
