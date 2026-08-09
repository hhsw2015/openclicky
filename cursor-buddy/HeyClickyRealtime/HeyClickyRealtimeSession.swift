//
//  HeyClickyRealtimeSession.swift
//  cursor-buddy
//
//  Port of clicky-mac RealtimeSession.swift.
//  High-level orchestrator over HeyClickyRealtimeTransport +
//  HeyClickyRealtimeAudioEngine. Owns:
//    - single persistent WS across all PTT turns (no per-turn reconnect)
//    - PTT begin / end / barge-in
//    - tool_call dispatch → run screen-context tool → post result back
//      into the same WS so realtime speaks the answer INLINE
//    - ephemeral refresh every 8 minutes with seamless swap
//
//  Only used by the HeyClicky Free lane. Other providers (Apple / Claude
//  BYOK / OpenAI BYOK) keep their existing per-turn WS path. Wire-in
//  happens through `CompanionManager+HeyClickyRealtimeSession.swift`.
//

import AVFoundation
import AppKit
import Combine
import Foundation

/// Notification names posted by the session so the CompanionManager UI
/// can update without depending on the session object directly.
public extension Notification.Name {
    /// Fired when the WS connects successfully. userInfo: [:].
    static let heyClickyRealtimeSessionConnected =
        Notification.Name("heyClickyRealtimeSessionConnected")
    /// Fired when the WS gets a fatal error and won't reconnect.
    static let heyClickyRealtimeSessionFailed =
        Notification.Name("heyClickyRealtimeSessionFailed")
    /// Fired when a user turn transcription lands. userInfo: ["text": String]
    static let heyClickyRealtimeUserTranscript =
        Notification.Name("heyClickyRealtimeUserTranscript")
    /// Fired for each partial delta of user transcription — gives UI
    /// a live caption feel while the model is still hearing.
    static let heyClickyRealtimeUserTranscriptPartial =
        Notification.Name("heyClickyRealtimeUserTranscriptPartial")
    /// Fired when the assistant transcript is fully delivered.
    /// userInfo: ["text": String]
    static let heyClickyRealtimeAssistantTranscript =
        Notification.Name("heyClickyRealtimeAssistantTranscript")
}

@MainActor
final class HeyClickyRealtimeSession: ObservableObject {
    static let shared = HeyClickyRealtimeSession()

    // MARK: - Published state (bindable from SwiftUI / CompanionManager)

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isResponding: Bool = false
    /// Live RMS (0..1) of the assistant playback stream. Updated as new
    /// audio buffers get scheduled; CompanionManager forwards this to
    /// `cursorOverlayState.currentAudioPowerLevel` during `.responding`
    /// so the speaking-pulse ring amplitude tracks TTS energy instead
    /// of a stale mic reading.
    var currentPlaybackRMS: CGFloat { audioEngine.lastPlaybackRMS }
    @Published private(set) var lastServerError: (code: String, message: String)?

    // MARK: - Assistant playback tracking (barge-in)

    private var currentAssistantItemId: String?
    private var playedAssistantAudioMs: Int = 0

    // MARK: - Turn tracking

    private var currentUserTranscript: String = ""
    private var currentAssistantTranscript: String = ""
    private var pendingFillerResponseId: String?
    private var fillerCompleteContinuation: CheckedContinuation<Bool, Never>?

    /// Suspends until a filler `response.done` arrives (or forever if
    /// the caller uses their own timeout). Only one waiter at a
    /// time — subsequent calls overwrite the previous continuation.
    private func waitForFillerComplete() async -> Bool {
        return await withCheckedContinuation { cont in
            self.fillerCompleteContinuation = cont
        }
    }
    private var recentTurns: [(role: String, text: String)] = []
    private var pttStartedAt: Date?
    private var totalPTTBytesSent: Int = 0

    // MARK: - Reconnect / refresh

    private var reconnectAttempt: Int = 0
    private var refreshTimer: Timer?
    /// 8 minutes matches clicky-mac ephemeralRefreshIntervalSeconds default.
    /// OpenAI Realtime ephemerals live ~10 min, so we swap ~2 min before
    /// expiry to leave margin for the seamless swap.
    private static let ephemeralRefreshInterval: TimeInterval = 480

    // MARK: - Components

    private let audioEngine = HeyClickyRealtimeAudioEngine(sampleRate: 24_000)
    private var transport: HeyClickyRealtimeTransport?
    private var eventTask: Task<Void, Never>?

    /// Weak back-reference to the CompanionManager the app spawns at
    /// launch. Set once via `attach(_:)` from the main initializer path
    /// so the session can execute in-app side effects (screen capture,
    /// text injection, clipboard) without touching the SwiftUI hierarchy.
    private weak var companionManagerRef: CompanionManager?

    private init() {}

    func attach(companionManager: CompanionManager) {
        self.companionManagerRef = companionManager
    }

    // MARK: - Lifecycle

    /// Idempotent connect. Skips work when a live WS is already up.
    /// Call from CompanionManager on sign-in, on app foreground, on
    /// unexpected disconnect.
    func connect() async {
        if transport != nil && isConnected {
            return
        }
        do {
            let (token, expiresAt) = try await HeyClickySessionTokenClient.shared.mintRealtimeToken()
            _ = expiresAt
            let model = HeyClickySessionTokenClient.shared.bakedRealtimeModel ?? "gpt-realtime-2"
            let endpoint = "wss://api.openai.com/v1/realtime"
            let newTransport = HeyClickyRealtimeTransport()
            try await newTransport.connect(endpoint: endpoint, ephemeral: token, model: model)
            self.transport = newTransport
            // Cancel any orphan reader from a previous failed connect
            // before installing a fresh one, else two tasks compete for
            // events from different transports.
            eventTask?.cancel()
            eventTask = Task { [weak self] in await self?.consumeEvents(from: newTransport) }
            scheduleRefresh()
            HeyClickyLog.log("realtime.session_connect_ok", lane: "voice", direction: "internal", [
                "model": model
            ])
        } catch {
            lastServerError = (code: "connect_failed", message: "\(error)")
            HeyClickyLog.log("realtime.session_connect_fail", lane: "voice", direction: "error", [
                "error": "\(error)",
                "attempt": reconnectAttempt
            ])
            isConnected = false
            reconnectAttempt += 1
            // Cap reconnect chain at 5 attempts. Beyond that we STOP
            // auto-reconnecting — the next PTT press or manual reconnect
            // will reset the counter. Prevents runaway proxy hammering
            // when upstream Cloudflare Worker is down for a sustained
            // period.
            if reconnectAttempt > 5 {
                HeyClickyLog.log("realtime.session_connect_stopped", lane: "voice", direction: "error", [
                    "reason": "max_attempts_exceeded",
                    "attempt": reconnectAttempt
                ])
                return
            }
            let delayS = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayS * 1_000_000_000))
                await self?.connect()
            }
        }
    }

    func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        eventTask?.cancel()
        eventTask = nil
        Task { [weak transport] in
            await transport?.disconnect()
        }
        transport = nil
        isConnected = false
    }

    // MARK: - PTT

    /// User pressed the PTT hotkey. Barge-in current playback if the
    /// assistant is still talking, then start streaming mic audio.
    func beginPushToTalk() {
        HeyClickyLog.log("realtime.session_ptt_recv", lane: "voice", direction: "internal", [
            "has_transport": transport != nil ? "yes" : "no",
            "is_connected": isConnected ? "yes" : "no"
        ])
        // Both conditions matter: nil transport (never connected) AND
        // transport-object-exists-but-disconnected (WS died mid-session,
        // e.g. token expired, network blip). Without the isConnected
        // check, the mic starts + audio streams into a dead socket and
        // the user hears no reply until reconnect ~30s later.
        guard let transport, isConnected else {
            HeyClickyLog.log("realtime.session_ptt_reconnect", lane: "voice",
                             direction: "internal", [
                "has_transport": transport != nil ? "yes" : "no",
                "is_connected": isConnected ? "yes" : "no"
            ])
            Task { [weak self] in
                guard let self else { return }
                // User pressed PTT — reset the backoff counter so the
                // reconnect chain (capped at 5) starts fresh. Otherwise
                // once we hit the cap after upstream Cloudflare Worker
                // outage, no future PTT press could ever reconnect.
                self.reconnectAttempt = 0
                await self.connect()
                if self.transport != nil, self.isConnected {
                    self.beginPushToTalk()
                }
            }
            return
        }

        // Barge-in guard — playback may still be flushing even after
        // isResponding flipped false, so key off item id + played ms too.
        if isResponding || currentAssistantItemId != nil || playedAssistantAudioMs > 0 {
            interruptCurrentResponse()
            audioEngine.stopPlayback()
            currentAssistantItemId = nil
            playedAssistantAudioMs = 0
        }
        // Bridge to CompanionManager voiceState so overlay + notch UI
        // reflect the mic-listening state. Without this the buddy stays
        // idle / disappears while the user is actually speaking.
        // voiceState is set by the outer CompanionManager PTT shortcut
        // handler (clicky-mac parity — pressed → .listening, released →
        // .processing). Session only publishes isResponding; the
        // CompanionManager subscribes and maps to responding/idle.
        currentUserTranscript = ""
        currentAssistantTranscript = ""
        pttStartedAt = Date()
        totalPTTBytesSent = 0
        do {
            try audioEngine.startCapture { [weak self] base64 in
                Task { [weak self] in
                    guard let self else { return }
                    if Task.isCancelled { return }
                    // Look up transport on self each tick — after disconnect()
                    // nils it, further callback bytes drop cleanly instead of
                    // riding a retained dead WS to a cancelled peer.
                    guard let transport = self.transport else { return }
                    self.totalPTTBytesSent += (base64.count / 4) * 3
                    try? await transport.send([
                        "type": "input_audio_buffer.append",
                        "audio": base64
                    ])
                }
            }
        } catch {
            lastServerError = (code: "mic_start_failed", message: "\(error)")
        }
    }

    /// Automated-test entry point: send `text` as if the user had
    /// spoken it, without touching the microphone or STT. Realtime
    /// still runs its normal tool-call decision path, so the
    /// `intent` field lands in the same log as a real PTT turn —
    /// letting us batch-measure classifier accuracy in seconds
    /// instead of getting the user to say each case aloud.
    func simulateTextTurn(_ text: String) async {
        guard let transport = transport else {
            HeyClickyLog.log("realtime.simulate_text.error",
                             lane: "voice", direction: "error",
                             ["reason": "no_transport"])
            return
        }
        HeyClickyLog.log("realtime.simulate_text.begin",
                         lane: "voice", direction: "internal",
                         ["preview": String(text.prefix(60))])
        let itemPayload: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ]
        try? await transport.send(itemPayload)
        try? await transport.send(["type": "response.create"])
    }

    /// User released PTT. Flush remaining audio, commit + response.create.
    /// Skip commit when <100 ms of audio was captured (OpenAI rejects).
    func endPushToTalk() {
        audioEngine.flushPending()
        audioEngine.stopCapture()
        let bytes = totalPTTBytesSent
        let elapsed = pttStartedAt.map { -$0.timeIntervalSinceNow } ?? 0
        pttStartedAt = nil
        totalPTTBytesSent = 0
        HeyClickyLog.log("realtime.session_ptt_committed", lane: "voice", direction: "internal", [
            "bytes": bytes,
            "elapsed_ms": Int(elapsed * 1000)
        ])
        guard bytes >= 5_000 else {
            Task { [weak self] in
                guard let self, let transport = self.transport else { return }
                try? await transport.send(["type": "input_audio_buffer.clear"])
            }
            isResponding = false
            return
        }
        Task { [weak self] in
            guard let self, let transport = self.transport else { return }

            // Inject fresh stash context as a system-role message
            // BEFORE committing the audio + creating the response.
            // The HeyClicky Free server prompt has persona but no
            // knowledge of what the user just pinned/drew/copied —
            // this per-turn item bridges that gap.
            if let cm = await self.companionManagerRef {
                let stash = await cm.currentStashContextForVoiceTurn()
                if !stash.isEmpty {
                    // NOTE: role=user (not system). HeyClicky Free's WS
                    // proxy whitelists client events narrowly; system role
                    // conversation items are silently dropped by their
                    // server. Wrap the stash as a user note prefixed with
                    // "[context]" so the model recognises it as auxiliary
                    // rather than a spoken utterance.
                    let stashPayload: [String: Any] = [
                        "type": "conversation.item.create",
                        "item": [
                            "type": "message",
                            "role": "user",
                            "content": [["type": "input_text", "text": "[context] \(stash)"]]
                        ]
                    ]
                    try? await transport.send(stashPayload)
                    HeyClickyLog.log(
                        "realtime.session_stash_injected",
                        lane: "voice",
                        direction: "outgoing",
                        [
                            "chars": stash.count,
                            "preview": String(stash.prefix(600))
                        ]
                    )
                } else {
                    HeyClickyLog.log(
                        "realtime.session_stash_empty",
                        lane: "voice",
                        direction: "internal",
                        [:]
                    )
                }
            }

            // Long-term memory injection — per-turn, same shape as the
            // stash block above. Wrap as role=user "[memory]" prefix so
            // the HeyClicky Free proxy accepts it (system role is
            // stripped by their server). Content = ambient blocks +
            // any FTS hits keyed to the most recent user transcript,
            // if the STT layer surfaced one.
            // Best-effort query proxy for FTS: (1) any live transcript
            // the STT already produced this turn, (2) else the newest
            // user turn from local recentTurns. The current turn's own
            // transcript won't be available until `userTranscriptDone`,
            // which fires AFTER response.create. Using the prior turn
            // as query still helps when the user asks a follow-up like
            // "then what about X" — Memory hits stay topically close.
            let recentTranscript = await MainActor.run {
                self.companionManagerRef?.lastTranscript ?? ""
            }
            let priorUserInMemory = recentTurns.last(where: { $0.role == "user" })?.text ?? ""
            // In-memory recentTurns is empty across app restarts. Pull
            // the last stored user utterance from the vault so PTT after
            // a fresh boot still has query context.
            let priorUserFromVault = await MainActor.run { () -> String in
                guard let bridge = OpenRewindBridge.shared else { return "" }
                // FIX(speaker-column-2026-07-30): new rows carry
                // speakerId=0 for user; pre-migration rows use the
                // `[user] ` prefix. Query both to cover the whole
                // history.
                let sql = """
                    SELECT word FROM transcript_word
                    WHERE speakerId = 0 OR word LIKE '[user]%'
                    ORDER BY id DESC LIMIT 1;
                    """
                guard let (_, rows) = try? bridge.reader.rawQuery(sql, []),
                      let first = rows.first, let raw = first.first,
                      let stamped = raw else { return "" }
                let prefix = "[user] "
                // FIX(speaker-column-strip-2026-07-30): new-schema
                // rows have no `[user] ` prefix — return the raw
                // word. Legacy rows carried the prefix and need
                // stripping. Falling through to return "" (as the
                // previous version did) would silently kill LTM
                // context for cold-boot PTT turns.
                if stamped.hasPrefix(prefix) { return String(stamped.dropFirst(prefix.count)) }
                return stamped
            }
            let queryProxy: String? = {
                let t = recentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
                let m = priorUserInMemory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !m.isEmpty { return m }
                let v = priorUserFromVault.trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }()
            let ltmBlock = await LongTermMemoryContext.build(query: queryProxy)
            if !ltmBlock.isEmpty {
                let ltmPayload: [String: Any] = [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": "[memory] \(ltmBlock)"]]
                    ]
                ]
                try? await transport.send(ltmPayload)
                HeyClickyLog.log(
                    "realtime.session_ltm_injected",
                    lane: "voice",
                    direction: "outgoing",
                    [
                        "chars": ltmBlock.count,
                        "hasQuery": !recentTranscript.isEmpty,
                        "queryPreview": String((queryProxy ?? "").prefix(60)),
                        "querySource": !recentTranscript.isEmpty ? "liveTranscript"
                            : !priorUserInMemory.isEmpty ? "priorUserMem"
                            : !priorUserFromVault.isEmpty ? "priorUserVault"
                            : "none"
                    ]
                )
            }

            try? await transport.send(["type": "input_audio_buffer.commit"])
            try? await transport.send(["type": "response.create"])
        }
    }

    /// Barge-in: cancel current response, clear input buffer, truncate
    /// assistant item to what the user has actually heard so the server
    /// doesn't try to keep streaming on any resume.
    func interruptCurrentResponse() {
        let hasPlayback = currentAssistantItemId != nil || playedAssistantAudioMs > 0
        guard let transport else { return }
        guard isResponding || hasPlayback else { return }
        let itemId = currentAssistantItemId
        let playedMs = playedAssistantAudioMs
        Task { [weak self] in
            try? await transport.send(["type": "response.cancel"])
            try? await transport.send(["type": "input_audio_buffer.clear"])
            if let itemId {
                try? await transport.send([
                    "type": "conversation.item.truncate",
                    "item_id": itemId,
                    "content_index": 0,
                    "audio_end_ms": playedMs
                ])
            }
            await self?.audioEngine.stopPlayback()
            await MainActor.run {
                self?.isResponding = false
                self?.currentAssistantItemId = nil
                self?.playedAssistantAudioMs = 0
            }
        }
    }

    // MARK: - Ephemeral refresh + seamless swap

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.ephemeralRefreshInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.seamlessSwap() }
        }
    }

    private func seamlessSwap() async {
        // Bail out if the session was disconnected while the timer was
        // waiting. Reinstalling a transport onto a torn-down session
        // creates a zombie WS with no consumer.
        guard transport != nil else { return }
        do {
            let (token, _) = try await HeyClickySessionTokenClient.shared.mintRealtimeToken()
            let model = HeyClickySessionTokenClient.shared.bakedRealtimeModel ?? "gpt-realtime-2"
            let endpoint = "wss://api.openai.com/v1/realtime"
            let newTransport = HeyClickyRealtimeTransport()
            try await newTransport.connect(endpoint: endpoint, ephemeral: token, model: model)
            // Recheck after the async connect: caller may have disconnected
            // during the token/connect window. Drop the new transport if so.
            guard transport != nil else {
                await newTransport.disconnect()
                return
            }

            // Replay the last 3 turns so the new session has recent context.
            let toReplay = Array(recentTurns.suffix(3))
            for turn in toReplay {
                let contentType = turn.role == "user" ? "input_text" : "output_text"
                let payload: [String: Any] = [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": turn.role,
                        "content": [["type": contentType, "text": turn.text]]
                    ]
                ]
                try? await newTransport.send(payload)
            }

            let oldTransport = transport
            transport = newTransport
            eventTask?.cancel()
            eventTask = Task { [weak self] in await self?.consumeEvents(from: newTransport) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await oldTransport?.disconnect()
            HeyClickyLog.log("realtime.session_swap_ok", lane: "voice", direction: "internal", [
                "replayed": toReplay.count
            ])
        } catch {
            lastServerError = (code: "refresh_failed", message: "\(error)")
            HeyClickyLog.log("realtime.session_swap_fail", lane: "voice", direction: "error", [
                "error": "\(error)"
            ])
        }
    }

    // MARK: - Event consumption

    private func consumeEvents(from transport: HeyClickyRealtimeTransport) async {
        for await event in await transport.events {
            switch event {
            case .sessionCreated(let model, _):
                isConnected = true
                reconnectAttempt = 0
                lastServerError = nil
                await sendInitialSessionUpdate(on: transport)
                NotificationCenter.default.post(name: .heyClickyRealtimeSessionConnected, object: nil)
                HeyClickyLog.log("realtime.session_created", lane: "voice", direction: "internal", [
                    "model": model
                ])
            case .sessionUpdated:
                break
            case .speechStarted, .speechStopped, .committed:
                break
            case .responseCreated:
                isResponding = true
                currentAssistantItemId = nil
                playedAssistantAudioMs = 0
            case .assistantItemStarted(let itemId):
                currentAssistantItemId = itemId
            case .userTranscriptDelta(let d):
                currentUserTranscript += d
                // Broadcast the partial so the notch / overlay can
                // display "we're hearing you" instantly, before the
                // full transcript lands (which can take 500-1500 ms
                // after PTT release). Feels like Siri live-caption.
                let snapshot = currentUserTranscript
                NotificationCenter.default.post(
                    name: .heyClickyRealtimeUserTranscriptPartial,
                    object: nil,
                    userInfo: ["text": snapshot])
            case .userTranscriptDone(let full):
                currentUserTranscript = full
                recentTurns.append((role: "user", text: full))
                NotificationCenter.default.post(
                    name: .heyClickyRealtimeUserTranscript,
                    object: nil,
                    userInfo: ["text": full]
                )
                // Persist user side to vault. Paired with assistant
                // side in `.assistantTranscriptDone` above; both write
                // into transcript_word + searchRanking so LTM builds
                // in the NEXT turn see this exchange.
                let trimmedUser = full.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedUser.isEmpty {
                    await MainActor.run {
                        ConversationLogger.log(trimmedUser, by: .user)
                    }
                }
            case .audioDelta(let data):
                if data.count > 0 {
                    // PCM16 mono 24 kHz → 48 bytes / ms
                    playedAssistantAudioMs += max(1, data.count / 48)
                    if !isResponding {
                        isResponding = true
                        HeyClickyLog.log("realtime.session_first_audio", lane: "voice", direction: "incoming", [
                            "bytes": data.count
                        ])
                    }
                }
                audioEngine.schedulePlayback(pcm16: data)
            case .assistantTranscriptDelta(let d):
                currentAssistantTranscript += d
            case .assistantTranscriptDone(let full):
                currentAssistantTranscript = full
                recentTurns.append((role: "assistant", text: full))
                NotificationCenter.default.post(
                    name: .heyClickyRealtimeAssistantTranscript,
                    object: nil,
                    userInfo: ["text": full]
                )
                // Persist assistant reply into vault so future turns
                // can retrieve it via LTM / rewind_search. Pair
                // partner (user side) is logged in endPushToTalk once
                // the STT transcript is available (see below).
                let trimmedFull = full.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedFull.isEmpty {
                    await MainActor.run {
                        ConversationLogger.log(trimmedFull, by: .assistant)
                    }
                }
            case .toolCallStarted:
                break
            case .toolCallArgumentsDelta:
                break
            case .toolCallArgumentsDone(let callId, let name, let arguments):
                await handleToolCall(name: name, callId: callId, arguments: arguments, on: transport)
            case .responseDone:
                isResponding = false
                HeyClickyLog.log("realtime.session_response_done", lane: "voice", direction: "incoming", [
                    "played_ms": playedAssistantAudioMs
                ])
                // Any response completing counts as filler-done for
                // whoever's waiting — the audio just played. We
                // don't inspect response IDs because Realtime only
                // has one active response at a time, so the pending
                // filler continuation is always the target.
                if let cont = fillerCompleteContinuation {
                    fillerCompleteContinuation = nil
                    cont.resume(returning: true)
                }
                if recentTurns.count > 12 {
                    recentTurns.removeFirst(recentTurns.count - 12)
                }
                // CompanionManager subscribes to $isResponding and
                // maps to .idle on its own.
            case .error(let code, let message):
                lastServerError = (code: code, message: message)
                HeyClickyLog.log("realtime.session_ws_error", lane: "voice", direction: "error", [
                    "code": code,
                    "message": String(message.prefix(200))
                ])
                if code == "ws_receive"
                    || message.contains("timed out")
                    || message.contains("not connected")
                    || message.contains("cancelled") {
                    isConnected = false
                    reconnectAttempt = min(reconnectAttempt + 1, 5)
                    let delayS = min(pow(2.0, Double(reconnectAttempt - 1)), 15.0)
                    try? await Task.sleep(nanoseconds: UInt64(delayS * 1_000_000_000))
                    await self.connect()
                    return
                }
                NotificationCenter.default.post(
                    name: .heyClickyRealtimeSessionFailed,
                    object: nil,
                    userInfo: ["code": code, "message": message]
                )
            case .unknown:
                break
            }
        }
    }

    // MARK: - Session config

    /// Sent on every `session.created`. Server-baked prompt already has
    /// persona + response style, so we do NOT populate `instructions`
    /// here — that would suppress the model's tool-calling behavior.
    /// We DO populate `audio.input.transcription.language` from the
    /// user's language preference so CJK sentences don't get mis-heard
    /// as English homophones.
    private func sendInitialSessionUpdate(on transport: HeyClickyRealtimeTransport) async {
        let voice = AppBundleConfiguration.openAIRealtimeVoiceID()
        var transcription: [String: Any] = ["model": "gpt-4o-mini-transcribe"]
        let lang = AppBundleConfiguration.voiceResponseLanguage()
        let langCode: String? = {
            switch lang {
            case "zh": return "zh"
            case "en": return "en"
            case "ja": return "ja"
            case "es": return "es"
            case "fr": return "fr"
            case "de": return "de"
            default: return nil
            }
        }()
        if let langCode {
            transcription["language"] = langCode
        }

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "audio": [
                    "input": [
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ],
                    "output": [
                        "voice": voice
                    ]
                ],
                "tools": Self.toolSchema,
                "tool_choice": "auto"
            ]
        ]
        try? await transport.send(payload)
    }

    /// Tool schema — trimmed to what openclicky supports today.
    /// `openclicky_use_screen_context` is the priority tool: realtime
    /// calls it whenever the user asks about anything visible, we run
    /// chat-tool-call, post the result back as `function_call_output`,
    /// realtime finishes speaking with the tool result inline.
    private static let toolSchema: [[String: Any]] = [
        [
            "type": "function",
            "name": "openclicky_use_screen_context",
            "description": "Hand off to OpenClicky's stronger dialog model. **You MUST call this**, not answer from audio alone, when the user's request refers to:\n- ANY past interaction / memory (\"我上次…\", \"刚才那个…\", \"记得吗\", \"上周…\") — you have no memory across turns, only OpenClicky's vault does.\n- ANYTHING on-screen (\"这个报错\", \"当前窗口\", \"这段代码\", \"看这里\") — you can't see the screen; OpenClicky captures a screenshot for the dialog model.\n- Pointing / highlighting / drawing on visible UI.\nOnly answer directly (skip this tool) for pure world-knowledge or a direct rephrase of your own last utterance.",
            "parameters": [
                "type": "object",
                "required": ["transcript"],
                "properties": [
                    "transcript": [
                        "type": "string",
                        "description": "The user's request, verbatim."
                    ],
                    "intent": [
                        "type": "string",
                        "enum": ["world_knowledge", "past_memory", "live_context", "recent_conv", "other"],
                        "description": "Classify the user's intent so downstream can pick the right context:\n- world_knowledge: general facts, not about the user's history/screen (e.g. \"苹果哪年成立\", \"光速是多少\").\n- past_memory: refers to something the user did / said / saw previously (e.g. \"我上周问过 kafka 什么\", \"上次那个项目\").\n- live_context: needs to see the current screen / active app right now (e.g. \"这个报错什么意思\", \"点亮这个按钮\").\n- recent_conv: direct follow-up to the last few voice exchanges (e.g. \"接着刚才说\", \"再解释下\").\n- other: doesn't fit above."
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "point_at_screen",
            "description": "Fly the blue Clicky cursor to a specific pixel to physically point at an element. Call this AFTER openclicky_use_screen_context returns — REUSE the exact x/y from that tool result's walkthrough point beat. The coordinates you receive from openclicky_use_screen_context are ALREADY in the downscaled screenshot pixel space (typically 1280×800, matching what was sent). Never scale them yourself — never invent retina/physical coords. If the tool result gave you (250, 660), pass exactly (250, 660).",
            "parameters": [
                "type": "object",
                "required": ["x", "y", "label"],
                "properties": [
                    "x": ["type": "integer", "description": "X in the downscaled screenshot's pixel space (top-left origin, same numbers openclicky_use_screen_context returned)."],
                    "y": ["type": "integer", "description": "Y in the same downscaled space."],
                    "label": ["type": "string", "description": "Short 1-3 word description of the element."],
                    "screen": ["type": "integer", "description": "1-based screen index; defaults to the cursor's screen."]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "type_text",
            "description": "Type text into the frontmost app / focused text field. Use this whenever the user asks you to type something for them.",
            "parameters": [
                "type": "object",
                "required": ["text"],
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The literal text to type."
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "write_clipboard",
            "description": "Write text to the system clipboard so the user can paste it.",
            "parameters": [
                "type": "object",
                "required": ["text"],
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The text to copy to the clipboard."
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "openclicky_start_background_agent",
            "description": "Start a long-running background Codex agent to do research / build / plan / summarise / anything that takes minutes. The Agent HUD appears in the top-right corner and the user can chat with it there. Call this ONLY when the user asks for background work (research, ‘go find X’, ‘build me Y’, ‘summarize this PDF’, ‘plan a trip’). Never call for quick chat or screen questions — those go through openclicky_use_screen_context.",
            "parameters": [
                "type": "object",
                "required": ["prompt"],
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "The user's task, verbatim and complete. The agent needs the full request to start working."
                    ]
                ]
            ]
        ]
    ]

    // MARK: - Tool dispatch

    /// Runs the tool locally, JSON-encodes the result, then posts
    /// `conversation.item.create` type=function_call_output +
    /// `response.create` so realtime speaks the tool result inline.
    private func handleToolCall(
        name: String,
        callId: String,
        arguments: String,
        on transport: HeyClickyRealtimeTransport
    ) async {
        HeyClickyLog.log("realtime.tool_call", lane: "voice", direction: "internal", [
            "name": name,
            "args_len": arguments.count,
            "args_preview": String(arguments.prefix(300))
        ])
        let outputJSON: String
        switch name {
        case "openclicky_use_screen_context":
            outputJSON = await runScreenContextTool(arguments: arguments)
        case "point_at_screen":
            outputJSON = runPointAtScreenTool(arguments: arguments)
        case "type_text":
            outputJSON = runTypeTextTool(arguments: arguments)
        case "write_clipboard":
            outputJSON = runWriteClipboardTool(arguments: arguments)
        case "openclicky_start_background_agent":
            outputJSON = runStartBackgroundAgentTool(arguments: arguments)
        default:
            // FIX(ai-audit-2026-08-01 multi-turn #4): return retry
            // guidance instead of a bare unknown_tool error so the LLM
            // knows how to recover (discover + activate a domain-scoped
            // tool). Previously the model retried the same broken name.
            outputJSON = #"""
            {"success":false,"error":"unknown_tool","hint":"This tool name is not registered on this session. If you need a capability that isn't in your current tool set, call search_tools with a query first, then activate_domain or activate_tools to make it available before retrying."}
            """#
        }
        try? await transport.send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": outputJSON
            ]
        ])
        try? await transport.send(["type": "response.create"])
    }

    private func runScreenContextTool(arguments: String) async -> String {
        let transcript = HeyClickyRealtimeSession.parseTranscript(from: arguments) ?? ""
        let intent = HeyClickyRealtimeSession.parseIntent(from: arguments)
        HeyClickyLog.log("realtime.tool_call.intent",
                         lane: "voice", direction: "internal",
                         ["intent": intent ?? "unset",
                          "transcript_preview": String(transcript.prefix(60))])

        // "Thinking out loud" filler — done via a dedicated response
        // that runs concurrently with our own tool execution. We
        // await this response to complete BEFORE we submit the
        // function_call_output, otherwise OpenAI Realtime queues /
        // rejects the second response.create. The wait typically
        // resolves in 800-1500 ms — well under the 8-15 s the chat
        // model takes to produce the real answer, so this is pure
        // perceived-latency win. Skips filler for very short
        // prompts because <3 s of silence isn't uncomfortable.
        if let transport = transport, transcript.count >= 6 {
            let responseId = "filler-\(UUID().uuidString.prefix(8))"
            self.pendingFillerResponseId = responseId
            self.fillerCompleteContinuation = nil
            try? await transport.send([
                "type": "response.create",
                "response": [
                    "conversation": "none",
                    "instructions": "Say ONE short natural filler (≤ 6 words / ≤ 12 中文字符) matching the user's language, acknowledging you'll take a moment while a deeper lookup runs. Do not answer the question yet. Vary the phrasing across turns.",
                    "metadata": ["responseTag": responseId]
                ]
            ])
            HeyClickyLog.log("realtime.filler_requested",
                             lane: "voice", direction: "outgoing",
                             ["intent": intent ?? "",
                              "responseId": responseId])
            // Wait up to 3 s for filler audio to finish playing;
            // beyond that fall through so we don't stall the chat
            // pipeline on a stuck filler.
            let ok = await withTaskGroup(of: Bool.self) { group in
                group.addTask { [weak self] in
                    await self?.waitForFillerComplete() ?? false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            HeyClickyLog.log("realtime.filler_wait_done",
                             lane: "voice", direction: "internal",
                             ["completedNaturally": ok])
        }

        if let cm = companionManagerRef {
            return await cm.executeInSessionScreenContextTool(
                instruction: transcript, intent: intent
            ) ?? #"{"success":false,"error":"tool_failed"}"#
        }
        return #"{"success":false,"error":"companion_unavailable"}"#
    }


    private static func parseIntent(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["intent"] as? String, !v.isEmpty
        else { return nil }
        return v
    }

    /// Fly the blue Clicky cursor to (x, y) in screenshot pixel space.
    /// Coordinate rescale + Y flip use the same helpers the walkthrough
    /// beat path uses so behavior matches clicky-mac AgentToolBridge's
    /// point-side-effect. Requires the CompanionManager to know the last
    /// captured screenshot's dimensions.
    private func runPointAtScreenTool(arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"success":false,"error":"invalid_json"}"#
        }
        let px = (json["x"] as? Double) ?? (json["x"] as? Int).map(Double.init) ?? -1
        let py = (json["y"] as? Double) ?? (json["y"] as? Int).map(Double.init) ?? -1
        let screenIndex = json["screen"] as? Int
        guard px >= 0, py >= 0 else {
            return #"{"success":false,"error":"missing_coords"}"#
        }
        let label = (json["label"] as? String) ?? "here"
        guard let cm = companionManagerRef else {
            return #"{"success":false,"error":"companion_unavailable"}"#
        }
        // Prefer the capture context stashed by the last
        // `openclicky_use_screen_context` tool run — those dims are
        // the ACTUAL image space the model just returned coords in.
        // Falls back to companion.currentScreenshotDimensions when the
        // realtime model called point_at_screen without a prior screen
        // context (rare).
        let captureCtx = cm.pendingHeyClickyCaptureContext
        guard let screen = HeyClickyCoordinateTransform.targetScreen(
            preferredIndex: screenIndex ?? captureCtx?.nsScreenIndex
        ) else {
            return #"{"success":false,"error":"no_screen"}"#
        }
        let frame = captureCtx?.displayFrame ?? screen.frame
        let sw: Int
        let sh: Int
        if let ctx = captureCtx {
            sw = ctx.screenshotWidth
            sh = ctx.screenshotHeight
        } else {
            let dims = cm.currentScreenshotDimensions()
            sw = dims.width > 0 ? dims.width : 1280
            sh = dims.height > 0 ? dims.height : 800
        }
        // Guard: sometimes the realtime model invents point_at_screen
        // coords in the ORIGINAL retina pixel space (3456×2234) instead
        // of the downscaled space we sent (1280×800). Detect that by
        // checking if any coord is larger than the sent dimensions and
        // rescale accordingly. If the coord is inside the sent space,
        // just use it as-is.
        var pxNorm = CGFloat(px)
        var pyNorm = CGFloat(py)
        let sentW = CGFloat(max(1, sw))
        let sentH = CGFloat(max(1, sh))
        if pxNorm > sentW * 1.5 || pyNorm > sentH * 1.5 {
            // Assume physical pixel space (backingScale ≈ 2×). Scale to
            // sent space so the rescale below lands correctly.
            let scale: CGFloat
            if let bs = HeyClickyCoordinateTransform.targetScreen(preferredIndex: screenIndex ?? captureCtx?.nsScreenIndex)?.backingScaleFactor {
                scale = bs
            } else {
                scale = 2.0
            }
            pxNorm = pxNorm / scale
            pyNorm = pyNorm / scale
            HeyClickyLog.log("realtime.point_at_screen_rescaled_from_physical", lane: "voice", direction: "internal", [
                "raw_x": px, "raw_y": py,
                "scale": scale,
                "corrected": "\(Int(pxNorm)),\(Int(pyNorm))"
            ])
        }
        let width = sentW
        let height = sentH
        let localX = pxNorm * (frame.width / width)
        let localY = pyNorm * (frame.height / height)
        let globalPoint = CGPoint(
            x: frame.origin.x + localX,
            y: frame.origin.y + (frame.height - localY)
        )
        cm.overlayWindowManager.flyBuddyTo(globalPoint)
        return #"{"success":true,"animated":true,"label":"\#(label)"}"#
    }

    /// Spawn a background Codex agent for a long-running task. Wires
    /// into openclicky's existing agent surface (CodexAgentSession
    /// launcher + CodexHUDWindowManager top-right panel) so the user
    /// can converse with the agent after realtime hands off.
    private func runStartBackgroundAgentTool(arguments: String) -> String {
        HeyClickyLog.log("agent.tool_call_received", lane: "voice", direction: "incoming", [
            "stage": "S1_spawn_trigger",
            "args_len": arguments.count
        ])
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            HeyClickyLog.log("agent.spawn_failed", lane: "voice", direction: "error", [
                "stage": "S1_spawn_trigger", "reason": "invalid_json"
            ])
            return #"{"success":false,"error":"invalid_json"}"#
        }
        let prompt = ((json["prompt"] as? String)
                      ?? (json["query"] as? String)
                      ?? (json["transcript"] as? String)
                      ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            HeyClickyLog.log("agent.spawn_failed", lane: "voice", direction: "error", [
                "stage": "S1_spawn_trigger", "reason": "missing_prompt"
            ])
            return #"{"success":false,"error":"missing_prompt"}"#
        }
        guard let cm = companionManagerRef else {
            HeyClickyLog.log("agent.spawn_failed", lane: "voice", direction: "error", [
                "stage": "S1_spawn_trigger", "reason": "companion_unavailable"
            ])
            return #"{"success":false,"error":"companion_unavailable"}"#
        }
        HeyClickyLog.log("agent.spawn_dispatch", lane: "voice", direction: "internal", [
            "stage": "S1_spawn_trigger",
            "prompt_len": prompt.count,
            "prompt_head": String(prompt.prefix(80))
        ])
        // Fire on the main actor so CodexHUDWindowManager (NSPanel) is
        // touched from the main thread.
        Task { @MainActor in
            cm.startBackgroundAgentFromRealtime(prompt: prompt)
        }
        // NOTE: We return success:true optimistically before spawn
        // completes. Review flagged this — see agent.spawn_started log
        // downstream for actual outcome.
        return #"{"success":true,"agent_launched":true,"visible_at":"top-right"}"#
    }

    private func runTypeTextTool(arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.isEmpty else {
            return #"{"success":false,"error":"missing_text"}"#
        }
        if let cm = companionManagerRef {
            cm.typeTextForHeyClickyFree(text)
            return #"{"success":true,"typed":true}"#
        }
        return #"{"success":false,"error":"companion_unavailable"}"#
    }

    private func runWriteClipboardTool(arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.isEmpty else {
            return #"{"success":false,"error":"missing_text"}"#
        }
        if let cm = companionManagerRef {
            cm.writeToClipboardPreservingUserContents(text)
            return #"{"success":true,"copied":true}"#
        }
        return #"{"success":false,"error":"companion_unavailable"}"#
    }

    private static func parseTranscript(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let v = json["transcript"] as? String, !v.isEmpty { return v }
        if let v = json["query"] as? String, !v.isEmpty { return v }
        if let v = json["text"] as? String, !v.isEmpty { return v }
        return nil
    }
}
