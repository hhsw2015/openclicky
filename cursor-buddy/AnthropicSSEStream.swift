//
//  AnthropicSSEStream.swift
//  cursor-buddy
//
//  Small SSE parser shared by every Anthropic-shaped streaming caller.
//  The Anthropic Messages API framing is `event: <type>\ndata: {json}\n\n`
//  where each `data:` payload is a JSON object with a `type` field.
//
//  This helper only surfaces `text_delta` chunks — the exact contract
//  the voice-response pipeline and the Peeky orchestrator's streaming
//  path both want. Callers that need the raw event stream (thinking
//  blocks, tool_use, structured output) should keep parsing themselves.
//
//  Semantics preserved from the two prior copies verbatim:
//   * chunk boundaries do not respect line boundaries → line buffer
//   * `data: [DONE]` and `type == "message_stop"` both terminate
//   * `type == "error"` throws NSError(domain: "AnthropicSSE", -1, message)
//   * everything else is ignored (unknown types are non-fatal)
//
//  Reference: docs/mirage-openclicky-integration-plan.md § SSE parity.

import Foundation

enum AnthropicSSEStream {
    /// Drain an SSE byte stream and return the accumulated assistant text.
    /// `onTextChunk` fires for each `text_delta.text` as it arrives so the
    /// caller can pipeline into StreamingTTSSession / UI without buffering.
    static func drainTextDeltas<S: AsyncSequence>(
        _ chunkStream: S,
        onTextChunk: @escaping (String) -> Void
    ) async throws -> String where S.Element == Data {
        var accumulated = ""
        var lineBuf = ""
        for try await chunk in chunkStream {
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            lineBuf += text
            while let nlRange = lineBuf.range(of: "\n") {
                let line = String(lineBuf[..<nlRange.lowerBound])
                lineBuf.removeSubrange(..<nlRange.upperBound)
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst("data: ".count))
                if payload == "[DONE]" { return accumulated }
                guard let jsonData = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "content_block_delta",
                   let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    accumulated += t
                    onTextChunk(t)
                } else if type == "message_stop" {
                    return accumulated
                } else if type == "error" {
                    let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                    throw NSError(
                        domain: "AnthropicSSE",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: msg]
                    )
                }
            }
        }
        // Final flush: some upstreams close the stream without a
        // trailing `\n` after `data: [DONE]` or after the last
        // content_block_delta. Drain whatever is still in the line
        // buffer so we do not silently drop the last event. Same
        // parsing rules as the main loop.
        let tail = lineBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.hasPrefix("data: ") {
            let payload = String(tail.dropFirst("data: ".count))
            if payload != "[DONE]",
               let jsonData = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let type = obj["type"] as? String {
                if type == "content_block_delta",
                   let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    accumulated += t
                    onTextChunk(t)
                } else if type == "error" {
                    let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                    throw NSError(
                        domain: "AnthropicSSE",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: msg])
                }
            }
        }
        return accumulated
    }
}
