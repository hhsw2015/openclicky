//
//  ScreenHistoryWindowManager.swift
//  cursor-buddy
//
//  Hosts OpenRewind Browser's full-screen TimelineImmersiveView via
//  the upstream AppCustomWindow / AppCustomWindowController pattern —
//  borderless, full-screen, dock+menubar auto-hidden. Matches how
//  OpenRewind ships the timeline standalone.
//

import AppKit
import SwiftUI

@MainActor
public final class ScreenHistoryWindowManager: NSObject {

    public static let shared = ScreenHistoryWindowManager()

    private var controller: AppCustomWindowController?
    private var appState: AppState?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: .screenHistoryOpenSearch,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
        NotificationCenter.default.addObserver(
            forName: .screenHistoryJumpToDate,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let date = note.userInfo?["date"] as? Date else { return }
            Task { @MainActor in
                self?.show()
                self?.appState?.seek(to: date)
            }
        }
        // FIX(regression-2026-07-30): removed didResignActive auto-mark.
        // Any time the user Cmd-Tab'd away, we treated it as "interacted"
        // and refused to jumpToLatest on next show — result: reopening
        // Timeline showed a stale frame instead of "now". Interaction
        // tracking is now driven only by explicit user actions inside
        // the timeline (scrub, link click, OCR copy, URL button).
    }

    public func show() {
        if let c = controller {
            // FIX(preserve-playhead-2026-07-30): if the user had
            // interacted with the current frame (clicked a link,
            // copied text, scrubbed) since the last show, keep the
            // playhead where it is so they can continue the flow
            // (e.g. click more links on the same captured page).
            // If they did not interact, jump to the newest frame
            // since they're clearly done with old context.
            let preserve = appState?.hasInteractedSinceShow == true
            // FIX(fresh-frames-on-reveal-2026-07-30 v2): reopen +
            // reload BEFORE showing the window and BEFORE
            // jumpToLatest. Previous async version let the window
            // paint the stale playhead before the reload completed
            // → user reported "打开 Timeline 前面看不到最新帧". A
            // sync reopen blocks main for ~300ms on a 200MB vault,
            // which is acceptable at click-to-show time (user is
            // actively summoning the UI).
            if !preserve, let bridge = OpenRewindBridge.shared {
                try? bridge.reopenReader()
                appState?.reloadEntries()
                appState?.jumpToLatest()
            }
            NSApp.activate(ignoringOtherApps: true)
            c.show()
            // Either way, arm a fresh interaction window for THIS
            // show cycle. jumpToLatest already resets it; the manual
            // reset here covers the preserve branch so the *next*
            // re-show is decided by *this* session's interactions.
            appState?.hasInteractedSinceShow = false
            return
        }
        // Pre-complete onboarding so the guided flow never opens when
        // we present the timeline from within OpenClicky. Users have
        // already onboarded via OpenClicky's own permission flow.
        UserDefaults.standard.set(true,
                                  forKey: "openrewind.onboarding.completed")
        // Make sure AppState's `OpenRewindStorage.openRewindDefault`
        // resolves to the OpenClicky vault (`~/Library/Application
        // Support/OpenClicky/rewind`) — same one the bridge writes
        // into. Otherwise AppState would open the standalone
        // OpenRewind vault and show stale data.
        OpenRewindStorage.defaultAppSupportName = "OpenClicky/rewind"

        let state = AppState()
        state.hotkeyProvider = NullHotkeyProvider()
        // Wire the Ask panel to OpenClicky's AI backend. Without this
        // the timeline's built-in chat shows "No model" and refuses.
        // Provider routes through ScreenHistoryAIProvider → HeyClicky
        // Free / Claude / OpenAI (user's Settings choice) — same path
        // the AskRewind pipeline uses.
        state.setAIProvider(OpenClickyRewindAIProvider())
        state.boot()
        // Mirror standalone OpenRewind main.swift: register the state
        // globally so any Browser view that reads `AppStateHolder.current`
        // finds it. Some views also look at NSApp.windows to detect
        // key visibility — that's covered by AppCustomWindow itself.
        AppStateHolder.current = state
        appState = state

        let c = AppCustomWindowController(appState: state)
        NSApp.activate(ignoringOtherApps: true)
        c.show()
        // AppCustomWindow.show() sets `[.hideDock, .autoHideMenuBar]`.
        // Revert on the NEXT runloop tick — doing it in-line inside
        // this stack has crashed inside MenuBarClientCore's SerialExecutor
        // callback. Deferring lets the system finish the presentation
        // apply, then we clear it safely.
        DispatchQueue.main.async {
            NSApp.presentationOptions = []
        }
        state.jumpToLatest()
        controller = c
    }

    public func hide() {
        controller?.teardown()
        controller?.window.orderOut(nil)
        // Restore menu bar + dock so OpenClicky's own status item is
        // visible again. AppCustomWindow.show() sets .hideDock +
        // .autoHideMenuBar which sticks until we clear it explicitly.
        NSApp.presentationOptions = []
    }

    /// Toggle: hides if visible, shows otherwise. Used by the global
    /// hotkey so a single binding pops the timeline up and down.
    public func toggle() {
        if let win = controller?.window, win.isVisible {
            hide()
        } else {
            show()
        }
    }
}
