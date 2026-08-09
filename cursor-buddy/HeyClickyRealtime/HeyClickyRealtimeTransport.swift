//
//  HeyClickyRealtimeTransport.swift
//  cursor-buddy
//
//  Direct port of clicky-mac RealtimeTransport.swift.
//  URLSessionWebSocketTask driver for the OpenAI Realtime WS endpoint.
//  Emits an AsyncStream<HeyClickyRealtimeEvent> for higher layers to consume.
//
//  Keep-alive matches HeyClicky IDA-reversed warmConnectionKeepAliveTimer
//  (7 s Timer + native task.sendPing). OpenAI rejects {"type":"KeepAlive"},
//  so we ONLY send the native ping — the HeyClicky-format ping is left as
//  a comment for reference.
//

import Foundation

enum HeyClickyRealtimeEvent {
    case sessionCreated(model: String, instructions: String?)
    case sessionUpdated
    case speechStarted
    case speechStopped
    case committed
    case userTranscriptDelta(String)
    case userTranscriptDone(String)
    case responseCreated
    case assistantItemStarted(itemId: String)
    case audioDelta(Data)
    case assistantTranscriptDelta(String)
    case assistantTranscriptDone(String)
    case toolCallStarted(itemId: String, callId: String, name: String)
    case toolCallArgumentsDelta(callId: String, delta: String)
    case toolCallArgumentsDone(callId: String, name: String, arguments: String)
    case responseDone(status: String)
    case error(code: String, message: String)
    case unknown(String)
}

actor HeyClickyRealtimeTransport {
    private var task: URLSessionWebSocketTask?
    private var eventContinuation: AsyncStream<HeyClickyRealtimeEvent>.Continuation?
    private var isRunning = false

    // Names of function_call items indexed by call_id so we can attach
    // a name to `toolCallArgumentsDone` events even when the argument-
    // delta frames omit the tool name.
    private var callIdToToolName: [String: String] = [:]

    private(set) var events: AsyncStream<HeyClickyRealtimeEvent> = AsyncStream { _ in }

    init() {
        var localContinuation: AsyncStream<HeyClickyRealtimeEvent>.Continuation!
        events = AsyncStream { continuation in
            localContinuation = continuation
        }
        Task { await self.setContinuation(localContinuation) }
    }

    private func setContinuation(_ continuation: AsyncStream<HeyClickyRealtimeEvent>.Continuation) {
        eventContinuation = continuation
    }

    // MARK: - Keep-alive
    //
    // clicky-mac reproduces HeyClicky's warmConnectionKeepAliveTimer with
    // BOTH `{"type":"KeepAlive"}` and native task.sendPing. OpenAI's public
    // Realtime API rejects `KeepAlive` (`invalid_value` server error) so we
    // ship only the native ping — WebSocket protocol pings never mutate
    // application-level session state and always keep the socket alive.
    private var pingTimer: Timer?

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.sendKeepAlive() }
        }
    }

    private func sendKeepAlive() async {
        guard let task else { return }
        task.sendPing { _ in }
    }

    // MARK: - Connect / disconnect

    func connect(endpoint: String, ephemeral: String, model: String) async throws {
        guard var comps = URLComponents(string: endpoint) else {
            throw NSError(
                domain: "HeyClickyRealtimeTransport",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid endpoint"]
            )
        }
        var query = comps.queryItems ?? []
        if !query.contains(where: { $0.name == "model" }) {
            query.append(URLQueryItem(name: "model", value: model))
        }
        comps.queryItems = query
        guard let url = comps.url else {
            throw NSError(
                domain: "HeyClickyRealtimeTransport",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "cannot build URL"]
            )
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(ephemeral)", forHTTPHeaderField: "Authorization")

        let ws = URLSession.shared.webSocketTask(with: request)
        task = ws
        isRunning = true
        ws.resume()
        startPingTimer()
        Task { await self.receiveLoop() }
    }

    func disconnect() {
        isRunning = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Send

    func send(_ payload: [String: Any]) async throws {
        guard let task else {
            throw NSError(
                domain: "HeyClickyRealtimeTransport",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "transport lost"]
            )
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let s = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(s))
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        while isRunning, let task {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let str):
                    handleMessage(str)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        handleMessage(s)
                    }
                @unknown default:
                    break
                }
            } catch {
                eventContinuation?.yield(.error(code: "ws_receive", message: "\(error)"))
                isRunning = false
                break
            }
        }
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            eventContinuation?.yield(.unknown(raw))
            return
        }
        switch type {
        case "session.created":
            let session = json["session"] as? [String: Any] ?? [:]
            let model = (session["model"] as? String) ?? ""
            let instructions = session["instructions"] as? String
            eventContinuation?.yield(.sessionCreated(model: model, instructions: instructions))
        case "session.updated":
            eventContinuation?.yield(.sessionUpdated)
        case "input_audio_buffer.speech_started":
            eventContinuation?.yield(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            eventContinuation?.yield(.speechStopped)
        case "input_audio_buffer.committed":
            eventContinuation?.yield(.committed)
        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String {
                eventContinuation?.yield(.userTranscriptDelta(delta))
            }
        case "conversation.item.input_audio_transcription.completed":
            let transcript = (json["transcript"] as? String) ?? ""
            eventContinuation?.yield(.userTranscriptDone(transcript))
        case "response.created":
            eventContinuation?.yield(.responseCreated)
        case "response.output_audio.delta", "response.audio.delta":
            if let deltaB64 = json["delta"] as? String,
               let bytes = Data(base64Encoded: deltaB64) {
                eventContinuation?.yield(.audioDelta(bytes))
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = json["delta"] as? String {
                eventContinuation?.yield(.assistantTranscriptDelta(delta))
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            let transcript = (json["transcript"] as? String) ?? ""
            eventContinuation?.yield(.assistantTranscriptDone(transcript))
        case "response.output_item.added":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String
                if itemType == "function_call",
                   let itemId = item["id"] as? String,
                   let callId = item["call_id"] as? String,
                   let name = item["name"] as? String {
                    callIdToToolName[callId] = name
                    eventContinuation?.yield(.toolCallStarted(itemId: itemId, callId: callId, name: name))
                } else if itemType == "message",
                          let itemId = item["id"] as? String {
                    eventContinuation?.yield(.assistantItemStarted(itemId: itemId))
                }
            }
        case "response.function_call_arguments.delta":
            let callId = (json["call_id"] as? String) ?? ""
            let delta = (json["delta"] as? String) ?? ""
            eventContinuation?.yield(.toolCallArgumentsDelta(callId: callId, delta: delta))
        case "response.function_call_arguments.done":
            let callId = (json["call_id"] as? String) ?? ""
            let arguments = (json["arguments"] as? String) ?? ""
            let name = callIdToToolName[callId] ?? ""
            eventContinuation?.yield(.toolCallArgumentsDone(callId: callId, name: name, arguments: arguments))
        case "response.done":
            let response = json["response"] as? [String: Any]
            let status = (response?["status"] as? String) ?? "unknown"
            // Log usage so we can verify the model actually saw our
            // injected stash context. Realtime API `response.done`
            // carries `usage.input_tokens` + breakdown of
            // `input_token_details.text_tokens` — if text_tokens is
            // large, the stash / preflight was consumed.
            if let usage = response?["usage"] as? [String: Any] {
                let inputTokens = usage["input_tokens"] as? Int ?? -1
                let outputTokens = usage["output_tokens"] as? Int ?? -1
                let details = usage["input_token_details"] as? [String: Any] ?? [:]
                let textTokens = details["text_tokens"] as? Int ?? -1
                let audioTokens = details["audio_tokens"] as? Int ?? -1
                let cachedTokens = details["cached_tokens"] as? Int ?? -1
                HeyClickyLog.log(
                    "realtime.session_usage",
                    lane: "voice",
                    direction: "incoming",
                    [
                        "input_total": inputTokens,
                        "output_total": outputTokens,
                        "text": textTokens,
                        "audio": audioTokens,
                        "cached": cachedTokens
                    ]
                )
            }
            eventContinuation?.yield(.responseDone(status: status))
        case "error":
            let err = (json["error"] as? [String: Any]) ?? [:]
            let code = (err["code"] as? String) ?? "unknown"
            let msg = (err["message"] as? String) ?? ""
            eventContinuation?.yield(.error(code: code, message: msg))
        default:
            eventContinuation?.yield(.unknown(type))
        }
    }
}
