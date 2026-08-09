//
//  MiniChatPanelManager.swift
//  OpenClicky
//
//  Floating per-session mini-chat NSPanel. One panel per session ID. Dies
//  with the parent HUD via `destroyAll()`.
//

import AppKit
import SwiftUI
import Combine
import OpenClickyCore
import OpenClickyUI

/// Store for archived session IDs (UserDefaults) and session transcript
/// snapshots (JSON files under Application Support). Snapshots carry full
/// transcripts and grow past the 4 MB CFPreferences write limit — cfprefsd
/// rejects oversized writes, silently losing the archive — so they must not
/// live in UserDefaults. Lives here (not in CompanionManager.swift) so the
/// additive patch keeps that file's diff minimal.
enum ChatWorkspaceArchiveStore {
  struct Snapshot: Codable, Sendable {
    let id: UUID
    let title: String
    let accentThemeRawValue: String
    let entries: [CodexTranscriptEntry]
    let activeThreadID: String?
    let lastSubmittedPrompt: String?
    let createdAt: Date?
    let latestActivityAt: Date?
    let wasRelaunchResumeCandidate: Bool?
    // Active-turn continuation state — mirrors HeyClicky-1.0.42's
    // `CodexActiveTaskSnapshot`. If the server-side lease is still
    // within `leaseExpiresAt` when the app restarts, we can resume by
    // sending `turn/steer` with this turnId and pay 0 new quota.
    // Nil for sessions that never had an active turn or that
    // completed cleanly. All three MUST be present together for the
    // steer path to fire on restore.
    let activeTurnID: String?
    let activeLeaseID: String?
    let leaseExpiresAt: Date?
  }

  private static let key = "openClickyArchivedSessions"
  private static let legacySnapshotsDefaultsKey = "openClickyArchivedSessionSnapshots"
  private static let legacyRelaunchableSnapshotsDefaultsKey = "openClickyRelaunchableAgentSessionSnapshots"
  private static let snapshotPersistenceQueue = DispatchQueue(label: "com.openclicky.chatWorkspaceArchiveStore.snapshots", qos: .utility)

  private static var snapshotsFileURL: URL {
    OpenClickyJSONFileStore.openClickyDirectory(subpath: ["ChatArchive"])
      .appendingPathComponent("archived-session-snapshots.json", isDirectory: false)
  }

  private static var relaunchableSnapshotsFileURL: URL {
    OpenClickyJSONFileStore.openClickyDirectory(subpath: ["ChatArchive"])
      .appendingPathComponent("relaunchable-session-snapshots.json", isDirectory: false)
  }

  static func load() -> Set<UUID> {
    guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
    return Set(raw.compactMap { UUID(uuidString: $0) })
  }

  static func save(_ ids: Set<UUID>) {
    UserDefaults.standard.set(ids.map { $0.uuidString }, forKey: key)
  }

  static func loadSnapshots() -> [Snapshot] {
    if let snapshots = OpenClickyJSONFileStore.read([Snapshot].self, from: snapshotsFileURL) {
      return snapshots
    }
    return migrateLegacyDefaultsSnapshots(defaultsKey: legacySnapshotsDefaultsKey, to: snapshotsFileURL)
  }

  @MainActor
  static func saveSnapshot(for session: CodexAgentSession) {
    let snapshot = Snapshot(
      id: session.id,
      title: session.title,
      accentThemeRawValue: session.accentTheme.rawValue,
      entries: session.entries,
      activeThreadID: session.activeThreadID,
      lastSubmittedPrompt: session.lastSubmittedPromptText,
      createdAt: session.createdAt,
      latestActivityAt: session.latestActivityDate,
      wasRelaunchResumeCandidate: false,
      activeTurnID: session.activeTurnID,
      activeLeaseID: session.activeLeaseID,
      leaseExpiresAt: session.leaseExpiresAt
    )

    snapshotPersistenceQueue.async {
      saveSnapshot(snapshot)
    }
  }

  static func removeSnapshot(for sessionID: UUID) {
    snapshotPersistenceQueue.async {
      saveSnapshots(loadSnapshots().filter { $0.id != sessionID })
    }
  }

  static func loadRelaunchableSnapshots() -> [Snapshot] {
    let snapshots = OpenClickyJSONFileStore.read([Snapshot].self, from: relaunchableSnapshotsFileURL)
      ?? migrateLegacyDefaultsSnapshots(defaultsKey: legacyRelaunchableSnapshotsDefaultsKey, to: relaunchableSnapshotsFileURL)
    return snapshots.sorted { left, right in
      let leftDate = left.latestActivityAt ?? left.entries.last?.createdAt ?? left.createdAt ?? .distantPast
      let rightDate = right.latestActivityAt ?? right.entries.last?.createdAt ?? right.createdAt ?? .distantPast
      return leftDate > rightDate
    }
  }

  @MainActor
  static func saveRelaunchableSnapshots(for sessions: [CodexAgentSession], archivedSessionIDs: Set<UUID>) {
    let snapshots = sessions.compactMap { session -> Snapshot? in
      guard !archivedSessionIDs.contains(session.id),
            session.hasVisibleActivity else {
        return nil
      }
      return Snapshot(
        id: session.id,
        title: session.title,
        accentThemeRawValue: session.accentTheme.rawValue,
        entries: session.entries,
        activeThreadID: session.activeThreadID,
        lastSubmittedPrompt: session.lastSubmittedPromptText,
        createdAt: session.createdAt,
        latestActivityAt: session.latestActivityDate,
        wasRelaunchResumeCandidate: session.isRelaunchResumeCandidate,
        activeTurnID: session.activeTurnID,
        activeLeaseID: session.activeLeaseID,
        leaseExpiresAt: session.leaseExpiresAt
      )
    }
    try? OpenClickyJSONFileStore.write(snapshots, to: relaunchableSnapshotsFileURL)
  }

  static func removeRelaunchableSnapshot(for sessionID: UUID) {
    let snapshots = loadRelaunchableSnapshots().filter { $0.id != sessionID }
    try? OpenClickyJSONFileStore.write(snapshots, to: relaunchableSnapshotsFileURL)
  }

  private static func saveSnapshot(_ snapshot: Snapshot) {
    var snapshots = loadSnapshots().filter { $0.id != snapshot.id }
    snapshots.append(snapshot)
    saveSnapshots(snapshots)
  }

  private static func saveSnapshots(_ snapshots: [Snapshot]) {
    try? OpenClickyJSONFileStore.write(snapshots, to: snapshotsFileURL)
  }

  /// One-time migration for snapshots persisted in UserDefaults before they
  /// moved to files. The defaults key is removed only after the file write
  /// succeeds, so a failed migration retries on the next load.
  private static func migrateLegacyDefaultsSnapshots(defaultsKey: String, to fileURL: URL) -> [Snapshot] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
          let snapshots = try? JSONDecoder().decode([Snapshot].self, from: data) else {
      return []
    }
    do {
      try OpenClickyJSONFileStore.write(snapshots, to: fileURL)
      UserDefaults.standard.removeObject(forKey: defaultsKey)
    } catch {}
    return snapshots
  }
}

@MainActor
final class MiniChatPanelManager: NSObject {
  static let shared = MiniChatPanelManager()
  private var panels: [UUID: NSPanel] = [:]
  private var delegates: [UUID: MiniChatPanelDelegate] = [:]

  override private init() { super.init() }

  func show(session: CodexAgentSession, companion: CompanionManager) {
    if let existing = panels[session.id] {
      OpenClickyWindowLevels.applyPanelDialogLevel(to: existing)
      existing.orderFrontRegardless()
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hosting = NSHostingView(
      rootView: MiniChatPanelView(
        session: session,
        companion: companion,
        close: { [weak self] in self?.close(sessionID: session.id) }
      )
    )

    // Standard window chrome — title bar + traffic lights, just smaller.
    let defaultWidth: CGFloat = 640
    let defaultHeight: CGFloat = 720
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = session.title
    panel.titleVisibility = .visible
    panel.titlebarAppearsTransparent = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isMovableByWindowBackground = false
    OpenClickyWindowLevels.applyPanelDialogLevel(to: panel)
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.hasShadow = false
    panel.minSize = NSSize(width: 320, height: 400)
    OpenClickyLiquidGlassWindowSurface.install(
      hostingView: hosting,
      in: panel,
      frame: NSRect(x: 0, y: 0, width: 380, height: 520),
      cornerRadius: 18,
      strength: .expanded
    )

    // Persist position + size across launches so the user only has to
    // arrange the mini panel once. NSWindow's built-in frame autosave
    // writes to UserDefaults (key = autosave name) and re-reads on the
    // NEXT setFrameUsingName call. We share one key across all
    // sessions — position matters, not per-session identity.
    let autosaveKey = "OpenClickyMiniChatPanelFrame"
    panel.setFrameAutosaveName("")
    if !panel.setFrameUsingName(autosaveKey) {
      // First time on this machine: center on the active screen.
      if let screen = NSScreen.openClickyActiveInteractionScreen() {
        let visibleFrame = screen.visibleFrame.isEmpty ? screen.frame : screen.visibleFrame
        let x = visibleFrame.midX - defaultWidth / 2
        let y = visibleFrame.midY - defaultHeight / 2
        panel.setFrame(NSRect(x: x, y: y, width: defaultWidth, height: defaultHeight),
                       display: false)
      }
    }
    panel.setFrameAutosaveName(autosaveKey)

    let delegate = MiniChatPanelDelegate { [weak self] in self?.close(sessionID: session.id) }
    panel.delegate = delegate
    panel.isReleasedWhenClosed = false
    delegates[session.id] = delegate
    panels[session.id] = panel
    panel.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  func close(sessionID: UUID) {
    panels[sessionID]?.close()
    panels.removeValue(forKey: sessionID)
    delegates.removeValue(forKey: sessionID)
  }

  /// Called when the parent HUD is destroyed. Tears down every popout.
  func destroyAll() {
    for (_, panel) in panels { panel.close() }
    panels.removeAll()
    delegates.removeAll()
  }
}

private struct MiniChatPanelView: View {
  @ObservedObject var session: CodexAgentSession
  @ObservedObject var companion: CompanionManager
  var close: () -> Void
  @State private var draft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Color.white.opacity(0.08))
      transcript
      Divider().background(Color.white.opacity(0.08))
      composer
    }
    .glassEffect(
      .regular.tint(DS.Colors.accent.opacity(0.045)),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
  }

  private var header: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(DS.Colors.accentText.opacity(0.7))
        .frame(width: 8, height: 8)
      Text(LocalizedStringKey(session.title))
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(DS.Colors.textPrimary)
        .lineLimit(1)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(DS.Colors.textSecondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(session.entries) { entry in
            MiniChatBubble(entry: entry).id(entry.id)
          }
        }
        .padding(12)
      }
      .onChange(of: session.entries.count) {
        if let last = session.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  private var composer: some View {
    HStack(spacing: 8) {
      TextField("Reply…", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .foregroundColor(DS.Colors.textPrimary)
        .lineLimit(1...4)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onSubmit(send)
        .onKeyPress(.return, phases: .down) { keyPress in
          if keyPress.modifiers.contains(.shift) {
            return .ignored
          }
          send()
          return .handled
        }
      Button(action: send) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 24))
          .foregroundColor(DS.Colors.accentText)
      }
      .buttonStyle(.plain)
      .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
  }

  private func send() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    session.submitPromptFromUI(trimmed, screenContext: nil)
    draft = ""
  }
}

private struct MiniChatBubble: View {
  let entry: CodexTranscriptEntry

  var body: some View {
    switch entry.role {
    case .command:
      commandRow
    case .system:
      systemRow
    case .plan:
      planRow
    case .user, .assistant:
      chatRow
    }
  }

  private var chatRow: some View {
    HStack {
      if entry.role == .user { Spacer(minLength: 24) }
      Text(entry.text)
        .font(.system(size: 14))
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(entry.role == .user
              ? DS.Colors.accentText.opacity(0.18)
              : Color.white.opacity(0.05))
        )
      if entry.role != .user { Spacer(minLength: 24) }
    }
  }

  /// Codex HUD renders `.command` entries in a monospaced font
  /// (`CodexHUDWindowManager.swift:791`). Match that here so the tool
  /// call badges look identical across surfaces.
  private var commandRow: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: entry.text.hasPrefix("←") ? "checkmark.circle" : "wrench.and.screwdriver")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.top, 2)
      Text(entry.text)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(DS.Colors.textPrimary)
        .lineLimit(4)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.white.opacity(0.03))
    )
  }

  private var systemRow: some View {
    HStack {
      Spacer()
      Text(entry.text)
        .font(.system(size: 11))
        .foregroundColor(DS.Colors.textSecondary.opacity(0.75))
        .italic()
      Spacer()
    }
    .padding(.vertical, 4)
  }

  private var planRow: some View {
    Text(entry.text)
      .font(.system(size: 13, weight: .medium))
      .foregroundColor(DS.Colors.textSecondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(DS.Colors.accentText.opacity(0.06))
      )
  }
}

@MainActor
private final class MiniChatPanelDelegate: NSObject, NSWindowDelegate {
  let onClose: () -> Void
  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
    super.init()
  }
  nonisolated func windowWillClose(_ notification: Notification) {
    Task { @MainActor in self.onClose() }
  }
}
