//
//  AssistAgentEvent.swift
//  cursor-buddy
//
//  Event stream for the in-App assist agent. Consumed by:
//    · AssistAgentRegistry — UI badges / per-agent progress bars
//    · TTS bridge — before-tool voice announcement
//    · HeyClickyLog — structured JSONL trace
//
//  Kinds mirror heyclicky_agent/agent.py::AgentEvent so the port
//  stays call-compatible with the Python reference.
//

import Foundation

public enum AssistAgentEventKind: String, Sendable {
    case turnStart      = "turn_start"
    case toolCall       = "tool_call"
    case toolResult     = "tool_result"
    case info           = "info"
    case sessionHop     = "session_hop"
    case compactBoundary = "compact_boundary"
    case done           = "done"
    case error          = "error"
}

public struct AssistAgentEvent: Sendable {
    public let kind: AssistAgentEventKind
    public let round: Int
    public let data: [String: AssistAgentEventValue]

    public init(kind: AssistAgentEventKind, round: Int, data: [String: AssistAgentEventValue] = [:]) {
        self.kind = kind
        self.round = round
        self.data = data
    }
}

/// Typed JSON-ish value tree so events remain Sendable without
/// dragging in Foundation.NSNumber boxing surprises.
public enum AssistAgentEventValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AssistAgentEventValue])
    case dict([String: AssistAgentEventValue])
    case null

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
