//
//  OpenClickyFileBridge.swift
//  cursor-buddy
//
//  SKI-compatible file-bridge IPC for SKI Mode profile.
//    Writer: <workspace>/.oc/events.jsonl (append)
//    Reader: <workspace>/.oc/commands.jsonl (tail-until-response)
//
//  Protocol mirrors SKI's `.ski/` layout so a user's already-installed
//  SKI skill (in Claude Code, Codex, etc.) works against OpenClicky
//  with only the directory renamed.
//

import Foundation

actor OpenClickyFileBridge {
    static let shared = OpenClickyFileBridge()

    struct Event: Codable {
        let event: String
        let session_id: String
        let text: String?
        let screenshots: [String]?
        let ts: Double
        /// Structured, per-turn context signals. Emitted so the CLI
        /// agent has the same capability set as the in-app Lane A
        /// (HeyClicky Free), just plumbed as JSON on the event
        /// instead of prepended to the LLM prompt.
        let context: EventContext?
    }

    /// Two-tier structure:
    ///   - Small always-emitted fields (focused_window, mcp URL/token)
    ///   - `hints` map: signals that fired this turn, each with a
    ///     short natural-language `brief`. The CLI decides which
    ///     hints to expand via MCP tools (`tools/list` on the URL).
    struct EventContext: Codable {
        let focused_window: String?
        let openclicky_mcp_url: String?
        let openclicky_mcp_token: String?
        let hints: [String: Hint]?

        struct Hint: Codable {
            let brief: String
        }
    }

    /// Optional per-turn extras a caller can pass into
    /// `writeUtteranceAndAwait`. Nil-safe: missing signals are
    /// dropped from the emitted JSON, keeping the payload compact.
    struct UtteranceContext: Sendable {
        var focusedWindowLine: String? = nil
        var mcpURL: String? = nil
        var mcpToken: String? = nil
        var ltmMemoriesBrief: String? = nil
        var xlbTopicsBrief: String? = nil
        var screenOCRStashBrief: String? = nil
        var everywhereActiveWindowBrief: String? = nil
        var openrewindOCRHitsBrief: String? = nil
        var clipboardBrief: String? = nil
        var screenshotsBrief: String? = nil
        var screenshotPaths: [String]? = nil
    }

    /// Wait for the next tts.speak reply for a given session_id.
    /// Returns the .text field when found, or nil on timeout / cancel.
    func writeUtteranceAndAwait(
        workspace: URL,
        text: String,
        context: UtteranceContext? = nil,
        timeoutSeconds: TimeInterval = 8.0
    ) async -> String? {
        let dir = workspace.appendingPathComponent(".oc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString

        // Assemble the on-wire context object from the caller's
        // UtteranceContext (nil-safe — only signals that fired are
        // included). Design rationale: unlike the in-app Lane A (which
        // pre-bakes the full LTM/xlb/stash text into the LLM prompt
        // because assistant LLMs can't easily do multi-turn tool
        // calls in one turn), the SKI CLI can and DOES call MCP tools
        // on demand — so we only pass short natural-language hints.
        // The CLI reads a hint like "3 相关记忆 about handleTurn" and
        // decides whether to expand via MCP `search_transcripts`.
        var eventContext: EventContext? = nil
        if let ctx = context {
            var hints: [String: EventContext.Hint] = [:]
            if let b = ctx.ltmMemoriesBrief, !b.isEmpty { hints["ltm_memories"] = .init(brief: b) }
            if let b = ctx.xlbTopicsBrief, !b.isEmpty { hints["xlb_topics"] = .init(brief: b) }
            if let b = ctx.screenOCRStashBrief, !b.isEmpty { hints["screen_ocr_stash"] = .init(brief: b) }
            if let b = ctx.everywhereActiveWindowBrief, !b.isEmpty { hints["everywhere_active_window"] = .init(brief: b) }
            if let b = ctx.openrewindOCRHitsBrief, !b.isEmpty { hints["openrewind_ocr_hits"] = .init(brief: b) }
            if let b = ctx.clipboardBrief, !b.isEmpty { hints["clipboard"] = .init(brief: b) }
            if let b = ctx.screenshotsBrief, !b.isEmpty { hints["screenshots"] = .init(brief: b) }
            eventContext = EventContext(
                focused_window: ctx.focusedWindowLine,
                openclicky_mcp_url: ctx.mcpURL,
                openclicky_mcp_token: ctx.mcpToken,
                hints: hints.isEmpty ? nil : hints
            )
        }

        let event = Event(
            event: "utterance.final",
            session_id: sessionID,
            text: text,
            screenshots: context?.screenshotPaths,
            ts: Date().timeIntervalSince1970,
            context: eventContext
        )

        let eventsPath = dir.appendingPathComponent("events.jsonl")
        let commandsPath = dir.appendingPathComponent("commands.jsonl")

        // Record commands.jsonl offset BEFORE writing so we only see
        // responses to THIS utterance, not stale lines.
        let startOffset = fileSize(commandsPath)

        guard appendJSON(event, to: eventsPath) else { return nil }

        // Mirror the utterance into the SKI conversation store so the
        // bubble UI has a turn to render even before the agent replies.
        let userMessageText = text
        let workspaceString = workspace.path
        await MainActor.run {
            let store = SKIModeConversationStore.shared
            store.startTailing(workspace: workspaceString)
            if store.focusedWorkspace == nil {
                store.focusedWorkspace = workspaceString
            }
            store.append(
                SKIMessage(
                    role: .user,
                    kind: .text,
                    text: userMessageText,
                    ts: Date(),
                    sessionID: sessionID
                ),
                workspace: workspaceString
            )
            // No explicit UI trigger here — SKIModeDockMirror mirrors
            // every session into the existing agent dock via a Combine
            // subscription on SKIModeConversationStore.$allSessions,
            // so the standard right-edge dock item appears automatically.
        }

        return await pollForSpeakReply(
            commandsPath: commandsPath,
            startOffset: startOffset,
            sessionID: sessionID,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Append a raw event JSON to `<workspace>/.oc/events.jsonl`.
    /// Used by SKI-only status events (session.started, tts.done,
    /// tts.interrupted, screen.capture_failed) that the CLI skill
    /// documents but we previously never emitted.
    func emitEventLine(workspace: URL, payload: [String: Any]) {
        let dir = workspace.appendingPathComponent(".oc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("events.jsonl")
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [])
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                fsync(handle.fileDescriptor)
            } else {
                try data.write(to: path, options: .atomic)
            }
        } catch {
            // fire-and-forget — best effort
        }
    }

    // MARK: Private

    private func appendJSON<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            var data = try encoder.encode(value)
            data.append(0x0A) // newline
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                // FIX(oc-file-bridge-fsync-2026-08-04): macOS
                // `tail -F` uses kevent VNODE watches that sometimes
                // miss plain writes to a growing file (SKI's Rust
                // side fsyncs). Force the write through so the CLI
                // agent's tail loop wakes up immediately.
                fsync(handle.fileDescriptor)
            } else {
                try data.write(to: url, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func pollForSpeakReply(
        commandsPath: URL,
        startOffset: UInt64,
        sessionID: String,
        timeoutSeconds: TimeInterval
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var currentOffset = startOffset
        while Date() < deadline {
            if Task.isCancelled { return nil }
            let size = fileSize(commandsPath)
            if size > currentOffset {
                let newBytes = readTail(url: commandsPath, from: currentOffset, to: size)
                currentOffset = size
                if let text = extractSpeakText(from: newBytes, sessionID: sessionID) {
                    return text
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    private func readTail(url: URL, from: UInt64, to: UInt64) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        let length = Int(to - from)
        return (try? handle.read(upToCount: length)) ?? Data()
    }

    private func extractSpeakText(from data: Data, sessionID: String) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        for line in raw.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let cmd = (obj["command"] as? String) ?? (obj["event"] as? String)
            guard cmd == "tts.speak" else { continue }
            // session_id may live in the top-level payload, or in a nested "args".
            let sid = (obj["session_id"] as? String)
                ?? ((obj["args"] as? [String: Any])?["session_id"] as? String)
            if sid != nil, sid != sessionID { continue }
            let text = (obj["text"] as? String)
                ?? ((obj["args"] as? [String: Any])?["text"] as? String)
            if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return t
            }
        }
        return nil
    }
}

/// Best-effort project resolver. Returns the git root of the frontmost
/// window's file, if any; otherwise nil.
enum OpenClickyWorkspaceResolver {
    static func resolveActiveWorkspace() -> URL? {
        guard let ctx = AssistAgentActiveWindow.capture() else { return nil }
        let candidatePath: String? = ctx.inferredWorkdir ?? ctx.filePath
        guard let path = candidatePath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return gitRoot(startingFrom: url.hasDirectoryPath ? url : url.deletingLastPathComponent())
    }

    private static func gitRoot(startingFrom dir: URL) -> URL? {
        var current = dir.standardizedFileURL
        for _ in 0..<10 {
            let gitDir = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}
