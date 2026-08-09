//
//  CompanionManager+HeyClicky.swift
//  cursor-buddy
//
//  Thin wrappers used by HeyClickyChatToolCallClient to bridge into
//  private CompanionManager primitives (typing, screenshot dims).
//

import AppKit
import AVFoundation
import Combine
import Foundation

/// Holds Combine subscriptions (e.g. session.$isResponding sink) alive
/// for as long as the CompanionManager exists. Uses ObjectIdentifier so
/// the extension can retain state without adding a stored property.
final class HeyClickyRealtimeSessionSubscriptionStore {
    static let shared = HeyClickyRealtimeSessionSubscriptionStore()
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.session.subs")
    private var subscriptions: [ObjectIdentifier: [AnyCancellable]] = [:]
    func retain(_ cancellable: AnyCancellable, for owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        queue.sync {
            var current = self.subscriptions[key] ?? []
            current.append(cancellable)
            self.subscriptions[key] = current
        }
    }
    func drop(for owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        queue.sync { self.subscriptions[key] = nil }
    }
}

// Preview player kept module-scope so it survives past the async task
// returning; without a strong reference AVAudioPlayer stops immediately
// after `play()` is called.
private final class VoicePreviewPlayerHolder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.voice.preview")
    private var player: AVAudioPlayer?
    func swap(_ next: AVAudioPlayer?) {
        queue.sync { self.player = next }
    }
    func retain() -> AVAudioPlayer? {
        queue.sync { self.player }
    }
}
private let voicePreviewPlayer = VoicePreviewPlayerHolder()

/// Storage for HeyClicky NotificationCenter observer tokens. Kept in
/// a global map keyed by ObjectIdentifier so we can wire this via an
/// extension without adding stored properties to CompanionManager.
internal let heyClickyObserverStore = HeyClickyObserverStore()

/// Stores per-CompanionManager playback-RMS sampling timers so the
/// speaking-pulse ring's amplitude tracks the actual TTS energy while
/// `.responding` is active. Keyed by ObjectIdentifier so the extension
/// can retain state without adding a stored property.
private final class HeyClickyPlaybackSamplerStore: @unchecked Sendable {
    static let shared = HeyClickyPlaybackSamplerStore()
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.playback.sampler")
    private var timers: [ObjectIdentifier: Timer] = [:]
    func set(_ owner: AnyObject, timer: Timer?) {
        let key = ObjectIdentifier(owner)
        queue.sync {
            self.timers[key]?.invalidate()
            self.timers[key] = timer
        }
    }
    func clear(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        queue.sync {
            self.timers[key]?.invalidate()
            self.timers[key] = nil
        }
    }
}

internal final class HeyClickyObserverStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.observers")
    private var tokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var workspaceTokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    /// Last epoch (seconds) an auto-replay "请继续" was dispatched for
    /// a given session. Debounces the wake / creds-refreshed / codex-
    /// exited fan-out where multiple observers otherwise fire replay
    /// within milliseconds of each other.
    private var lastAutoReplayAt: [ObjectIdentifier: TimeInterval] = [:]
    /// Per-session consecutive replay-without-progress counter. If N
    /// replays fire without the session's entry count advancing, the
    /// error is unrecoverable at the app layer (quota / lease / server
    /// state) and further replays only spam the log. Reset by
    /// `noteReplayProgress(session:)` when entries advance.
    private var replayFailureCount: [UUID: Int] = [:]
    private var replayLastEntryCount: [UUID: Int] = [:]
    /// When a session exhausts its budget, we stamp the time here so
    /// subsequent `shouldAttemptRecovery` calls within the cooldown
    /// window return false without incrementing. Once cooldown lapses,
    /// counter is cleared and the session gets another 3 tries. This
    /// makes recovery robust to transient outages (5xx run for 10min
    /// then clear) without letting a genuinely dead session spam
    /// forever.
    private var replayCooldownUntil: [UUID: TimeInterval] = [:]
    /// Turn-timeout watchdog state: last time a session's assistant
    /// entry count went up. If more than `watchdogTimeoutSeconds`
    /// elapse without progress while the session is in an active
    /// stage, we kill codex + trigger replay. Prevents the "hung
    /// turn" case where /responses stalls with no error emitted.
    private var lastAssistantAdvanceAt: [UUID: TimeInterval] = [:]
    private var lastKnownAssistantCount: [UUID: Int] = [:]
    private var watchdogTicker: DispatchSourceTimer?
    private var chromeExtTicker: DispatchSourceTimer?
    /// Global circuit-breaker state. Every `noteResetFailure` bump
    /// counts a quota_exhausted + reset_failed pair in the last 15
    /// min sliding window. If >5, isCircuitOpen() returns true and
    /// all auto-replay must halt to prevent ban-worthy abuse. User
    /// interaction closes the breaker.
    private var resetFailureTimestamps: [TimeInterval] = []
    private var circuitOpenUntil: TimeInterval = 0

    func noteResetFailure() {
        queue.sync {
            let now = Date().timeIntervalSince1970
            self.resetFailureTimestamps.append(now)
            // Prune >15min old
            self.resetFailureTimestamps = self.resetFailureTimestamps.filter { now - $0 < 900 }
            if self.resetFailureTimestamps.count > 5 {
                // Open circuit for 30 min
                self.circuitOpenUntil = now + 1800
            }
        }
    }

    func noteResetSuccess() {
        queue.sync {
            self.resetFailureTimestamps.removeAll()
            self.circuitOpenUntil = 0
        }
    }

    func isCircuitOpen() -> Bool {
        return queue.sync {
            Date().timeIntervalSince1970 < self.circuitOpenUntil
        }
    }

    func closeCircuitManually() {
        queue.sync {
            self.resetFailureTimestamps.removeAll()
            self.circuitOpenUntil = 0
        }
    }

    func startChromeExtHeartbeatTicker(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        queue.sync {
            guard self.chromeExtTicker == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { tick() }
            t.resume()
            self.chromeExtTicker = t
        }
    }

    func stopChromeExtHeartbeatTicker() {
        queue.sync {
            self.chromeExtTicker?.cancel()
            self.chromeExtTicker = nil
        }
    }

    func startWatchdogTicker(interval: TimeInterval = 60, tick: @escaping @Sendable () -> Void) {
        queue.sync {
            guard self.watchdogTicker == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { tick() }
            t.resume()
            self.watchdogTicker = t
        }
    }

    func stopWatchdogTicker() {
        queue.sync {
            self.watchdogTicker?.cancel()
            self.watchdogTicker = nil
        }
    }

    /// Update watchdog on every progress observation. Returns true
    /// if the session has timed out (caller should kill+replay).
    /// Timeout is 15min (was 5min): a legitimate long turn can spend
    /// many minutes inside reasoning + shell exec without emitting a
    /// new assistant text entry. 5min was too aggressive and killed
    /// productive turns mid-work.
    /// Caller should pass the LATEST entry count (any role) so any
    /// activity counts as progress, not just final assistant messages.
    func recordProgressAndCheckTimeout(sessionID: UUID,
                                       assistantEntryCount: Int,
                                       isActive: Bool,
                                       timeoutSeconds: TimeInterval = 900) -> Bool {
        return queue.sync {
            let now = Date().timeIntervalSince1970
            let last = self.lastKnownAssistantCount[sessionID] ?? -1
            if assistantEntryCount > last {
                self.lastKnownAssistantCount[sessionID] = assistantEntryCount
                self.lastAssistantAdvanceAt[sessionID] = now
                return false
            }
            // No new entry. Check timeout only if active.
            guard isActive else { return false }
            let firstSeen = self.lastAssistantAdvanceAt[sessionID] ?? now
            if self.lastAssistantAdvanceAt[sessionID] == nil {
                self.lastAssistantAdvanceAt[sessionID] = now
            }
            return (now - firstSeen) > timeoutSeconds
        }
    }

    /// External bump: any codex.rpc.message (reasoning / commandExec /
    /// item.completed) counts as progress. Prevents watchdog from
    /// killing a long turn that's actively doing shell/tool work but
    /// hasn't emitted a new assistant text.
    func bumpWatchdogFromRpcActivity(sessionID: UUID) {
        queue.sync {
            self.lastAssistantAdvanceAt[sessionID] = Date().timeIntervalSince1970
        }
    }

    func resetWatchdog(sessionID: UUID) {
        queue.sync {
            self.lastAssistantAdvanceAt[sessionID] = nil
            self.lastKnownAssistantCount[sessionID] = nil
        }
    }

    func set(_ owner: AnyObject, tokens: [NSObjectProtocol]) {
        let key = ObjectIdentifier(owner)
        queue.sync { self.tokens[key] = tokens }
    }

    func setWorkspace(_ owner: AnyObject, tokens: [NSObjectProtocol]) {
        let key = ObjectIdentifier(owner)
        queue.sync { self.workspaceTokens[key] = tokens }
    }

    func take(_ owner: AnyObject) -> [NSObjectProtocol] {
        let key = ObjectIdentifier(owner)
        return queue.sync {
            let out = self.tokens[key] ?? []
            self.tokens[key] = nil
            return out
        }
    }

    func takeWorkspace(_ owner: AnyObject) -> [NSObjectProtocol] {
        let key = ObjectIdentifier(owner)
        return queue.sync {
            let out = self.workspaceTokens[key] ?? []
            self.workspaceTokens[key] = nil
            return out
        }
    }

    /// Returns true if the caller is allowed to dispatch an auto-replay
    /// for this owner right now; also stamps the current time so the
    /// next caller inside the debounce window is denied. 3-second window
    /// covers the wake fan-out (JWT refresh → creds-refreshed observer
    /// + inline wake handler both queue replay Tasks).
    func shouldDispatchAutoReplay(owner: AnyObject, windowSeconds: TimeInterval = 3.0) -> Bool {
        let key = ObjectIdentifier(owner)
        return queue.sync {
            let now = Date().timeIntervalSince1970
            if let last = self.lastAutoReplayAt[key], now - last < windowSeconds {
                return false
            }
            self.lastAutoReplayAt[key] = now
            return true
        }
    }

    /// Returns true if the session hasn't exceeded its consecutive
    /// no-progress replay budget. Stamps the attempt so subsequent
    /// calls without progress increment the counter. `currentEntryCount`
    /// is the session's `entries.count` at signal time; when it advances
    /// between calls, the counter resets (progress observed).
    /// After `maxAttempts` consecutive attempts with no advance, returns
    /// false so the caller aborts. Manually reset via `resetFailureBudget`.
    func shouldAttemptRecovery(sessionID: UUID,
                               currentEntryCount: Int,
                               maxAttempts: Int = 3,
                               cooldownSeconds: TimeInterval = 300) -> Bool {
        return queue.sync {
            let now = Date().timeIntervalSince1970
            // If we're inside an active cooldown, deny.
            if let until = self.replayCooldownUntil[sessionID], now < until {
                return false
            }
            // Cooldown lapsed (or never happened): if we had one, clear
            // it and reset the failure counter so this session gets a
            // fresh 3 attempts.
            if self.replayCooldownUntil[sessionID] != nil {
                self.replayCooldownUntil[sessionID] = nil
                self.replayFailureCount[sessionID] = 0
                self.replayLastEntryCount[sessionID] = -1
            }
            let lastCount = self.replayLastEntryCount[sessionID] ?? -1
            if currentEntryCount > lastCount {
                self.replayFailureCount[sessionID] = 0
            }
            self.replayLastEntryCount[sessionID] = currentEntryCount
            let attempts = self.replayFailureCount[sessionID] ?? 0
            if attempts >= maxAttempts {
                // Budget exhausted → arm cooldown. After 5min the
                // next call will clear it and give another 3 tries.
                self.replayCooldownUntil[sessionID] = now + cooldownSeconds
                return false
            }
            self.replayFailureCount[sessionID] = attempts + 1
            return true
        }
    }

    func cooldownRemaining(sessionID: UUID) -> TimeInterval {
        return queue.sync {
            let now = Date().timeIntervalSince1970
            guard let until = self.replayCooldownUntil[sessionID], now < until else {
                return 0
            }
            return until - now
        }
    }

    func resetFailureBudget(sessionID: UUID) {
        queue.sync {
            self.replayFailureCount[sessionID] = nil
            self.replayLastEntryCount[sessionID] = nil
            self.replayCooldownUntil[sessionID] = nil
        }
    }

    func currentFailureCount(sessionID: UUID) -> Int {
        queue.sync { self.replayFailureCount[sessionID] ?? 0 }
    }
}

extension CompanionManager {
    /// Build a "please continue" prompt that carries enough context
    /// for the assistant to NOT drift off-task when the server has lost
    /// the backend thread's memory (which happens whenever
    /// clicky_agent_thread_resumed doesn't actually rehydrate on the
    /// proxy — currently always). Without this, the model sees only
    /// "请继续" and reconstructs "what to do" from disk memory + the
    /// visible screen, which is why the log showed "认成调
    /// openclicky 代码" instead of the actual 七里香 task.
    ///
    /// F28 (Task #204) — the fire prompt used when the auto-continue
    /// observer wakes up a progress-driven long-run session. Deliberately
    /// single-line, English, and lightweight: the agent already has the
    /// full AGENTS-longrun template and PROGRESS.md loaded, so the only
    /// job of this text is to nudge it forward one step without asking
    /// for a summary or a question. See F28 review Issue #7.
    fileprivate static let progressDrivenAutoContinuePrompt =
        "Continue against PROGRESS.md — next unchecked item. Do not summarize."

    /// The prompt bundles: original title, last user prompt, last
    /// assistant excerpt (up to 240 chars), and a bold reminder to
    /// stay on the ORIGINAL task. Kept ≤ 1KB so it fits easily.
    fileprivate static func buildContextfulResumePrompt(_ session: CodexAgentSession) -> String {
        var pieces: [String] = [
            "请继续之前的任务，不要切换到新任务。",
            // Memory-hold hint: minimize wasted tool calls. Agent
            // should ONLY re-read PROGRESS.md (checkpoint) — TASK.md
            // and AGENTS.md rarely change so skip re-reading them.
            "工作目录里有 PROGRESS.md 记录了断点。只读 PROGRESS.md 确认进度，不要重复读 TASK.md/AGENTS.md（内容你已经看过）。"
        ]
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != "Agent", title != "Ask Agent" {
            pieces.append("原始任务：\(title)")
        }
        if let userPrompt = session.lastSubmittedPromptText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !userPrompt.isEmpty,
           userPrompt != "请继续",
           // Don't recurse: if the previous submission was itself a
           // resume-prompt (contains our marker), extract the ORIGINAL
           // user instruction from within it rather than nesting.
           !userPrompt.hasPrefix("请继续之前的任务") {
            let trimmed = userPrompt.count > 400
                ? String(userPrompt.prefix(400)) + "…"
                : userPrompt
            pieces.append("用户上次的指令：\(trimmed)")
        }
        if let recap = session.latestActivityDisplaySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !recap.isEmpty {
            let clean = Self.isTransientRecoveryCaption(recap) ? "" : recap
            if !clean.isEmpty {
                let trimmed = clean.count > 240
                    ? String(clean.prefix(240)) + "…"
                    : clean
                pieces.append("你上次的进展：\(trimmed)")
            }
        }
        pieces.append("请从中断处接着做完，不要重新开始或改任务。")
        return pieces.joined(separator: "\n\n")
    }

    /// True when the session was in the middle of a real, non-completed
    /// turn — i.e. the interruption actually chopped a running response.
    /// `.idle` means either "never started" or "cleanly finished and
    /// reset" — neither should trigger auto-replay. `.completed` means
    /// the turn ended successfully. Everything else was in-flight.
    fileprivate static func hasInterruptedInFlightTurn(_ session: CodexAgentSession) -> Bool {
        guard session.model.hasPrefix("heyclicky-free-") else { return false }
        guard session.lastSubmittedPromptText?.isEmpty == false else { return false }
        guard !isUserInitiatedStop(session.stopReason) else { return false }
        // Watchdog-killed turns MUST replay regardless of transcript
        // size — the whole point of the watchdog is to unstick a
        // long-running turn that stopped producing output. The old
        // `.idle + entries<=4` guard blocked this because the turn
        // had already produced 12+ entries before it stalled.
        if session.stopReason == "turn_watchdog_timeout" {
            return true
        }
        switch session.progressStage {
        case .starting, .planning, .executing, .composing, .failed:
            return true
        case .idle:
            // .ready + .idle with a pending prompt but almost no
            // transcript = the task was accepted but never produced an
            // assistant reply. Guard by entry count so completed
            // tasks (many entries + prompt) don't get re-run.
            if case .stopped = session.status { return false }
            if case .completed = session.progressStage { return false }
            return session.entries.count <= 4
        case .completed:
            // F28 (Task #204) — progress-driven sessions accept a
            // clean `.completed` turn as fire-worthy iff PROGRESS.md
            // has NOT yet been marked done. The sole poster of the
            // notification in this mode is CodexAgentSession's
            // `turn/completed` handler, but the observer body invokes
            // this predicate before dispatching, so mirror the same
            // marker check here rather than trusting the caller. That
            // way any future non-F28 sender still gets a safe verdict.
            if session.progressDriven,
               !session.workingDirectoryPath.isEmpty {
                let marker = session.completionMarker ?? "LAST_COMPLETED: DONE"
                // Prefer the explicit task-progress path (variant A writes to
                // <workdir>/.openclicky/task/PROGRESS.md, NOT <workdir>/PROGRESS.md).
                // Legacy sessions with no taskProgressPath keep the old fallback.
                // See docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md HIGH #2.
                let progressPath: String
                if let tp = session.taskProgressPath, !tp.isEmpty {
                    progressPath = tp
                } else {
                    progressPath = (session.workingDirectoryPath as NSString)
                        .appendingPathComponent("PROGRESS.md")
                }
                if !OpenClickyProgressMarkerCheck.isDone(
                    path: progressPath,
                    marker: marker
                ) {
                    return true
                }
            }
            return false
        }
    }

    /// A stopReason string is "user-initiated" when it comes from an
    /// explicit user gesture (Stop button, panel close, session
    /// archive). Anything else — nil, "codex_process_exited",
    /// "credentials_refreshed", "api_key_reconfigured" — is a
    /// system-driven stop that COULD legitimately be resumed by
    /// auto-replay. Terminal user gestures MUST NOT trigger replay
    /// or the Stop button becomes useless (user reported: "点了停止,
    /// 但你又发了请继续, 它停止不了").
    fileprivate static func isUserInitiatedStop(_ reason: String?) -> Bool {
        guard let reason else { return false }
        let userReasons: Set<String> = [
            "agent_panel_stop",
            "agent.stop_button",
            "agent.stop_button_pressed",
            "agent_dock_stop",
            "agent_hud_stop",
            "agent_task_cancelled",
            "user_stop",
            "user_cancel",
            "session_stopped",
            "chat_workspace_archived",
            "manual_stop"
        ]
        return userReasons.contains(reason)
    }

    /// Registers observers for HeyClicky Free lifecycle events:
    /// guided-click follow-up injection + quota-fallback lane switch +
    /// session expiration. Tokens are stored so stop() can remove them.
    func installHeyClickyGuidedClickBridge() {
        // Tear any prior registrations down before installing new ones,
        // otherwise repeated boots (e.g. tests) leak observers.
        uninstallHeyClickyObservers()
        var tokens: [NSObjectProtocol] = []

        let followUp = NotificationCenter.default.addObserver(
            forName: .clickyHeyClickyGuidedClickFollowUp,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let text = note.userInfo?["text"] as? String else { return }
            self.openAIRealtimeSpeechClient.injectFollowUp(text)
        }
        tokens.append(followUp)

        let expired = NotificationCenter.default.addObserver(
            forName: .clickyHeyClickySessionExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // If a quota reset is in flight, skip — it does its own
            // wipe + re-sign-in; a duplicate wipe here would race.
            if HeyClickyAccountResetManager.shared.isResetInProgress {
                HeyClickyLog.log("system.heyclicky.session_expired_suppressed_during_reset",
                                 lane: "system", direction: "internal",
                                 ["reason": "reset_in_progress"])
                return
            }
            HeyClickyLog.log("system.heyclicky.session_expired", lane: "system",
                             direction: "error",
                             ["action_required": "sign_in_again"])
            AppBundleConfiguration.heyClickyWipeSession()
            HeyClickySessionTokenClient.shared.invalidateAll()
            NotificationCenter.default.postHeyClickyStatus(.signInRequired)
            self?.revertHeyClickyLanesToDefaults()
        }
        tokens.append(expired)

        // Status → cursorOverlayState.heyClickyStatusCaption so overlay
        // + notch reflect refreshing / signInRequired / needsExtension
        // the instant the backend transitions, not the next time Settings
        // is opened. Previously only OpenClickySettingsWindowManager
        // observed this; the main UI was blind to reset-in-progress /
        // extension-offline / token-refresh states.
        let statusChanged = NotificationCenter.default.addObserver(
            forName: .heyClickyStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let rawStatus = note.userInfo?["status"] as? String
            let userMessage = note.userInfo?["message"] as? String
            let userHint = note.userInfo?["user_message"] as? String
            let caption = userHint ?? userMessage
            let severity: String
            switch rawStatus {
            case HeyClickyStatus.ready.rawValue:
                self.cursorOverlayState.heyClickyStatusCaption = nil
                self.cursorOverlayState.heyClickyStatusSeverity = nil
                self.notchCaptureWindowManager.updateBackendStatusCaption(nil)
                return
            case HeyClickyStatus.refreshing.rawValue:
                severity = "info"
            case HeyClickyStatus.transportError.rawValue:
                severity = "warning"
            case HeyClickyStatus.needsExtension.rawValue,
                 HeyClickyStatus.signInRequired.rawValue:
                severity = "error"
            default:
                severity = "info"
            }
            // Prefer the Chinese hint from the caller (user_message), else
            // the enum's default English caption. Empty string means "hide."
            let finalCaption = (caption?.isEmpty == false) ? caption : nil
            self.cursorOverlayState.heyClickyStatusCaption = finalCaption
            self.cursorOverlayState.heyClickyStatusSeverity = severity
            // Notch pill title override.
            self.notchCaptureWindowManager.updateBackendStatusCaption(finalCaption)
            HeyClickyLog.log("ui.status_bound", lane: "system", direction: "internal", [
                "status": rawStatus ?? "?",
                "severity": severity,
                "caption_len": finalCaption?.count ?? 0
            ])
        }
        tokens.append(statusChanged)

        let resetCompleted = NotificationCenter.default.addObserver(
            forName: .clickyHeyClickyResetCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let lane = note.userInfo?["lane"] as? String else { return }
            let fallback = note.userInfo?["fallback"] as? String
            switch lane {
            case HeyClickyLane.chat.rawValue:
                if let fallback, !fallback.isEmpty {
                    self.setSelectedModel(fallback)
                }
            case HeyClickyLane.stt.rawValue,
                 HeyClickyLane.agent.rawValue:
                // Router side-effect (defaults or hook.deactivate) already ran.
                break
            default:
                break
            }
        }
        tokens.append(resetCompleted)

        // Live-rekey the codex process whenever HeyClicky refreshes its
        // access token. Otherwise the running codex keeps sending the
        // stale JWT as OPENAI_API_KEY and the proxy returns HTTP 402
        // for every subsequent turn (user has to sign out+in manually).
        let credsRefreshed = NotificationCenter.default.addObserver(
            forName: .clickyHeyClickyCredentialsRefreshed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Scan ALL heyclicky-free sessions, not just the active one.
            // Previously this only looked at `self.codexAgentSession`
            // (the currently-selected one), so a failed restored dock
            // agent — which is a DIFFERENT session — never got its
            // "请继续" replay when credentials came back. User's log
            // showed status_failed:false for the default session while
            // their UI's failed dock card was another session entirely.
            let candidateSessions = self.codexAgentSessions.filter { s in
                guard s.model.hasPrefix("heyclicky-free-") else { return false }
                // User-stopped sessions are terminal — never revive.
                guard !Self.isUserInitiatedStop(s.stopReason) else { return false }
                let progressCompleted = s.progressStage == .completed
                guard !progressCompleted else { return false }
                guard s.lastSubmittedPromptText?.isEmpty == false else { return false }
                // CRITICAL: only replay when the turn is FAILED, not
                // when it's still running. Proactive JWT refresh
                // (hourly) posts `.credentialsRefreshed` even when
                // nothing is broken — a turn happily reasoning in
                // codex should NOT get a "请继续" injected into its
                // stream, which corrupts the turn and produces `error`
                // events on the server side. Previously the filter
                // was `inFlight || failed`, treating a running turn
                // as needing rescue. Log 08:28:10 showed this
                // corrupting an active `019f83c8` turn.
                var failed = false
                if case .failed = s.status { failed = true }
                return failed
            }
            let anyToReplay = !candidateSessions.isEmpty
            HeyClickyLog.log("codex.credentials_refreshed_replay_check",
                             lane: "agent", direction: "internal", [
                "will_replay": anyToReplay,
                "candidate_count": candidateSessions.count,
                "total_sessions": self.codexAgentSessions.count
            ])
            // Rekey against the default running codex process (there's
            // only one shared app-server across sessions).
            // SKIP rekey when the running codex has a live lease AND its
            // last turn completed normally. Rekey nukes the lease
            // (post-rekey the running child authenticates as a new
            // identity → old lease dead), which costs +1 credit on the
            // next preamble even though nothing was actually broken.
            // This is triggered by the hourly proactive JWT refresh
            // fired after a turn just completed → without this guard we
            // burn a credit every time the hourly timer happens to land
            // right after a successful turn/completed.
            let defaultSession = self.codexAgentSession
            let hasLiveLease = defaultSession.currentHeyClickyLease != nil
            let sessionHealthy: Bool = {
                switch defaultSession.status {
                case .ready, .running, .starting: return true
                case .stopped: return false
                case .failed: return false
                }
            }()
            // Skip #1 — preamble is actively acquiring a new lease.
            // Rekey right now would nuke the lease we're in the middle
            // of committing, forcing a retry (+1 credit).
            if defaultSession.preambleInProgress {
                HeyClickyLog.log("codex.rekey_skipped_preamble_in_progress",
                                 lane: "agent", direction: "internal", [
                    "reason": "avoid_racing_with_lease_acquisition"
                ])
                return
            }
            // Skip #2 — running codex has a live lease AND is healthy
            // (mid-turn or between turns). Rekey would burn a credit
            // even though nothing was broken. Only rekey when we have
            // failed sessions waiting to replay.
            if hasLiveLease && sessionHealthy && !anyToReplay {
                HeyClickyLog.log("codex.rekey_skipped_lease_still_healthy",
                                 lane: "agent", direction: "internal", [
                    "status": String(describing: defaultSession.status),
                    "reason": "proactive_jwt_refresh_but_lease_alive_and_session_healthy"
                ])
                return
            }
            Task { @MainActor in
                await defaultSession.rekeyLiveCodexWithFreshJWT()
                if anyToReplay {
                    guard heyClickyObserverStore.shouldDispatchAutoReplay(owner: self) else {
                        HeyClickyLog.log("codex.auto_replay_debounced",
                                         lane: "agent", direction: "internal", [
                            "source": "credentials_refreshed"
                        ])
                        return
                    }
                    for target in candidateSessions {
                        let resumePrompt = Self.buildContextfulResumePrompt(target)
                        HeyClickyLog.log("codex.auto_replay_after_reset",
                                         lane: "agent", direction: "internal", [
                            "resume_prompt": resumePrompt,
                            "session_id_prefix": String(target.id.uuidString.prefix(8)),
                            "thread_preserved": "yes (all_turns memory intact)"
                        ])
                        self.submitAgentPrompt(resumePrompt, to: target)
                    }
                }
            }
        }
        tokens.append(credsRefreshed)

        // Proactive codex-ephemeral refresh (every 3.5h): the token
        // client just minted a fresh ephemeral and posted this notif.
        // Soft-rekey the live codex process so its Bearer swaps in-
        // place — no restart, no interruption to an in-flight turn.
        // Distinct from `credentials_refreshed` (which is a
        // full Supabase JWT rotation triggered reactively by 401 or
        // manual refresh) — this one is proactive + codex-scoped
        // only, so it must NOT replay any session, only rekey.
        let codexEphemeralRefreshed = NotificationCenter.default.addObserver(
            forName: .heyClickyCodexEphemeralRefreshed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let defaultSession = self.codexAgentSession
            Task { @MainActor in
                await defaultSession.rekeyLiveCodexWithFreshJWT()
                HeyClickyLog.log("codex.proactive_soft_rekey_dispatched",
                                 lane: "agent", direction: "internal", [:])
            }
        }
        tokens.append(codexEphemeralRefreshed)

        // Codex process crashed → clear thread + lease so next prompt
        // gets a fresh preamble. Without this, ensureThread's early-
        // return path reuses the dead activeThreadID forever.
        let codexExited = NotificationCenter.default.addObserver(
            forName: .heyClickyCodexProcessExited,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let statusCode = note.userInfo?["exit_status"] as? Int32 ?? -1
            let session = self.codexAgentSession
            // Snapshot BEFORE teardown clears thread state.
            let inFlightPrompt = session.lastSubmittedPromptText
            // User-initiated stops must NEVER auto-replay. Previously
            // clicking Stop → codex process exit → this observer fired
            // "请继续" → the task the user just cancelled came back to
            // life and kept burning quota. `stopReason` is set by every
            // stop path in CodexAgentSession.stop; treat any non-nil
            // reason that carries an explicit user gesture as terminal.
            let wasInterrupted = Self.hasInterruptedInFlightTurn(session)
            HeyClickyLog.log("codex.crashed_relaunch_trigger", lane: "agent",
                             direction: "internal", [
                "exit_status": Int(statusCode),
                "will_replay": wasInterrupted,
                "progress_stage": String(describing: session.progressStage),
                "stop_reason": session.stopReason ?? "-"
            ])
            session.clearActiveThreadForRelaunch(reason: "codex_process_exited")
            if wasInterrupted {
                guard heyClickyObserverStore.shouldDispatchAutoReplay(owner: self) else {
                    HeyClickyLog.log("codex.auto_replay_debounced", lane: "agent",
                                     direction: "internal", ["source": "codex_exited"])
                    return
                }
                HeyClickyLog.log("codex.auto_replay_after_crash", lane: "agent",
                                 direction: "internal", [:])
                self.submitAgentPrompt(Self.buildContextfulResumePrompt(session), to: session)
            }
        }
        tokens.append(codexExited)

        // Turn-limit hit / other soft interruption → auto-send "请继续"
        // on the corresponding session so the conversation resumes
        // without the user retyping.
        let autoContinueReplay = NotificationCenter.default.addObserver(
            forName: .heyClickyRequestAutoContinueReplay,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let sessionIDStr = note.userInfo?["session_id"] as? String,
                  let sessionID = UUID(uuidString: sessionIDStr) else { return }
            guard let session = self.codexAgentSessions.first(where: { $0.id == sessionID })
                    ?? (self.codexAgentSession.id == sessionID ? self.codexAgentSession : nil) else {
                return
            }
            // GATING — auto-followup consumes 1 quota unit. Only fire when
            // ALL of the following are true:
            //   (1) task was genuinely INTERRUPTED — status=.failed OR
            //       (codex crashed AND there was an in-flight prompt).
            //       Any other state (idle, completed, ready-with-no-work)
            //       means the task ended intentionally, DON'T continue.
            //   (2) user engaged THIS RUN (not disk-resurrected state)
            //   (3) NOT user-initiated stop
            //   (4) NO active turn — an active turn is steerable for 0
            //       quota, don't burn a new turn
            //   (5) breaker not open, debounce not tripped, budget not
            //       exhausted
            // Even a completed turn will NOT auto-replay: if the turn ran
            // and finished, that's the model saying "I'm done." Trust it.
            // Delegate the "was this session truly interrupted"
            // question to hasInterruptedInFlightTurn — already handles:
            //   - status = .failed
            //   - progressStage in {.starting, .planning, .executing,
            //     .composing, .failed}
            //   - watchdog kill (turn_watchdog_timeout stopReason)
            //   - .idle with entries<=4 (task never really got going)
            // AND excludes user-initiated stops.
            if !Self.hasInterruptedInFlightTurn(session) {
                HeyClickyLog.log("codex.auto_replay_skipped_not_interrupted",
                                 lane: "agent", direction: "internal",
                                 ["session_id_prefix": String(sessionIDStr.prefix(8)),
                                  "status": "\(session.status)",
                                  "stage": "\(session.progressStage)",
                                  "stopReason": session.stopReason ?? "-"])
                return
            }
            if session.progressStage == .completed {
                // F28 (Task #204) — progress-driven sessions bypass this
                // "completed means intentionally done" skip. The
                // `turn/completed` handler in CodexAgentSession already
                // verified PROGRESS.md is not yet DONE before posting,
                // and `hasInterruptedInFlightTurn` above re-checked the
                // marker for defence in depth. Any other `.completed`
                // still stops here.
                if !session.progressDriven {
                    HeyClickyLog.log("codex.auto_replay_skipped_completed",
                                     lane: "agent", direction: "internal",
                                     ["session_id_prefix": String(sessionIDStr.prefix(8))])
                    return
                }
            }
            if !self.userEngagedSessionIDs.contains(sessionID) {
                HeyClickyLog.log("codex.auto_replay_skipped_not_engaged",
                                 lane: "agent", direction: "internal",
                                 ["session_id_prefix": String(sessionIDStr.prefix(8))])
                return
            }
            if Self.isUserInitiatedStop(session.stopReason) {
                HeyClickyLog.log("codex.auto_replay_skipped_user_stopped",
                                 lane: "agent", direction: "internal",
                                 ["source": "turn_limit", "stop_reason": session.stopReason ?? "-"])
                return
            }
            // If the turn is still active (steerable), send via turn/steer
            // instead of firing a new record-agent-launch. This is the
            // 0-quota path — never route steerable continuations through
            // full submitAgentPrompt.
            if let tid = session.activeTurnID, !tid.isEmpty,
               session.activeThreadID?.isEmpty == false {
                HeyClickyLog.log("codex.auto_replay_routed_through_steer",
                                 lane: "agent", direction: "internal",
                                 ["session_id_prefix": String(sessionIDStr.prefix(8)),
                                  "turn_prefix": String(tid.prefix(8))])
                // submitPromptFromUI takes the steer path when activeTurnID
                // is present (see CodexAgentSession.submitPromptFromUI).
                let steerPrompt = session.progressDriven
                    ? Self.progressDrivenAutoContinuePrompt
                    : Self.buildContextfulResumePrompt(session)
                session.submitPromptFromUI(steerPrompt)
                return
            }
            if heyClickyObserverStore.isCircuitOpen() {
                HeyClickyLog.log("codex.auto_replay_circuit_open", lane: "agent",
                                 direction: "internal",
                                 ["source": "turn_limit", "note": "reset failures exceeded"])
                return
            }
            guard heyClickyObserverStore.shouldDispatchAutoReplay(owner: self) else {
                HeyClickyLog.log("codex.auto_replay_debounced", lane: "agent",
                                 direction: "internal", ["source": "turn_limit"])
                return
            }
            HeyClickyLog.log("codex.auto_continue_replay_dispatched", lane: "agent",
                             direction: "internal", [
                "session_id_prefix": String(sessionIDStr.prefix(8)),
                "reason": "no_active_turn_new_turn_needed",
                "progress_driven": session.progressDriven
            ])
            let newTurnPrompt = session.progressDriven
                ? Self.progressDrivenAutoContinuePrompt
                : Self.buildContextfulResumePrompt(session)
            self.submitAgentPrompt(newTurnPrompt, to: session)
        }
        tokens.append(autoContinueReplay)

        // macOS wake-from-sleep → force realtime reconnect + JWT
        // preemptive refresh so the first user interaction after wake
        // is not a compound stall (dead WS + expired token + stale
        // extension poll).
        let didWake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            HeyClickyLog.log("system_did_wake", lane: "system",
                             direction: "internal", [:])
            guard let self else { return }
            let session = self.codexAgentSession
            let inFlightPrompt = session.lastSubmittedPromptText
            let userStopped = Self.isUserInitiatedStop(session.stopReason)
            let wasInterrupted = session.model.hasPrefix("heyclicky-free-")
                && (inFlightPrompt?.isEmpty == false)
                && session.progressStage != .completed
                && !userStopped
            Task { @MainActor [weak self] in
                _ = try? await HeyClickySessionAuthenticator.shared.refresh()
                _ = try? await HeyClickySessionTokenClient.shared.mintRealtimeToken()
                NotificationCenter.default.post(
                    name: .heyClickyDidWakeFromSleep, object: nil
                )
                // rekey posts .clickyHeyClickyCredentialsRefreshed internally
                // via HeyClickySessionAuthenticator.refresh — that observer
                // (installed above) will also try to replay. Debounce
                // prevents two "请继续" landing in the queue.
                await session.rekeyLiveCodexWithFreshJWT()
                if wasInterrupted, let self {
                    guard heyClickyObserverStore.shouldDispatchAutoReplay(owner: self) else {
                        HeyClickyLog.log("codex.auto_replay_debounced",
                                         lane: "agent", direction: "internal",
                                         ["source": "wake"])
                        return
                    }
                    HeyClickyLog.log("codex.auto_replay_after_wake", lane: "agent",
                                     direction: "internal", [:])
                    self.submitAgentPrompt(Self.buildContextfulResumePrompt(session), to: session)
                }
            }
        }
        // NSWorkspace uses a distinct notification center; track the token
        // separately so uninstall can call `removeObserver` on the right
        // center. Previously this leaked → every start stacked another wake
        // observer → one wake fanned into N rekey+replay cycles.
        heyClickyObserverStore.setWorkspace(self, tokens: [didWake])

        let targetArmed = NotificationCenter.default.addObserver(
            forName: .heyClickyTargetArmed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let x = note.userInfo?["x"] as? CGFloat,
                  let y = note.userInfo?["y"] as? CGFloat else { return }
            self.overlayWindowManager.flyBuddyTo(CGPoint(x: x, y: y))
        }
        tokens.append(targetArmed)

        heyClickyObserverStore.set(self, tokens: tokens)
    }

    /// Removes every observer installed by
    /// `installHeyClickyGuidedClickBridge`. Idempotent — safe to call
    /// when no tokens are registered.
    /// Poll the realtime session's playback RMS 30x/s while TTS is
    /// playing so the speaking-pulse ring modulates with the assistant's
    /// voice. Without this the ring pulses off stale mic power (0 unless
    /// user is still speaking) and looks dead during the reply.
    func startPlaybackPowerLevelSampling() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let rms = HeyClickyRealtimeSession.shared.currentPlaybackRMS
            // Scale to roughly match mic-input dynamic range so the ring
            // sizing feels balanced with the listening waveform.
            let scaled = min(max(rms * 2.2, 0), 1)
            self.cursorOverlayState.currentAudioPowerLevel = scaled
        }
        RunLoop.main.add(timer, forMode: .common)
        HeyClickyPlaybackSamplerStore.shared.set(self, timer: timer)
    }

    func stopPlaybackPowerLevelSampling() {
        HeyClickyPlaybackSamplerStore.shared.clear(self)
        // Zero the level so the ring collapses back to its base breathing
        // radius rather than freezing on the last sample.
        cursorOverlayState.currentAudioPowerLevel = 0
    }

    func uninstallHeyClickyObservers() {
        for token in heyClickyObserverStore.take(self) {
            NotificationCenter.default.removeObserver(token)
        }
        for token in heyClickyObserverStore.takeWorkspace(self) {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// Called from `CompanionManager.stop()` to close every HeyClicky
    /// Free subsystem in one place (F1 review action).
    func stopHeyClickyFreeSubsystems() {
        uninstallHeyClickyObservers()
        HeyClickyChromeBridgeServer.shared.stop()
        HeyClickySessionTokenClient.shared.stopProactiveRefreshLoop()
        HeyClickySessionTokenClient.shared.stopProactiveCodexRefreshLoop()
        HeyClickyRealtimeSession.shared.disconnect()
        heyClickyObserverStore.stopWatchdogTicker()
        heyClickyObserverStore.stopChromeExtHeartbeatTicker()
    }

    /// Every 30s, verify Chrome extension is polling. If dead >90s
    /// and we're signed into heyclicky (i.e. we rely on ext for
    /// account reset OAuth chooser), log a warning + emit a
    /// notification so UI / test harness knows. Doesn't try to
    /// restart Chrome itself (out of app scope), but the log gives
    /// the operator a chance to fix.
    private var extLastDeadWarningAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: "openClickyExtLastDeadWarningAt") }
        set { UserDefaults.standard.set(newValue, forKey: "openClickyExtLastDeadWarningAt") }
    }

    func startChromeExtHeartbeatMonitor() {
        heyClickyObserverStore.startChromeExtHeartbeatTicker(interval: 30) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard AppBundleConfiguration.heyClickySignedIn() else { return }
                let alive = HeyClickyChromeBridgeServer.shared.isExtensionAlive
                if !alive {
                    let now = Date().timeIntervalSince1970
                    // Rate-limit warning to once per 5min.
                    if now - self.extLastDeadWarningAt > 300 {
                        self.extLastDeadWarningAt = now
                        HeyClickyLog.log("chrome_ext.heartbeat_dead",
                                         lane: "system", direction: "error",
                                         ["note": "ext not polled >30s; account reset flow unavailable"])
                    }
                }
            }
        }
    }

    func startTurnTimeoutWatchdogTicker() {
        heyClickyObserverStore.startWatchdogTicker(interval: 60) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for session in self.codexAgentSessions where session.model.hasPrefix("heyclicky-free-") {
                    let isActive: Bool = {
                        switch session.progressStage {
                        case .starting, .planning, .executing, .composing: return true
                        default: return false
                        }
                    }()
                    guard isActive else { continue }
                    let anyN = session.entries.count
                    if heyClickyObserverStore.recordProgressAndCheckTimeout(
                        sessionID: session.id,
                        assistantEntryCount: anyN,
                        isActive: true) {
                        HeyClickyLog.log("codex.turn_watchdog_ticker_timeout",
                                         lane: "agent", direction: "internal",
                                         ["session_id_prefix": String(session.id.uuidString.prefix(8))])
                        // First try to unstick via turn/steer nudge —
                        // this is 0-quota, keeps codex + lease alive,
                        // and just pokes the model to keep working.
                        // Only if there's no active turn to nudge (e.g.
                        // turn just completed and we're between turns)
                        // do we fall back to the old kill+replay path,
                        // which spends a new lease.
                        let nudged = session.nudgeActiveTurn(reason: "watchdog_idle_timeout")
                        if nudged {
                            HeyClickyLog.log("codex.turn_watchdog_nudged_no_kill",
                                             lane: "agent", direction: "internal",
                                             ["session_id_prefix": String(session.id.uuidString.prefix(8))])
                            heyClickyObserverStore.resetWatchdog(sessionID: session.id)
                        } else {
                            HeyClickyLog.log("codex.turn_watchdog_kill_fallback",
                                             lane: "agent", direction: "internal",
                                             ["session_id_prefix": String(session.id.uuidString.prefix(8)),
                                              "reason": "no_active_turn_to_nudge"])
                            session.stop(reason: "turn_watchdog_timeout")
                            NotificationCenter.default.post(
                                name: .heyClickyCodexProcessExited,
                                object: nil,
                                userInfo: ["exit_status": -9]
                            )
                            heyClickyObserverStore.resetWatchdog(sessionID: session.id)
                        }
                    }
                }
            }
        }
    }

    /// Boots every HeyClicky Free subsystem in one place, called from
    /// `CompanionManager.start()`. Follows the same "only start when
    /// configured" gate other openclicky subsystems use.
    func startHeyClickyFreeSubsystems() {
        installHeyClickyGuidedClickBridge()
        HeyClickyChromeBridgeServer.shared.start()
        // Watchdog ticker: every 60s, walk heyclicky sessions in an
        // active stage and check if their assistant-entry count has
        // been stuck. If yes → kill+replay. `sink` on progressStage
        // only fires on transitions; a genuinely hung turn stays in
        // .executing forever, so we need an external poll.
        startTurnTimeoutWatchdogTicker()
        startChromeExtHeartbeatMonitor()
        if AppBundleConfiguration.heyClickySignedIn() {
            HeyClickySessionTokenClient.shared.startProactiveRefreshLoop()
        // Keep plan client (Settings row + Notch quota) 20s-fresh so
        // the user always sees current credits.
        HeyClickyPlanClient.shared.startPeriodicRefresh()
            // Persistent realtime session (clicky-mac RealtimeSession
            // parity): keep one WS open across all PTT turns. This
            // replaces the old warm-connection pool + per-turn reconnect;
            // PTT hotkey routes here for HeyClicky Free lane via
            // `shouldRoutePTTToHeyClickyRealtimeSession`.
            HeyClickyRealtimeSession.shared.attach(companionManager: self)
            // Subscribe to the session's isResponding publisher so the
            // buddy overlay animates responding/idle in sync with the
            // Realtime audio stream (clicky-mac
            // `bindRealtimeStateFeedback` parity).
            let responseObserver = HeyClickyRealtimeSession.shared.$isResponding
                .receive(on: DispatchQueue.main)
                .sink { [weak self] responding in
                    guard let self else { return }
                    if responding {
                        self.voiceState = .responding
                        self.startPlaybackPowerLevelSampling()
                    } else {
                        self.stopPlaybackPowerLevelSampling()
                        if self.voiceState == .responding || self.voiceState == .processing {
                            self.voiceState = .idle
                        }
                    }
                }
            HeyClickyRealtimeSessionSubscriptionStore.shared.retain(responseObserver, for: self)
            Task { await HeyClickyRealtimeSession.shared.connect() }
            // Prime the plan snapshot at boot so Settings sees a
            // non-nil `latest` on first open (no "Loading…" flash).
            Task { @MainActor in
                await HeyClickyPlanClient.shared.refresh()
            }
        }
        reconcileHeyClickyProfile()
        applyHeyClickyRealtimeHookIfNeeded()
    }

    /// If the persisted active profile is HeyClicky Free but the
    /// voice-response model drifted (e.g. after a bad session-expired
    /// wipe rewrote lane defaults), reapply the profile so all four
    /// lane UserDefaults line up again. Idempotent.
    private func reconcileHeyClickyProfile() {
        let defaults = UserDefaults.standard
        let activeID = defaults.string(forKey: OpenClickyProfileCatalog.activeProfileDefaultsKey)
        guard activeID == OpenClickyProfileCatalog.heyclickyFree.id else { return }
        let currentModel = defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey)
        let expectedModel = OpenClickyProfileCatalog.heyclickyFree.responseModelID
        if currentModel != expectedModel {
            OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.heyclickyFree)
            setSelectedModel(expectedModel)
        }
    }

    /// Wire the proxy-minted ephemeral token into the Realtime WS
    /// client whenever the currently-selected voice model is a
    /// HeyClicky Free entry. Called at boot and whenever the model
    /// selection changes so a lane switch doesn't leave the WS
    /// authenticated against a stale BYOK key.
    func applyHeyClickyRealtimeHookIfNeeded() {
        let model = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        let isHeyClickyLane = model.provider == .heyclickyFree
        // Also check whether the CURRENTLY selected AGENT model is heyclicky.
        // The agent + voice model are chosen independently: user might pick
        // BYOK codex for the agent while keeping realtime on heyclicky, or
        // vice versa. Only tear down the agent hook when NEITHER lane wants
        // the proxy — otherwise the still-heyclicky lane loses its base URL.
        let agentModelID = UserDefaults.standard.string(forKey: "clickyCodexModel")
            ?? OpenClickyModelCatalog.defaultCodexActionsModelID
        let isAgentHeyClickyLane = agentModelID.hasPrefix("heyclicky-free-")
        if isHeyClickyLane {
            Task {
                await self.openAIRealtimeSpeechClient.updateConfiguration(
                    apiKey: "",
                    voiceID: AppBundleConfiguration.openAIRealtimeVoiceID(),
                    realtimeBaseURL: nil,
                    serverInstructions: nil,
                    onEphemeralRefreshNeeded: {
                        let (token, expiresAt) = try await HeyClickySessionTokenClient.shared.mintRealtimeToken()
                        return (token, expiresAt)
                    }
                )
            }
        } else {
            // Non-HeyClicky voice lane: clear the realtime hook so the WS
            // client falls back to the user's BYOK apiKey.
            Task {
                await self.openAIRealtimeSpeechClient.updateConfiguration(
                    apiKey: AppBundleConfiguration.openAIAPIKey() ?? "",
                    voiceID: AppBundleConfiguration.openAIRealtimeVoiceID(),
                    realtimeBaseURL: nil,
                    serverInstructions: nil,
                    onEphemeralRefreshNeeded: nil
                )
            }
        }
        // Restore the user's original agent base URL + BYOK Codex API key
        // when neither lane is heyclicky. Without this, `clickyAgentBaseURL`
        // stays pinned to the proxy from a prior heyclicky session and
        // `HeyClickyPreviousAgentBaseURL` snapshot stays non-nil, which
        // causes CodexProcessManager.start to inject CLICKY_WORKER_BASE_URL
        // + OPENAI_BASE_URL into a plain BYOK codex child → every response
        // gets routed through the heyclicky proxy → 401/402.
        if !isHeyClickyLane && !isAgentHeyClickyLane {
            HeyClickyFreeTierAgentHook.deactivate()
        }
    }

    /// U5 fallback: after session expires or user signs out, drop any
    /// heyclicky-* lane selections back to a safe default so the
    /// picker doesn't leave the user staring at a broken option.
    /// Uses the `local` profile (Parakeet STT + Claude Haiku + Edge TTS +
    /// no Codex model override) as the safe baseline.
    func revertHeyClickyLanesToDefaults() {
        let defaults = UserDefaults.standard

        let sttKey = AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey
        if defaults.string(forKey: sttKey) == BuddyTranscriptionProviderID.heyclickyFree.rawValue {
            defaults.set(BuddyTranscriptionProviderID.automatic.rawValue, forKey: sttKey)
        }

        let responseKey = OpenClickyProfileCatalog.voiceResponseModelDefaultsKey
        if let raw = defaults.string(forKey: responseKey), raw.hasPrefix("heyclicky-free-") {
            let fallback = OpenClickyProfileCatalog.local.responseModelID
            defaults.set(fallback, forKey: responseKey)
            setSelectedModel(fallback)
        }

        let agentKey = "clickyCodexModel"
        if let raw = defaults.string(forKey: agentKey), raw.hasPrefix("heyclicky-free-") {
            defaults.removeObject(forKey: agentKey)
        }
    }

    /// Heuristic: does the user's transcript specifically ask about the
    /// FOCUSED window (as opposed to the whole screen)? Keeps focused-
    /// window capture as an opt-in — for everything else we send the
    /// full display so cross-window / menu-bar / dock queries work.
    static func instructionMentionsCurrentWindow(_ text: String) -> Bool {
        let t = text.lowercased()
        let terms = [
            "当前窗口", "这个窗口", "此窗口", "当前界面", "这个界面",
            "当前页面", "这个页面", "本窗口", "这个应用", "当前应用",
            "this window", "current window", "this app", "the pdf",
            "this page", "the article", "the doc", "focused window"
        ]
        return terms.contains(where: { t.contains($0.lowercased()) })
    }

    /// In-session tool execution for the realtime `openclicky_use_screen_context`
    /// tool. Captures screen, runs chat-tool-call, applies local side-
    /// effects (clipboard / typing / walkthrough), and returns a JSON
    /// string that the realtime WS speaks INLINE via `function_call_output`
    /// (matches clicky-mac AgentToolBridge.handleSendToHigherModel).
    /// Returning nil signals a hard failure to the caller.
    func executeInSessionScreenContextTool(instruction: String,
                                            intent: String? = nil) async -> String? {
        do {
            // Skip screenshot only for intents where visual context
            // is objectively noise: world_knowledge (physics facts)
            // and recent_conv (already have last exchange in
            // context). For everything else — including uncertain
            // intents — capture. LTM retrieval on the other hand
            // ALWAYS runs (see HeyClickyChatToolCallClient) because
            // it's cheap and the classifier can't know if the vault
            // has relevant memory. Two-track strategy:
            //   * cheap fast track (LTM) — always attempt
            //   * expensive track (screenshot) — gated on intent
            let skipsScreenshot = (intent == "world_knowledge"
                                    || intent == "recent_conv")
            // Capture selection:
            //   - "此/这个/当前 窗口/界面/页面/window/this window/this app" → focused window
            //   - everything else → full display (default)
            let wantsFocusedWindow = Self.instructionMentionsCurrentWindow(instruction)
            let captures: [CompanionScreenCapture]
            if skipsScreenshot {
                captures = []
            } else if wantsFocusedWindow {
                captures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
            } else {
                captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }
            let primary = captures.first { $0.isCursorScreen } ?? captures.first
            let images: [(data: Data, label: String)]
            if let capture = primary {
                images = [(capture.imageData, "screen_context")]
                // Stash the capture context so walkthrough-beat rescale
                // can use the ACTUAL image space (screenshot dims + the
                // screen-frame those px belong to) instead of guessing
                // from NSScreen.main.
                let nsIndex = NSScreen.screens.firstIndex(where: { $0.frame == capture.displayFrame }).map { $0 + 1 }
                await MainActor.run {
                    self.pendingHeyClickyCaptureContext = CompanionManager.HeyClickyCaptureContext(
                        displayFrame: capture.displayFrame,
                        screenshotWidth: capture.screenshotWidthInPixels,
                        screenshotHeight: capture.screenshotHeightInPixels,
                        nsScreenIndex: nsIndex,
                        isWindowCapture: wantsFocusedWindow
                    )
                }
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "voice.screen_capture_context",
                    fields: [
                        "display_frame": "\(Int(capture.displayFrame.origin.x)),\(Int(capture.displayFrame.origin.y)),\(Int(capture.displayFrame.width))x\(Int(capture.displayFrame.height))",
                        "shot_wh": "\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels)",
                        "ns_index": nsIndex ?? -1
                    ]
                )
            } else {
                images = []
            }
            let systemPrompt = await MainActor.run { self.currentVoiceResponseSystemPrompt() }
            let history = await MainActor.run { self.voiceConversationHistoryForAPI() }
            let text = try await HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(
                companionManager: self,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: history,
                userPrompt: instruction,
                intent: intent,
                onTextChunk: { _ in }
            )
            // Persist this turn back into Screen History — the realtime
            // tool-call path bypasses `rememberVoiceExchange`, so without
            // this the vault never learns what the user said or what
            // we answered. `rememberVoiceExchange` handles both sides
            // (ConversationLogger.log + home chat + LTM cache bust).
            await MainActor.run {
                self.rememberVoiceExchange(
                    userTranscript: instruction,
                    assistantResponse: text,
                    reason: "realtime_tool_call_screen_context")
            }
            // Wrap the model's text into the same shape realtime expects
            // for a function_call_output: JSON string with a `text` field
            // that the model will read out. Include a short hint to speak
            // the text so the follow-up response.create is triggered.
            let payload: [String: Any] = [
                "text": text,
                "spoke_result": true
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return #"{"text":"","spoke_result":false}"#
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "voice.in_session_tool_failed",
                fields: ["error": "\(error)", "instruction_len": instruction.count]
            )
            return #"{"error":"tool_failed"}"#
        }
    }

    /// Speak a short greeting in the currently configured reply
    /// language using the given voice. Wired to the speaker icon next
    /// to the voice picker so the user can preview each option before
    /// committing. Temporarily overrides the persisted voice for the
    /// preview only, then restores it.
    /// Play the pre-recorded voice preview shipped as
    /// `realtime-voice-preview-<voice>.mp3`. These 10 short clips come
    /// straight from HeyClicky (IDA-verified: `realtime-voice-preview-*`
    /// asset keys, loaded via `_voicePreviewPlayer`). Doing it locally is
    /// zero-latency, needs no proxy quota, and works whether the user is
    /// signed in or not — matches the real app's UX.
    func previewOpenAIRealtimeVoice(voiceID: String) async {
        let normalized = voiceID.lowercased()
        guard let url = Bundle.main.url(forResource: "realtime-voice-preview-\(normalized)", withExtension: "mp3") else {
            OpenClickyMessageLogStore.shared.append(
                lane: "system",
                direction: "error",
                event: "voice.preview_missing",
                fields: ["voice_id": voiceID]
            )
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            voicePreviewPlayer.swap(player)
            player.play()
            OpenClickyMessageLogStore.shared.append(
                lane: "system",
                direction: "info",
                event: "voice.preview_play",
                fields: ["voice_id": voiceID, "duration_ms": Int(player.duration * 1000)]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "system",
                direction: "error",
                event: "voice.preview_failed",
                fields: ["voice_id": voiceID, "error": "\(error)"]
            )
        }
    }

    /// Pull widgets stashed by the most recent HeyClicky chat turn and
    /// clear the stash. Call this exactly once per card construction so
    /// the widgets never bleed into an unrelated turn (e.g. a subsequent
    /// non-HeyClicky lane response would show stale slots otherwise).
    func drainPendingHeyClickyWidgets() -> [WidgetPayload] {
        let out = pendingHeyClickyWidgets
        pendingHeyClickyWidgets = []
        return out
    }

    /// Returns (widthPx, heightPx) sized from the main screen backing
    /// scale. HeyClicky proxy needs pixel dimensions inline with the
    /// screenshot for point-tag denormalization.
    func currentScreenshotDimensions() -> (width: Int, height: Int) {
        guard let screen = NSScreen.main else { return (0, 0) }
        let scale = screen.backingScaleFactor
        let frame = screen.frame
        return (
            Int((frame.width * scale).rounded()),
            Int((frame.height * scale).rounded())
        )
    }

    /// Bridge from HeyClickyRealtimeSession's tool handler into the
    /// existing agent-task launcher + HUD manager. Public because the
    /// realtime session lives in a separate module and can't reach
    /// startVoiceAgentTaskPlan directly. Uses the same `agent.realtime_tool`
    /// route as legacy realtime for logging + telemetry parity.
    /// Start the /agent-messages poller so incoming agent turns flow
    /// into the HUD, and mark the HUD as ready to accept user input
    /// (typed replies get POST'd back). Called by both the realtime
    /// agent-spawn tool and any manual "open HUD" hook.
    func beginAgentMessagesPollingIfNeeded() {
        // If the HUD is disabled (advanced mode off), the user can't see
        // inbox messages anyway — don't spin the poller. Prevents burning
        // /agent-messages calls when the HUD failed to open.
        guard isAdvancedModeEnabled else { return }
        HeyClickyAgentMessagesClient.shared.start { [weak self] message in
            Task { @MainActor [weak self] in
                self?.deliverAgentInboxMessage(message)
            }
        }
    }

    func stopAgentMessagesPolling() {
        HeyClickyAgentMessagesClient.shared.stop()
    }

    /// Route an inbound agent message into whichever Codex session is
    /// currently rendering in the HUD. Assistants land as assistant
    /// entries; user echoes and system rows follow their roles.
    private func deliverAgentInboxMessage(_ message: HeyClickyAgentMessage) {
        guard !message.content.isEmpty else { return }
        let role: CodexTranscriptEntry.Role
        switch message.role.lowercased() {
        case "user": role = .user
        case "system": role = .system
        default: role = .assistant
        }
        HeyClickyLog.log("agent_messages.delivered_to_transcript", lane: "agent", direction: "incoming", [
            "stage": "S4_message_ingress",
            "id": message.id,
            "role": message.role,
            "target_session": codexAgentSession.activeThreadID ?? "nil",
            "text_head": String(message.content.prefix(60))
        ])
        codexAgentSession.appendRemoteTranscriptEntry(role: role, text: message.content, id: message.id)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "agent_messages.inbox_row",
            fields: [
                "role": message.role,
                "id": message.id,
                "content_len": message.content.count,
                "session_id": message.sessionID ?? ""
            ]
        )
    }

    /// Post a user reply from the HUD text field back through
    /// /agent-messages so the running agent hears the follow-up.
    func postUserReplyToAgentInbox(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task.detached { [sessionID = codexAgentSession.activeThreadID] in
            _ = await HeyClickyAgentMessagesClient.shared.postUserMessage(
                trimmed,
                sessionID: sessionID
            )
        }
    }

    func startBackgroundAgentFromRealtime(prompt: String) {
        HeyClickyLog.log("agent.spawn_started", lane: "agent", direction: "internal", [
            "stage": "S2_agent_process_launch",
            "prompt_len": prompt.count,
            "advanced_mode": isAdvancedModeEnabled
        ])
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.realtime_tool_route",
            fields: [
                "instruction": prompt,
                "toolName": "openclicky_start_background_agent",
                "executor": "agent_mode",
                "route": "agent.realtime_tool"
            ]
        )
        // Reuse the legacy realtime path — it handles all agent
        // lifecycle: parallel split, launcher, HUD open, heartbeat.
        launchBackgroundAgentForRealtime(instruction: prompt)
        HeyClickyLog.log("agent.launch_returned", lane: "agent", direction: "internal", [
            "stage": "S2_agent_process_launch",
            "active_session_id": activeCodexAgentSessionID ?? "nil"
        ])
        // The realtime tool contract promises "the Agent HUD appears in
        // the top-right corner" — that is the DOCK ICON, not the full
        // chat panel. `launchBackgroundAgentForRealtime` above already
        // triggers `agentDockWindowManager.show(...)` (CompanionManager.swift
        // :13740). Opening the full CodexHUD chat panel on spawn is
        // intrusive — the user has to click the dock icon to open it.
        HeyClickyLog.log("agent.dock_icon_shown", lane: "agent", direction: "internal", [
            "stage": "S3_hud_opens",
            "advanced_mode": isAdvancedModeEnabled,
            "note": "hud_panel_not_auto_opened"
        ])
        beginAgentMessagesPollingIfNeeded()
        // Kick a notifications badge refresh in the background so the
        // HUD's inbox indicator reflects reality on first paint. Also
        // start the periodic refresh so "agent finished" surfaces even
        // when the HUD is closed later.
        HeyClickyAgentNotificationsClient.shared.startPeriodicRefresh()
        Task { @MainActor in
            await HeyClickyAgentNotificationsClient.shared.refresh()
        }
        // Refresh plan/quota after spawn — a background agent burns
        // 1 agent credit + subsequent turns burn message credits. The
        // Settings quota row and any future UI overlay bind to
        // HeyClickyPlanClient.shared.latest, so refresh writes there.
        Task { @MainActor in
            _ = await HeyClickyPlanClient.shared.refresh()
        }
    }

    /// Click at a global AppKit bottom-left point, wait briefly, then
    /// type text as real keyboard events. Used when the server's
    /// `typing` payload includes a target x/y (verified via probe:
    /// `{"x": 400, "y": 684, "text": "hello", "label": "命令行输入框"}`).
    /// Clicking first lets the type land in the intended field even
    /// when it wasn't already focused.
    func clickAtGlobalPointThenType(text: String, globalPoint: CGPoint) {
        // AppKit bottom-left → CGEvent top-left: flip Y against the
        // full multi-display arrangement.
        let screenTopY = NSScreen.screens
            .map { $0.frame.origin.y + $0.frame.height }
            .max() ?? 0
        let cgY = screenTopY - globalPoint.y
        let cgPoint = CGPoint(x: globalPoint.x, y: cgY)
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                              mouseCursorPosition: cgPoint, mouseButton: .left) {
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: cgPoint, mouseButton: .left) {
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
        // Give the target app a beat to focus its input field, then
        // deliver the typed string via the same unicode-keystroke path
        // used everywhere else.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.typeTextForHeyClickyFree(text)
        }
    }

    /// Type text into the frontmost app as real keyboard input.
    /// Mirrors clicky-mac `DesktopActions.typeIntoFrontmostApp`: post
    /// CGEvent key events with `keyboardSetUnicodeString` in 20-char
    /// chunks with 20ms gaps so target apps see genuine typing (works
    /// in password fields, Terminal, address bars — where Cmd+V paste
    /// is blocked or produces different behavior).
    func typeTextForHeyClickyFree(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let scalars = Array(text.unicodeScalars)
        let chunkSize = 20
        var index = 0
        while index < scalars.count {
            let end = min(index + chunkSize, scalars.count)
            let chunk = Array(scalars[index..<end])
            index = end
            let utf16 = chunk.flatMap { Array(String($0).utf16) }
            utf16.withUnsafeBufferPointer { buffer in
                guard let ptr = buffer.baseAddress else { return }
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr)
                    down.post(tap: .cgAnnotatedSessionEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr)
                    up.post(tap: .cgAnnotatedSessionEventTap)
                }
            }
            usleep(20_000)
        }
    }

    /// Write to clipboard without erasing what was there before. Preserves
    /// prior contents so proxy-driven clipboard_copy doesn't destroy the
    /// user's clipboard silently. Restore after 5s.
    func writeToClipboardPreservingUserContents(_ text: String, restoreAfter seconds: Double = 5.0) {
        let pb = NSPasteboard.general
        let prior = pb.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let current = pb.string(forType: .string)
            // Only restore if the user hasn't copied something new since.
            guard current == text else { return }
            pb.clearContents()
            for itemContents in prior {
                let restored = NSPasteboardItem()
                for (type, data) in itemContents {
                    restored.setData(data, forType: type)
                }
                pb.writeObjects([restored])
            }
        }
    }
}
