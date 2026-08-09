//
//  SKIModeHotkeyMonitor.swift
//  cursor-buddy
//
//  Global CGEvent tap for the SKI-parity hotkeys. Mirrors what
//  ~/.ski/settings.json exposes under `hotkeys`:
//
//    - next_project   (Ctrl+Shift+D)  cycle pinned workspace
//    - toggle_silent  (Ctrl+Shift+V)  mute TTS playback (bubble still visible)
//    - capture_screen (Ctrl+Shift+S)  proactively snapshot main display
//    - toggle_widget  (unbound)       hide / show the notch entirely
//
//  Only active when the SKI Mode profile is selected.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// UserDefaults keys for SKI hotkey bindings. Top-level (not nested
/// inside the @MainActor monitor class) so the CGEvent thread can read
/// them without actor hopping.
enum SKIModeHotkeyKeys {
    static let nextProject   = "openclicky.ski.hotkey.next_project"
    static let toggleSilent  = "openclicky.ski.hotkey.toggle_silent"
    static let captureScreen = "openclicky.ski.hotkey.capture_screen"
    static let toggleWidget  = "openclicky.ski.hotkey.toggle_widget"
    /// Reply-muted state (persisted across launches).
    static let isSilent      = "openclicky.ski.replyMuted"
}

@MainActor
final class SKIModeHotkeyMonitor {
    static let shared = SKIModeHotkeyMonitor()

    /// Backwards-compatible alias so existing code paths that referred
    /// to `SKIModeHotkeyMonitor.Keys.*` keep compiling.
    typealias Keys = SKIModeHotkeyKeys

    /// Serialised as "modifiers:keycode" — modifiers is the union of
    /// CGEventFlags rawValues we care about (masked to shift/ctrl/opt/cmd);
    /// keycode is CGKeyCode.
    nonisolated static let defaults: [String: String] = [
        SKIModeHotkeyKeys.nextProject:   "\(CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue):2",  // Ctrl+Shift+D
        SKIModeHotkeyKeys.toggleSilent:  "\(CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue):9",  // Ctrl+Shift+V
        SKIModeHotkeyKeys.captureScreen: "\(CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue):1",  // Ctrl+Shift+S
        SKIModeHotkeyKeys.toggleWidget:  ""                                                                            // unbound
    ]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFire: [String: Date] = [:]

    private init() {
        // Seed defaults exactly once.
        for (key, value) in Self.defaults {
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    func start() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SKIModeHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type != .keyDown {
                    return Unmanaged.passUnretained(event)
                }
                let handled = monitor.handleKeyDown(event: event)
                return handled ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )
        guard let tap = tap else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.hotkey_tap_failed",
                fields: ["reason": "tapCreate returned nil (Accessibility permission?)"]
            )
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = src
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.ski.hotkey_tap_started",
            fields: [:]
        )
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
    }

    /// Runs on the CGEvent thread. Return true to swallow the event.
    nonisolated private func handleKeyDown(event: CGEvent) -> Bool {
        guard OpenClickyProfileCatalog.activeProfile().id == "ski_mode" else { return false }
        let flags = event.flags.rawValue & (
            CGEventFlags.maskShift.rawValue |
            CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskCommand.rawValue
        )
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let signature = "\(flags):\(keycode)"

        for (key, action) in [
            (SKIModeHotkeyKeys.nextProject,   Action.nextProject),
            (SKIModeHotkeyKeys.toggleSilent,  Action.toggleSilent),
            (SKIModeHotkeyKeys.captureScreen, Action.captureScreen),
            (SKIModeHotkeyKeys.toggleWidget,  Action.toggleWidget),
        ] {
            let value = UserDefaults.standard.string(forKey: key) ?? ""
            guard !value.isEmpty, value == signature else { continue }
            let repeatKey = key
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let now = Date()
                if let last = self.lastFire[repeatKey], now.timeIntervalSince(last) < 0.4 { return }
                self.lastFire[repeatKey] = now
                self.dispatchAction(action)
            }
            return true
        }
        return false
    }

    private enum Action {
        case nextProject
        case toggleSilent
        case captureScreen
        case toggleWidget
    }

    private func dispatchAction(_ action: Action) {
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.ski.hotkey_fired",
            fields: ["action": "\(action)"]
        )
        switch action {
        case .nextProject:
            cyclePinnedProject()
        case .toggleSilent:
            let cur = UserDefaults.standard.bool(forKey: SKIModeHotkeyKeys.isSilent)
            UserDefaults.standard.set(!cur, forKey: SKIModeHotkeyKeys.isSilent)
        case .captureScreen:
            triggerScreenCaptureForActiveWorkspace()
        case .toggleWidget:
            NotificationCenter.default.post(
                name: Notification.Name("com.openclicky.ski.toggleWidgetVisibility"),
                object: nil
            )
        }
    }

    /// Cycle through the presence-store's connected agents. Wraps around;
    /// setting nil = auto-follow-focused.
    private func cyclePinnedProject() {
        let presence = OpenClickyAgentsPresenceStore.shared
        let roots = presence.connected.map { $0.projectRoot }
        guard !roots.isEmpty else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.next_project_no_connected",
                fields: [:]
            )
            return
        }
        let current = presence.pinnedActiveProjectRoot
        let next: String?
        if let cur = current, let idx = roots.firstIndex(of: cur) {
            if idx + 1 >= roots.count {
                next = nil // wrap to auto
            } else {
                next = roots[idx + 1]
            }
        } else {
            next = roots.first
        }
        presence.setPinnedActiveProject(next)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.ski.next_project_cycled",
            fields: ["to": next ?? "auto"]
        )
    }

    /// Ask OpenClicky to grab the main display, drop it inside the
    /// active workspace's `.oc/screenshots/`, and append a
    /// `screen.captured` event to `events.jsonl`.
    private func triggerScreenCaptureForActiveWorkspace() {
        NotificationCenter.default.post(
            name: Notification.Name("com.openclicky.ski.captureScreenRequested"),
            object: nil
        )
    }
}
