//
//  AssistAgentRegistry.swift
//  cursor-buddy
//
//  Observable registry of every live assist-agent session — the main
//  one plus any parallel sub-agents. UI surfaces (notch badge, mini
//  chat progress rows, settings diagnostics) subscribe to `agents`
//  and re-render on any @Published mutation.
//
//  Port of heyclicky_agent/registry.py, trimmed to what an @MainActor
//  ObservableObject needs.
//

import Foundation
import Combine

@MainActor
public final class AssistAgentRegistry: ObservableObject {
    public static let shared = AssistAgentRegistry()

    public struct Entry: Identifiable, Sendable {
        public let id: UUID           // AssistAgentSession.id
        public var label: String      // "main" or "sub:t1" etc.
        public var email: String      // credential this agent runs as
        public var round: Int
        public var toolsRun: Int
        public var lastMessage: String
        public var status: Status
        public var startedAt: Date

        public enum Status: String, Sendable {
            case running, done, error
        }
    }

    @Published public private(set) var agents: [Entry] = []

    /// Notch status-pill hook. When set, every registry mutation
    /// pushes a short caption to the persistent pill so the user
    /// sees WHICH tool the assist agent is running WITHOUT having
    /// to open the main panel. CompanionManager assigns this in
    /// its init.
    public var notchCaptionSink: (@MainActor (String?) -> Void)?

    /// Publicly-readable pill caption for anyone (e.g. the notch
    /// window manager's width calculator) that needs to react to
    /// current assist state without going through the sink.
    public private(set) var notchPillCaption: String?

    private init() {}

    /// Compute the caption for the notch status pill. Return the
    /// FULL message — the pill width calculation on the App side
    /// scales to fit the caption string, so pre-truncating here
    /// just leaves the widened pill with empty space at the end.
    /// nil when nothing is running.
    private func currentCaption() -> String? {
        if let running = agents.first(where: { $0.status == .running }) {
            let msg = running.lastMessage
            if !msg.isEmpty { return msg }
            return "助理探索中"
        }
        let cutoff = Date().addingTimeInterval(-8)
        if let err = agents.last(where: {
            $0.status == .error && $0.startedAt > cutoff
        }) {
            return err.lastMessage.isEmpty ? "已停" : err.lastMessage
        }
        return nil
    }

    /// Reduce a full path/cmd/URL to its most-recognizable tail so
    /// the pill stays readable. Prefer basename for paths, first
    /// binary word for shell cmds, host for URLs.
    static func shortenTarget(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        // Path: keep basename
        if trimmed.hasPrefix("/") || trimmed.contains("/") {
            let base = (trimmed as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        // URL: keep host
        if trimmed.hasPrefix("http") {
            if let url = URL(string: trimmed), let host = url.host {
                return host
            }
        }
        // Shell cmd: first token
        if trimmed.contains(" ") {
            let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
            return head + " …"
        }
        // Fallback: trim to 30 chars
        return trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
    }

    /// Compact a tool result summary — extract signal (bytes, exit
    /// code, hit count) instead of prose.
    static func shortenSummary(_ raw: String) -> String {
        // e.g. "read /Users/.../ROADMAP.md full 8109B" → "8109B"
        // e.g. "run cat ... exit=0 8109B" → "exit=0 · 8109B"
        // e.g. "found 3 matches" → "3 matches"
        let s = raw.trimmingCharacters(in: .whitespaces)
        // Byte size
        if let m = s.range(of: #"\b\d+B\b"#, options: .regularExpression) {
            let bytes = String(s[m])
            var parts: [String] = [bytes]
            if let e = s.range(of: #"exit=\S+"#, options: .regularExpression) {
                parts.insert(String(s[e]), at: 0)
            }
            return parts.joined(separator: " · ")
        }
        // Fallback: first 40 chars
        return s.count > 40 ? String(s.prefix(40)) + "…" : s
    }

    private func flushCaption() {
        let caption = currentCaption()
        self.notchPillCaption = caption
        guard let sink = notchCaptionSink else { return }
        Task { @MainActor in sink(caption) }
    }

    // MARK: - Mutations

    /// Register a fresh agent session; returns true if it was new.
    @discardableResult
    public func register(id: UUID, label: String, email: String) -> Bool {
        if agents.contains(where: { $0.id == id }) { return false }
        agents.append(Entry(
            id: id, label: label, email: email,
            round: 0, toolsRun: 0, lastMessage: "",
            status: .running, startedAt: Date()))
        flushCaption()
        return true
    }

    public func bumpRound(id: UUID, round: Int) {
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].round = round
            flushCaption()
        }
    }

    public func recordTool(id: UUID, summary: String) {
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].toolsRun += 1
            agents[i].lastMessage = summary
            flushCaption()
        }
    }

    public func setMessage(id: UUID, _ msg: String) {
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].lastMessage = msg
            flushCaption()
        }
    }

    public func finish(id: UUID, status: Entry.Status = .done) {
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].status = status
            flushCaption()
        }
    }

    /// Drop entries older than `keepSec` that have reached a terminal
    /// state. Cheap, idempotent. Call between top-level dialog turns.
    public func compact(keepSec: TimeInterval = 300) {
        let deadline = Date().addingTimeInterval(-keepSec)
        agents.removeAll { entry in
            entry.status != .running && entry.startedAt < deadline
        }
    }

    // MARK: - Bridging AssistAgentEvent → Registry mutations

    public func bindEventStream(_ session: AssistAgentSession,
                                label: String, email: String) -> AnyCancellable {
        register(id: session.id, label: label, email: email)
        return session.events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event.kind {
                case .turnStart:
                    self.bumpRound(id: session.id, round: event.round)
                case .toolCall:
                    // Show WHAT the tool is doing, including its
                    // concrete target: "跑命令 · cat /Users/.../ROADMAP.md"
                    // rather than just "跑命令". Path/cmd/URL are tail-
                    // trimmed so the notch has room to breathe.
                    // Just show the raw target (path/cmd/URL/pattern).
                    // Adding a phrase prefix ("读文件 · ", "跑命令 · ")
                    // is redundant when the target itself makes the
                    // action obvious. Fall back to the phrase only
                    // when there's no target (rare).
                    let kind = event.data["kind"]?.stringValue ?? ""
                    let tool = event.data["tool"]?.stringValue ?? "?"
                    let target = event.data["target"]?.stringValue ?? ""
                    let display: String
                    if !target.isEmpty {
                        display = target
                    } else {
                        display = AssistAgentBridge.spokenPhrase(kind: kind, tool: tool)
                    }
                    self.setMessage(id: session.id, display)
                case .toolResult:
                    // Result: just prepend ✓/✗ to the summary — the
                    // summary itself already contains path/cmd/bytes,
                    // repeating the tool phrase would be redundant.
                    let kind = event.data["kind"]?.stringValue ?? ""
                    let tool = event.data["tool"]?.stringValue ?? "?"
                    let ok = event.data["ok"]?.boolValue ?? true
                    let summary = event.data["summary"]?.stringValue ?? ""
                    let display: String
                    if !summary.isEmpty {
                        display = "\(ok ? "✓" : "✗") \(summary)"
                    } else {
                        let phrase = AssistAgentBridge.spokenPhrase(kind: kind, tool: tool)
                        display = "\(ok ? "✓" : "✗") \(phrase)"
                    }
                    self.recordTool(id: session.id, summary: display)
                case .info:
                    // Info messages are the "still alive" pulse — user
                    // sees WHY the loop is taking N seconds. Empty
                    // classification, content-filter suspicion,
                    // grace-retry, nudge — all land here.
                    if let msg = event.data["message"]?.stringValue,
                       !msg.isEmpty {
                        self.setMessage(id: session.id, msg)
                    }
                case .sessionHop:
                    let reason = event.data["reason"]?.stringValue ?? ""
                    let to = event.data["to"]?.stringValue ?? "?"
                    if reason.hasPrefix("output_degrade") {
                        self.setMessage(id: session.id, "输出变短,换会话继续")
                    } else if reason.contains("empty_streak") {
                        self.setMessage(id: session.id, "换个账号重试(上一个没响应)")
                    } else {
                        self.setMessage(id: session.id, "切换会话 → \(String(to.prefix(20)))")
                    }
                case .done:
                    // Preserve the last successful message so the UI
                    // has something concrete to show right up until it
                    // fades out.
                    if let msg = event.data["message"]?.stringValue,
                       !msg.isEmpty {
                        self.setMessage(id: session.id, msg)
                    } else if let reason = event.data["reason"]?.stringValue,
                              reason == "max_rounds_partial" {
                        self.setMessage(id: session.id, "达到最大轮次,已给出部分答案")
                    } else {
                        self.setMessage(id: session.id, "查完了")
                    }
                    self.finish(id: session.id, status: .done)
                case .error:
                    // Error messages MUST stay visible so the user
                    // sees why the loop stopped, not just that it did.
                    if let err = event.data["error"]?.stringValue {
                        self.setMessage(id: session.id, err)
                    } else {
                        self.setMessage(id: session.id, "出错了")
                    }
                    self.finish(id: session.id, status: .error)
                case .compactBoundary:
                    let folded = event.data["folded_this_round"]?.intValue ?? 0
                    self.setMessage(id: session.id,
                                    "压缩了 \(folded) 步旧记录,继续")
                }
            }
        }
    }
}
