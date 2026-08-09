//
//  cursor_buddyApp.swift
//  cursor-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import Sparkle
import OpenClickyBrowser

@main
struct cursor_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene, while the app menu command below routes to OpenClicky's full
        // custom settings dialog instead of showing this placeholder scene.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettingsWindowFromApplicationMenu()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Tools") {
                Button("Visual Intelligence…") {
                    appDelegate.showVisualIntelligenceWorkspaceFromApplicationMenu()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])

                Button("Meeting Notes…") {
                    appDelegate.showVisualIntelligenceWorkspaceFromApplicationMenu()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Divider()

                Button("Browser Workspace…") {
                    appDelegate.showBrowserWorkspaceFromApplicationMenu()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Divider()

                Button("Memory Browser…") {
                    appDelegate.showMemoryWindowFromApplicationMenu()
                }

                Button("Open Memory File") {
                    appDelegate.openMemoryFileFromApplicationMenu()
                }

                Button("Open Skills Folder") {
                    appDelegate.openSkillsFolderFromApplicationMenu()
                }

                Button("Log Viewer…") {
                    appDelegate.showLogViewerFromApplicationMenu()
                }

                Divider()

                Button("Settings…") {
                    appDelegate.showSettingsWindowFromApplicationMenu()
                }
            }
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private static let sparkleFeedOverrideDefaultsKey = "OpenClickySparkleFeedURLOverride"
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("OpenClicky: Starting...")
        print("OpenClicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        OpenClickyAgentsSocketServer.shared.start()

        // Terminate any duplicate running instances of OpenClicky to prevent port (error 48) and permission conflicts
        let currentApp = NSRunningApplication.current
        let runningApps = NSWorkspace.shared.runningApplications
        if let bundleID = currentApp.bundleIdentifier {
            let duplicateApps = runningApps.filter { app in
                app.bundleIdentifier == bundleID && app.processIdentifier != currentApp.processIdentifier
            }
            for app in duplicateApps {
                print("OpenClicky: Terminating duplicate running instance (PID: \(app.processIdentifier)) to free resources/ports.")
                app.terminate()
            }
            if !duplicateApps.isEmpty {
                // FIX(startup-perf-2026-08-01): was unconditional 300 ms
                // Thread.sleep on the main thread — a visible boot
                // hitch every launch when NO stale copy was actually
                // still running. Poll each duplicate's `.isTerminated`
                // with a 5 ms sleep, cap at 150 ms total. Users with
                // no duplicates see 0 delay.
                let deadline = Date().addingTimeInterval(0.15)
                while Date() < deadline {
                    if duplicateApps.allSatisfy({ $0.isTerminated }) { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }

        // If the real HeyClicky.app is running, defer to it: both apps
        // share the same global hotkeys (Ctrl+Option, Alt+S/L, Shift+Space)
        // and only the first CGEvent tap installer wins. Rather than fight
        // for the tap, we exit cleanly so the user can toggle which one
        // owns the machine simply by launching the other.
        let heyClickyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.humansongs.clicky"
        }
        if heyClickyRunning {
            print("OpenClicky: real HeyClicky.app is running — exiting to yield hotkeys/OAuth.")
            NSApp.terminate(nil)
            return
        }

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        AppBundleConfiguration.registerDefaults()

        // H15: prune old voice-transcript message logs on launch so the plaintext
        // PII on disk doesn't grow unbounded. Also re-prune every
        // hour so long-running instances don't accumulate a
        // full day's log before the next reboot.
        OpenClickyMessageLogStore.shared.pruneOldMessageLogs()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            OpenClickyMessageLogStore.shared.pruneOldMessageLogs()
        }

        // Layer-0 audit hook: forward every AX / AppleScript / CGEvent
        // boundary from the OpenClickyContextService package into the
        // in-process HeyClickyLog store so `curl /agent/log/tail`
        // surfaces the runtime capture trace after each hotkey press.
        OpenClickyContextServiceLogBridge.install()

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()
        OpenClickyDesktopNotificationCenter.shared.configure()

        // xlb topic index: sync once at launch, then watch the library
        // directory. `startWatchingIfEnabled()` previously had zero
        // callers and nothing else synced, so `[xlb-context]` was never
        // produced in production even with the Settings switch on —
        // lookups ran against an empty sqlite file. Both calls no-op
        // when the switch is off (AppBundleConfiguration.xlbEnabled()).
        if AppBundleConfiguration.xlbEnabled() {
            Task.detached(priority: .utility) {
                do {
                    _ = try await XLBTopicIndex.shared.syncIfNeeded()
                } catch {
                    print("OpenClicky: xlb initial sync failed — \(error.localizedDescription)")
                }
                await XLBTopicIndex.shared.startWatchingIfEnabled()
            }
        }

        // Prime the locale manager before any SwiftUI hierarchy is
        // instantiated. Idempotent; installs the bundle-swizzle once
        // and honors the persisted UI language choice.
        _ = OpenClickyLocaleManager.shared

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        companionManager.scheduleWidgetSnapshotPublish()
        reconcileLoginItemFromUserPreference()
        startSparkleUpdater()

        // UX audit #337 P0-1: on first launch (before onboarding is
        // complete), auto-open the menu-bar panel so a new user is
        // not staring at a mystery status icon with no cue. Returning
        // users see nothing new — the panel opens on click as before.
        if !companionManager.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.menuBarPanelManager?.showPanelOnLaunch()
            }
        }

        // Phase 7.5 F29 — open-connector Node subprocess. No-op unless
        // the user has opted in via Settings; failures are surfaced in
        // `OpenClickyConnectorSettings.lastError` rather than blocking
        // app launch.
        OpenClickyConnectorSettings.autostartIfEnabled()

        // Phase 7.6a F30 — OpenCLI Node subprocess. Independent of F29
        // (separate binary, port range, auth token). Same opt-in shape.
        OpenClickyOpenCLISettings.autostartIfEnabled()

        // Phase 7.6b F31 — OpenDia Node subprocess. Independent of
        // F29/F30 (own binary, port range [56000,57000), auth token).
        // Same opt-in shape; the browser extension is a user-installed
        // Chrome/Firefox extension that connects as a WS client.
        OpenClickyOpenDiaSettings.autostartIfEnabled()

        // Diagnostic snapshot of every NSWindow the app currently owns.
        // Used to hunt the "overlay stays on screen after dismiss" bug:
        // after `curl /agent/log/tail | grep openclicky.window` runs,
        // any install log without a matching dismiss log identifies the
        // culprit fullscreen surface.
        logWindowStartupSnapshot()
    }

    private func logWindowStartupSnapshot() {
        // NSApp.windows may briefly include the SwiftUI Settings scene
        // hidden proxy; that's intentional — we want the raw list.
        struct WindowRow: Encodable {
            let num: Int
            let w: Int
            let h: Int
            let level: Int
            let alpha: Double
            let title: String
            let visible: Bool
            let cls: String
        }
        let rows: [WindowRow] = NSApp.windows.map { win in
            WindowRow(
                num: win.windowNumber,
                w: Int(win.frame.width),
                h: Int(win.frame.height),
                level: win.level.rawValue,
                alpha: Double(win.alphaValue),
                title: String((win.title.isEmpty ? "" : win.title).prefix(80)),
                visible: win.isVisible,
                cls: String(describing: type(of: win))
            )
        }
        let payload: String
        if let data = try? JSONEncoder().encode(rows),
           let str = String(data: data, encoding: .utf8) {
            payload = str
        } else {
            payload = "[]"
        }
        HeyClickyLog.log(
            "openclicky.window.startup_snapshot",
            lane: "system",
            direction: "internal",
            [
                "count": rows.count,
                "windows": payload,
            ]
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        OpenClickyConnectorSubprocess.shared.stop()
        OpenClickyConnectorOAuthCallback.shared.stop()
        OpenClickyOpenCLISubprocess.shared.stop()
        OpenClickyOpenDiaSubprocess.shared.stop()
        // Free whisper.cpp contexts BEFORE AppKit calls exit(), so the
        // ggml-metal static destructor doesn't race the still-running
        // ggml_metal_rsets_init worker (SIGABRT on quit otherwise).
        WhisperCppShutdown.freeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { companionManager.handleApplicationOpenURL($0) }
    }

    func showSettingsWindowFromApplicationMenu() {
        companionManager.showSettingsWindow()
    }

    func showBrowserWorkspaceFromApplicationMenu() {
        OpenClickyBrowserWorkspaceWindowManager.shared.show(delegate: companionManager)
    }

    func showVisualIntelligenceWorkspaceFromApplicationMenu() {
        companionManager.showVisualIntelligenceWorkspace()
    }

    func showMemoryWindowFromApplicationMenu() {
        companionManager.showMemoryWindow()
    }

    func openMemoryFileFromApplicationMenu() {
        companionManager.openOpenClickyDocument(companionManager.codexHomeManager.persistentMemoryFile)
    }

    func openSkillsFolderFromApplicationMenu() {
        NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
    }

    func showLogViewerFromApplicationMenu() {
        companionManager.showLogViewerWindow()
    }

    /// UserDefaults key backing the "Launch OpenClicky at login" toggle.
    /// Absent = user has not yet decided (default OFF, we don't touch
    /// SMAppService); true = user opted in (we ensure registered);
    /// false = user opted out (we ensure unregistered).
    static let launchAtLoginDefaultsKey = "openclicky.launchAtLogin"

    /// Reconciles the SMAppService state with the user's explicit
    /// preference. Called from `applicationDidFinishLaunching` — no
    /// side effects until the user has toggled the preference.
    /// Previously the app auto-registered itself as a login item on
    /// every launch (opt-out), which surprised users. Now: strict
    /// opt-in via Settings.
    private func reconcileLoginItemFromUserPreference() {
        guard UserDefaults.standard.object(forKey: Self.launchAtLoginDefaultsKey) != nil else {
            // No decision recorded → do nothing. Do NOT touch
            // SMAppService.mainApp — leaving the previous state (which
            // for a fresh install is `.notRegistered`).
            return
        }
        let desired = UserDefaults.standard.bool(forKey: Self.launchAtLoginDefaultsKey)
        let service = SMAppService.mainApp
        do {
            if desired && service.status != .enabled {
                try service.register()
            } else if !desired && service.status == .enabled {
                try service.unregister()
            }
        } catch {
            print("OpenClicky: login-item reconcile failed: \(error)")
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.sparkleUpdaterController = updaterController

        if Self.sparkleFeedOverrideURLString() != nil {
            DispatchQueue.main.async {
                updaterController.updater.checkForUpdatesInBackground()
            }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let override = Self.sparkleFeedOverrideURLString() else { return nil }
        print("OpenClicky: Using Sparkle feed override: \(override)")
        return override
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        NSApp.activate(ignoringOtherApps: true)
        menuBarPanelManager?.showPanelOnLaunch()
    }

    private static func sparkleFeedOverrideURLString() -> String? {
        let override = UserDefaults.standard.string(forKey: sparkleFeedOverrideDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty else { return nil }
        guard let url = URL(string: override),
              ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
            print("OpenClicky: Ignoring invalid Sparkle feed override: \(override)")
            return nil
        }

        if url.scheme?.lowercased() == "http" {
            let host = url.host?.lowercased() ?? ""
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                print("OpenClicky: Ignoring non-local HTTP Sparkle feed override: \(override)")
                return nil
            }
        }

        return override
    }
}
