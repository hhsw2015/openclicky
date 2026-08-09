//
//  OpenClickyRewindAIProvider.swift
//  cursor-buddy
//
//  Bridges OpenRewind's `OpenRewindAIProvider` protocol through
//  OpenClicky's multi-backend `ScreenHistoryAIProvider`. The user's
//  backend choice in Settings → Screen History → "AI backend" routes
//  each request.
//
//  ScreenHistoryAIProvider is one-shot (non-streaming); we adapt by
//  emitting a single `.textDelta` + `.isFinal` chunk. Tool-calling is
//  not surfaced (rewind's chat only uses tools for its own search;
//  assist-agent gets those via the MCP path instead).
//

import Foundation

public final class OpenClickyRewindAIProvider: OpenRewindAIProvider {

    public var displayName: String { "OpenClicky" }

    private let provider = ScreenHistoryAIProvider()

    public init() {}

    public func complete(
        messages: [OpenRewindChatMessage],
        tools: OpenRewindToolCatalog
    ) -> AsyncThrowingStream<OpenRewindChatChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let prompt = Self.flatten(messages: messages)
                    let reply = try await self.provider.summarize(prompt)
                    continuation.yield(OpenRewindChatChunk(textDelta: reply,
                                                          isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.yield(OpenRewindChatChunk(
                        isFinal: true,
                        error: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func flatten(messages: [OpenRewindChatMessage]) -> String {
        messages
            .map { m in "[\(m.role.rawValue)] \(m.content)" }
            .joined(separator: "\n\n")
    }
}
