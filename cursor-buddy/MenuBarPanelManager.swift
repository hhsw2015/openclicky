//
//  MenuBarPanelManager.swift
//  cursor-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside unless pinned.
//

import AppKit
import Combine
import SwiftUI
import OpenClickyCore
import OpenClickyUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
    static let clickyPanelContentSizeDidChange = Notification.Name("clickyPanelContentSizeDidChange")
    static let clickyMainPanelResizeStateDidChange = Notification.Name("clickyMainPanelResizeStateDidChange")
    static let clickyHeyClickyResetCompleted = Notification.Name("clickyHeyClickyResetCompleted")
    static let clickyHeyClickyCredentialsRefreshed = Notification.Name("clickyHeyClickyCredentialsRefreshed")
    static let clickyHeyClickyGuidedClickFollowUp = Notification.Name("clickyHeyClickyGuidedClickFollowUp")
    static let clickyHeyClickySessionExpired = Notification.Name("clickyHeyClickySessionExpired")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    /// Combine sink that repaints the status-item icon when the Agent
    /// inbox unread count changes. Retained for lifetime of manager.
    private var notificationsBadgeCancellable: AnyCancellable?
    /// Sinks for Screen History recording state — one dot per active
    /// channel (screen / mic / system audio) drawn as a small colored
    /// pip on top of the base menubar icon. Same repaint pipeline as
    /// the agent-notification badge.
    private var recordingStateCancellables = Set<AnyCancellable>()
    private var lastRecordingBadge: (screen: Bool, audio: Bool) = (false, false)
    /// Cached template icon image loaded once — badge overlay redraws
    /// on top of this so we don't rebuild the whole symbol per tick.
    private var baseStatusIcon: NSImage?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?
    private var contentSizeObserver: NSObjectProtocol?
    private var contentResizeWorkItem: DispatchWorkItem?
    private var isPanelPinned = false
    private var themeObserver: NSObjectProtocol?
    private var glassBackdrop: OpenClickyLiquidGlassBackdropView?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 356
    private let panelHeight: CGFloat = 318
    private let panelMinimumSize = NSSize(width: 356, height: 300)
    private let transientPanelScreenEdgePadding: CGFloat = 12
    private let transientPanelMaximumContentHeight: CGFloat = 720

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showPanel()
            }
        }

        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resizeVisiblePanelToCurrentContent()
            }
        }

        // FIX(perf audit #334 P0-2): UserDefaults.didChangeNotification
        // fires on EVERY UserDefaults.set anywhere in the app — many
        // dozens/sec during voice streaming. Previously refreshThemeAppearance
        // + refreshGlassBackdropAccent ran per fire on main. Coalesce
        // to a 500 ms tail: at most 2 refreshes/sec regardless of write
        // rate, and only when a themekey actually changed.
        themeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleThemeRefresh()
            }
        }
    }

    deinit {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = contentSizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Low: remove the menu-bar slot on dealloc for symmetry with the
        // observer cleanup above. Negligible today (app-lifetime owner) but
        // prevents a leaked slot if the manager is ever recreated.
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        baseStatusIcon = makeClickyMenuBarIcon()
        button.image = baseStatusIcon
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // FIX(a11y-audit-2026-08-01 #1): VoiceOver would announce this
        // status item as "button" without a label. Add explicit label
        // + tooltip so VoiceOver and hover both surface the app name.
        button.setAccessibilityLabel("OpenClicky")
        button.setAccessibilityRole(.button)
        button.toolTip = "OpenClicky"

        // Repaint the icon whenever the Agent inbox unread count
        // changes so the user sees a red badge when the running agent
        // has pushed a new message (or the Notch surface is expected
        // to show a dot). Sink runs on main queue because we touch
        // NSStatusItem UI.
        notificationsBadgeCancellable = HeyClickyAgentNotificationsClient.shared
            .$unreadCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.applyAgentBadge(count: count)
            }
        // Kick a one-shot refresh so cold-boot users see the badge for
        // any unread notifications from prior sessions. The @Published
        // sink above will fire when the response lands.
        Task { await HeyClickyAgentNotificationsClient.shared.refresh() }
        // Watch Screen History recording state so the menu-bar icon
        // shows AT-A-GLANCE whether video / audio is currently being
        // captured. No need to open the app to check.
        // Watch defaults changes so the icon flips instantly when
        // the user toggles capture in Settings or the menu bar,
        // without waiting for the capture pipeline to acknowledge.
        // FIX(task #326 UI-11): filter didChangeNotification by
        // whether the recording keys are the ones that could have
        // changed. Prior code re-ran the badge repaint on EVERY
        // defaults write (dock frame autosave, SKI hotkey remap,
        // model selector, etc.) — hundreds of no-op repaints per
        // typing session.
        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification)
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.applyRecordingBadgeIfChanged() }
            .store(in: &recordingStateCancellables)
        // Also react to pipeline state as a secondary signal (covers
        // cases where the user hits an OS-level pause, e.g. entering
        // a Sonoma system-lock, without touching our defaults).
        ScreenHistoryState.shared.$isRecordingScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRecordingBadge() }
            .store(in: &recordingStateCancellables)
        ScreenHistoryState.shared.$isRecordingMic
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRecordingBadge() }
            .store(in: &recordingStateCancellables)
        ScreenHistoryState.shared.$isRecordingSystemAudio
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRecordingBadge() }
            .store(in: &recordingStateCancellables)
        // Initial paint so the icon matches state at boot, not just
        // on first Combine event.
        DispatchQueue.main.async { [weak self] in
            self?.applyRecordingBadge()
        }
    }

    /// Swap the menu-bar icon itself between four states so a glance
    /// at the top-right of the screen tells the user what's being
    /// recorded (Rewind ships the same UX with `ic_rewind-menubar`
    /// variants). No overlays — the base image is replaced entirely
    /// so the shape reads unambiguously at 22 px.
    ///
    ///   idle       → triangle only (baseStatusIcon)
    ///   video only → record.circle (SF Symbol, red tint)
    ///   audio only → mic.fill      (SF Symbol, orange tint)
    ///   both       → record.circle.fill + micro dot (both indicator)
    /// Cached snapshot of the recording defaults so `applyRecordingBadgeIfChanged`
    /// can short-circuit when nothing relevant to the badge moved.
    private var lastRecordingBadgeSnapshot: (screen: Bool, mic: Bool, sysAudio: Bool)?

    private func applyRecordingBadgeIfChanged() {
        let ud = UserDefaults.standard
        let screen = ud.object(forKey: "openclicky.screenHistory.capture.screen") as? Bool ?? true
        let mic = ud.bool(forKey: "openclicky.screenHistory.capture.mic")
        let sysAudio = ud.bool(forKey: "openclicky.screenHistory.capture.systemAudio")
        let snap = (screen, mic, sysAudio)
        if let last = lastRecordingBadgeSnapshot, last == snap { return }
        lastRecordingBadgeSnapshot = snap
        applyRecordingBadge()
    }

    private func applyRecordingBadge() {
        guard let button = statusItem?.button, let base = baseStatusIcon
        else { return }
        // Icon should reflect USER INTENT (what they've toggled in
        // Settings / menu bar), not just live capture-pipeline state.
        // `ScreenHistoryState.isRecordingScreen` only flips true once
        // ScreenCaptureKit hands us the first frame — that lags the
        // user's click by seconds and leaves the icon looking stuck.
        let ud = UserDefaults.standard
        // FIX(#342): master toggle defaults to true when the key is
        // absent, matching the capture pipeline's own default. The old
        // `ud.bool(forKey:)` returned false whenever the user had never
        // touched a "master" toggle → icon stayed idle even while
        // recording was live. Use `object(forKey:) as? Bool` so we can
        // distinguish absent (→ default) from explicit false.
        let masterEnabled: Bool = {
            if let v = ud.object(forKey: "openclicky.screenHistory.enabled") as? Bool {
                return v
            }
            return true
        }()
        let screenIntent = ud.object(
            forKey: "openclicky.screenHistory.capture.screen") == nil
            ? true
            : ud.bool(forKey: "openclicky.screenHistory.capture.screen")
        let audioIntent = ud.bool(forKey: "openclicky.screenHistory.capture.mic")
                       || ud.bool(forKey: "openclicky.screenHistory.capture.systemAudio")
        // Live state takes precedence over intent: if ScreenHistoryState
        // says recording is active, force the icon on regardless of what
        // the master defaults key looks like (covers cases where the
        // capture pipeline was started via a different route).
        let liveScreen = ScreenHistoryState.shared.isRecordingScreen
        let liveAudio = ScreenHistoryState.shared.isRecordingMic
            || ScreenHistoryState.shared.isRecordingSystemAudio
        let screen = liveScreen || (masterEnabled && screenIntent)
        let audio = liveAudio || (masterEnabled && audioIntent)
        NSLog("[OpenClicky] menubar icon state screen=%d audio=%d master=%d",
              screen ? 1 : 0, audio ? 1 : 0, masterEnabled ? 1 : 0)
        if lastRecordingBadge == (screen, audio) { return }
        lastRecordingBadge = (screen, audio)
        // Idle → plain triangle, template-tintable.
        if !screen && !audio {
            button.image = base
            button.image?.isTemplate = true
            return
        }
        // Pick a SF Symbol that spells out the state.
        let symbolName: String
        let tint: NSColor
        switch (screen, audio) {
        case (true,  false): symbolName = "record.circle";     tint = .systemRed
        case (false, true):  symbolName = "mic.fill";           tint = .systemOrange
        case (true,  true):  symbolName = "record.circle.fill"; tint = .systemRed
        default:             symbolName = "circle";             tint = .labelColor
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let sym = NSImage(systemSymbolName: symbolName,
                                 accessibilityDescription: symbolName)?
                .withSymbolConfiguration(cfg)
        else {
            button.image = base
            return
        }
        // Draw the symbol tinted; for the both-state overlay a small
        // mic pip on top so users can distinguish "video+audio" from
        // "video only".
        let size = NSSize(width: 20, height: 20)
        let composed = NSImage(size: size)
        composed.lockFocus()
        tint.set()
        let rect = NSRect(origin: .zero, size: size)
        let symRect = NSRect(x: (size.width - sym.size.width) / 2,
                              y: (size.height - sym.size.height) / 2,
                              width: sym.size.width, height: sym.size.height)
        sym.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        // Tint pass — multiply blend so template glyph picks up color.
        tint.setFill()
        rect.fill(using: .sourceAtop)
        // Both-state: overlay a small orange mic tick in the corner.
        if screen && audio {
            NSColor.systemOrange.setFill()
            let d: CGFloat = 5
            NSBezierPath(ovalIn: NSRect(x: size.width - d - 1,
                                         y: 0.5, width: d, height: d)).fill()
        }
        composed.unlockFocus()
        composed.isTemplate = false
        button.image = composed
    }

    /// Redraw the status-bar icon with an optional badge (red dot for
    /// 1-9, "9+" for larger). Keeps the underlying template icon
    /// intact so light/dark mode inversion still works.
    private func applyAgentBadge(count: Int) {
        guard let button = statusItem?.button, let base = baseStatusIcon else { return }
        if count <= 0 {
            button.image = base
            button.image?.isTemplate = true
            return
        }
        let size = base.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        // Draw the base icon as template so system inversion kicks in.
        base.draw(in: NSRect(origin: .zero, size: size))
        // Red dot in the top-right corner. Not template — it stays red
        // regardless of menubar color mode (matches macOS mail badge).
        let dotDiameter: CGFloat = 6
        let dotRect = NSRect(
            x: size.width - dotDiameter,
            y: size.height - dotDiameter,
            width: dotDiameter,
            height: dotDiameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        composed.unlockFocus()
        composed.isTemplate = false  // Preserve red fill.
        button.image = composed
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemContextMenu(from: sender)
            return
        }

        togglePanelVisibility()
    }

    private func togglePanelVisibility() {
        if let panel, panel.isVisible {
            if isPanelPinned {
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            } else {
                hidePanel()
            }
        } else {
            showMainInterfacePanel()
        }
    }

    private func showStatusItemContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let quickItem = NSMenuItem(
            title: "Quick Ask OpenClicky",
            action: #selector(quickAskOpenClickyFromStatusMenu),
            keyEquivalent: ""
        )
        quickItem.target = self
        menu.addItem(quickItem)

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsFromStatusMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        addScreenHistoryQuickControls(to: menu)
        menu.addItem(.separator())
        menu.addItem(agentHistoryMenuItem())

        menu.popUp(positioning: quickItem, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func addScreenHistoryQuickControls(to menu: NSMenu) {
        // Header shows the master state ("Screen History · ON/OFF").
        let masterOn = ScreenHistoryState.shared.isEnabled
        let masterHeader = NSMenuItem(
            title: "Screen History · " + (masterOn ? "ON" : "OFF"),
            action: nil, keyEquivalent: "")
        masterHeader.isEnabled = false
        menu.addItem(masterHeader)

        // Read the same UserDefaults keys the Settings page writes,
        // so menu bar and settings pane stay in sync. Screen capture
        // defaults to true when unset (matches @AppStorage default),
        // audio defaults to false.
        let ud = UserDefaults.standard
        let videoOn: Bool = ud.object(forKey: "openclicky.screenHistory.capture.screen") == nil
            ? true
            : ud.bool(forKey: "openclicky.screenHistory.capture.screen")
        // FIX(ui-2026-07-31): split "Record audio" into microphone
        // and system-audio switches. Users need to separately opt into
        // the microphone (privacy-sensitive) vs system audio (video/
        // meeting playback). The unified switch mixed the two.
        let micOn = ud.bool(forKey: "openclicky.screenHistory.capture.mic")
        let sysAudioOn = ud.bool(forKey: "openclicky.screenHistory.capture.systemAudio")
        menu.addItem(makeToggleMenuItem(
            title: "Record video",
            isOn: videoOn,
            action: #selector(toggleScreenHistoryVideo)))
        // FIX(mic-menu-restored-2026-08-04): restored "Record
        // microphone" now that whisper.cpp is on 1.9.1 with the
        // large-v3-turbo-q5_0 model + auto language detection.
        // The old failure mode ("buffers arrive silent, Whisper
        // hallucinates on <0.05 RMS clips") was caused by (a) the
        // ABI-mismatched libwhisper crashing, (b) hard-coded
        // `language="zh"` making zh→en drift into YouTube subtitle
        // template hallucinations. Both fixed in Tasks #259 and #260.
        menu.addItem(makeToggleMenuItem(
            title: "Record microphone",
            isOn: micOn,
            action: #selector(toggleScreenHistoryMic)))
        menu.addItem(makeToggleMenuItem(
            title: "Record system audio",
            isOn: sysAudioOn,
            action: #selector(toggleScreenHistorySystemAudio)))

        // Vault size — actually measure the vault dir even before
        // capture kicks in. `ScreenHistoryState.vaultBytes` only
        // updates while capture is running; fall back to a direct
        // du of the vault root when off.
        let bytes = liveVaultSize()
        let sizeText = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: bytes,
                                         countStyle: .file)
            : "empty"
        let storage = NSMenuItem(
            title: "Vault: \(sizeText)",
            action: nil, keyEquivalent: "")
        storage.isEnabled = false
        menu.addItem(storage)
    }

    /// Cached vault-size measurement. Menu-bar dropdown reads this
    /// value synchronously so opening the menu is instant; a 30-s
    /// background timer keeps it fresh. `du`-style enumeration on
    /// the main thread stalled the click by ~200 ms on GB-scale
    /// vaults — unacceptable for a menu open.
    private var cachedVaultBytes: Int64 = 0
    private var vaultSizeRefreshTimer: Timer?

    private func liveVaultSize() -> Int64 {
        startVaultSizeRefreshIfNeeded()
        return cachedVaultBytes
    }

    private func startVaultSizeRefreshIfNeeded() {
        guard vaultSizeRefreshTimer == nil else { return }
        // FIX(perf-2026-08-01): 30 s vault-size walk enumerates every
        // file in ~/Library/.../OpenClicky/rewind on a utility queue —
        // fine per-tick, but the tick fires every 30 s forever whether
        // the user ever opens the menu or not. Widen to 5 min for
        // steady-state; on-demand refresh happens whenever the panel
        // actually shows via `NSMenuDelegate.menuWillOpen`. Cuts disk
        // walk 10× at rest.
        recomputeVaultSizeInBackground()
        vaultSizeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300,
                                                      repeats: true) { [weak self] _ in
            self?.recomputeVaultSizeInBackground()
        }
    }

    private func recomputeVaultSizeInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first?.appendingPathComponent("OpenClicky/rewind", isDirectory: true)
            guard let root,
                  let en = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles])
            else { return }
            var total: Int64 = 0
            for case let f as URL in en {
                if let s = try? f.resourceValues(
                        forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(s)
                }
            }
            DispatchQueue.main.async { self?.cachedVaultBytes = total }
        }
    }

    /// Rewind-style toggle menu item — NSMenuItem hosting a SwiftUI
    /// Toggle. Users see a real on/off switch, not a plain text row.
    /// Ported from Rewind's `MenuItemToggleHostingView` (IDA
    /// _TtC6Rewind25MenuItemToggleHostingView). Menu closes when the
    /// user clicks the toggle so the state visibly changes on next
    /// open — matches Rewind's own UX.
    private func makeToggleMenuItem(title: String,
                                     isOn: Bool,
                                     action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let host = NSHostingView(rootView: MenuBarToggleRow(
            title: title,
            isOn: isOn,
            onToggle: { [weak self] in
                _ = self?.perform(action)
            }))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        it.view = host
        return it
    }

    @objc private func toggleScreenHistoryVideo() {
        // Same key the Screen History Settings page's "Capture screen"
        // checkbox writes. Flipping either one moves the other — no
        // desync between menu bar and settings pane.
        let key = "openclicky.screenHistory.capture.screen"
        let cur = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(!cur, forKey: key)
    }

    @objc private func toggleScreenHistoryMic() {
        // FIX(ui-2026-07-31): microphone toggle is independent from
        // system-audio. Same key the Settings page writes.
        let key = "openclicky.screenHistory.capture.mic"
        let cur = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(!cur, forKey: key)
    }

    @objc private func toggleScreenHistorySystemAudio() {
        // FIX(ui-2026-07-31): system audio (video / meeting playback)
        // toggle, separate from the microphone.
        let key = "openclicky.screenHistory.capture.systemAudio"
        let cur = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(!cur, forKey: key)
    }

    private func agentHistoryMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: "Task History", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Task History")
        let sessions = companionManager.codexAgentSessions.reversed()

        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No tasks yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: historyTitle(for: session),
                    action: #selector(openHistorySessionFromStatusMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                submenu.addItem(item)
            }
        }

        historyItem.submenu = submenu
        return historyItem
    }

    private func historyTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Untitled task" : title
        return "\(statusLabel(for: session.status)) · \(fallbackTitle)"
    }

    private func statusLabel(for status: CodexAgentSessionStatus) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .ready: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    @objc private func quickAskOpenClickyFromStatusMenu() {
        companionManager.showQuickTextInputFromMenuBar()
    }

    @objc private func openSettingsFromStatusMenu() {
        companionManager.showSettingsWindow()
    }

    @objc private func openHistorySessionFromStatusMenu(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        companionManager.selectCodexAgentSession(sessionID)
        companionManager.showCodexHUD()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        showMainInterfacePanel()
    }

    private func showMainInterfacePanel() {
        hidePanel()
        companionManager.notchCaptureWindowManager.showMainInterfacePanel(companionManager: companionManager)
    }

    private func showLegacyStatusItemPanel() {
        let isCreatingPanel = panel == nil
        if panel == nil {
            createPanel()
        }

        if !isPanelPinned {
            positionPanelBelowStatusItem(allowFittingSize: !isCreatingPanel)
        } else {
            enforcePanelMinimumSize()
        }

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        if let p = panel {
            HeyClickyLog.log(
                "openclicky.window.installed.menu_bar_panel",
                lane: "system",
                direction: "internal",
                [
                    "window_num": p.windowNumber,
                    "size_w": Int(p.frame.width),
                    "size_h": Int(p.frame.height),
                    "level": p.level.rawValue,
                    "alpha": Double(p.alphaValue),
                    "purpose": "legacy_status_item_panel",
                ]
            )
        }
        installClickOutsideMonitor()

        if isCreatingPanel {
            resizeVisiblePanelToCurrentContent(after: 0.08)
        }
    }

    private func hidePanel() {
        let windowNum = panel?.windowNumber ?? 0
        panel?.orderOut(nil)
        HeyClickyLog.log(
            "openclicky.window.dismissed.menu_bar_panel",
            lane: "system",
            direction: "internal",
            [
                "window_num": windowNum,
                "reason": "hidePanel",
            ]
        )
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let notchPanelView = OpenClickyNotchPanelView(
            companionManager: companionManager,
            isPanelPinned: isPanelPinned,
            setPanelPinned: { [weak self] isPinned in
                self?.setPanelPinned(isPinned)
            }
        )
        .frame(
            minWidth: panelWidth,
            maxWidth: .infinity,
            alignment: .topLeading
        )

        let hostingView = NSHostingView(rootView: notchPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        OpenClickyWindowLevels.applyPanelDialogLevel(to: menuBarPanel)
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.isReleasedWhenClosed = false
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = true
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true
        applyPanelMinimumSize(to: menuBarPanel)

        let containerView = OpenClickyGlassContainerView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = .clear

        let backdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: 28)
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.width, .height]
        glassBackdrop = backdrop
        containerView.addSubview(backdrop)

        hostingView.frame = containerView.bounds
        containerView.addSubview(hostingView)

        menuBarPanel.contentView = containerView
        panel = menuBarPanel
        applyPinnedPanelBehavior()
        refreshThemeAppearance()
        refreshGlassBackdropAccent()
    }

    /// Debounces theme refreshes fired by UserDefaults.didChange. See
    /// perf audit #334 P0-2. Trailing edge: last write within a 500 ms
    /// window wins.
    private var pendingThemeRefresh: DispatchWorkItem?
    private func scheduleThemeRefresh() {
        pendingThemeRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshThemeAppearance()
            self.refreshGlassBackdropAccent()
        }
        pendingThemeRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func refreshGlassBackdropAccent() {
        glassBackdrop?.configure(
            cornerRadius: 28,
            roundsTopCorners: true,
            accentColor: OpenClickyNotchCaptureWindowManager.nsAccentColor(for: nil),
            strength: .expanded
        )
    }

    private func refreshThemeAppearance() {
        let theme = ClickyTheme.current
        let appearanceName: NSAppearance.Name?
        switch theme {
        case .system:
            appearanceName = nil
        case .light:
            appearanceName = .aqua
        case .dark:
            appearanceName = .darkAqua
        }
        
        if let appearanceName = appearanceName {
            panel?.appearance = NSAppearance(named: appearanceName)
        } else {
            panel?.appearance = nil
        }
    }

    private func positionPanelBelowStatusItem(allowFittingSize: Bool = true) {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? statusItemFrame
        let maximumPanelWidth = max(
            panelMinimumSize.width,
            visibleFrame.width - (transientPanelScreenEdgePadding * 2)
        )
        let availablePanelHeight = max(
            panelMinimumSize.height,
            statusItemFrame.minY - visibleFrame.minY - gapBelowMenuBar - transientPanelScreenEdgePadding
        )
        let maximumPanelHeight = min(availablePanelHeight, transientPanelMaximumContentHeight)

        let actualPanelHeight = preferredPanelHeight(
            maximumPanelHeight: maximumPanelHeight,
            allowFittingSize: allowFittingSize
        )

        // Horizontally center the panel beneath the status item icon
        let currentPanelWidth = max(panel.frame.width, panelWidth)
        let actualPanelWidth = min(currentPanelWidth, maximumPanelWidth)
        let centeredPanelOriginX = statusItemFrame.midX - (actualPanelWidth / 2)
        let panelOriginX = min(
            max(centeredPanelOriginX, visibleFrame.minX + transientPanelScreenEdgePadding),
            visibleFrame.maxX - actualPanelWidth - transientPanelScreenEdgePadding
        )
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: actualPanelWidth, height: actualPanelHeight),
            display: true
        )
    }

    private func resizeVisiblePanelToCurrentContent() {
        resizeVisiblePanelToCurrentContent(after: 0.03)
    }

    private func resizeVisiblePanelToCurrentContent(after delay: TimeInterval) {
        guard let panel, panel.isVisible else { return }

        contentResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if self.isPanelPinned {
                self.resizePinnedPanelToCurrentContent()
            } else {
                self.positionPanelBelowStatusItem()
            }
        }
        contentResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func preferredPanelHeight(maximumPanelHeight: CGFloat, allowFittingSize: Bool = true) -> CGFloat {
        if allowFittingSize,
           let panel,
           let contentView = panel.contentView {
            contentView.needsLayout = true
            contentView.invalidateIntrinsicContentSize()
            let fittingHeight = ceil(contentView.fittingSize.height)
            if fittingHeight.isFinite, fittingHeight > 0 {
                return min(max(panelMinimumSize.height, fittingHeight), maximumPanelHeight)
            }
        }

        return min(max(panelMinimumSize.height, panelHeight), maximumPanelHeight)
    }

    private func resizePinnedPanelToCurrentContent() {
        guard let panel else { return }
        guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let maximumPanelWidth = max(panelMinimumSize.width, visibleFrame.width - (transientPanelScreenEdgePadding * 2))
        let maximumPanelHeight = min(
            max(panelMinimumSize.height, visibleFrame.height - (transientPanelScreenEdgePadding * 2)),
            transientPanelMaximumContentHeight
        )
        let constrainedWidth = min(panel.frame.width, maximumPanelWidth)
        let constrainedHeight = preferredPanelHeight(maximumPanelHeight: maximumPanelHeight)

        guard constrainedWidth != panel.frame.width || constrainedHeight != panel.frame.height else { return }

        let topY = panel.frame.maxY
        let constrainedOriginX = min(
            max(panel.frame.origin.x, visibleFrame.minX + transientPanelScreenEdgePadding),
            visibleFrame.maxX - constrainedWidth - transientPanelScreenEdgePadding
        )
        let constrainedOriginY = min(
            max(topY - constrainedHeight, visibleFrame.minY + transientPanelScreenEdgePadding),
            visibleFrame.maxY - constrainedHeight - transientPanelScreenEdgePadding
        )

        panel.setFrame(
            NSRect(x: constrainedOriginX, y: constrainedOriginY, width: constrainedWidth, height: constrainedHeight),
            display: true
        )
    }

    private func applyPanelMinimumSize(to panel: NSPanel) {
        panel.minSize = panelMinimumSize
        panel.contentMinSize = panelMinimumSize
    }

    private func enforcePanelMinimumSize() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let constrainedWidth = max(currentFrame.width, panelMinimumSize.width)
        let constrainedHeight = max(currentFrame.height, panelMinimumSize.height)

        guard constrainedWidth != currentFrame.width || constrainedHeight != currentFrame.height else { return }

        panel.setFrame(
            NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.maxY - constrainedHeight,
                width: constrainedWidth,
                height: constrainedHeight
            ),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        guard !isPanelPinned else { return }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func setPanelPinned(_ isPinned: Bool) {
        guard isPanelPinned != isPinned else { return }
        isPanelPinned = isPinned
        applyPinnedPanelBehavior()

        guard let panel else { return }
        if isPinned {
            removeClickOutsideMonitor()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        } else {
            positionPanelBelowStatusItem()
            if panel.isVisible {
                installClickOutsideMonitor()
            }
        }
    }

    private func applyPinnedPanelBehavior() {
        guard let panel else { return }

        // Keep the panel visually consistent (floating + no title bar) in both
        // pinned and transient modes. Pinning now only controls auto-dismiss.
        // It still needs the shared dialog level so menu-bar overlays stay
        // above the main panel instead of tucking underneath it.
        panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        OpenClickyWindowLevels.applyPanelDialogLevel(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyPanelMinimumSize(to: panel)

        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        enforcePanelMinimumSize()
    }
}

// MARK: - Agent Menu Bar Status Items

@MainActor
final class AgentMenuBarStatusManager: NSObject {
    private var statusItemsByItemID: [UUID: NSStatusItem] = [:]
    private var latestItemsByID: [UUID: ClickyAgentDockItem] = [:]
    private var syncTask: Task<Void, Never>?
    private var activePopover: NSPopover?
    private weak var companionManager: CompanionManager?

    func scheduleSync(companionManager: CompanionManager) {
        syncTask?.cancel()
        syncTask = Task { [weak companionManager, weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run {
                guard let self, let companionManager else { return }
                self.sync(companionManager: companionManager)
            }
        }
    }

    func sync(companionManager: CompanionManager) {
        self.companionManager = companionManager
        let visibleItems = menuBarItems(from: companionManager)
        latestItemsByID = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.id, $0) })

        // Consolidate: default to a single-icon UX (macOS convention —
        // one app owns one status item, agent state lives in its
        // dropdown submenu). Users who preferred the per-agent
        // icons can flip this UserDefault back on.
        let showPerAgent = UserDefaults.standard.bool(
            forKey: "openclicky.menuBar.perAgentIcons")
        if !showPerAgent {
            for (_, statusItem) in statusItemsByItemID {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItemsByItemID.removeAll()
            return
        }

        let visibleIDs = Set(visibleItems.map(\.id))
        let staleIDs = statusItemsByItemID.keys.filter { !visibleIDs.contains($0) }
        for itemID in staleIDs {
            if let statusItem = statusItemsByItemID.removeValue(forKey: itemID) {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }

        for item in visibleItems {
            let statusItem = statusItemsByItemID[item.id] ?? makeStatusItem(for: item)
            statusItemsByItemID[item.id] = statusItem
            update(statusItem: statusItem, with: item)
        }
    }

    private func menuBarItems(from companionManager: CompanionManager) -> [ClickyAgentDockItem] {
        var dockItemsBySessionID: [UUID: ClickyAgentDockItem] = [:]
        for item in companionManager.agentDockItems {
            if let sessionID = item.sessionID {
                dockItemsBySessionID[sessionID] = item
            }
        }

        let sessionItems = companionManager.codexAgentSessions
            .filter { session in
                session.hasVisibleActivity && !companionManager.archivedSessionIDs.contains(session.id)
            }
            .map { session -> ClickyAgentDockItem in
                if let existingItem = dockItemsBySessionID[session.id] {
                    return existingItem
                }

                return ClickyAgentDockItem(
                    id: session.id,
                    sessionID: session.id,
                    title: session.title,
                    userInstruction: session.title,
                    accentTheme: session.accentTheme,
                    status: Self.dockStatus(for: session.status),
                    progressStageLabel: session.progressStage.label,
                    progressStepText: session.latestActivityDisplaySummary ?? session.latestActivitySummary,
                    activityStatusLines: session.activityStatusLines,
                    caption: session.latestActivityDisplaySummary ?? session.latestActivitySummary,
                    suggestedNextActions: session.latestResponseCard?.suggestedNextActions ?? [],
                    createdAt: session.createdAt
                )
            }

        let unsessionedItems = companionManager.agentDockItems.filter { $0.sessionID == nil }
        let combinedItems = (sessionItems + unsessionedItems)
            .sorted { $0.createdAt < $1.createdAt }

        return Array(combinedItems.suffix(5))
    }

    private static func dockStatus(for status: CodexAgentSessionStatus) -> ClickyAgentDockStatus {
        switch status {
        case .starting:
            return .starting
        case .running:
            return .running
        case .ready:
            return .done
        case .stopped, .failed:
            return .failed
        }
    }

    private func makeStatusItem(for item: ClickyAgentDockItem) -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            button.target = self
            button.action = #selector(agentStatusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        return statusItem
    }

    private func update(statusItem: NSStatusItem, with item: ClickyAgentDockItem) {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip(for: item)
        button.image = makeAgentStatusIcon(theme: item.accentTheme, status: item.status)
        button.image?.isTemplate = false
        installDropTarget(on: button, itemID: item.id)
    }

    @objc private func agentStatusItemClicked(_ sender: NSStatusBarButton) {
        guard let rawID = sender.identifier?.rawValue,
              let itemID = UUID(uuidString: rawID),
              let item = latestItemsByID[itemID] else { return }

        handleAgentStatusItemClick(item: item, from: sender, isRightClick: NSApp.currentEvent?.type == .rightMouseUp)
    }

    private func handleAgentStatusItemClick(item: ClickyAgentDockItem, from sender: NSStatusBarButton, isRightClick: Bool) {
        let itemID = item.id

        if isRightClick {
            showAgentContextMenu(for: item, from: sender)
            return
        }

        if let activePopover, activePopover.isShown {
            activePopover.performClose(nil)
            if activePopover.contentViewController?.representedObject as? UUID == itemID {
                return
            }
        }

        guard let companionManager else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let rootView = ClickyAgentDockHoverCard(
            item: item,
            canOpenDashboard: companionManager.isAdvancedModeEnabled,
            chat: { [weak self, weak companionManager] in
                self?.openMenuBarAgent(item, companionManager: companionManager)
            },
            text: { [weak self, weak companionManager] in
                self?.openMenuBarAgentTextFollowUp(item, companionManager: companionManager)
            },
            voice: { [weak companionManager] in
                companionManager?.prepareVoiceFollowUpForAgentDockItem(item.id)
            },
            mini: { [weak companionManager, weak popover] in
                popover?.performClose(nil)
                companionManager?.openMiniChatForAgentDockItem(item.id)
            },
            close: { [weak popover] in
                popover?.performClose(nil)
            },
            stop: { [weak self, weak companionManager, weak popover] in
                popover?.performClose(nil)
                self?.stopMenuBarAgent(item, companionManager: companionManager)
            },
            dismiss: { [weak self, weak companionManager, weak popover] in
                // Close == dismiss the finished item: hide the popover
                // and remove the dock entry. dismissAgentDockItem is
                // UI-only — it does NOT send a cancel signal (the agent
                // is already terminal here).
                popover?.performClose(nil)
                self?.dismissMenuBarAgent(item, companionManager: companionManager)
            },
            runSuggestedAction: { [weak companionManager, weak popover] actionTitle in
                popover?.performClose(nil)
                companionManager?.runSuggestedNextAction(actionTitle, forAgentDockItem: item.id)
            }
        )
        let controller = NSHostingController(rootView: rootView)
        controller.representedObject = itemID
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 560, height: 360)
        activePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func openMenuBarAgent(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.openAgentDockItem(item.id)
            return
        }
        if let sessionID = item.sessionID {
            companionManager.selectCodexAgentSession(sessionID)
            companionManager.notchCaptureWindowManager.showMainInterfacePanel(
                companionManager: companionManager,
                focusedAgentSessionID: sessionID
            )
            return
        }
        companionManager.notchCaptureWindowManager.showMainInterfacePanel(companionManager: companionManager)
    }

    private func openMenuBarAgentTextFollowUp(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.showTextFollowUpForAgentDockItem(item.id)
            return
        }
        guard let sessionID = item.sessionID else { return }
        companionManager.showTextFollowUpForAgentSession(sessionID)
    }

    private func stopMenuBarAgent(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.stopAgentDockItem(item.id)
            return
        }
        if let sessionID = item.sessionID {
            companionManager.stopCodexAgentSession(sessionID, reason: "agent_menu_bar_stop")
        }
    }

    private func dismissMenuBarAgent(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        companionManager.dismissAgentDockItem(item.id)
    }

    private func installDropTarget(on button: NSStatusBarButton, itemID: UUID) {
        let targetIdentifier = NSUserInterfaceItemIdentifier("OpenClickyAgentStatusDropTarget")
        let dropTarget: AgentStatusItemDropTargetView

        if let existing = button.subviews.first(where: { $0.identifier == targetIdentifier }) as? AgentStatusItemDropTargetView {
            dropTarget = existing
        } else {
            dropTarget = AgentStatusItemDropTargetView(frame: button.bounds)
            dropTarget.identifier = targetIdentifier
            dropTarget.autoresizingMask = [.width, .height]
            button.addSubview(dropTarget)
        }

        dropTarget.frame = button.bounds
        dropTarget.configure(
            itemID: itemID,
            companionManager: companionManager,
            clickHandler: { [weak self, weak button] itemID, isRightClick in
                guard let self,
                      let button,
                      let item = self.latestItemsByID[itemID] else { return }
                self.handleAgentStatusItemClick(item: item, from: button, isRightClick: isRightClick)
            }
        )
    }

    private func showAgentContextMenu(for item: ClickyAgentDockItem, from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let quickItem = NSMenuItem(
            title: "Quick Reply",
            action: #selector(quickReplyToAgentFromMenu(_:)),
            keyEquivalent: ""
        )
        quickItem.target = self
        quickItem.representedObject = item.id
        menu.addItem(quickItem)

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsFromAgentMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(agentHistoryMenuItem())

        menu.popUp(positioning: quickItem, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func agentHistoryMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: "Task History", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Task History")
        guard let companionManager else {
            let emptyItem = NSMenuItem(title: "OpenClicky is not ready", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            historyItem.submenu = submenu
            return historyItem
        }

        let sessions = companionManager.codexAgentSessions.reversed()
        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No tasks yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: historyTitle(for: session),
                    action: #selector(openHistorySessionFromAgentMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                submenu.addItem(item)
            }
        }

        historyItem.submenu = submenu
        return historyItem
    }

    private func historyTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Untitled task" : title
        return "\(statusLabel(for: session.status)) · \(fallbackTitle)"
    }

    private func statusLabel(for status: CodexAgentSessionStatus) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .ready: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    @objc private func quickReplyToAgentFromMenu(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID else { return }
        if let item = latestItemsByID[itemID] {
            openMenuBarAgentTextFollowUp(item, companionManager: companionManager)
        } else {
            companionManager?.showTextFollowUpForAgentDockItem(itemID)
        }
    }

    @objc private func openSettingsFromAgentMenu() {
        companionManager?.showSettingsWindow()
    }

    @objc private func openHistorySessionFromAgentMenu(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        companionManager?.selectCodexAgentSession(sessionID)
        if let companionManager {
            companionManager.notchCaptureWindowManager.showMainInterfacePanel(
                companionManager: companionManager,
                focusedAgentSessionID: sessionID
            )
        }
    }

    private func tooltip(for item: ClickyAgentDockItem) -> String {
        let status: String
        switch item.status {
        case .starting: status = "Starting"
        case .running: status = "Working"
        case .done: status = "Done"
        case .failed: status = "Stopped"
        }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Agent: \(status)" : "Agent: \(status) — \(title)"
    }

    private func makeAgentStatusIcon(theme: ClickyAccentTheme, status: ClickyAgentDockStatus) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let accent = Self.nsColor(for: theme)
        let center = CGPoint(x: size * 0.48, y: size * 0.50)

        let triangleSize = size * 0.55
        let height = triangleSize * sqrt(3.0) / 2.0
        let top = CGPoint(x: center.x, y: center.y + height / 1.5)
        let bottomLeft = CGPoint(x: center.x - triangleSize / 2, y: center.y - height / 3)
        let bottomRight = CGPoint(x: center.x + triangleSize / 2, y: center.y - height / 3)
        let angle = -35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: center.x + cosA * dx - sinA * dy, y: center.y + sinA * dx + cosA * dy)
        }
        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()
        accent.setFill()
        path.fill()

        let dotColor: NSColor
        switch status {
        case .starting: dotColor = NSColor.systemBlue
        case .running: dotColor = accent
        case .done: dotColor = NSColor.systemGreen
        case .failed: dotColor = NSColor.systemRed
        }
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: size - 6.2, y: size - 6.2, width: 5.4, height: 5.4)).fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let dotStroke = NSBezierPath(ovalIn: NSRect(x: size - 6.2, y: size - 6.2, width: 5.4, height: 5.4))
        dotStroke.lineWidth = 0.7
        dotStroke.stroke()

        image.unlockFocus()
        return image
    }

    private static func nsColor(for theme: ClickyAccentTheme) -> NSColor {
        switch theme {
        case .blue: return NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1)
        case .mint: return NSColor(calibratedRed: 0.21, green: 0.83, blue: 0.60, alpha: 1)
        case .amber: return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1)
        case .rose: return NSColor(calibratedRed: 1.00, green: 0.31, blue: 0.37, alpha: 1)
        case .white: return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .cyan:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .lime:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .orange:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .violet:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        }
    }
}

private final class AgentStatusItemDropTargetView: NSView {
    private var itemID: UUID?
    private weak var companionManager: CompanionManager?
    private var clickHandler: ((UUID, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL])
    }

    func configure(
        itemID: UUID,
        companionManager: CompanionManager?,
        clickHandler: @escaping (UUID, Bool) -> Void
    ) {
        self.itemID = itemID
        self.companionManager = companionManager
        self.clickHandler = clickHandler
    }

    override func mouseUp(with event: NSEvent) {
        guard let itemID else { return }
        clickHandler?(itemID, false)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let itemID else { return }
        clickHandler?(itemID, true)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let itemID else { return false }
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        companionManager?.attachDroppedAgentFiles(urls, toAgentDockItem: itemID, source: "agent_menu_avatar_drop")
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map(\.standardizedFileURL)
        }

        let filenames = pasteboard.propertyList(forType: .fileURL) as? [String] ?? []
        return filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

/// Menu-bar row with a real SwiftUI Toggle — mirrors Rewind's
/// `MenuItemToggleHostingView`. Sized to match Apple's own menu row
/// padding (~28 pt height, 14 pt side inset), so it feels native
/// alongside plain NSMenuItems below it.
struct MenuBarToggleRow: View {
    let title: String
    @State var isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isOn) { _, _ in onToggle() }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
    }
}
