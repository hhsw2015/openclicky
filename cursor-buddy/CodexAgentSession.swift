import AppKit
import Combine
import Foundation
import OpenClickyBrowser
import OpenClickyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

actor OpenClickyAgentFileLeaseCoordinator {
    static let shared = OpenClickyAgentFileLeaseCoordinator()

    struct LeaseConflict {
        let path: String
        let ownerSessionID: UUID
        let ownerTitle: String
    }

    struct LeaseSummary {
        let claimedPaths: [String]
        let conflicts: [LeaseConflict]
        let activeClaims: [String]
        let waitedForConflicts: Bool
        let waitTimedOut: Bool
    }

    private struct LeaseRecord {
        let sessionID: UUID
        let sessionTitle: String
        let acquiredAt: Date
    }

    private var leasesByPath: [String: LeaseRecord] = [:]
    private var pathsBySession: [UUID: Set<String>] = [:]

    func claimPaths(_ paths: [String], for sessionID: UUID, title: String) -> LeaseSummary {
        claimAvailablePaths(Array(Set(paths.map(Self.normalizedPath))).sorted(), for: sessionID, title: title, waitedForConflicts: false, waitTimedOut: false)
    }

    func claimPathsWaitingForRelease(_ paths: [String], for sessionID: UUID, title: String, timeout: TimeInterval = 900, pollInterval: TimeInterval = 2) async throws -> LeaseSummary {
        releaseLeases(for: sessionID)
        let uniquePaths = Array(Set(paths.map(Self.normalizedPath))).sorted()
        let deadline = Date().addingTimeInterval(timeout)
        var waitedForConflicts = false

        while !conflicts(for: uniquePaths, excluding: sessionID).isEmpty {
            try Task.checkCancellation()
            waitedForConflicts = true
            guard Date() < deadline else {
                return claimAvailablePaths(uniquePaths, for: sessionID, title: title, waitedForConflicts: true, waitTimedOut: true)
            }
            let nanoseconds = UInt64(max(0.25, pollInterval) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }

        try Task.checkCancellation()
        return claimAvailablePaths(uniquePaths, for: sessionID, title: title, waitedForConflicts: waitedForConflicts, waitTimedOut: false)
    }

    private func claimAvailablePaths(_ uniquePaths: [String], for sessionID: UUID, title: String, waitedForConflicts: Bool, waitTimedOut: Bool) -> LeaseSummary {
        releaseLeases(for: sessionID)
        var claimedPaths: [String] = []
        var conflicts: [LeaseConflict] = []

        for path in uniquePaths {
            if let existing = leasesByPath[path], existing.sessionID != sessionID {
                conflicts.append(LeaseConflict(path: path, ownerSessionID: existing.sessionID, ownerTitle: existing.sessionTitle))
                continue
            }

            leasesByPath[path] = LeaseRecord(sessionID: sessionID, sessionTitle: title, acquiredAt: Date())
            pathsBySession[sessionID, default: []].insert(path)
            claimedPaths.append(path)
        }

        return LeaseSummary(
            claimedPaths: claimedPaths,
            conflicts: conflicts,
            activeClaims: activeClaimLines(excluding: sessionID),
            waitedForConflicts: waitedForConflicts,
            waitTimedOut: waitTimedOut
        )
    }

    private func conflicts(for paths: [String], excluding sessionID: UUID) -> [LeaseConflict] {
        paths.compactMap { path in
            guard let existing = leasesByPath[path], existing.sessionID != sessionID else { return nil }
            return LeaseConflict(path: path, ownerSessionID: existing.sessionID, ownerTitle: existing.sessionTitle)
        }
    }

    func coordinationSnapshot(excluding sessionID: UUID? = nil) -> [String] {
        activeClaimLines(excluding: sessionID)
    }

    func releaseLeases(for sessionID: UUID) {
        guard let paths = pathsBySession.removeValue(forKey: sessionID) else { return }
        for path in paths {
            if leasesByPath[path]?.sessionID == sessionID {
                leasesByPath.removeValue(forKey: path)
            }
        }
    }

    private func activeClaimLines(excluding sessionID: UUID? = nil) -> [String] {
        leasesByPath
            .filter { _, lease in lease.sessionID != sessionID }
            .map { path, lease in "- \(path) (owned by \(lease.sessionTitle))" }
            .sorted()
    }

    private static func normalizedPath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expanded = path
        }
        return (expanded as NSString).standardizingPath
    }
}

struct CodexTranscriptEntry: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Equatable, Codable, Sendable {
        case user
        case assistant
        case system
        case command
        case plan
    }

    let id: String
    var role: Role
    var text: String
    var createdAt: Date

    init(id: String = UUID().uuidString, role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct CodexAgentScreenContextAttachment: Equatable {
    let label: String
    let fileURL: URL
    let note: String?
}

struct CodexAgentScreenContext: Equatable {
    let source: String
    let capturedAt: Date
    let selectedText: String?
    let attachments: [CodexAgentScreenContextAttachment]

    var isEmpty: Bool {
        attachments.isEmpty && (selectedText == nil || selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    }

    func promptPrefix() -> String {
        guard !isEmpty else { return "" }

        var lines: [String] = [
            "OpenClicky screen context:",
            "- Source: \(source)",
            "- Captured at: \(ISO8601DateFormatter().string(from: capturedAt))",
            "- Screenshot files are saved locally as task context. Inspect them if your runtime exposes image/file viewing; otherwise be explicit that screenshot inspection is unavailable.",
            "- Treat these screenshots as visual reference material for the task, not as files the user is asking you to find or show back to them."
        ]

        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- Selected text:\n\(selectedText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        for (index, attachment) in attachments.enumerated() {
            lines.append("\(index + 1). \(attachment.label): \(attachment.fileURL.path)")
            if let note = attachment.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines.append("   Note: \(note)")
            }
        }

        return lines.joined(separator: "\n")
    }
}


enum CodexAgentSessionStatus: Equatable {
    case stopped
    case starting
    case ready
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Ready"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .running: return "Running"
        case .failed: return "Stopped"
        }
    }
}

enum CodexAgentProgressStage: Equatable {
    case idle
    case starting
    case planning
    case executing
    case composing
    case completed
    case failed

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .planning: return "Planning"
        case .executing: return "Executing"
        case .composing: return "Composing reply"
        case .completed: return "Completed"
        case .failed: return "Stopped"
        }
    }
}

@MainActor
final class CodexAgentSession: ObservableObject, Identifiable, BrowserWorkspaceAgentSessionProtocol {
    let id: UUID
    let createdAt: Date
    let accentTheme: OpenClickyCore.ClickyAccentTheme

    /// SKI-Mode shim marker. When non-nil the session is a lightweight
    /// facade over a file-bridge CLI agent — no codex daemon behind it.
    /// Contains (workspace path, upstream SKI session id) so
    /// submitPromptFromUI can post text via OpenClickyFileBridge.
    var skiBridge: (workspace: String, skiSessionID: String)? = nil

    /// Force the shim to appear in the "Active" agents list even
    /// before its first entry arrives. Without this, the main panel
    /// filters out shim sessions (hasVisibleActivity=false when both
    /// entries and status are empty) and the Chat button opens an
    /// empty panel until the first tts.speak arrives.
    func forceVisibleForSKIShim() {
        if status == .stopped {
            status = .ready
        }
    }

    /// Update Codex-facing state fields for the SKI shim so the UI's
    /// dock caption, activity lines, progress dot, and status summary
    /// all render the same way as a real Codex session.
    func updateSKIShimState(
        status newStatus: CodexAgentSessionStatus?,
        progressStage newStage: CodexAgentProgressStage?,
        activityStatus: String?
    ) {
        if let newStatus, newStatus != status {
            status = newStatus
        }
        if let newStage, newStage != progressStage {
            progressStage = newStage
        }
        if let activityStatus, !activityStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var lines = activityStatusLines
            if lines.last != activityStatus {
                lines.append(activityStatus)
                if lines.count > 40 { lines.removeFirst(lines.count - 40) }
                activityStatusLines = lines
            }
        }
    }

    /// Directly assign transcript entries. Used by SKI shims to mirror
    /// SKIModeConversationStore messages without going through the
    /// codex process manager.
    func setEntriesForSKIShim(_ newEntries: [CodexTranscriptEntry]) {
        entries = newEntries
        if !newEntries.isEmpty && status == .stopped {
            status = .ready
        }
        let roleCounts = Dictionary(grouping: newEntries, by: { "\($0.role)" }).mapValues { $0.count }
        let rolesStr = roleCounts.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "openclicky.ski.shim_set_entries",
            fields: [
                "shim_id": id.uuidString.prefix(8).description,
                "total": "\(newEntries.count)",
                "roles": rolesStr
            ]
        )
    }

    /// Bypass codex process spawning for SKI shim sessions and forward
    /// user text through the file bridge. Called by submitPromptFromUI
    /// when skiBridge is set.
    private func submitPromptViaSKIBridge(_ prompt: String) {
        guard let bridge = skiBridge else { return }
        entries.append(CodexTranscriptEntry(role: .user, text: prompt))
        let workspaceURL = URL(fileURLWithPath: bridge.workspace)
        // Route via CompanionManager so the utterance carries the same
        // rich `context` (LTM/xlb/stash/window/mcp URL+token/hints)
        // that the voice-response pipeline builds. Direct file-bridge
        // call here would ship only raw text and rob the CLI of the
        // capabilities the AI-response path enjoys.
        NotificationCenter.default.post(
            name: Notification.Name("com.openclicky.ski.textSubmitFromMiniChat"),
            object: nil,
            userInfo: [
                "text": prompt,
                "workspace": workspaceURL.path
            ]
        )
    }
    @Published private(set) var status: CodexAgentSessionStatus = .stopped
    @Published private(set) var entries: [CodexTranscriptEntry] = []
    @Published private(set) var activeThreadID: String?
    /// The current active turn id, learned from codex's `turn/started`
    /// notification. Non-nil ONLY when a turn is actively running.
    /// Cleared on turn/completed/failed. Used to route in-flight
    /// follow-ups through `turn/steer` (0 quota) instead of
    /// `turn/start` (new lease = +1 quota).
    @Published private(set) var activeTurnID: String?
    /// Objective queued by external caller (automation start) to be
    /// set as the thread's durable goal at preamble completion.
    /// Consumed once; cleared after use so re-runs don't overwrite
    /// a goal that may have been manually adjusted.
    internal var pendingThreadGoalObjective: String?
    /// Server-side lease id from the last record-agent-launch response.
    /// Non-nil ONLY while the lease has not been server-marked complete.
    /// Persisted so restart can attempt turn/steer against the same
    /// lease if it hasn't expired yet — 0 quota resume across app
    /// crashes.
    @Published private(set) var activeLeaseID: String?
    /// Server-side lease expiry deadline. If Date() < leaseExpiresAt
    /// on restore, we can still steer that turn.
    @Published private(set) var leaseExpiresAt: Date?

    /// True while `heyClickyFreePreamble` is actively running. The
    /// credentials-refreshed observer checks this to avoid firing a
    /// rekey that would race with, and destroy, the lease we're in
    /// the middle of acquiring.
    @Published internal var preambleInProgress: Bool = false

    internal func setActiveLease(id: String?, expiresAt: Date?) {
        activeLeaseID = id
        leaseExpiresAt = expiresAt
    }
    /// Setter accessible to extension files (`+HeyClicky`) so they can
    /// null the thread after teardown without breaking encapsulation.
    func setActiveThreadID(_ id: String?) { activeThreadID = id }

    /// Consolidated lifecycle log. Every meaningful state transition
    /// (lease acquired, turn started, turn steered, turn completed,
    /// lease released, memory restored) goes through this so `grep -E
    /// codex.lifecycle` gives a linear timeline of what happened, why,
    /// and how much quota it cost. Callers should keep the `action`
    /// tag short and the `reason` line human-readable.
    internal func logLifecycle(
        action: String,
        reason: String,
        extra: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "action": action,
            "reason": reason,
            "lease_prefix": String((activeLeaseID ?? currentHeyClickyLease?.leaseID ?? "-").prefix(8)),
            "thread_prefix": String((activeThreadID ?? "-").prefix(8)),
            "turn_prefix": String((activeTurnID ?? "-").prefix(8)),
            "session_id_prefix": String(id.uuidString.prefix(8))
        ]
        for (k, v) in extra { payload[k] = v }
        HeyClickyLog.log("codex.lifecycle", lane: "agent",
                         direction: "internal", payload)
    }

    /// When the current thread has to be torn down (credentials refresh
    /// / codex crash / turn-limit / quota reset), stash the prior
    /// thread_id here so the next `heyClickyFreePreamble.launchThread`
    /// can pass it back to the proxy for **thread resumption**. This is
    /// what keeps the conversation continuous across an account reset:
    /// the proxy re-hydrates message history from the old thread_id
    /// onto the new account. Cleared once a fresh thread starts.
    var pendingThreadResumeID: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var latestResponseCard: ClickyResponseCard?
    @Published private(set) var stopReason: String?
    @Published private(set) var title: String
    @Published private(set) var progressStage: CodexAgentProgressStage = .idle
    @Published private(set) var activityStatusLines: [String] = []
    @Published private(set) var queuedFollowUpPrompts: [String] = []
    @Published private(set) var wasRestoredAfterRelaunch = false
    @Published var model: String = OpenClickyModelCatalog.codexActionsModel(
        withID: UserDefaults.standard.string(forKey: "clickyCodexModel") ?? OpenClickyModelCatalog.defaultCodexActionsModelID
    ).id
    /// Optional specialist-agent system context (soul/instructions/memory)
    /// prepended to the developer instructions when this session is launched
    /// under a specialist agent. Empty for default sessions.
    @Published var prependedSystemContext: String = ""
    /// Slug of the specialist agent powering this session, if any.
    @Published var specialistAgentSlug: String? = nil
    @Published var workingDirectoryPath: String = UserDefaults.standard.string(forKey: "clickyCodexWorkingDirectory")
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    /// F26 HIGH #1 substrate — set by `RouteDispatcher.spawnCodex` via
    /// `CompanionManager.startVoiceAgentTask` when the Fable classifier
    /// reports `progress_driven=true`. The F28 auto-continue observer
    /// (Task #203, separate landing) will poll `<workdir>/progress.md`
    /// and re-fire this session's turn until `completionMarker` appears.
    /// F26 only propagates the fields; no observer is wired here.
    @Published var progressDriven: Bool = false
    /// Completion marker string the agent is instructed to write into
    /// its progress file. When `progressDriven=true` and the parser did
    /// not supply an explicit marker, callers substitute the
    /// `AGENTS-longrun-template.md` default ("LAST_COMPLETED: DONE").
    @Published var completionMarker: String? = nil
    /// Optional project reference and slug carried on the [ROUTE] tag
    /// so downstream tooling (progress observer, dock title, archival
    /// notes) can attribute the session without re-parsing the prompt.
    @Published var routeProjectRef: String? = nil
    @Published var routeSlug: String? = nil
    /// Openclicky task-planning contract substrate. When set, the child
    /// codex process receives them as `OPENCLICKY_TASK_DIR` and
    /// `OPENCLICKY_TASK_PROGRESS` env vars; AGENTS-longrun-template.md
    /// tells codex to glob the directory and drive PROGRESS.md to
    /// `LAST_COMPLETED: DONE`. Set by RouteDispatcher via
    /// CompanionManager.dispatchRoutedAgentTask.
    @Published var taskDir: String? = nil
    @Published var taskProgressPath: String? = nil
    /// Browser-origin tasks carry only an origin and user goal, but retain a
    /// restricted execution policy as defense in depth if future context is
    /// added to that handoff.
    var usesRestrictedExecutionPolicy = false
    var onOpenableFileFound: (@MainActor (URL) -> Void)?

    private var executionApprovalPolicy: String {
        usesRestrictedExecutionPolicy ? "on-request" : "never"
    }

    private var executionSandboxMode: String {
        usesRestrictedExecutionPolicy ? "workspace-write" : "danger-full-access"
    }

    func configureRestrictedExecutionPolicy() {
        usesRestrictedExecutionPolicy = true
        let sandboxRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("OpenClicky/AgentMode/BrowserSandbox", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        workingDirectoryPath = sandboxRoot.path
    }

    var spokenAgentName: String {
        "the agent"
    }

    var spokenAgentSentenceName: String {
        "The agent"
    }

    private var spokenTaskTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != "Agent" else {
            return "the agent task"
        }
        return trimmedTitle
    }

    var statusSummaryLine: String {
        let taskTitle = spokenTaskTitle
        let latestActivity = latestActivitySummary

        if canResumeAfterRelaunch {
            return "\(taskTitle) needs resuming after relaunch."
        }

        switch status {
        case .stopped:
            guard hasVisibleActivity else {
                return "No agent task has been started yet."
            }
            return "\(taskTitle) is stopped."
        case .starting:
            return "\(taskTitle) is starting."
        case .running:
            if let latestActivity {
                return "\(taskTitle) is running. Latest: \(latestActivity)"
            }
            return "\(taskTitle) is running."
        case .ready:
            if let latestActivity {
                return "\(taskTitle) is done. Latest: \(latestActivity)"
            }
            return "\(taskTitle) is ready."
        case .failed:
            let errorText = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let errorText, !errorText.isEmpty {
                return "\(taskTitle) stopped: \(Self.spokenSnippet(from: errorText, maxLength: 110))"
            }
            return "\(taskTitle) stopped."
        }
    }

    var latestActivitySummary: String? {
        if isTurnActiveForChatQueue, let statusActivity = latestActivityStatusLine {
            return Self.spokenSnippet(from: statusActivity, maxLength: 120)
        }
        if let transcriptActivity = Self.latestActivitySummary(from: entries) {
            return transcriptActivity
        }
        return latestActivityStatusLine.map { Self.spokenSnippet(from: $0, maxLength: 120) }
    }

    var latestActivityDisplaySummary: String? {
        if isTurnActiveForChatQueue, let statusActivity = latestActivityStatusLine {
            return Self.displaySnippet(from: statusActivity, maxLength: 1_200)
        }
        if let transcriptActivity = Self.latestActivityDisplaySummary(from: entries) {
            return transcriptActivity
        }
        return latestActivityStatusLine.map { Self.displaySnippet(from: $0, maxLength: 1_200) }
    }

    private var latestActivityStatusLine: String? {
        activityStatusLines.reversed().first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var latestActivityDate: Date {
        entries.last?.createdAt ?? createdAt
    }

    var hasVisibleActivity: Bool {
        !entries.isEmpty || activeThreadID != nil || status != .stopped
    }

    var hasFinishedAgentResponse: Bool {
        entries.contains { entry in
            entry.role == .assistant
                && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isFinishedForArchive: Bool {
        if canResumeAfterRelaunch {
            return false
        }

        if progressStage == .completed {
            return true
        }

        guard status == .ready, !isTurnActiveForChatQueue else {
            return false
        }

        return hasFinishedAgentResponse
    }

    var canResumeAfterRelaunch: Bool {
        guard wasRestoredAfterRelaunch,
              lastSubmittedPrompt != nil,
              !isTurnActiveForChatQueue else { return false }
        // Restored interrupted tasks, including HeyClicky Free tasks, get one
        // automatic resume attempt per app run. CompanionManager records the
        // session ID in `autoResumedRelaunchSessionIDs` before dispatch, so the
        // periodic checker cannot spend another turn on the same restoration.
        // The persisted `wasRelaunchResumeCandidate` flag still prevents
        // completed or intentionally stopped sessions from being restarted.
        return true
    }

    var isRelaunchResumeCandidate: Bool {
        switch status {
        case .starting, .running:
            return true
        case .failed:
            return lastSubmittedPrompt != nil
        case .ready:
            return progressStage != .completed && lastSubmittedPrompt != nil
        case .stopped:
            return false
        }
    }

    private let homeManager: CodexHomeManager
    private let processManager: CodexProcessManager
    /// Optional Claude Agent SDK bridge used for money-rule-compliant title
    /// generation (SDK first, direct REST fallback). Injected by
    /// `CompanionManager`; nil when the SDK bridge is unavailable.
    private let claudeAgentSDKAPI: ClaudeAgentSDKAPI?
    private var currentAssistantEntryID: String?
    private var pendingAssistantDeltas: [String: String] = [:]
    private var pendingAssistantDeltaFlushTask: Task<Void, Never>?
    /// Owns the preflight work (including file-lease waits) for the current
    /// prompt. It must be retained so Stop can make a pending start terminal.
    private var promptStartTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    /// Every stop or new prompt invalidates work that was suspended before it.
    /// A cancelled task alone is not enough because not every awaited API
    /// cooperates with cancellation immediately.
    private var runGeneration: UInt64 = 0
    private var hasInitializedProcess = false
    private var lastSubmittedPrompt: String?
    private var latestAssistantResponseForCompletedTurn: String?
    private var hasPersistedCompletedTurnMemory = false
    var lastSubmittedPromptText: String? {
        lastSubmittedPrompt
    }
    private var currentLeasePaths: [String] = []
    /// HeyClicky Free lease active for the current agent turn.
    /// nil when running under BYOK / non-HeyClicky provider.
    /// Accessed by `CodexAgentSession+HeyClicky.swift`.
    var currentHeyClickyLease: HeyClickyTurnLease?
    private static let codexRuntimeCompatibilityFallbackModel = "gpt-5.4-mini"
    private static let assistantDeltaFlushDelayNanoseconds: UInt64 = 180_000_000

    init(
        id: UUID = UUID(),
        title: String = "Agent",
        accentTheme: OpenClickyCore.ClickyAccentTheme = .blue,
        homeManager: CodexHomeManager? = nil,
        processManager: CodexProcessManager? = nil,
        claudeAgentSDKAPI: ClaudeAgentSDKAPI? = nil
    ) {
        self.id = id
        self.createdAt = Date()
        self.title = title
        self.accentTheme = accentTheme
        self.homeManager = homeManager ?? CodexHomeManager()
        self.processManager = processManager ?? CodexProcessManager()
        self.claudeAgentSDKAPI = claudeAgentSDKAPI

        self.processManager.onNotification = { [weak self] notification in
            Task { @MainActor in
                self?.handleNotification(notification)
            }
        }
        self.processManager.onStderrLine = { [weak self] line in
            Task { @MainActor in
                self?.handleStderrLine(line)
            }
        }
    }

    func warmUp() {
        warmUpTask?.cancel()
        let generation = runGeneration
        warmUpTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureThread(for: generation)
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentRun(generation) else { return }
                self.lastErrorMessage = error.localizedDescription
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func restoreArchivedState(entries archivedEntries: [CodexTranscriptEntry], activeThreadID archivedThreadID: String?, lastSubmittedPrompt archivedPrompt: String?) {
        stop(reason: "archived_session_recalled")
        entries = archivedEntries
        activeThreadID = archivedThreadID
        lastSubmittedPrompt = archivedPrompt
        latestResponseCard = nil
        queuedFollowUpPrompts.removeAll()
        activityStatusLines.removeAll()
        progressStage = hasFinishedAgentResponse ? .completed : .idle
        lastErrorMessage = nil
        stopReason = nil
        status = archivedEntries.isEmpty ? .stopped : .ready
    }

    func restoreInterruptedRelaunchState(entries restoredEntries: [CodexTranscriptEntry],
                                          activeThreadID restoredThreadID: String?,
                                          lastSubmittedPrompt restoredPrompt: String?,
                                          canResume: Bool = true,
                                          restoredActiveTurnID: String? = nil,
                                          restoredLeaseID: String? = nil,
                                          restoredLeaseExpiresAt: Date? = nil) {
        stop(reason: "restored_after_relaunch")
        entries = restoredEntries
        activeThreadID = restoredThreadID
        // NEVER restore activeTurnID across app restart. codex daemon
        // is a new process — its in-memory activeTasks is empty.
        // Sending turn/steer with a persisted turnId would be
        // rejected by the new daemon ("no active turn to steer") and
        // we'd fall back to turn/start (+1 quota wasted). Only the
        // thread_id is a server-side concept and safe to keep.
        // Note: leaseExpiresAt is kept for OBSERVABILITY only —
        // useful in log to understand whether the server-side lease
        // has expired, but never used as a steer decision input.
        activeTurnID = nil
        activeLeaseID = nil
        leaseExpiresAt = nil
        if restoredActiveTurnID != nil {
            HeyClickyLog.log("codex.lease_not_restored_after_restart",
                             lane: "agent", direction: "internal", [
                "reason": "codex_daemon_reset",
                "hadPersistedTurn": true,
                "persistedExpiresIn": Int(restoredLeaseExpiresAt?.timeIntervalSinceNow ?? 0)
            ])
        }
        // Stash the pre-restart thread_id so the next preamble sends
        // `clicky_agent_thread_resumed:true + thread_id` to the proxy
        // and the SAME server-side conversation is re-hydrated on the
        // new codex process. Without this, restarting mid-task creates
        // a brand-new backend thread and the assistant has no memory
        // of the prior exchange (user's report: "他的这种记忆有没有
        // 丢失呢？是不是在同一个设想里面呢？" — before this fix, yes,
        // memory was lost across restart).
        if let restoredThreadID, !restoredThreadID.isEmpty {
            pendingThreadResumeID = restoredThreadID
            HeyClickyLog.log("codex.thread_stashed_for_relaunch_resume",
                             lane: "agent", direction: "internal", [
                "thread_prefix": String(restoredThreadID.prefix(8))
            ])
        }
        lastSubmittedPrompt = restoredPrompt
        latestResponseCard = nil
        queuedFollowUpPrompts.removeAll()
        activityStatusLines = ["Restored after relaunch"]
        progressStage = (!canResume && hasFinishedAgentResponse) ? .completed : .idle
        lastErrorMessage = nil
        stopReason = "restored_after_relaunch"
        wasRestoredAfterRelaunch = canResume
        status = restoredEntries.isEmpty ? .stopped : .ready
    }

    func resumeInterruptedTaskAfterRelaunch() {
        guard let originalPrompt = lastSubmittedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !originalPrompt.isEmpty else { return }

        let recentContext = entries.suffix(8).map { entry in
            "\(entry.role.rawValue): \(Self.spokenSnippet(from: entry.text, maxLength: 900))"
        }.joined(separator: "\n\n")
        wasRestoredAfterRelaunch = false
        // Preserve the thread_id across app relaunch — the next preamble
        // will pass it via `is_follow_up: true` so proxy re-hydrates the
        // prior conversation history. Without this stash, restored
        // sessions lose their cross-app-restart memory.
        if let existing = activeThreadID, !existing.isEmpty {
            pendingThreadResumeID = existing
        }
        activeThreadID = nil
        activeTurnID = nil
        submitPromptFromUI("""
        Resume this OpenClicky Agent Mode task after an app relaunch.

        Original user request:
        \(originalPrompt)

        Recent visible transcript before relaunch:
        \(recentContext.isEmpty ? "No transcript was captured before relaunch." : recentContext)

        Continue from the last unfinished step. Re-check files and current state before editing, preserve unrelated work, and finish the task if it is still needed.
        """)
    }

    func submitPromptFromUI(_ prompt: String, screenContext: CodexAgentScreenContext? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // SKI shim sessions have no codex daemon — text is delivered
        // to the external CLI agent through the file bridge instead.
        if skiBridge != nil {
            submitPromptViaSKIBridge(trimmed)
            return
        }

        // Three-way dispatch (IDA HeyClicky-1.0.42 sub_1007B4688 launchTask):
        //   [1] steerTask  — active turn exists → turn/steer (0 quota)
        //   [2] resumeThread — thread known but no active turn → thread/resume + turn/start
        //   [3] submitTask — brand-new thread → thread/start + turn/start
        //
        // Only [1] is free. Route the follow-up through turn/steer when
        // codex has an active turn we can inject into. This maximizes
        // per-quota output and prevents wasting a whole new turn on a
        // trivial follow-up.
        if isTurnActiveForChatQueue,
           let turnID = activeTurnID, !turnID.isEmpty,
           let threadID = activeThreadID, !threadID.isEmpty,
           model.hasPrefix("heyclicky-free-") {
            steerActiveTurn(with: trimmed, turnID: turnID, threadID: threadID)
            return
        }

        if isTurnActiveForChatQueue {
            queueFollowUp(trimmed)
            return
        }

        startPromptTurn(trimmed, screenContext: screenContext)
    }

    /// Set the thread's long-running OBJECTIVE. codex daemon injects
    /// this into every subsequent model call so the model stays on
    /// task across many turns (stronger than prompt-level "章程").
    /// IDA HeyClicky-1.0.42 does NOT use this method — it's a codex
    /// daemon feature that HeyClicky hasn't adopted yet, giving us a
    /// drift-prevention edge.
    /// - Parameters:
    ///   - objective: the durable goal text (e.g. "Build todo-cli
    ///     with 30 files per TASK.md; do not scope-creep").
    ///   - tokenBudget: optional hard budget per turn. codex will
    ///     compact/stop when a turn approaches this. Nil = server
    ///     default.
    func setThreadGoal(objective: String, tokenBudget: Int? = nil) async {
        guard let threadID = activeThreadID, !threadID.isEmpty,
              hasInitializedProcess else { return }
        var params: [String: Any] = [
            "threadId": threadID,
            "objective": objective,
            "status": "active"
        ]
        if let tb = tokenBudget { params["tokenBudget"] = tb }
        do {
            _ = try await processManager.sendRequest(method: "thread/goal/set", params: params)
            HeyClickyLog.log("codex.thread_goal_set", lane: "agent",
                             direction: "outgoing", [
                "thread_prefix": String(threadID.prefix(8)),
                "obj_len": objective.count,
                "tokenBudget": tokenBudget ?? -1
            ])
        } catch {
            HeyClickyLog.log("codex.thread_goal_set_failed", lane: "agent",
                             direction: "error",
                             ["error": String("\(error)".prefix(200))])
        }
    }

    func clearThreadGoal() async {
        guard let threadID = activeThreadID, !threadID.isEmpty,
              hasInitializedProcess else { return }
        do {
            _ = try await processManager.sendRequest(method: "thread/goal/clear", params: [
                "threadId": threadID
            ])
            HeyClickyLog.log("codex.thread_goal_cleared", lane: "agent",
                             direction: "outgoing",
                             ["thread_prefix": String(threadID.prefix(8))])
        } catch {
            HeyClickyLog.log("codex.thread_goal_clear_failed", lane: "agent",
                             direction: "error",
                             ["error": String("\(error)".prefix(200))])
        }
    }

    /// Push context messages into thread history WITHOUT starting a
    /// turn. Zero quota cost. Used for recovery scenarios: instead of
    /// firing a "请继续之前的任务" replay (which turn/start = +1 quota),
    /// inject the prior conversation as system context so the next
    /// legitimate turn already has full context.
    /// IDA HeyClicky-1.0.42 method: `thread/inject_items`.
    /// Items are raw Responses API items — typical shape:
    ///   {"type":"message","role":"user"|"assistant"|"system","content":[{"type":"input_text","text":"..."}]}
    func injectContextItems(_ items: [[String: Any]], reason: String) async {
        guard model.hasPrefix("heyclicky-free-"),
              let threadID = activeThreadID, !threadID.isEmpty,
              hasInitializedProcess,
              !items.isEmpty else {
            HeyClickyLog.log("codex.inject_items_skipped", lane: "agent",
                             direction: "internal",
                             ["reason": reason,
                              "hasThread": activeThreadID?.isEmpty == false,
                              "hasProcess": hasInitializedProcess])
            return
        }
        HeyClickyLog.log("codex.inject_items_dispatch", lane: "agent",
                         direction: "outgoing", [
            "thread_prefix": String(threadID.prefix(8)),
            "items_count": items.count,
            "reason": reason
        ])
        do {
            _ = try await processManager.sendRequest(method: "thread/inject_items", params: [
                "threadId": threadID,
                "items": items
            ])
            HeyClickyLog.log("codex.inject_items_ok", lane: "agent",
                             direction: "incoming",
                             ["thread_prefix": String(threadID.prefix(8))])
        } catch {
            HeyClickyLog.log("codex.inject_items_failed", lane: "agent",
                             direction: "error",
                             ["error": String("\(error)".prefix(200))])
        }
    }

    /// Send a lightweight nudge into an active turn via `turn/steer`
    /// (0-quota, same-lease continuation). Used by the watchdog when
    /// a turn appears stuck to poke the model without killing codex.
    /// No-op if no active turn/thread. Returns `true` if a nudge was
    /// dispatched.
    @discardableResult
    func nudgeActiveTurn(reason: String) -> Bool {
        guard let turnID = activeTurnID, !turnID.isEmpty,
              let threadID = activeThreadID, !threadID.isEmpty else {
            return false
        }
        let nudge = "[runtime nudge — \(reason)] You appear to be idle. Read PROGRESS.md and continue the next unchecked item. Chain tool calls. Do NOT summarize; do NOT ask questions; do NOT stop."
        HeyClickyLog.log("codex.turn_nudge_dispatch", lane: "agent",
                         direction: "outgoing", [
            "reason": reason,
            "turn_prefix": String(turnID.prefix(8)),
            "thread_prefix": String(threadID.prefix(8))
        ])
        steerActiveTurn(with: nudge, turnID: turnID, threadID: threadID)
        return true
    }

    private func steerActiveTurn(with prompt: String, turnID: String, threadID: String) {
        logLifecycle(
            action: "TURN_STEER_DISPATCHED",
            reason: "reuse active turn (0 quota) instead of new turn",
            extra: ["prompt_len": prompt.count]
        )
        HeyClickyLog.log("codex.turn_steer_dispatch", lane: "agent",
                         direction: "outgoing", [
            "thread_prefix": String(threadID.prefix(8)),
            "turn_prefix": String(turnID.prefix(8)),
            "prompt_len": prompt.count
        ])
        // Add to local transcript so UI mirrors what the model sees.
        entries.append(CodexTranscriptEntry(role: .user, text: prompt))
        lastSubmittedPrompt = prompt

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.processManager.sendRequest(method: "turn/steer", params: [
                    "threadId": threadID,
                    "expectedTurnId": turnID,
                    "input": [
                        ["type": "text", "text": prompt]
                    ]
                ])
                HeyClickyLog.log("codex.turn_steer_ok", lane: "agent",
                                 direction: "incoming", [
                    "turn_prefix": String(turnID.prefix(8))
                ])
            } catch {
                // Steer failed (turn ended between check + call, or codex
                // rejected). Fall back to a fresh turn — expected during
                // races. Kick startPromptTurn so the user's input isn't
                // lost.
                let msg = "\(error)"
                HeyClickyLog.log("codex.turn_steer_failed_fallback",
                                 lane: "agent", direction: "error",
                                 ["error": String(msg.prefix(200))])
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.activeTurnID = nil
                    self.startPromptTurn(prompt, screenContext: nil)
                }
            }
        }
    }

    var isTurnActiveForChatQueue: Bool {
        switch status {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return false
        }
    }

    func removeQueuedFollowUp(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where queuedFollowUpPrompts.indices.contains(index) {
            queuedFollowUpPrompts.remove(at: index)
        }
    }

    func removeQueuedFollowUp(_ prompt: String) {
        guard let index = queuedFollowUpPrompts.firstIndex(of: prompt) else { return }
        queuedFollowUpPrompts.remove(at: index)
    }

    private func queueFollowUp(_ prompt: String) {
        queuedFollowUpPrompts.append(prompt)
        appendActivityStatusLine("Queued follow-up: \(Self.spokenSnippet(from: prompt, maxLength: 90))")
    }

    private func startPromptTurn(_ prompt: String, screenContext: CodexAgentScreenContext? = nil) {
        // A prompt can spend minutes waiting for a file lease. Invalidate any
        // prior preflight before adding this turn so an older task cannot wake
        // up later and start a stale Codex turn.
        runGeneration &+= 1
        let generation = runGeneration
        promptStartTask?.cancel()
        promptStartTask = nil
        warmUpTask?.cancel()
        warmUpTask = nil

        if entries.isEmpty {
            let fallbackTitle = Self.shortTitle(from: prompt)
            title = fallbackTitle
            if !Self.shouldKeepInitialTaskTitle(fallbackTitle) {
                Task { [weak self] in
                    guard let generatedTitle = await self?.fastFriendlyTitle(from: prompt, fallbackTitle: fallbackTitle) else { return }
                    guard let self else { return }
                    if self.entries.first?.text == prompt, self.title == fallbackTitle {
                        self.title = generatedTitle
                    }
                }
            }
        }

        lastSubmittedPrompt = prompt
        latestAssistantResponseForCompletedTurn = nil
        hasPersistedCompletedTurnMemory = false
        entries.append(CodexTranscriptEntry(role: .user, text: prompt))
        OpenClickyMessageLogStore.shared.appendConversationTurn(
            lane: "agent",
            direction: "incoming",
            role: "user",
            text: prompt,
            source: "codex_agent_session",
            sessionID: id.uuidString,
            title: title,
            extraFields: [
                "model": model,
                "workingDirectory": workingDirectoryPath,
                "screenContextAttached": screenContext != nil
            ]
        )
        appendActivityStatusLine("Queued request: \(Self.spokenSnippet(from: prompt, maxLength: 90))")
        status = .starting
        progressStage = .starting
        let sessionID = id
        promptStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                let coordinationNote = try await self.buildAgentCoordinationNote(for: prompt)
                try self.requireCurrentRun(generation)
                let modelPrompt = self.promptForModel(
                    prompt: prompt,
                    screenContext: screenContext,
                    coordinationNote: coordinationNote
                )
                await self.runPrompt(modelPrompt, generation: generation)
            } catch is CancellationError {
                await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: sessionID)
            } catch {
                guard self.isCurrentRun(generation) else { return }
                let text = Self.userFacingErrorMessage(from: error.localizedDescription)
                self.lastErrorMessage = text
                self.status = .failed(text)
                self.progressStage = .failed
                self.entries.append(CodexTranscriptEntry(role: .system, text: text))
                await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: sessionID)
            }
        }
    }

    func dismissLatestResponseCard() {
        latestResponseCard = nil
    }

    func setModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.codexActionsModel(withID: model).id
        guard self.model != resolvedModel else { return }
        applyModel(resolvedModel)

        if processManager.isRunning || promptStartTask != nil || warmUpTask != nil {
            stop(reason: "model_changed")
        }
    }

    func setWorkerBaseURL(_ url: URL) {
        homeManager.workerBaseURL = url
    }

    @discardableResult
    func syncProviderConfigurationFromCurrentSettings() throws -> URL {
        // HeyClicky Free lane MUST route codex at the heyclicky proxy
        // (`.../agent/openai/v1`) with custom provider + apikey auth.
        // If we let it fall back to the default OpenAI base URL, codex
        // reads `~/.codex/auth.json` (ChatGPT tokens) and rejects
        // heyclicky-free with "not supported when using Codex
        // with a ChatGPT account". clicky-mac
        // AgentSessionsBridge.swift:810-828 encodes the same rule.
        if model.hasPrefix("heyclicky-free-"),
           let proxyBase = try? AppBundleConfiguration.heyClickyProxyBaseURL() {
            // Config template's openAICompatibleEndpoint appends "/v1",
            // so we hand it the proxy root + "agent/openai" and end up
            // with "<proxy>/agent/openai/v1" — the path the heyclicky
            // proxy actually exposes to codex (clicky-mac config uses
            // the exact same route).
            let codexBase = proxyBase.appendingPathComponent("agent/openai", isDirectory: false)
            homeManager.workerBaseURL = codexBase
            HeyClickyLog.log("codex.config_worker_base_url", lane: "agent",
                             direction: "internal", [
                "stage": "S2_agent_process_launch",
                "base_url": codexBase.absoluteString,
                "reason": "heyclicky_lane_forces_proxy"
            ])
        } else {
            homeManager.workerBaseURL = ClickyCodexBackend.configuredWorkerBaseURL()
        }
        homeManager.model = model
        homeManager.reasoningEffort = UserDefaults.standard.string(forKey: "clickyCodexReasoningEffort") ?? homeManager.reasoningEffort
        return try homeManager.writeCodexConfigFromSettings()
    }

    /// Insert a transcript row that originated from the remote
    /// `/agent-messages` inbox (agent → client push). Skips duplicates
    /// via the message id and preserves creation order. Called by
    /// CompanionManager+HeyClicky after the long-poll returns.
    func appendRemoteTranscriptEntry(role: CodexTranscriptEntry.Role, text: String, id: String) {
        guard !text.isEmpty else {
            HeyClickyLog.log("transcript.remote_skipped", lane: "agent", direction: "internal", [
                "stage": "S4_message_ingress", "reason": "empty_text", "id": id
            ])
            return
        }
        if entries.contains(where: { $0.id == id }) {
            HeyClickyLog.log("transcript.remote_dup", lane: "agent", direction: "internal", [
                "stage": "S4_message_ingress", "id": id
            ])
            return
        }
        entries.append(CodexTranscriptEntry(
            id: id,
            role: role,
            text: text,
            createdAt: Date()
        ))
        HeyClickyLog.log("transcript.remote_appended", lane: "agent", direction: "internal", [
            "stage": "S4_message_ingress",
            "id": id,
            "role": "\(role)",
            "total_entries": entries.count
        ])
    }

    func stop(reason: String? = nil) {
        // Clean turn end via turn/interrupt RPC before killing the
        // daemon. Server-side lease is torn down cooperatively — the
        // server marks the turn done, removes it from activeTasks,
        // and (empirically) is friendlier about not double-billing on
        // subsequent replay. Best-effort with a short timeout; if the
        // RPC hangs (daemon dead / socket gone), fall through to
        // process.stop() as before.
        // IDA HeyClicky-1.0.42: RPC method is `turn/interrupt`,
        // params `{threadId, turnId}`.
        if let turnID = activeTurnID, let threadID = activeThreadID,
           !turnID.isEmpty, !threadID.isEmpty,
           hasInitializedProcess {
            let capturedTurn = turnID
            let capturedThread = threadID
            let mgr = processManager
            HeyClickyLog.log("codex.turn_interrupt_dispatch", lane: "agent",
                             direction: "outgoing", [
                "turn_prefix": String(capturedTurn.prefix(8)),
                "reason": reason ?? "-"
            ])
            // Fire-and-forget with 2s cap so the stop() path stays
            // responsive to UI.
            Task.detached {
                let interruptTask = Task {
                    _ = try? await mgr.sendRequest(method: "turn/interrupt", params: [
                        "threadId": capturedThread,
                        "turnId": capturedTurn
                    ])
                }
                let timeout = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    interruptTask.cancel()
                }
                _ = await interruptTask.value
                timeout.cancel()
            }
        }
        heyClickyFreeTeardown(reason: reason)
        runGeneration &+= 1
        promptStartTask?.cancel()
        promptStartTask = nil
        warmUpTask?.cancel()
        warmUpTask = nil
        queuedFollowUpPrompts.removeAll()
        pendingAssistantDeltaFlushTask?.cancel()
        pendingAssistantDeltaFlushTask = nil
        pendingAssistantDeltas.removeAll()
        stopReason = reason
        processManager.stop()
        hasInitializedProcess = false
        // Stash thread_id so a later replay can resume the same conversation.
        if let existing = activeThreadID, !existing.isEmpty {
            pendingThreadResumeID = existing
        }
        activeThreadID = nil
        activeTurnID = nil
        currentAssistantEntryID = nil
        currentLeasePaths = []
        status = .stopped
        progressStage = .idle
        Task { await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id) }
    }

    private func runPrompt(_ prompt: String, generation: UInt64, didRetryCompatibilityFallback: Bool = false) async {
        do {
            try requireCurrentRun(generation)
            try await ensureThread(for: generation)
            try requireCurrentRun(generation)
            guard let activeThreadID else {
                throw CodexRPCError(message: "Codex thread did not start.")
            }

            stopReason = nil
            status = .running
            progressStage = .starting
            lastErrorMessage = nil
            UserDefaults.standard.set(model, forKey: "clickyCodexModel")
            if !usesRestrictedExecutionPolicy {
                UserDefaults.standard.set(workingDirectoryPath, forKey: "clickyCodexWorkingDirectory")
            }

            try requireCurrentRun(generation)
            // HeyClicky Free lane: turn/start params MUST carry
            //   - `responsesapiClientMetadata` (4 clicky_agent_* fields)
            //   - a `<clicky_agent_turn_lease_metadata>` prompt tag
            //   - `sandboxPolicy: {type: "dangerFullAccess"}` object shape
            //   - the real codex model id (`gpt-5.6-sol`), NOT the UI label
            // Missing any of these = proxy HTTP 426 / codex_models_manager
            // "Unsupported agent proxy path" / no assistantMessage emitted.
            // IDA HeyClicky-1.0.40 literals at 0x1012a3730..0x1012a9340
            // and clicky-mac CodexRPC.turnStart (:120-138) both encode
            // exactly this shape.
            if model.hasPrefix("heyclicky-free-"),
               let lease = currentHeyClickyLease {
                let leaseID = lease.leaseID
                let turnID = lease.turnID
                let taskID = UUID().uuidString.uppercased()
                // Dispatch thread/goal/set right here — codex is
                // spawned + initialized, activeThreadID committed,
                // still BEFORE turn/start so the very first
                // /responses call carries the goal. Only on the
                // first turn of a new thread (not on follow-ups
                // that reuse the same threadId).
                if let objective = pendingThreadGoalObjective, !objective.isEmpty {
                    await setThreadGoal(objective: objective, tokenBudget: 200_000)
                    pendingThreadGoalObjective = nil
                }
                let metadataTag = "<clicky_agent_turn_lease_metadata>{\"clicky_agent_task_id\":\"\(taskID)\",\"clicky_agent_thread_id\":\"\(activeThreadID)\",\"clicky_agent_turn_id\":\"\(turnID)\",\"clicky_agent_turn_lease_id\":\"\(leaseID)\"}</clicky_agent_turn_lease_metadata>\n"
                HeyClickyLog.log("codex.turn_start_dispatch", lane: "agent",
                                 direction: "outgoing", [
                    "stage": "S2_agent_process_launch",
                    "model": ClickyCodexConfigTemplate.heyClickyRealCodexModel,
                    "lease_prefix": String(leaseID.prefix(8)),
                    "turn_prefix": String(turnID.prefix(8)),
                    "task_prefix": String(taskID.prefix(8)),
                    "prompt_len": prompt.count
                ])
                _ = try await processManager.sendRequest(method: "turn/start", params: [
                    "threadId": activeThreadID,
                    "sandboxPolicy": ["type": "dangerFullAccess"],
                    "approvalPolicy": "never",
                    "model": ClickyCodexConfigTemplate.heyClickyRealCodexModel,
                    // `gpt-5.6-sol` is defined by codex with
                    // `use_responses_lite = true`. The Responses-Lite
                    // path REQUIRES `reasoning.context = "all_turns"` on
                    // every turn — omitting it makes the proxy return
                    //   X-OpenAI-Internal-Codex-Responses-Lite requires
                    //   `reasoning.context` to be `all_turns`.
                    // Value + effort fields are string literals baked
                    // into the codex Rust source (found in the codex
                    // binary at `all_turns`/`current_turn`).
                    "reasoning": [
                        "context": "all_turns",
                        "effort": homeManager.reasoningEffort
                    ],
                    "responsesapiClientMetadata": [
                        "clicky_agent_thread_id": activeThreadID,
                        "clicky_agent_turn_id": turnID,
                        "clicky_agent_task_id": taskID,
                        "clicky_agent_turn_lease_id": leaseID
                    ],
                    "input": [[
                        "type": "text",
                        "text": metadataTag + prompt
                    ]]
                ])
            } else {
                _ = try await processManager.sendRequest(method: "turn/start", params: [
                    "threadId": activeThreadID,
                    "input": [[
                        "type": "text",
                        "text": prompt,
                        "text_elements": []
                    ]],
                    "cwd": workingDirectoryPath,
                    "approvalPolicy": executionApprovalPolicy,
                    "sandbox": executionSandboxMode,
                    "model": model,
                    "effort": homeManager.reasoningEffort,
                    "config": [
                        "approval_policy": executionApprovalPolicy,
                        "sandbox_mode": executionSandboxMode
                    ]
                ])
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRun(generation) else { return }
            let text = Self.userFacingErrorMessage(from: error.localizedDescription)
            if text == "Codex app-server stopped.",
               lastErrorMessage?.contains("terminal xcodebuild") == true {
                return
            }

            if !didRetryCompatibilityFallback,
               Self.shouldRetryWithCompatibilityFallback(text),
               model != Self.codexRuntimeCompatibilityFallbackModel {
                let requestedModel = model
                entries.append(CodexTranscriptEntry(
                    role: .system,
                    text: "Codex rejected \(requestedModel) with this runtime, so OpenClicky is retrying with \(Self.codexRuntimeCompatibilityFallbackModel)."
                ))
                applyModel(Self.codexRuntimeCompatibilityFallbackModel)
                restartProcessForCompatibilityFallback()
                await runPrompt(prompt, generation: generation, didRetryCompatibilityFallback: true)
                return
            }

            lastErrorMessage = text
            status = .failed(text)
            progressStage = .failed
            entries.append(CodexTranscriptEntry(role: .system, text: text))
        }
    }

    private func applyModel(_ resolvedModel: String) {
        model = resolvedModel
        homeManager.model = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "clickyCodexModel")
    }

    private func restartProcessForCompatibilityFallback() {
        processManager.stop()
        hasInitializedProcess = false
        // Preserve thread_id so next preamble can resume conversation.
        if let existing = activeThreadID, !existing.isEmpty {
            pendingThreadResumeID = existing
        }
        activeThreadID = nil
        activeTurnID = nil
    }

    private func isCurrentRun(_ generation: UInt64) -> Bool {
        runGeneration == generation && !Task.isCancelled
    }

    private func requireCurrentRun(_ generation: UInt64) throws {
        guard isCurrentRun(generation) else {
            throw CancellationError()
        }
    }

    private func promptForModel(prompt: String, screenContext: CodexAgentScreenContext?, coordinationNote: String?) -> String {
        let coordinationSection: String
        if let coordinationNote, !coordinationNote.isEmpty {
            coordinationSection = "\n\(coordinationNote)\n"
        } else {
            coordinationSection = ""
        }

        let taskBrief = """
        OpenClicky Agent Mode brief:
        - User request: \(prompt)
        - Work as an independent background agent. Each OpenClicky agent session has its own Codex runtime, thread, and process; do not assume another agent has your local state.
        \(coordinationSection)
        - Runtime map file: \(homeManager.runtimeMapFile.path)
        - Codex home directory: \(homeManager.codexHomeDirectory.path)
        - Codex config file: \(homeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false).path)
        - Soul/persona file: \(homeManager.soulFile.path) (for explicit persona/storage tasks only; routine persona context is already in AGENTS.md)
        - Persistent memory file: \(homeManager.persistentMemoryFile.path)
        - Memory articles directory: \(homeManager.memoriesDirectory.path)
        - Bundled skills directory: \(homeManager.codexHomeDirectory.appendingPathComponent(homeManager.bundledSkillsDirectoryName, isDirectory: true).path)
        - Learned skills directory: \(homeManager.learnedSkillsDirectory.path)
        - Archives directory: \(homeManager.archivesDirectory.path)
        - Logs directory: \(OpenClickyMessageLogStore.shared.logDirectory.path)
        - Current message log file: \(OpenClickyMessageLogStore.shared.currentLogFile.path)
        - Log review JSONL file: \(OpenClickyMessageLogStore.shared.reviewCommentsFile.path)
        - Log review comments file: \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path)
        - Widget snapshot file: \(OpenClickyWidgetStateStore.snapshotURL.path)
        - Before working, read the runtime map and persistent memory file if they exist.
        - Treat the OpenClicky persona already inlined in AGENTS.md as OpenClicky's operating identity. Do not open SOUL.md at task start unless the user explicitly asks to view or edit persona/storage files.
        - If the user asks where OpenClicky stores logs, memory, skills, widgets, config, sessions, or review comments, answer from the runtime map and include exact paths.
        - If the user asks to view or edit OpenClicky's logs, memory, learned skills, runtime map, widget state, or review comments, use the local filesystem paths above directly instead of claiming you cannot access them.
        - If the user asks to look at skills and optimize them, inspect bundled and learned skills, archive previous versions under \(homeManager.archivesDirectory.path), then update or create the improved skill files needed.
        - If the user asks to look at logs and learn from them, inspect message logs and review comments, extract actionable learnings, create or update memory and learned skills, and archive superseded artifacts under \(homeManager.archivesDirectory.path). Do not delete old versions.
        - If the user asks you to fix OpenClicky behavior, tune prompts, or review flagged logs, read the log review comments file and address those comments as concrete issues.
        - If the user asks about widgets or desktop task/status display, read the widget snapshot file to understand the current widget state.
        - Do not say you cannot remember outside the current conversation. Use the persistent memory file.
        - Update persistent memory only for stable preferences, useful project facts, task outcomes, or workflow context that will clearly help future sessions.
        - Use or update learned skills only when the user asks to inspect, optimize, or learn from skills/logs, or when a repeated workflow would materially speed up future work. Create curated skills directly with specific names; do not create request-shaped `workflow_*` skills. Do not mention skill creation in progress or final answers unless the user asked about skills.
        - When working on the OpenClicky app repo, do not run terminal `xcodebuild`. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks.
        - Proceed autonomously. Choose sensible defaults and keep working without asking the user unless critical information is truly missing or the action would be destructive, credential-related, or permission-sensitive.
        - Voice is the primary interaction path. Keep user-facing progress and final answers concise enough to be spoken aloud, and put detailed logs or code context in the transcript when needed.
        - Final user-facing answers should sound like a capable coworker over the user's shoulder: one or two plain sentences, no bullets, no markdown, no headings, and no code blocks unless the user explicitly asks for them.
        - When you discover a local document, image, or other user file as the object of the user's request, include its exact local path in your final answer so OpenClicky can show it.
        - Do not restate paths for OpenClicky-provided screen-context images or dropped task attachments in the final answer unless the user specifically asks for the file location; those images are evidence to assist the task, not search results.
        - If blocked, report the exact blocker and the smallest user action needed. If not blocked, finish the task and summarize what changed or what you found.
        - After the final user-facing answer, include a `<NEXT_ACTIONS>` block with one or two overlay button suggestions. Each suggestion must be a `- ` bullet, under about 40 characters, self-contained, and executable without more user input. Prefer concrete follow-ups like "Review the Swift diff" or "Test the cursor label". Omit weak suggestions instead of padding.
        - The `<NEXT_ACTIONS>` block is machine-readable metadata. Do not mention it in prose, and do not put anything after the closing `</NEXT_ACTIONS>` tag except the `TASK_TITLE:` metadata line below.
        - At the end of your final response, include one metadata line exactly like `TASK_TITLE: Short task title` using 2-5 words. Make it a compact noun-based action label with filler removed, such as `Voice Response Naturalization` or `Task Subject Cleanup`. OpenClicky strips this line and uses it to rename the agent task.
        """

        guard let context = screenContext, !context.isEmpty else {
            return taskBrief
        }

        return """
        \(context.promptPrefix())

        \(taskBrief)
        """
    }

    private func ensureThread(for generation: UInt64) async throws {
        try requireCurrentRun(generation)
        // Reuse everything if the codex child is still running with a
        // known thread. This is the "same-lease multi-turn" fast path
        // — no preamble, no record-agent-launch, no new credit. The
        // caller (runPrompt) will still emit a turn/start RPC over
        // the existing lease, which is 0 quota.
        if processManager.isRunning, activeThreadID != nil {
            if currentHeyClickyLease != nil {
                logLifecycle(
                    action: "LEASE_REUSED_NO_NEW_CREDIT",
                    reason: "codex alive + thread known + lease alive → next turn is 0 quota",
                    extra: [:]
                )
            } else {
                // Rare: thread known but lease already released. Turn/start
                // will still work but this is worth flagging.
                logLifecycle(
                    action: "THREAD_ALIVE_BUT_LEASE_GONE",
                    reason: "possible bug — thread survived but lease released; will 428 on turn/start",
                    extra: [:]
                )
            }
            return
        }

        status = .starting

        // HeyClicky Free preamble (spec §5.4). Fires only when the selected
        // Codex agent model is a heyclicky-free-* entry. This is the SLOW
        // path — it acquires a fresh lease (+1 credit). We only get here
        // when the codex child died or the thread was torn down.
        let didRunHeyClickyPreamble: Bool
        if model.hasPrefix("heyclicky-free-") {
            logLifecycle(
                action: "PREAMBLE_STARTED_NEW_LEASE_INCOMING",
                reason: "no reusable lease/thread — will spend +1 credit",
                extra: [
                    "had_process": processManager.isRunning,
                    "had_thread": activeThreadID != nil,
                    "had_lease": currentHeyClickyLease != nil,
                    "has_resume_id": pendingThreadResumeID != nil
                ]
            )
            try await heyClickyFreePreamble(generation: generation)
            try requireCurrentRun(generation)
            didRunHeyClickyPreamble = true
        } else {
            didRunHeyClickyPreamble = false
        }
        // Rollback marker: cleared on the success path just before the
        // final `return` of ensureThread. If we exit with this still set,
        // the downstream spawn didn't complete and the lease must be
        // failed out.
        var heyClickyPreambleNeedsRollback = didRunHeyClickyPreamble
        defer {
            if heyClickyPreambleNeedsRollback {
                heyClickyFreeTeardown(reason: "ensure_thread_failed")
            }
        }
        let processManager = self.processManager
        let applicationSupportDirectory = homeManager.applicationSupportDirectory
        let workerBaseURL = homeManager.workerBaseURL
        let model = homeManager.model
        let reasoningEffort = homeManager.reasoningEffort
        let modelProviderID = homeManager.modelProviderID

        let preparedLayout = try await MainActor.run {
            let hm = CodexHomeManager(
                applicationSupportDirectory: applicationSupportDirectory,
                workerBaseURL: workerBaseURL,
                model: model,
                reasoningEffort: reasoningEffort
            )
            return try hm.prepare(bundle: .main)
        }
        try requireCurrentRun(generation)

        let executable = try CodexRuntimeLocator.codexExecutableURL(bundle: .main)
        let spawnTaskDir = self.taskDir
        let spawnTaskProgressPath = self.taskProgressPath
        try await Task.detached(priority: .userInitiated) {
            try processManager.start(
                executableURL: executable,
                codexHome: preparedLayout.homeDirectory,
                taskDir: spawnTaskDir,
                taskProgressPath: spawnTaskProgressPath
            )
        }.value
        try requireCurrentRun(generation)

        if !hasInitializedProcess {
            _ = try await processManager.initialize(clientName: "openclicky", title: "OpenClicky", version: "1.0.0")
            try requireCurrentRun(generation)
            hasInitializedProcess = true
        }

        try await ensureCodexAuthentication(for: generation)
        try requireCurrentRun(generation)

        let baseInstructions = (try? String(contentsOf: preparedLayout.modelInstructionsFile, encoding: .utf8))
            ?? "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode."
        let specialistContext = prependedSystemContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let specialistPrefix = specialistContext.isEmpty ? "" : "\(specialistContext)\n\n--- OpenClicky base instructions ---\n"
        let developerInstructions = """
        \(specialistPrefix)You are running inside OpenClicky Agent Mode on macOS. Be direct, helpful, and careful. Prefer concrete actions over vague advice.

        When working on the OpenClicky app repo, do not run terminal `xcodebuild`. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks.

        OpenClicky's runtime map is at \(preparedLayout.runtimeMapFile.path). Read it when the user asks about logs, storage locations, memory, skills, widgets, settings, sessions, or where OpenClicky keeps anything. You may view or edit those local files when asked, subject to normal safety rules for destructive changes, credentials, and permissions.

        OpenClicky's persona is at \(preparedLayout.soulFile.path). Read it before task work. Treat it as the operating identity for voice-first behavior, autonomy, memory, archive-first changes, and plain-English progress.

        Archive-first is mandatory. When replacing, optimizing, pruning, or superseding OpenClicky memory, skills, runtime notes, prompts, config, or log-derived artifacts, copy or move the old version into \(preparedLayout.archivesDirectory.path) first. Do not delete old artifacts unless the user explicitly asks for deletion and understands it is destructive.

        Persistent memory is available. Read \(preparedLayout.persistentMemoryFile.path) before task work, then update it only when useful durable context is learned. Never tell the user you cannot remember outside the current conversation; use this memory file instead.

        Learned skills live at \(preparedLayout.learnedSkillsDirectory.path). Use or update them when the user asks to inspect, optimize, or learn from skills/logs, or when a repeated workflow would materially speed up future work. Create curated skills directly with specific names; do not create request-shaped `workflow_*` skills. Do not announce learned-skill checks or skill creation in progress or final answers unless the user asked about skills.

        Message logs are stored in \(OpenClickyMessageLogStore.shared.logDirectory.path). The current JSONL log is \(OpenClickyMessageLogStore.shared.currentLogFile.path). Log review comments are available at \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path), with JSONL comments at \(OpenClickyMessageLogStore.shared.reviewCommentsFile.path). When the user asks you to fix issues discovered from logs, read those files and treat each comment as actionable review context.

        When the user asks you to optimize skills, audit learned skills, or learn from logs, treat that as an active task: inspect the relevant files, identify repeatable improvements, archive old versions first, then create or update memory entries and learned skill files that make future agents faster and better.

        Widget state is available at \(OpenClickyWidgetStateStore.snapshotURL.path). When the user asks about widgets or desktop task/status display, read that snapshot before changing widget behavior.

        You are allowed to help with computer-use tasks. OpenClicky may be configured to use native CUA Swift or Background Computer Use for direct control before Agent Mode. When you operate the Mac from Agent Mode, prefer OpenClicky's available direct computer-use path and the `cuaDriver` MCP server when available; describe it as OpenClicky's computer-use path rather than assuming CUA is always selected. Do not choose or advertise Clawd or clawdcursor mouse/keyboard tools as the default for typing or focused-window control; use them only as an explicit fallback when OpenClicky's direct computer-use path is unavailable and say that it is a fallback. Simple focused-window typing is normally intercepted by OpenClicky before Agent Mode and handled through the selected direct computer-use backend.

        You are allowed to perform web research when the user asks for current information, web search, browsing, or research. Use the available network, browser, or search capabilities in the runtime; cite the pages or URLs you relied on in your final response. Do not tell the user voice mode lacks live web access once a task is running in Agent Mode.

        If a task requires destructive filesystem, git, credentials, or system permission changes, explain the action before doing it.

        \(ThreeDGenerationDispatcher.systemPromptInstruction)
        """

        let isHeyClickyLane = model.hasPrefix("heyclicky-free-")
        let effectiveModel = isHeyClickyLane
            ? ClickyCodexConfigTemplate.heyClickyRealCodexModel
            : model
        let effectiveModelProvider = isHeyClickyLane
            ? ClickyCodexConfigTemplate.heyClickyModelProviderID
            : modelProviderID
        let threadStart: [String: Any]
        do {
            threadStart = try await processManager.sendRequest(method: "thread/start", params: [
                "model": effectiveModel,
                "modelProvider": effectiveModelProvider,
                "cwd": workingDirectoryPath,
                "approvalPolicy": executionApprovalPolicy,
                "sandbox": executionSandboxMode,
                "config": [:],
                "serviceName": "OpenClicky",
                "baseInstructions": baseInstructions,
                "developerInstructions": developerInstructions,
                "personality": "friendly",
                "ephemeral": false,
                "sessionStartSource": "startup"
            ])
            try requireCurrentRun(generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentRun(generation)
            let text = Self.userFacingErrorMessage(from: error.localizedDescription)
            if Self.shouldRetryWithCompatibilityFallback(text),
               model != Self.codexRuntimeCompatibilityFallbackModel {
                let requestedModel = model
                entries.append(CodexTranscriptEntry(
                    role: .system,
                    text: "Codex rejected \(requestedModel) during startup with this runtime, so OpenClicky is retrying with \(Self.codexRuntimeCompatibilityFallbackModel)."
                ))
                applyModel(Self.codexRuntimeCompatibilityFallbackModel)
                restartProcessForCompatibilityFallback()
                try await ensureThread(for: generation)
                return
            }
            throw error
        }

        if let thread = CodexJSON.dictionary(threadStart["thread"]),
           let threadID = CodexJSON.string(thread["id"]) {
            activeThreadID = threadID
            status = .ready
            progressStage = .idle
            // Success path: hand ownership of the lease off to the running
            // session. The defer above will now do nothing.
            heyClickyPreambleNeedsRollback = false
        } else {
            throw CodexRPCError(message: "Codex app-server did not return a thread id.")
        }
    }

    private func ensureCodexAuthentication(for generation: UInt64) async throws {
        try requireCurrentRun(generation)

        // HeyClicky Free lane: actively login with apiKey so codex writes
        // its own auth.json inside our CodexHome (auth_mode:"apikey" +
        // OPENAI_API_KEY:<heyclicky JWT>). Without this, codex reads the
        // symlinked ChatGPT auth from ~/.codex/auth.json (or falls back
        // to it) and rejects heyclicky-free with "not supported
        // when using Codex with a ChatGPT account". The clicky-mac
        // reverse-engineering notes captured this exact requirement.
        if model.hasPrefix("heyclicky-free-") {
            let apiKey = AppBundleConfiguration.openAIAPIKey() ?? ""
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            HeyClickyLog.log("codex.login_apikey_starting", lane: "agent",
                             direction: "internal", [
                "stage": "S2_agent_process_launch",
                "have_key": !trimmed.isEmpty,
                "key_len": trimmed.count
            ])
            if !trimmed.isEmpty {
                do {
                    _ = try await processManager.sendRequest(
                        method: "account/login/start",
                        params: ["type": "apiKey", "apiKey": trimmed]
                    )
                    HeyClickyLog.log("codex.login_apikey_ok", lane: "agent",
                                     direction: "incoming",
                                     ["stage": "S2_agent_process_launch"])
                } catch {
                    HeyClickyLog.log("codex.login_apikey_failed", lane: "agent",
                                     direction: "error", [
                        "stage": "S2_agent_process_launch",
                        "error": "\(error)"
                    ])
                }
            }
            return
        }

        let modelProviderID = homeManager.modelProviderID
        guard modelProviderID == ClickyCodexConfigTemplate.defaultModelProviderID else { return }
        guard !codexConfigPrefersAPIKeyAuth() else { return }

        let accountRead = try await processManager.sendRequest(method: "account/read", params: [
            "refreshToken": false
        ])
        try requireCurrentRun(generation)

        if CodexJSON.dictionary(accountRead["account"]) != nil {
            return
        }

        let loginStart = try await processManager.sendRequest(method: "account/login/start", params: [
            "type": "chatgpt"
        ])
        try requireCurrentRun(generation)

        if let authURLString = CodexJSON.string(loginStart["authUrl"]),
           let authURL = URL(string: authURLString) {
            NSWorkspace.shared.open(authURL)
        }

        throw CodexRPCError(message: "OpenClicky found no Codex ChatGPT login. Finish the Codex sign-in that just opened, then start the Agent task again.")
    }

    /// Smart 402 handler. Refuses to burn a reset when the server
    /// still has quota left — instead refreshes the access token and
    /// re-keys the running codex. Only if `/me/plan` shows we are
    /// actually at cap does it fall through to `attemptReset`.
    func handle402MidChat(errorText: String) async {
        let lower = errorText.lowercased()
        // Classify: IDA HeyClicky-1.0.40 gives us the exact wire codes.
        //   agent_turn_limit_exceeded (0x1012a9650) — one turn ran too
        //     long; recover by dropping the stale lease and letting
        //     the next follow-up acquire a fresh one, no reset needed.
        //   session expired (0x1012ce6b2) — auth token stale;
        //     refresh + rekey.
        //   quota_exhausted (already in heartbeat whitelist) — real cap;
        //     attemptReset via extension.
        //   extra_usage_approval — turn cost cap; autoContinue.
        if lower.contains("agent_turn_limit_exceeded") || lower.contains("turn limit") {
            HeyClickyLog.log("codex.quota_402_route_turn_limit", lane: "agent",
                             direction: "internal", [:])
            // Stash thread for resume, tear down, and auto-continue.
            // Without the auto-continue, user's reply is stranded.
            if let existing = self.activeThreadID, !existing.isEmpty {
                self.pendingThreadResumeID = existing
            }
            self.heyClickyFreeTeardown(reason: "agent_turn_limit_exceeded")
            self.activeThreadID = nil
            HeyClickyLog.log("codex.turn_limit_teardown_ok", lane: "agent",
                             direction: "internal", [:])
            // Post notification for CompanionManager to auto-send
            // "请继续" — CodexAgentSession has no direct handle back
            // to companion.submitAgentPrompt, but the app-level
            // observer in CompanionManager+HeyClicky picks this up.
            NotificationCenter.default.post(
                name: .heyClickyRequestAutoContinueReplay,
                object: nil,
                userInfo: ["session_id": self.id.uuidString]
            )
            return
        }
        // agent_extra_effort_required: proxy wants approval to spend
        // more of the $1.5 per-turn cost cap. HeyClicky.app auto
        // approves by default. Fire /agent/turn-lease/{id}/continue
        // with extra_usage_approval:true so codex's paused /responses
        // stream resumes. No teardown, no thread reset — same turn
        // keeps flowing.
        if lower.contains("agent_extra_effort_required")
            || lower.contains("extra_usage_approval")
            || lower.contains("extra effort") {
            HeyClickyLog.log("codex.quota_402_route_extra_effort", lane: "agent",
                             direction: "internal",
                             ["had_lease": currentHeyClickyLease != nil ? "yes" : "no"])
            if let lease = currentHeyClickyLease {
                do {
                    try await HeyClickyTurnLeaseClient.shared.autoContinue(leaseID: lease.leaseID)
                    HeyClickyLog.log("codex.extra_effort_approved", lane: "agent",
                                     direction: "internal", [:])
                } catch HeyClickyProxyError.quotaExhausted {
                    // Proxy refused to approve extra usage because the
                    // account is truly out of quota — escalate to
                    // single-account reset (same email, re-auth via
                    // Chrome ext to open a fresh 25-turn window).
                    HeyClickyLog.log("codex.extra_effort_escalate_reset", lane: "agent",
                                     direction: "internal", [
                        "reason": "continue_returned_402_or_429"
                    ])
                    await MainActor.run {
                        _ = HeyClickyAccountResetManager.shared.attemptReset(
                            reason: "extra_effort_denied_quota_exhausted"
                        )
                    }
                } catch {
                    HeyClickyLog.log("codex.extra_effort_approve_failed", lane: "agent",
                                     direction: "error", ["error": "\(error)"])
                }
            } else {
                HeyClickyLog.log("codex.extra_effort_no_lease", lane: "agent",
                                 direction: "error",
                                 ["reason": "cannot_approve_without_lease"])
            }
            return
        }
        if lower.contains("session expired") || lower.contains("token expired")
            || lower.contains("unauthorized") || lower.contains("401") {
            HeyClickyLog.log("codex.quota_402_route_refresh_rekey", lane: "agent",
                             direction: "internal", [:])
            _ = try? await HeyClickySessionAuthenticator.shared.refresh()
            // rekey happens automatically via .clickyHeyClickyCredentialsRefreshed observer
            return
        }
        // Fall back to plan check — only reset if we ACTUALLY have no
        // quota left. Blind reset destroys the conversation for a
        // stale token that just needed a refresh.
        let plan = await HeyClickyPlanClient.shared.refresh()
        let atCap: Bool
        if let plan {
            atCap = plan.agentsUsed >= plan.agentsCap && plan.agentsCap > 0
            HeyClickyLog.log("codex.quota_402_plan_check", lane: "agent", direction: "internal", [
                "agents_used": plan.agentsUsed,
                "agents_cap": plan.agentsCap,
                "at_cap": atCap
            ])
        } else {
            atCap = false
            HeyClickyLog.log("codex.quota_402_plan_unknown", lane: "agent", direction: "internal", [
                "assume": "not_at_cap_will_refresh"
            ])
        }
        if atCap {
            HeyClickyLog.log("codex.quota_402_route_reset", lane: "agent",
                             direction: "internal", [:])
            _ = HeyClickyAccountResetManager.shared.attemptReset(
                reason: "quota_exhausted_402_midchat"
            )
        } else {
            HeyClickyLog.log("codex.quota_402_route_refresh_rekey_default", lane: "agent",
                             direction: "internal", [:])
            _ = try? await HeyClickySessionAuthenticator.shared.refresh()
        }
    }

    /// Rekey the still-running codex app-server after HeyClicky
    /// refreshed the Supabase access token. Without this, codex keeps
    /// sending the OLD JWT as `OPENAI_API_KEY` on every /responses call
    /// and the proxy returns HTTP 402 forever — the user had to
    /// force-relaunch (sign out+in) to unstick it.
    /// Also releases the stale lease + nulls activeThreadID so the
    /// next follow-up prompt re-runs `heyClickyFreePreamble` and
    /// acquires a fresh lease against the new account. Without that,
    /// after a full account reset the session keeps calling into a
    /// dead thread on the old account and hangs forever.
    func rekeyLiveCodexWithFreshJWT() async {
        guard model.hasPrefix("heyclicky-free-") else { return }
        // Prefer BYOK OpenAI key (if user has one); otherwise use the
        // HeyClicky session JWT as the bearer, matching what
        // CodexProcessManager injects at spawn. Previously this only
        // read openAIAPIKey → in the pure heyclicky lane the key was
        // always empty so rekey silently skipped and the live codex
        // kept using its stale spawn-time JWT, causing 401 storms.
        let byokKey = AppBundleConfiguration.openAIAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        // In the heyclicky lane the correct bearer for codex is the
        // SHORT-LIVED per-account ephemeral minted via
        // /agent/session-token, NOT the Supabase JWT. Force a fresh
        // mint before rekey so a rekey after credentials refresh
        // pushes the current ephemeral (else we send the same JWT
        // that caused the 401 in the first place).
        var ephemeral: String?
        do {
            ephemeral = try await HeyClickySessionTokenClient.shared.mintCodexToken(launchSource: .codex)
        } catch {
            HeyClickyLog.log("codex.rekey_ephemeral_mint_failed", lane: "agent",
                             direction: "error", ["error": "\(error)"])
        }
        let apiKey: String
        if let byokKey, !byokKey.isEmpty {
            apiKey = byokKey
        } else if let eph = ephemeral, !eph.isEmpty {
            apiKey = eph
        } else if let jwt = AppBundleConfiguration.heyClickySessionAccessToken()?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !jwt.isEmpty {
            apiKey = jwt
        } else {
            HeyClickyLog.log("codex.rekey_skipped", lane: "agent", direction: "internal", [
                "reason": "no_api_key_and_no_ephemeral_and_no_jwt"
            ])
            return
        }
        HeyClickyLog.log("codex.rekey_starting", lane: "agent", direction: "outgoing", [
            "key_len": apiKey.count,
            "had_thread": activeThreadID != nil ? "yes" : "no",
            "had_lease": currentHeyClickyLease != nil ? "yes" : "no",
            "process_running": processManager.isRunning
        ])
        // If codex is not running, there's nothing to rekey — the next
        // preamble will spawn it fresh with the current JWT via env.
        // Do NOT nuke thread/lease in this branch: there is nothing
        // stale to invalidate, and clearing forces the next preamble
        // to acquire a fresh lease (+1 credit wasted).
        guard processManager.isRunning else {
            HeyClickyLog.log("codex.rekey_skipped_not_running", lane: "agent",
                             direction: "internal", [
                "had_thread": activeThreadID != nil ? "yes" : "no",
                "had_lease": currentHeyClickyLease != nil ? "yes" : "no"
            ])
            return
        }

        var rekeyOk = false
        do {
            _ = try await processManager.sendRequest(
                method: "account/login/start",
                params: ["type": "apiKey", "apiKey": apiKey]
            )
            HeyClickyLog.log("codex.rekey_ok", lane: "agent", direction: "incoming", [:])
            rekeyOk = true
        } catch {
            HeyClickyLog.log("codex.rekey_failed", lane: "agent", direction: "error", [
                "error": "\(error)"
            ])
        }

        // ONLY nuke thread/lease if we actually rekeyed the running
        // codex child — that's the exact case where the child now
        // authenticates as a different upstream identity and any
        // lease/thread bound to the old identity is dead. If the
        // rekey call FAILED, the child is still on the old identity
        // and its lease/thread are still valid, so keep them alive.
        // Stashing the current thread_id lets the next
        // launchThread send `thread_id + clicky_agent_thread_resumed:true`
        // and the proxy resumes the SAME conversation on the new account.
        if rekeyOk {
            logLifecycle(
                action: "LEASE_NUKED_BY_REKEY",
                reason: "codex child re-authenticated with new identity — old lease dead — next submit spends +1 credit",
                extra: [
                    "stashed_for_resume": pendingThreadResumeID != nil,
                    "resume_prefix": String((pendingThreadResumeID ?? "").prefix(8))
                ]
            )
            if let existing = activeThreadID, !existing.isEmpty {
                pendingThreadResumeID = existing
            }
            heyClickyFreeTeardown(reason: "credentials_refreshed")
            activeThreadID = nil
            activeTurnID = nil
            HeyClickyLog.log("codex.thread_cleared_for_rekey", lane: "agent", direction: "internal", [
                "stashed_for_resume": pendingThreadResumeID != nil ? "yes" : "no",
                "resume_prefix": String((pendingThreadResumeID ?? "").prefix(8))
            ])
        } else {
            HeyClickyLog.log("codex.rekey_keeping_thread_and_lease", lane: "agent",
                             direction: "internal", [
                "had_thread": activeThreadID != nil ? "yes" : "no",
                "had_lease": currentHeyClickyLease != nil ? "yes" : "no"
            ])
        }
    }

    private func codexConfigPrefersAPIKeyAuth() -> Bool {
        let configFile = homeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false)
        guard let configText = try? String(contentsOf: configFile, encoding: .utf8) else { return false }
        return configText.contains("preferred_auth_method = \"apikey\"")
    }

    private func handleNotification(_ notification: [String: Any]) {
        guard let method = CodexJSON.string(notification["method"]) else { return }
        let params = CodexJSON.dictionary(notification["params"]) ?? [:]

        switch method {
        case "thread/started":
            if let thread = CodexJSON.dictionary(params["thread"]),
               let threadID = CodexJSON.string(thread["id"]) {
                activeThreadID = threadID
                status = .ready
                progressStage = .idle
            }
        case "turn/started":
            status = .running
            progressStage = .starting
            lastErrorMessage = nil
            if let tid = CodexJSON.string(params["turnId"]) {
                activeTurnID = tid
            }
            logLifecycle(
                action: "TURN_STARTED",
                reason: "codex daemon notified turn started",
                extra: ["cost": "0_quota_within_current_lease"]
            )
        case "item/agentMessage/delta":
            let itemID = CodexJSON.string(params["itemId"]) ?? UUID().uuidString
            let delta = CodexJSON.string(params["delta"]) ?? ""
            let wasComposing = progressStage == .composing
            progressStage = .composing
            if !wasComposing {
                appendActivityStatusLine("Writing the response")
            }
            appendAssistantDelta(itemID: itemID, delta: delta)
        case "item/started":
            if blockForbiddenCommandIfNeeded(params["item"]) {
                return
            }
            handleStartedItem(params["item"])
        case "item/completed":
            handleCompletedItem(params["item"])
        case "turn/plan/updated":
            if let text = CodexJSON.string(params["text"]), !text.isEmpty {
                progressStage = .planning
                appendActivityStatusLine("Planning: \(Self.spokenSnippet(from: text, maxLength: 100))")
                entries.append(CodexTranscriptEntry(role: .plan, text: text))
            }
        case "command/exec/outputDelta", "item/commandExecution/outputDelta":
            let itemID = CodexJSON.string(params["itemId"])
                ?? CodexJSON.string(params["callId"])
                ?? "active-command-progress"
            let commandText = CodexJSON.string(params["command"])
                ?? CodexJSON.string(CodexJSON.dictionary(params["item"])?["command"])
                ?? ""
            progressStage = .executing
            let summary = Self.liveCommandProgressSummary(command: commandText)
            appendActivityStatusLine(summary)
            upsertEntryIfChanged(
                id: itemID,
                role: .command,
                text: summary
            )
        case "thread/status/changed":
            // Codex daemon explicit thread lifecycle signal:
            //   notLoaded | idle | systemError | active
            // `active` carries `activeFlags`: waitingOnApproval or
            // waitingOnUserInput. `waitingOnUserInput` is the true
            // signal that the turn produced its response and is
            // parked expecting a NEW user prompt. Log so upper
            // layers can gate follow-up dispatch on this signal
            // instead of guessing from progressStage.
            if let statusDict = params["status"] as? [String: Any] {
                let statusType = (statusDict["type"] as? String) ?? "?"
                let flags = (statusDict["activeFlags"] as? [String]) ?? []
                HeyClickyLog.log("codex.thread_status_changed", lane: "agent",
                                 direction: "incoming", [
                    "thread_prefix": String((params["threadId"] as? String ?? "").prefix(8)),
                    "status": statusType,
                    "flags": flags.joined(separator: ",")
                ])
                // If the turn is truly idle waiting on user, clear
                // activeTurnID so the next submit takes the
                // record-agent-launch path (a real new turn) — since
                // turn/steer would be rejected with "no active turn."
                // 500ms debounce: sometimes turn/completed arrives
                // slightly AFTER status_changed=idle. If the user
                // submits in that ~0.5s window, we still want to try
                // steer (it's cheap to fail). Wait, then clear.
                if statusType == "idle" || (statusType == "active" && flags.contains("waitingOnUserInput")) {
                    if activeTurnID != nil {
                        let currentTurn = activeTurnID
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard let self else { return }
                            // Only clear if it's STILL the same turn
                            // — a new turn/started between now and
                            // the 500ms mark means we should keep it.
                            if self.activeTurnID == currentTurn {
                                HeyClickyLog.log("codex.active_turn_cleared_by_status",
                                                 lane: "agent", direction: "internal",
                                                 ["reason": "\(statusType)/\(flags)",
                                                  "delayed": "500ms"])
                                self.activeTurnID = nil
                            }
                        }
                    }
                }
            }
        case "account/rateLimits/updated":
            // Server-pushed per-account quota snapshot. Format from
            // codex daemon: params.rateLimits is an array of buckets.
            // Structure varies by upstream; log raw for now so we have
            // observable data to decide when to preemptively swap
            // accounts before hitting the hard 25/25 cap.
            if let rl = params["rateLimits"] {
                HeyClickyLog.log("codex.rate_limits_updated", lane: "agent",
                                 direction: "incoming",
                                 ["snapshot": String(describing: rl).prefix(300).description])
            }
        case "thread/tokenUsage/updated":
            // Codex daemon reports running token usage per turn.
            // total.input + total.output = cumulative token spent this
            // turn. modelContextWindow = hard ceiling for this thread.
            // Use as advisory quota signal — the closer to the ceiling
            // we are, the more likely next /responses call will hit
            // extra_effort_required or turn_limit_exceeded. We log it
            // for observability; higher layers can decide to wrap up.
            if let usage = params["tokenUsage"] as? [String: Any] {
                let ctxWindow = (usage["modelContextWindow"] as? Int) ?? -1
                var totalIn = -1, totalOut = -1
                if let total = usage["total"] as? [String: Any] {
                    totalIn = (total["input_tokens"] as? Int) ?? -1
                    totalOut = (total["output_tokens"] as? Int) ?? -1
                }
                HeyClickyLog.log("codex.token_usage_updated", lane: "agent",
                                 direction: "incoming", [
                    "turn_prefix": String((params["turnId"] as? String ?? "").prefix(8)),
                    "totalIn": totalIn,
                    "totalOut": totalOut,
                    "totalAll": (totalIn>0 && totalOut>0) ? totalIn+totalOut : -1,
                    "ctxWindow": ctxWindow,
                    "pctUsed": (ctxWindow>0 && totalIn>0 && totalOut>0)
                                 ? String(format:"%.1f",Double(totalIn+totalOut)*100.0/Double(ctxWindow))
                                 : "-"
                ])
            }
        case "turn/completed":
            flushPendingAssistantDeltas()
            currentAssistantEntryID = nil
            status = .ready
            progressStage = .completed
            persistCompletedTurnMemoryIfNeeded()
            logLifecycle(
                action: "TURN_COMPLETED",
                reason: "codex emitted stop; lease may still be alive for next turn",
                extra: [
                    "lease_still_alive": currentHeyClickyLease != nil,
                    "next_action_should_be": currentHeyClickyLease != nil
                        ? "reuse_this_lease_for_next_turn_0_quota"
                        : "acquire_new_lease_next_submit_1_quota"
                ]
            )
            activeTurnID = nil
            Task { await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id) }
            currentLeasePaths = []
            if !queuedFollowUpPrompts.isEmpty {
                let nextPrompt = queuedFollowUpPrompts.removeFirst()
                startPromptTurn(nextPrompt, screenContext: nil)
            }
            // F28 (Task #204) — progress-driven auto-continue.
            // Sole trigger site for the progress-driven variant of
            // .heyClickyRequestAutoContinueReplay: fire only after the
            // model has cleanly ended a turn without writing the DONE
            // marker to PROGRESS.md. The observer body in
            // CompanionManager+HeyClicky treats `.completed` as
            // fire-worthy iff `session.progressDriven == true` and the
            // marker is absent — see the extended
            // `hasInterruptedInFlightTurn` gate at
            // CompanionManager+HeyClicky.swift ~ :404.
            //
            // Lane gate mirrors that observer (heyclicky-free-only) so
            // Anthropic / OpenAI / Codex-direct sessions stay opt-out.
            // Marker semantics (whole-line, case-sensitive, missing
            // file => not done) are handled by OpenClickyProgressMarkerCheck.
            if progressDriven,
               !workingDirectoryPath.isEmpty,
               model.hasPrefix("heyclicky-free-") {
                let marker = completionMarker ?? "LAST_COMPLETED: DONE"
                // Prefer the explicit task-progress path threaded through by
                // RouteDispatcher (variant A writes to
                // <workdir>/.openclicky/task/PROGRESS.md, NOT
                // <workdir>/PROGRESS.md). Fall back to the workdir root only
                // for legacy sessions that never had taskProgressPath set.
                // See docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md HIGH #2.
                let progressPath: String
                if let tp = taskProgressPath, !tp.isEmpty {
                    progressPath = tp
                } else {
                    progressPath = (workingDirectoryPath as NSString)
                        .appendingPathComponent("PROGRESS.md")
                }
                // Move the file read + regex off @MainActor. The check
                // is pure (no shared state) so a detached task is safe;
                // this prevents PROGRESS.md I/O from stalling the UI
                // when disk is slow. See perf-audit 2026-07-23 MEDIUM #3.
                let sessionIDString = id.uuidString
                Task { [weak self] in
                    let markerFound = await Task.detached {
                        OpenClickyProgressMarkerCheck.isDone(
                            path: progressPath,
                            marker: marker
                        )
                    }.value
                    guard self != nil else { return }
                    HeyClickyLog.log(
                        "openclicky.f28.progress_check",
                        lane: "agent",
                        direction: "internal",
                        [
                            "session_id_prefix": String(sessionIDString.prefix(8)),
                            "progress_path": progressPath,
                            "marker": marker,
                            "marker_found": markerFound
                        ]
                    )
                    if !markerFound {
                        NotificationCenter.default.post(
                            name: .heyClickyRequestAutoContinueReplay,
                            object: nil,
                            userInfo: [
                                "session_id": sessionIDString,
                                "source": "f28_progress_driven"
                            ]
                        )
                    }
                }
            }
            // Chime intentionally NOT played here. CompanionManager owns
            // the audio choreography and plays the chime *after* any
            // in-flight TTS finishes, so the chime can't cut the
            // acknowledgement speech. See `playAgentDoneChimeAfterCurrentTTS`.
        case "error":
            // Preserve the RAW error text (before user-facing wrapper)
            // so status-code / error-string classifiers below can see
            // "428", "agent_turn_lease_required", etc. The
            // `userFacingErrorMessage` wrapper collapses those into
            // friendly captions and loses the signal.
            let rawErrorText = Self.notificationErrorMessage(from: params) ?? ""
            let text = Self.userFacingErrorMessage(
                from: rawErrorText.isEmpty ? "Codex app-server emitted an error." : rawErrorText
            )
            // Also mine `params.error` sub-dict directly — some codex
            // versions put the numeric code under `error.code` /
            // `error.status` that don't survive the readable-message
            // extractor. Concatenate everything we can find.
            var classifierText = rawErrorText
            if let errDict = params["error"] as? [String: Any] {
                for key in ["code", "status", "type", "message", "error"] {
                    if let v = errDict[key] {
                        classifierText += " \(v)"
                    }
                }
            }
            if let msgDict = params["message"] as? [String: Any] {
                for key in ["code", "status", "type", "message"] {
                    if let v = msgDict[key] {
                        classifierText += " \(v)"
                    }
                }
            }
            let lowerClassifier = classifierText.lowercased()
            // Persist the full server error text to the observability log
            // so 402/429/quota/schema failures are diagnosable from the
            // JSONL file. The paramsSummary path collapses this away.
            HeyClickyLog.log("codex.rpc_error_text", lane: "agent", direction: "incoming", [
                "stage": "S2_agent_process_launch",
                "turn_prefix": String((params["turnId"] as? String ?? "").prefix(8)),
                "errorRaw": String(text.prefix(400)),
                "classifierText": String(classifierText.prefix(400)),
                "raw_params_keys": params.keys.sorted().joined(separator: ",")
            ])
            // 402 mid-chat: HeyClicky proxy returns 402 for THREE
            // different conditions and each needs a different fix:
            //   a) auth token stale     → refresh + rekey codex (no
            //                              reset — user still has quota)
            //   b) turn cost cap        → auto-continue (extra_usage
            //                              approval — user still has quota)
            //   c) real quota exhausted → attempt account reset
            // Blindly resetting on any 402 destroys the conversation
            // when quota is still available (user's original complaint:
            // "余额没用完不能直接重置吧").
            if model.hasPrefix("heyclicky-free-"),
               (classifierText.contains("402") || lowerClassifier.contains("payment required")
                    || lowerClassifier.contains("quota") || lowerClassifier.contains("upgrade")
                    || lowerClassifier.contains("agent_turn_limit")) {
                HeyClickyLog.log("codex.quota_402_detected", lane: "agent", direction: "incoming", [
                    "text_head": String(text.prefix(120))
                ])
                let capturedText = classifierText
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handle402MidChat(errorText: capturedText)
                }
            }
            // 428 Precondition Required + `agent_turn_lease_required`:
            // codex hit `/responses` without a valid lease. This happens
            // when the current lease was completed/failed but codex kept
            // pushing to the same turn stream. Fix: teardown so the
            // NEXT prompt re-runs the whole preamble (fresh lease +
            // fresh thread resume) — mirrors the turn_limit path.
            if model.hasPrefix("heyclicky-free-"),
               (classifierText.contains("428") || lowerClassifier.contains("agent_turn_lease_required")
                    || lowerClassifier.contains("precondition required")) {
                HeyClickyLog.log("codex.turn_lease_428_detected", lane: "agent",
                                 direction: "incoming", [
                    "text_head": String(text.prefix(120))
                ])
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Stash thread for resume, tear down lease, then
                    // post the auto-continue-replay signal so
                    // CompanionManager submits "请继续" against this
                    // session (same as the turn_limit branch).
                    if let existing = self.activeThreadID, !existing.isEmpty {
                        self.pendingThreadResumeID = existing
                    }
                    self.heyClickyFreeTeardown(reason: "agent_turn_lease_required_428")
                    self.setActiveThreadID(nil)
                    HeyClickyLog.log("codex.turn_lease_428_teardown_ok", lane: "agent",
                                     direction: "internal", [:])
                    NotificationCenter.default.post(
                        name: .heyClickyRequestAutoContinueReplay,
                        object: nil,
                        userInfo: ["session_id": self.id.uuidString]
                    )
                }
            }
            lastErrorMessage = text
            status = .failed(text)
            progressStage = .failed
            // If the failure text is a transient recovery caption
            // (auto-recovery is in flight), DON'T pollute the transcript
            // history — it would be read back later as
            // `latestActivitySummary` for the dock even after recovery
            // succeeded, permanently pinning "网络恢复中…" on the card.
            // The recovery is a temporary UI state, not a persistent
            // conversation event.
            if !Self.isTransientRecoveryCaptionForTranscript(text) {
                entries.append(CodexTranscriptEntry(role: .system, text: text))
            }
            appendActivityStatusLine("Stopped: \(Self.spokenSnippet(from: text, maxLength: 100))")
        case "account/login/completed":
            if CodexJSON.bool(params["success"]) == true {
                entries.append(CodexTranscriptEntry(role: .system, text: "Codex ChatGPT sign-in completed. Start the Agent task again."))
            } else if let text = CodexJSON.string(params["error"]), !text.isEmpty {
                lastErrorMessage = text
                status = .failed(text)
                progressStage = .failed
                entries.append(CodexTranscriptEntry(role: .system, text: text))
            }
        default:
            break
        }
    }

    private static func notificationErrorMessage(from params: [String: Any]) -> String? {
        if let text = CodexRPCErrorMessage.readableMessage(from: params["message"]), !text.isEmpty {
            return text
        }

        guard let error = CodexJSON.dictionary(params["error"]) else { return nil }

        let message = CodexRPCErrorMessage.readableMessage(from: error["message"])
            ?? CodexRPCErrorMessage.readableMessage(from: error)
            ?? "Codex app-server emitted an error."
        let details = CodexRPCErrorMessage.readableMessage(from: error["additionalDetails"])
        if let details, !details.isEmpty, details != message {
            return "\(message)\n\(details)"
        }

        return message
    }

    private func blockForbiddenCommandIfNeeded(_ itemValue: Any?) -> Bool {
        guard let item = CodexJSON.dictionary(itemValue),
              let command = Self.forbiddenTerminalCommand(from: item) else {
            return false
        }

        let message = "OpenClicky stopped this Agent Mode run because it attempted to run terminal xcodebuild. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks."
        let id = CodexJSON.string(item["id"]) ?? UUID().uuidString
        upsertEntry(id: id, role: .system, text: message)
        latestResponseCard = ClickyResponseCard(
            source: .agent,
            rawText: message,
            contextTitle: lastSubmittedPrompt
        )
        lastErrorMessage = message
        currentAssistantEntryID = nil
        activeThreadID = nil
        activeTurnID = nil
        hasInitializedProcess = false
        status = .failed(message)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "blocked",
            event: "openclicky.agent_task.blocked_forbidden_command",
            fields: [
                "command": command,
                "reason": "terminal_xcodebuild_forbidden"
            ]
        )
        processManager.stop()
        return true
    }

    private static func forbiddenTerminalCommand(from item: [String: Any]) -> String? {
        var commands: [String] = []
        if let command = CodexJSON.string(item["command"]) {
            commands.append(command)
        }
        if let commandActions = CodexJSON.array(item["commandActions"]) {
            for actionValue in commandActions {
                guard let action = CodexJSON.dictionary(actionValue),
                      let command = CodexJSON.string(action["command"]) else {
                    continue
                }
                commands.append(command)
            }
        }

        return commands.first { commandInvokesTerminalXcodebuild($0) }
    }

    private static func commandInvokesTerminalXcodebuild(_ command: String) -> Bool {
        let normalized = command
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if normalized == "xcodebuild" || normalized.hasPrefix("xcodebuild ") {
            return true
        }

        let invocationPattern = #"(^|[;&|(`"'])\s*(?:sudo\s+|env\s+)?(?:/[^\s"';|&`]+/)?xcodebuild(\s|$)"#
        return normalized.range(of: invocationPattern, options: .regularExpression) != nil
    }

    nonisolated static func userFacingErrorMessage(from rawMessage: String) -> String {
        // Full raw text always goes to log via `codex.rpc_error_text`.
        // Here we only render a friendly HUD caption. The user wants to
        // feel like they're on an unlimited account, so wire-level
        // codes never surface — instead we show a short reassurance
        // like "正在刷新 Token…" or "正在为你续上额度…" and let the
        // auto-recovery machinery deal with the actual failure.
        if let friendly = friendlyRecoveryCaption(for: rawMessage) {
            return friendly
        }
        return CodexRPCErrorMessage.readableMessage(from: rawMessage) ?? rawMessage
    }

    /// Classifies raw error text and returns a friendly, action-hint
    /// caption when the app is silently recovering behind the scenes.
    /// Returns nil for genuinely unknown errors — those fall through
    /// to the raw readable message.
    nonisolated private static func friendlyRecoveryCaption(from raw: String) -> String? {
        return friendlyRecoveryCaption(for: raw)
    }
    nonisolated private static func friendlyRecoveryCaption(for raw: String) -> String? {
        let lower = raw.lowercased()
        // extra_effort = 本 turn 已用 cost 到 $1.5 cap；autoContinue
        // 会替用户 approve 继续同一 turn，跟"额度用完"不同。
        if lower.contains("agent_extra_effort_required")
            || lower.contains("extra_usage_approval")
            || lower.contains("extra effort") {
            return "正在自动继续…"
        }
        // 真正的账号额度用完（agents 25/25），auto-reset 后台换账号。
        if lower.contains("quota") || lower.contains("payment required")
            || raw.contains("402") || lower.contains("upgrade") {
            return "正在为你自动续期额度…"
        }
        // Auth token 过期 - refresh + rekey
        if lower.contains("session expired") || lower.contains("token expired")
            || lower.contains("unauthorized") || raw.contains("401")
            || lower.contains("invalid_issuer") {
            return "正在自动重新连接…"
        }
        // 单 turn 时长 cap - teardown + 新 turn 上继续
        if lower.contains("agent_turn_limit_exceeded") || lower.contains("turn limit") {
            return "正在自动继续下一段…"
        }
        // 428 Precondition — lease 过期/缺失，teardown 后自动重新开一 turn
        if lower.contains("agent_turn_lease_required")
            || (raw.contains("428") && lower.contains("precondition")) {
            return "正在自动重新开启会话…"
        }
        // 网络抖动 - codex 内部重试 Reconnecting 1/5..5/5
        if lower.contains("timed out") || lower.contains("stream disconnected")
            || lower.contains("reconnecting") || lower.contains("nsurlerror") {
            return "网络恢复中…"
        }
        // HeyClickyProxyError 枚举漏到 UI — Swift 默认把 enum
        // 印成 "OpenClicky.HeyClickyProxyError error 4." 这种鬼话。
        // 每个 case 都是能自动恢复的，用户看到裸枚举 index 会以为坏了。
        // 4=malformedResponse (代理返回 body 不符预期), 3=transportError,
        // 2=upstreamUnavailable, 1=quotaExhausted, 0=unauthorized。
        if lower.contains("heyclickyproxyerror") {
            if raw.contains("error 4") || lower.contains("malformedresponse") {
                return "服务响应异常，正在自动重试…"
            }
            if raw.contains("error 3") || lower.contains("transporterror") {
                return "网络恢复中…"
            }
            if raw.contains("error 2") || lower.contains("upstreamunavailable") {
                return "服务暂时不可用，正在自动重试…"
            }
            if raw.contains("error 1") || lower.contains("quotaexhausted") {
                return "正在为你自动续期额度…"
            }
            if raw.contains("error 0") || lower.contains("unauthorized") {
                return "正在自动重新连接…"
            }
            // Fallback for future enum growth.
            return "正在自动恢复…"
        }
        // codex app-server 没启动 → rekey 尝试时 abort。这是我们内部
        // 的一个 no-op case，用户不该看到"is not running"文字。
        if lower.contains("codex app-server is not running") {
            return "正在启动会话…"
        }
        return nil
    }

    nonisolated static func shouldRetryWithCompatibilityFallback(_ message: String) -> Bool {
        let foldedMessage = message
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return foldedMessage.contains("requires a newer version of codex")
            || foldedMessage.contains("please upgrade to the latest app or cli")
    }

    private func handleStartedItem(_ itemValue: Any?) {
        guard let item = CodexJSON.dictionary(itemValue), let type = CodexJSON.string(item["type"]) else { return }

        switch type {
        case "reasoning":
            progressStage = .planning
            appendActivityStatusLine("Thinking through the task")
        case "plan":
            progressStage = .planning
            appendActivityStatusLine("Planning next steps")
        case "commandExecution":
            progressStage = .executing
            appendActivityStatusLine(Self.commandStartedSummary(from: item))
        case "webSearch":
            progressStage = .executing
            appendActivityStatusLine(Self.webSearchStartedSummary(from: item))
        case "fileChange":
            progressStage = .executing
            appendActivityStatusLine(Self.fileChangeStartedSummary(from: item))
        case "agentMessage":
            progressStage = .composing
            appendActivityStatusLine("Writing the response")
        case "userMessage":
            break
        default:
            appendActivityStatusLine("Using \(Self.humanReadableItemType(type))")
        }
    }

    private func handleCompletedItem(_ itemValue: Any?) {
        guard let item = CodexJSON.dictionary(itemValue), let type = CodexJSON.string(item["type"]) else { return }
        let id = CodexJSON.string(item["id"]) ?? UUID().uuidString

        switch type {
        case "agentMessage":
            flushPendingAssistantDeltas(for: id)
            appendActivityStatusLine("Finished writing the response")
            let text = CodexJSON.string(item["text"]) ?? ""
            if !text.isEmpty {
                let parsed = Self.extractTaskTitleMetadata(from: text)
                if let taskTitle = parsed.taskTitle {
                    title = taskTitle
                }
                let visibleText = parsed.visibleText
                if !visibleText.isEmpty {
                    latestAssistantResponseForCompletedTurn = visibleText
                    upsertEntry(id: id, role: .assistant, text: visibleText)
                    OpenClickyMessageLogStore.shared.appendConversationTurn(
                        lane: "agent",
                        direction: "outgoing",
                        role: "assistant",
                        text: visibleText,
                        source: "codex_agent_session",
                        sessionID: self.id.uuidString,
                        title: title,
                        extraFields: [
                            "model": model,
                            "workingDirectory": workingDirectoryPath,
                            "itemID": id,
                            "taskTitleMetadata": parsed.taskTitle ?? ""
                        ]
                    )
                    latestResponseCard = ClickyResponseCard(
                        source: .agent,
                        rawText: Self.userFacingAgentMessage(from: visibleText),
                        contextTitle: lastSubmittedPrompt
                    )
                    if let fileURL = Self.firstOpenableFileURL(in: visibleText) {
                        onOpenableFileFound?(fileURL)
                    }
                }
            }
            currentAssistantEntryID = nil
        case "plan":
            if let text = CodexJSON.string(item["text"]), !text.isEmpty {
                appendActivityStatusLine("Planned: \(Self.spokenSnippet(from: text, maxLength: 100))")
                upsertEntry(id: id, role: .plan, text: text)
            }
        case "commandExecution":
            let command = CodexJSON.string(item["command"]) ?? "Command"
            let output = CodexJSON.string(item["aggregatedOutput"]) ?? ""
            let exitCode = CodexJSON.int(item["exitCode"])
            let summary = Self.plainEnglishCommandSummary(command: command, output: output, exitCode: exitCode)
            appendActivityStatusLine(summary)
            upsertEntry(
                id: id,
                role: .command,
                text: summary
            )
        case "webSearch":
            appendActivityStatusLine("Finished web search")
        case "fileChange":
            appendActivityStatusLine(Self.fileChangeCompletedSummary(from: item))
        default:
            break
        }
    }

    private func buildAgentCoordinationNote(for prompt: String) async throws -> String? {
        try Task.checkCancellation()
        let mentionedPaths = Self.extractLikelyFilePaths(from: prompt)
        let leaseSummary: OpenClickyAgentFileLeaseCoordinator.LeaseSummary?

        if mentionedPaths.isEmpty {
            currentLeasePaths = []
            await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id)
            leaseSummary = nil
        } else {
            let claimed = try await OpenClickyAgentFileLeaseCoordinator.shared.claimPathsWaitingForRelease(mentionedPaths, for: id, title: title)
            try Task.checkCancellation()
            currentLeasePaths = claimed.claimedPaths
            leaseSummary = claimed
        }

        let activeClaims: [String]
        if let leaseSummary {
            activeClaims = leaseSummary.activeClaims
        } else {
            activeClaims = await OpenClickyAgentFileLeaseCoordinator.shared.coordinationSnapshot(excluding: id)
        }
        try Task.checkCancellation()
        let activeClaimsSection = activeClaims.isEmpty
            ? "  - No explicit file leases are currently registered by other OpenClicky agents."
            : "  - Files currently claimed by other OpenClicky agents:\n" + activeClaims.joined(separator: "\n")

        let claimedSection: String
        if let leaseSummary, !leaseSummary.claimedPaths.isEmpty {
            claimedSection = "  - Claimed file ownership for this run:\n"
                + leaseSummary.claimedPaths.map { "- \($0)" }.joined(separator: "\n")
        } else {
            claimedSection = "  - This prompt did not name exact files, so no file lease was claimed yet."
        }

        let conflictSection: String
        if let leaseSummary, !leaseSummary.conflicts.isEmpty {
            let conflicts = leaseSummary.conflicts.map { conflict in
                "- \(conflict.path) (currently held by \(conflict.ownerTitle))"
            }.joined(separator: "\n")
            let timeoutNote = leaseSummary.waitTimedOut
                ? " OpenClicky already waited for the lease to clear, but it is still active."
                : ""
            conflictSection = "  - Potential ownership conflicts detected:\n"
                + conflicts
                + "\n  -\(timeoutNote) Do not edit conflicting files; wait for the lease to be released, then re-check before patching."
        } else if let leaseSummary, leaseSummary.waitedForConflicts {
            conflictSection = "  - OpenClicky waited for the previous file lease to be released before claiming these files. Re-check the target file immediately before patching."
        } else {
            conflictSection = "  - If scope changes or exact files become clear, avoid editing files owned by another running agent; wait for the lease to be released before patching."
        }

        return """
        - OpenClicky agent coordination:
          - Multiple OpenClicky agents may share the same working directory even though each has its own Codex runtime, process, and thread.
          - Before editing, run `git status --short` and inspect target files so you preserve uncommitted work from other agents.
          - Re-read a file immediately before patching it, and never replace whole files or reset changes unless the user explicitly asked for that destructive action.
          - Prefer small patches that merge with existing edits; if another agent owns or is clearly editing the same file, wait until the lease is released before patching.
        \(activeClaimsSection)
        \(claimedSection)
        \(conflictSection)
        """
    }

    private static func extractLikelyFilePaths(from text: String) -> [String] {
        let pattern = #"(?:~|/)?(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.(?:swift|m|mm|h|cpp|c|js|ts|tsx|jsx|json|toml|yaml|yml|md|txt|plist|xcodeproj|pbxproj)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            let candidate = nsText.substring(with: match.range)
            return isLikelyRealFilePath(candidate) ? candidate : nil
        }
    }

    private static func isLikelyRealFilePath(_ candidate: String) -> Bool {
        if candidate.contains("/") || candidate.hasPrefix("~/") {
            return true
        }

        // Console snippets often contain reverse-DNS domains that look like
        // header files, e.g. `com.apple.ViewBridge.error.h`. Those are log
        // identifiers, not editable files, so do not claim leases for them.
        let lowered = candidate.lowercased()
        let reverseDNSPrefixes = ["com.", "org.", "net.", "io.", "dev.", "app."]
        if reverseDNSPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return false
        }

        let dotCount = candidate.filter { $0 == "." }.count
        if dotCount >= 3 {
            return false
        }

        return true
    }

    private func appendAssistantDelta(itemID: String, delta: String) {
        guard !delta.isEmpty else { return }
        let id = currentAssistantEntryID ?? itemID
        currentAssistantEntryID = id
        pendingAssistantDeltas[id, default: ""] += delta
        scheduleAssistantDeltaFlush()
    }

    private func scheduleAssistantDeltaFlush() {
        guard pendingAssistantDeltaFlushTask == nil else { return }
        pendingAssistantDeltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.assistantDeltaFlushDelayNanoseconds)
            await MainActor.run {
                guard let self else { return }
                self.pendingAssistantDeltaFlushTask = nil
                self.flushPendingAssistantDeltas()
            }
        }
    }

    private func flushPendingAssistantDeltas(for entryID: String? = nil) {
        let targetIDs: [String]
        if let entryID {
            targetIDs = [entryID]
        } else {
            targetIDs = Array(pendingAssistantDeltas.keys)
        }

        for id in targetIDs {
            guard let delta = pendingAssistantDeltas.removeValue(forKey: id), !delta.isEmpty else { continue }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].text += delta
                if entries[index].role == .assistant {
                    latestAssistantResponseForCompletedTurn = entries[index].text
                }
            } else {
                entries.append(CodexTranscriptEntry(id: id, role: .assistant, text: delta))
                latestAssistantResponseForCompletedTurn = delta
            }
        }
    }

    private func upsertEntry(id: String, role: CodexTranscriptEntry.Role, text: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].role = role
            entries[index].text = text
        } else {
            entries.append(CodexTranscriptEntry(id: id, role: role, text: text))
        }
    }

    private func upsertEntryIfChanged(id: String, role: CodexTranscriptEntry.Role, text: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            guard entries[index].role != role || entries[index].text != text else { return }
            entries[index].role = role
            entries[index].text = text
        } else {
            entries.append(CodexTranscriptEntry(id: id, role: role, text: text))
        }
    }

    private func appendActivityStatusLine(_ text: String) {
        let flattened = Self.spokenSnippet(from: text, maxLength: 120)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return }
        if activityStatusLines.last == flattened { return }
        activityStatusLines.append(flattened)
        if activityStatusLines.count > 12 {
            activityStatusLines.removeFirst(activityStatusLines.count - 12)
        }
    }

    private func handleStderrLine(_ line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }
        if Self.isNonFatalCodexRuntimeStderrLine(trimmedLine) {
            if Self.isSkillLoadDiagnosticLine(trimmedLine) {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.skill_load.warning",
                    fields: [
                        "line": trimmedLine
                    ]
                )
            }
            return
        }

        if trimmedLine.localizedCaseInsensitiveContains("error") || trimmedLine.localizedCaseInsensitiveContains("unauthorized") {
            lastErrorMessage = trimmedLine
            if case .running = status {
                status = .failed(trimmedLine)
            }
        }
    }

    nonisolated static func testIsNonFatalCodexRuntimeStderrLine(_ line: String) -> Bool {
        isNonFatalCodexRuntimeStderrLine(line)
    }

    nonisolated private static func isNonFatalCodexRuntimeStderrLine(_ line: String) -> Bool {
        let normalized = line
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("responses_websocket")
            && normalized.contains("failed to connect to websocket")
            && normalized.contains("bad gateway") {
            return true
        }

        if normalized.contains("rmcp::transport::worker")
            && normalized.contains("worker quit with fatal")
            && (
                normalized.contains("authrequired")
                || normalized.contains("no authorization: bearer header")
                || normalized.contains("data did not match any variant of untagged enum jsonrpcmessage")
            ) {
            return true
        }

        if normalized.contains("failed to load skill")
            && normalized.contains("invalid description")
            && normalized.contains("exceeds maximum length") {
            return true
        }

        if normalized.contains("apply_patch verification failed") {
            return true
        }

        // The Codex memory writer can emit setup diagnostics on stderr while
        // the turn keeps running normally. Do not convert that background
        // memory-table warning into an OpenClicky agent failure; real task
        // failure still arrives through a Codex `error`, process exit, or a
        // failed command item.
        if normalized.contains("codex_memories_write")
            && normalized.contains("failed to claim job")
            && normalized.contains("no such table: jobs") {
            return true
        }

        // Codex can emit tool-router diagnostics on stderr while the
        // turn is still alive. In the logs this showed up as
        // `write_stdin failed: stdin is closed...` after an already-ended
        // terminal session, then OpenClicky marked the whole background
        // agent failed even though Codex continued reasoning and sending
        // messages. Treat that as a non-fatal tool interaction warning;
        // real agent failure should come from a Codex `error`, process
        // exit, or terminal command result.
        if normalized.contains("codex_core::tools::router")
            && normalized.contains("write_stdin failed")
            && normalized.contains("stdin is closed") {
            return true
        }

        return false
    }

    private static func isSkillLoadDiagnosticLine(_ line: String) -> Bool {
        let normalized = line
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return normalized.contains("failed to load skill")
            || normalized.contains("invalid description")
            || normalized.contains("exceeds maximum length")
    }

    // Note: the agent-done chime is no longer played from this class.
    // `CompanionManager.playAgentDoneChimeAfterCurrentTTS()` owns it so
    // it can be sequenced behind any in-flight TTS playback.

    private func persistCompletedTurnMemoryIfNeeded() {
        guard !hasPersistedCompletedTurnMemory else { return }
        guard let lastSubmittedPrompt else { return }
        guard let rawAgentResponse = latestAssistantResponseForCompletedTurn?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        let agentResponse = Self.strippingAgentResponseMetadata(from: rawAgentResponse)
        guard !agentResponse.isEmpty else {
            return
        }

        hasPersistedCompletedTurnMemory = true

        do {
            try homeManager.appendPersistentMemoryEvent(
                userRequest: lastSubmittedPrompt,
                agentResponse: agentResponse
            )
            try createLearnedSkillIfApplicable(userRequest: lastSubmittedPrompt, agentResponse: agentResponse)
        } catch {
            entries.append(CodexTranscriptEntry(role: .system, text: "OpenClicky could not update persistent memory or learned skills: \(error.localizedDescription)"))
        }
    }

    private func createLearnedSkillIfApplicable(userRequest: String, agentResponse: String) throws {
        let normalizedRequest = userRequest
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if isNoteWorkflow(requestText: normalizedRequest) {
            try homeManager.createLearnedSkillIfNeeded(
                name: "create_apple_note",
                title: "Create Apple Note",
                description: "Use when the user asks OpenClicky to create, save, or update an Apple Note from spoken or typed instructions.",
                body: """
                Use this workflow when the user asks to create a note in Apple Notes or save something as a note.

                ## Workflow

                1. Derive a concise note title from the request. If the user provides a title, use it exactly.
                2. Derive the note body from the request and any provided screen/file context. Keep formatting simple.
                3. Use AppleScript through `osascript` to create the note in Apple Notes. Prefer the default account and the standard Notes folder.
                4. Open or focus Notes only when useful for confirmation.
                5. Keep the final response short: say the note was created and include the title.
                6. Update `memory.md` with any durable preference or reusable detail learned during the note workflow.

                ## AppleScript Pattern

                ```applescript
                tell application "Notes"
                    activate
                    set noteTitle to "Title"
                    set noteBody to "Body"
                    make new note at folder "Notes" of default account with properties {name:noteTitle, body:noteBody}
                end tell
                ```

                If the default account or folder is unavailable, inspect the Notes accounts/folders and choose the most obvious personal Notes folder.
                """
            )
            return
        }

        // Generic request-shaped workflow capture was intentionally removed:
        // agents should create curated learned skills directly when the task
        // warrants it, not archive every successful prompt as `workflow_*`.
    }

    private func isNoteWorkflow(requestText: String) -> Bool {
        let noteIntentPhrases = [
            "create a note",
            "create an apple note",
            "make a note",
            "save this to notes",
            "save that to notes",
            "save it to notes",
            "save this in notes",
            "add this to notes",
            "add that to notes",
            "add to apple notes",
            "put this in notes",
            "update my note",
            "update the note"
        ]
        return noteIntentPhrases.contains { requestText.contains($0) }
    }

    private static func userFacingAgentMessage(from text: String) -> String {
        let visibleText = strippingAgentResponseMetadata(from: text)
        if let fileURL = firstOpenableFileURL(in: visibleText) {
            return "Found \(genericArtifactLabel(for: fileURL)). Showing it now."
        }

        return visibleText
    }

    private static func genericArtifactLabel(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
            return "the image"
        }
        if ["log", "txt", "md", "json", "jsonl", "yaml", "yml", "toml", "csv"].contains(ext) {
            return "that file"
        }
        if ["keychain", "pem", "key", "crt", "cer", "p12", "pfx"].contains(ext) {
            return "that login file"
        }
        return "that file"
    }

    private static func plainEnglishCommandSummary(command: String, output: String, exitCode: Int?) -> String {
        let cleanedCommand = compactSingleLine(command)
        _ = output

        if let exitCode, exitCode != 0 {
            return "Command failed (\(exitCode)): \(snippet(cleanedCommand, maxLength: 180))"
        }

        if !cleanedCommand.isEmpty {
            return "Command finished: \(snippet(cleanedCommand, maxLength: 160))"
        }

        return "Command finished"
    }

    private static func compactSingleLine(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func snippet(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0, text.count > maxLength else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        let prefix = String(text[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }

    private static func strippingANSI(_ text: String) -> String {
        let ansiPattern = #"\u{001B}\[[0-9;]*[A-Za-z]"#
        return text.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
    }

    private static func firstOpenableFileURL(in text: String, fileManager: FileManager = .default) -> URL? {
        for candidate in pathCandidates(in: text) {
            guard let fileURL = resolvedFileURL(from: candidate, fileManager: fileManager) else { continue }
            return fileURL
        }

        return nil
    }

    private static func pathCandidates(in text: String) -> [String] {
        var candidates: [String] = []

        for delimiter in ["`", "\"", "'"] {
            let parts = text.components(separatedBy: delimiter)
            guard parts.count > 2 else { continue }
            for index in stride(from: 1, to: parts.count, by: 2) {
                candidates.append(parts[index])
            }
        }

        for line in text.components(separatedBy: .newlines) {
            for marker in ["~/", "/Users/", "/Volumes/", "/tmp/", "/var/"] {
                guard let range = line.range(of: marker) else { continue }
                let suffix = String(line[range.lowerBound...])
                if let candidate = pathCandidateEndingAtKnownExtension(in: suffix) {
                    candidates.append(candidate)
                }
            }
        }

        return candidates
    }

    private static func pathCandidateEndingAtKnownExtension(in text: String) -> String? {
        let loweredText = text.lowercased()
        var bestEnd: String.Index?

        for fileExtension in openableFileExtensions {
            guard let range = loweredText.range(of: ".\(fileExtension)") else { continue }
            let end = text.index(text.startIndex, offsetBy: loweredText.distance(from: loweredText.startIndex, to: range.upperBound))
            if bestEnd == nil || end < bestEnd! {
                bestEnd = end
            }
        }

        guard let bestEnd else { return nil }
        return String(text[..<bestEnd])
    }

    private static func resolvedFileURL(from candidate: String, fileManager: FileManager) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: pathTrimCharacters)
        guard !trimmed.isEmpty else { return nil }

        let fileURL: URL
        if trimmed.hasPrefix("~/") {
            let relativePath = String(trimmed.dropFirst(2))
            fileURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        } else if trimmed.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: trimmed)
        } else {
            return nil
        }

        guard openableFileExtensions.contains(fileURL.pathExtension.lowercased()) else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        return fileURL.standardizedFileURL
    }

    private static let openableFileExtensions: Set<String> = [
        "csv",
        "doc",
        "docx",
        "gif",
        "heic",
        "jpeg",
        "jpg",
        "key",
        "md",
        "numbers",
        "pages",
        "pdf",
        "png",
        "rtf",
        "txt",
        "webp",
        "xls",
        "xlsx"
    ]

    private static let pathTrimCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "`'\".,;:)]}>"))

    private static func shortTitle(from prompt: String) -> String {
        nounBasedTaskTitle(from: prompt, maximumCharacters: 44, maximumWords: 5)
    }

    private static func shouldKeepInitialTaskTitle(_ title: String) -> Bool {
        let stableTitles: Set<String> = [
            "Log Issue Review",
            "Task Title Cleanup",
            "Task Title Stability",
            "Task Title Ordering",
            "Task Status Wording",
            "Lozenge Sizing"
        ]
        return stableTitles.contains(title)
    }

    private func fastFriendlyTitle(from prompt: String, fallbackTitle: String) async -> String? {
        let systemPrompt = """
        You create compact, friendly titles for OpenClicky background agent tasks.
        Return only the title, with no quotes or punctuation.
        Rules:
        - 2 to 5 words.
        - Noun-based action label.
        - Remove filler like can you, please, just, maybe, help me, deal with it.
        - Preserve the real requested work.
        - Examples: Voice Response Naturalization, Task Subject Cleanup, Inbox Triage, Settings Permissions Move.
        """
        let userPrompt = """
        Create a friendly task title for this OpenClicky agent request:
        \(prompt)
        """

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let title = await CodexAgentSession.localFoundationFriendlyTitle(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                fallbackTitle: fallbackTitle
            ) {
                return title
            }
        }
        #endif

        // Money rule (AGENTS.md): the Claude Agent SDK is PRIMARY — it uses the
        // local, already-paid-for Claude Code sign-in. Direct ClaudeAPI HTTP
        // bills per token and is FALLBACK ONLY (SDK nil or throws). Previously
        // this method short-circuited straight to direct REST on every task.
        if let sdk = claudeAgentSDKAPI {
            do {
                let (text, duration) = try await sdk.analyzeImageStreaming(
                    images: [],
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    onTextChunk: { _ in }
                )
                if let title = CodexAgentSession.cleanedFastFriendlyTitle(text, fallbackTitle: fallbackTitle) {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "agent",
                        direction: "incoming",
                        event: "openclicky.agent_task.title_generated",
                        fields: [
                            "provider": "claude_agent_sdk",
                            "durationMs": Int((duration * 1000).rounded()),
                            "title": title
                        ]
                    )
                    return title
                }
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generation_failed",
                    fields: [
                        "provider": "claude_agent_sdk",
                        "error": error.localizedDescription
                    ]
                )
                // Fall through to the direct REST fallback below.
            }
        }

        if let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() {
            let fastAnthropicModel = "claude-haiku-4-5"
            do {
                let api = ClaudeAPI(
                    apiKey: anthropicAPIKey,
                    model: fastAnthropicModel,
                    maxOutputTokens: 64
                )
                let (text, duration) = try await api.analyzeImage(
                    images: [],
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt
                )
                if let title = CodexAgentSession.cleanedFastFriendlyTitle(text, fallbackTitle: fallbackTitle) {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "agent",
                        direction: "incoming",
                        event: "openclicky.agent_task.title_generated",
                        fields: [
                            "provider": "anthropic",
                            "model": fastAnthropicModel,
                            "durationMs": Int((duration * 1000).rounded()),
                            "title": title
                        ]
                    )
                    return title
                }
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generation_failed",
                    fields: [
                        "provider": "anthropic",
                        "model": fastAnthropicModel,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        if let openAIAPIKey = AppBundleConfiguration.openAIAPIKey() {
            let fastOpenAIModel = "gpt-5.4-mini"
            do {
                let api = OpenAIAPI(
                    apiKey: openAIAPIKey,
                    model: fastOpenAIModel,
                    maxOutputTokens: 64
                )
                let (text, duration) = try await api.analyzeImage(
                    images: [],
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt
                )
                if let title = CodexAgentSession.cleanedFastFriendlyTitle(text, fallbackTitle: fallbackTitle) {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "agent",
                        direction: "incoming",
                        event: "openclicky.agent_task.title_generated",
                        fields: [
                            "provider": "openai",
                            "model": fastOpenAIModel,
                            "durationMs": Int((duration * 1000).rounded()),
                            "title": title
                        ]
                    )
                    return title
                }
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generation_failed",
                    fields: [
                        "provider": "openai",
                        "model": fastOpenAIModel,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func localFoundationFriendlyTitle(
        systemPrompt: String,
        userPrompt: String,
        fallbackTitle: String
    ) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.title_generation_skipped",
                fields: [
                    "provider": "apple_foundation_models",
                    "reason": "unavailable"
                ]
            )
            return nil
        }

        let startedAt = Date()
        do {
            let session = LanguageModelSession(instructions: systemPrompt)
            let response = try await session.respond(to: userPrompt)
            if let title = cleanedFastFriendlyTitle(response.content, fallbackTitle: fallbackTitle) {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generated",
                    fields: [
                        "provider": "apple_foundation_models",
                        "model": "SystemLanguageModel.default",
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "title": title
                    ]
                )
                return title
            }
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.title_generation_failed",
                fields: [
                    "provider": "apple_foundation_models",
                    "model": "SystemLanguageModel.default",
                    "error": error.localizedDescription
                ]
            )
        }

        return nil
    }
    #endif

    private static func cleanedFastFriendlyTitle(_ rawTitle: String, fallbackTitle: String) -> String? {
        if isRawTransportDiagnosticText(rawTitle) {
            return "Runtime Event Filter"
        }

        var title = rawTitle
            .components(separatedBy: .newlines)
            .first ?? rawTitle
        title = title.replacingOccurrences(
            of: #"(?i)^\s*(?:TASK_TITLE|title)\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:task\s+title|friendly\s+title)\b\s*:?"#,
            with: "",
            options: .regularExpression
        )
        title = title
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t`\"'“”‘’.,:;!?-–—[](){}<>"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(5)

        let cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.split(separator: " ").count >= 2 else { return nil }
        guard cleaned.count <= 44 else {
            return nounBasedTaskTitle(from: cleaned, maximumCharacters: 44, maximumWords: 5)
        }
        guard cleaned.caseInsensitiveCompare(fallbackTitle) != .orderedSame else { return nil }
        return cleaned
    }

    private static func nounBasedTaskTitle(
        from prompt: String,
        maximumCharacters: Int,
        maximumWords: Int
    ) -> String {
        var title = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'.,:;!?-–—[](){}<>"))

        if isRawTransportDiagnosticText(title) {
            return "Runtime Event Filter"
        }

        let directTitleRules: [(pattern: String, title: String)] = [
            (#"(?i)\b(?:see\s+(?:the\s+)?issue\s+here|look\s+at\s+this|fix\s+this)\b.*\b(?:OpenClickyLog|NSXPCDecoder|ViewBridge|unifiedReasons|NSXPCConnection)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:OpenClickyLog|NSXPCDecoder|NSXPCInterface|NSXPCConnection|ViewBridge|NSViewBridgeError|Unable to obtain a task name port right|nw_protocol_instance|nw_read_request_report|unifiedReasons)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:lozenge|pill|caption|label)\b.*\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b.*\b(?:lozenge|pill|caption|label)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:whole|full)\s+(?:task\s+)?names?\b"#, "Task Status Wording"),
            (#"(?i)\bshort\s+(?:version|task\s+name|name)\b"#, "Task Status Wording"),
            (#"(?i)\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b.*\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b.*\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:short|compact)\s+(?:version|label|title|name)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:proper|better|concise|short|compact)\s+(?:task\s+)?titles?\b"#, "Task Title Cleanup"),
            (#"(?i)\btask\s+titles?\b.*\b(?:read(?:ing)?\s+out|raw|asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:read(?:ing)?\s+out|raw)\b.*\b(?:asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b"#, "Task Title Stability"),
            (#"(?i)\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Stability")
        ]
        for rule in directTitleRules where title.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.title
        }

        let attachmentPathPatterns = [
            #"(?i)^/.*?\.(?:png|jpe?g|jpeg|heic|webp|gif|pdf|mov|mp4|m4v)\b"#,
            #"(?i)(?:^|\s)/(?:Users|var|tmp|private|Applications|Volumes)/\S+"#
        ]
        for pattern in attachmentPathPatterns {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let fillerPatterns = [
            #"(?i)^hey\s+(?:clicky\s+)?agent[,\s]+"#,
            #"(?i)^clicky\s+agent[,\s]+"#,
            #"(?i)^(?:can|could|would)\s+you\s+"#,
            #"(?i)^(?:please\s+)?(?:help\s+me\s+)?(?:do|make|handle|sort|take\s+care\s+of)\s+"#,
            #"(?i)^the\s+(?:updates?|changes?)\s+(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:to|for|about)\s+"#
        ]
        for pattern in fillerPatterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        title = title.replacingOccurrences(
            of: #"(?i)\b(?:please|just|maybe|basically|actually|kind\s+of|sort\s+of|you\s+know|everything\s+else)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:can\s+you|could\s+you|would\s+you|we(?:'|’)ve|we\s+have|we\s+were|talking\s+about)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:so\s+that|and\s+then|which\s+is\s+to|that\s+you)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:shorten|remove|make|making|sound|sounding|turn|change|update|fix|clean\s+up)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:the|a|an|this|that|it|them|you|your|then|also|with|from|into|and|or|but|for|of|to|in|on|as|is|are|be|have|has|had|asked)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:find|out|why|when|sure|use|uses?|using|start|starts|started|starting|speak|speaks|speaking|say|says|saying|read|reads|reading|whole|full|long|name|version|words?|thing|stuff|phrases?|responses?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(maximumWords)

        var cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            cleaned = "Agent Task"
        }

        guard cleaned.count > maximumCharacters else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: maximumCharacters)
        let prefix = String(cleaned[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractTaskTitleMetadata(from text: String) -> (visibleText: String, taskTitle: String?) {
        let lines = text.components(separatedBy: .newlines)
        var extractedTitle: String?
        var visibleLines: [String] = []

        for line in lines {
            if let parsedTitle = taskTitleMetadataValue(from: line) {
                extractedTitle = sanitizedReturnedTaskTitle(parsedTitle)
                continue
            }
            visibleLines.append(line)
        }

        let visibleText = strippingAgentResponseMetadata(from: visibleLines.joined(separator: "\n"))
        let fallbackText = strippingAgentResponseMetadata(from: text)
        return (visibleText.isEmpty ? fallbackText : visibleText, extractedTitle)
    }

    private static func strippingAgentResponseMetadata(from text: String) -> String {
        var visibleText = text
        visibleText = visibleText.replacingOccurrences(
            of: #"(?is)<\s*NEXT_ACTIONS\s*>.*?<\s*/\s*NEXT_ACTIONS\s*>"#,
            with: " ",
            options: .regularExpression
        )
        visibleText = visibleText.replacingOccurrences(
            of: #"(?im)^\s*TASK[_\s-]*TITLE\s*:\s*.*$"#,
            with: " ",
            options: .regularExpression
        )
        return visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func taskTitleMetadataValue(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\[?\s*TASK[_\s-]*TITLE\s*:\s*(.+?)\s*\]?$"#,
            #"(?i)^\[?\s*TITLE\s*:\s*(.+?)\s*\]?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let valueRange = Range(match.range(at: 1), in: trimmed) else { continue }
            return String(trimmed[valueRange])
        }
        return nil
    }

    private static func sanitizedReturnedTaskTitle(_ value: String) -> String? {
        let cleaned = nounBasedTaskTitle(from: value, maximumCharacters: 44, maximumWords: 5)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Matches the recovery-caption phrases produced by
    /// `friendlyRecoveryCaption`. Used to skip persisting these in the
    /// transcript so a resolved recovery doesn't leave a permanent
    /// "网络恢复中…" system entry that the dock keeps rendering.
    nonisolated static func isTransientRecoveryCaptionForTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let recoveryPhrases = [
            "正在自动继续",
            "正在为你自动续期额度",
            "正在自动重新连接",
            "正在自动继续下一段",
            "网络恢复中",
            "服务响应异常，正在自动重试",
            "服务暂时不可用，正在自动重试",
            "正在自动恢复",
            "正在启动会话",
            "正在自动重新开启会话",
            "服务响应异常"
        ]
        return recoveryPhrases.contains(where: { trimmed.contains($0) })
    }

    private static func latestActivitySummary(from entries: [CodexTranscriptEntry]) -> String? {
        latestActivityText(from: entries).map { spokenSnippet(from: $0, maxLength: 120) }
    }

    private static func latestActivityDisplaySummary(from entries: [CodexTranscriptEntry]) -> String? {
        latestActivityText(from: entries).map { displaySnippet(from: $0, maxLength: 1_200) }
    }

    private static func latestActivityText(from entries: [CodexTranscriptEntry]) -> String? {
        guard let latestEntry = entries.reversed().first(where: { entry in
            switch entry.role {
            case .assistant, .plan, .command, .system:
                return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user:
                return false
            }
        }) else {
            return nil
        }

        let text = strippingAgentResponseMetadata(from: latestEntry.text)
        return text.isEmpty ? nil : text
    }

    private static func liveCommandProgressSummary(command: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCommand.isEmpty {
            return "Running: \(spokenSnippet(from: trimmedCommand, maxLength: 90))"
        }

        return "Executing command…"
    }

    private static func commandStartedSummary(from item: [String: Any]) -> String {
        if let command = CodexJSON.string(item["command"]),
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Running command: \(spokenSnippet(from: command, maxLength: 90))"
        }

        if let commandActions = CodexJSON.array(item["commandActions"]) {
            for actionValue in commandActions {
                guard let action = CodexJSON.dictionary(actionValue),
                      let command = CodexJSON.string(action["command"]),
                      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                return "Running command: \(spokenSnippet(from: command, maxLength: 90))"
            }
        }

        return "Running a command"
    }

    private static func webSearchStartedSummary(from item: [String: Any]) -> String {
        let query = CodexJSON.string(item["query"])
            ?? CodexJSON.string(item["searchQuery"])
            ?? CodexJSON.string(item["text"])
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Searching web: \(spokenSnippet(from: query, maxLength: 90))"
        }
        return "Searching the web"
    }

    private static func fileChangeStartedSummary(from item: [String: Any]) -> String {
        let path = CodexJSON.string(item["path"])
            ?? CodexJSON.string(item["filePath"])
            ?? CodexJSON.string(item["filename"])
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Editing a file"
        }
        return "Editing files"
    }

    private static func fileChangeCompletedSummary(from item: [String: Any]) -> String {
        let path = CodexJSON.string(item["path"])
            ?? CodexJSON.string(item["filePath"])
            ?? CodexJSON.string(item["filename"])
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Updated a file"
        }
        return "Updated files"
    }

    private static func humanReadableItemType(_ type: String) -> String {
        let spaced = type
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.isEmpty ? "tool" : spaced.lowercased()
    }


    private static func isRawTransportDiagnosticText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let signals = [
            "/incoming]",
            "/outgoing]",
            "[incoming]",
            "[outgoing]",
            "codex.rpc.message",
            "codex.rpc.notification",
            "codex.rpc.request",
            #""method":"#,
            "paramsSummary",
            "turn/completed",
            "thread/tokenUsage/updated",
            "account/rateLimits/updated"
        ]
        let signalCount = signals.filter { trimmed.localizedCaseInsensitiveContains($0) }.count
        return signalCount >= 2 || (trimmed.localizedCaseInsensitiveContains("codex.rpc") && signalCount >= 1)
    }

    private static func spokenSnippet(from text: String, maxLength: Int) -> String {
        if isRawTransportDiagnosticText(text) {
            return "OpenClicky runtime event"
        }

        let flattened = strippingAgentResponseMetadata(from: text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattened.count > maxLength else {
            return flattened
        }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }

    private static func displaySnippet(from text: String, maxLength: Int) -> String {
        if isRawTransportDiagnosticText(text) {
            return "OpenClicky runtime event"
        }

        let flattened = strippingAgentResponseMetadata(from: text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattened.count > maxLength else {
            return flattened
        }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        return String(flattened[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if DEBUG
extension CodexAgentSession {
    func setTestStatus(_ status: CodexAgentSessionStatus) {
        self.status = status
    }
    func setTestLastErrorMessage(_ message: String?) {
        self.lastErrorMessage = message
    }
}
#endif
