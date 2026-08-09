//
//  ScreenHistoryHotkeys.swift
//  cursor-buddy
//
//  Lightweight global-hotkey dispatcher for the Screen History
//  shortcuts the user configures in Settings. Uses
//  NSEvent.addGlobalMonitorForEvents / addLocalMonitorForEvents so we
//  don't need CGEventTap accessibility permission just for opening a
//  search window.
//
//  User writes a shortcut string like "⌥⌘R" (or "opt+cmd+r") in the
//  Settings text field; we parse it to (keyCode, modifierFlags) and
//  fire the matching action on match. Empty = disabled.
//
//  Reads UserDefaults live so Settings edits apply immediately.
//

import AppKit
import Combine

@MainActor
public final class ScreenHistoryHotkeys {

    public static let shared = ScreenHistoryHotkeys()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    private init() {}

    public func install() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    public func uninstall() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor  { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    private func handle(_ event: NSEvent) {
        // Read current bindings from UserDefaults on each keystroke so
        // Settings edits apply without restart. Cheap: 11 lookups.
        let shownow = matches(event, key: ScreenHistoryDefaults.hotkeyShowWindowKey)
        let openSearch = matches(event, key: ScreenHistoryDefaults.hotkeyOpenSearchKey)
        let openSettings = matches(event, key: ScreenHistoryDefaults.hotkeyOpenSettingsKey)
        let pauseToggle = matches(event, key: ScreenHistoryDefaults.hotkeyPauseKey)

        if shownow || openSearch {
            NotificationCenter.default.post(name: .screenHistoryOpenSearch, object: nil)
        }
        if openSettings {
            NotificationCenter.default.post(name: .screenHistoryOpenSettings, object: nil)
        }
        if pauseToggle {
            ScreenHistoryState.shared.isPaused.toggle()
        }
    }

    private func matches(_ event: NSEvent, key: String) -> Bool {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let combo = Self.parse(trimmed) else { return false }
        // Restrict to the modifier flags we care about (drop capsLock,
        // numericPad, function).
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let observed = event.modifierFlags.intersection(mask)
        guard observed == combo.mods else { return false }
        // Match by lowercased characters (case-insensitive letter match).
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return key == combo.key
    }

    /// Parse "⌥⌘R" / "⌥Space" / "opt+cmd+r" into (mods, key).
    public static func parse(_ raw: String) -> (mods: NSEvent.ModifierFlags, key: String)? {
        var mods: NSEvent.ModifierFlags = []
        var remaining = raw
        // Symbol form
        while let first = remaining.first {
            switch first {
            case "⌘": mods.insert(.command); remaining.removeFirst()
            case "⌥": mods.insert(.option);  remaining.removeFirst()
            case "⌃": mods.insert(.control); remaining.removeFirst()
            case "⇧": mods.insert(.shift);   remaining.removeFirst()
            default:
                let head = remaining.prefix(while: { $0 != "+" && $0 != " " })
                let token = String(head).lowercased()
                switch token {
                case "cmd", "command":  mods.insert(.command)
                case "opt", "option", "alt": mods.insert(.option)
                case "ctrl", "control": mods.insert(.control)
                case "shift":           mods.insert(.shift)
                default:
                    // Rest is the key. Normalise "space".
                    let key = token == "space" ? " " : token
                    return (mods, key)
                }
                remaining.removeFirst(head.count)
                if remaining.first == "+" || remaining.first == " " {
                    remaining.removeFirst()
                }
            }
        }
        return nil
    }
}
