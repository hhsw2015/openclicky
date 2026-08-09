//
//  MirageToolAdapter.swift
//  cursor-buddy
//
//  Translate Claude tool_use blocks (Peeky wire schemas) into OpenClicky's
//  existing runtime calls. Every dispatched tool reuses code OpenClicky
//  already ships — the adapter is a naming shim, not a reimplementation.
//
//  Reuse map:
//    Peeky tool                     → OpenClicky call site
//    ─────────────────────────────────────────────────────────────
//    computer.mouse_move            → OpenClickyComputerUseRuntime.moveCursor
//    computer.left_click            → OpenClickyComputerUseRuntime.click
//    computer.type                  → OpenClickyComputerUseRuntime.typeText
//    computer.key                   → OpenClickyComputerUseRuntime.pressKey
//    computer.scroll                → CGEvent scroll wheel (no bridge case
//                                     exists so we call CGEvent directly)
//    open_url                       → NSWorkspace.shared.open(url)
//    launch_app                     → NSWorkspace.launchApplication
//    switch_to_window               → NSRunningApplication.activate
//    clipboard_read / _write        → NSPasteboard (same code path bridge uses)
//    store_fact / recall_fact       → UserDefaults (interim — swap to
//                                     OpenClickyMessageLogStore later)
//    recall_conversation            → OpenClickyMessageLogStore
//                                     conversation.turn events
//    spotify_*/calendar_*/…         → MirageMacIntegrations native impl

import AppKit
import Foundation

enum MirageToolResult {
    case ok(String)
    case error(String)

    var stringValue: String {
        switch self {
        case .ok(let s): return s
        case .error(let s): return "ERROR: \(s)"
        }
    }
}

enum MirageToolAdapter {

    /// One entry point per tool_use block. Returns a plain-text tool_result
    /// suitable for feeding back into the next assistant turn. Any tool
    /// not in this table returns a `.error("Unknown tool: …")` so Claude
    /// gets a clean tool_result and the agent loop stays alive.
    static func dispatch(name: String, input: [String: Any]) async -> MirageToolResult {
        switch name {
        case "computer":
            return await dispatchComputer(input: input)
        case "open_url":
            return dispatchOpenURL(input: input)
        case "launch_app":
            return dispatchLaunchApp(input: input)
        case "switch_to_window":
            return dispatchSwitchToWindow(input: input)
        case "clipboard_read":
            return dispatchClipboardRead()
        case "clipboard_write":
            return dispatchClipboardWrite(input: input)
        case "store_fact":
            return await dispatchStoreFact(input: input)
        case "recall_fact":
            return await dispatchRecallFact(input: input)
        case "recall_conversation":
            return await dispatchRecallConversation()
        case _ where name.hasPrefix("spotify_")
              || name.hasPrefix("calendar_")
              || name.hasPrefix("contacts_")
              || name.hasPrefix("messages_")
              || name.hasPrefix("facetime_")
              || name.hasPrefix("reminders_")
              || name.hasPrefix("shortcuts_")
              || name.hasPrefix("safari_")
              || name.hasPrefix("spotlight_"):
            return await MirageMacIntegrations.dispatch(name: name, input: input)
        default:
            return .error("Unknown tool: \(name)")
        }
    }

    // MARK: - computer tool

    /// Peeky's `computer` tool packs multiple actions into one schema
    /// (Anthropic's `computer_20250124`): mouse_move / left_click / type
    /// / key / scroll. Screenshot is refused because the outer
    /// orchestrator supplies a fresh one with every tool_result.
    private static func dispatchComputer(input: [String: Any]) async -> MirageToolResult {
        guard let action = input["action"] as? String else {
            return .error("computer: missing 'action'")
        }
        switch action {
        case "screenshot":
            return .error("screenshot action is not needed; a fresh screenshot is attached to every tool_result")

        case "mouse_move":
            guard let coords = coordinates(from: input) else {
                return .error("computer.mouse_move: missing 'coordinate'")
            }
            postMouseMove(x: coords.x, y: coords.y)
            return .ok("moved cursor to (\(coords.x), \(coords.y))")

        case "left_click":
            guard let coords = coordinates(from: input) else {
                return .error("computer.left_click: missing 'coordinate'")
            }
            postMouseClick(x: coords.x, y: coords.y)
            return .ok("clicked at (\(coords.x), \(coords.y))")

        case "type":
            guard let text = input["text"] as? String, !text.isEmpty else {
                return .error("computer.type: missing 'text'")
            }
            postTypeText(text)
            return .ok("typed \(text.count) chars")

        case "key":
            guard let text = input["text"] as? String, !text.isEmpty else {
                return .error("computer.key: missing 'text'")
            }
            postKeyChord(text)
            return .ok("pressed \(text)")

        case "scroll":
            let direction = (input["scroll_direction"] as? String) ?? "down"
            let amount = (input["scroll_amount"] as? Int) ?? 3
            postScrollEvent(direction: direction, amount: amount)
            return .ok("scrolled \(direction) x\(amount)")

        default:
            return .error("computer.\(action) is not supported")
        }
    }

    private static func coordinates(from input: [String: Any]) -> (x: Int, y: Int)? {
        for key in ["coordinate", "coordinates"] {
            if let arr = input[key] as? [Any], arr.count >= 2 {
                let x = (arr[0] as? Int) ?? Int((arr[0] as? Double) ?? -1)
                let y = (arr[1] as? Int) ?? Int((arr[1] as? Double) ?? -1)
                if x >= 0 && y >= 0 { return (x, y) }
            }
        }
        return nil
    }

    // MARK: - Direct CGEvent input primitives
    //
    // These are the CGEvent calls OpenClickyNativeComputerUseController
    // wraps in its @MainActor methods. Calling CGEvent directly here
    // avoids the actor hop (MirageToolAdapter runs on the orchestrator's
    // task) and keeps the adapter self-contained. If OpenClicky adds any
    // side effects to click/typeText/pressKey later (permission gating,
    // logging, undo tracking), we should switch these to route through
    // the controller instead.

    private static func postMouseMove(x: Int, y: Int) {
        let point = CGPoint(x: x, y: y)
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postMouseClick(x: Int, y: Int) {
        let point = CGPoint(x: x, y: y)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private static func postTypeText(_ text: String) {
        for ch in text.unicodeScalars {
            let s = String(ch)
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: nil,
                                       virtualKey: 0,
                                       keyDown: down) {
                    var chars: [UniChar] = Array(s.utf16)
                    event.keyboardSetUnicodeString(stringLength: chars.count,
                                                   unicodeString: &chars)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Very small key-chord emitter for common combos (return / tab /
    /// escape / ctrl+a / cmd+shift+f). Non-exhaustive by design — the
    /// full key-code map lives in OpenClickyNativeComputerUseController;
    /// once we're happy to route through @MainActor we'll switch here.
    private static func postKeyChord(_ chord: String) {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        let key = parts.last ?? chord.lowercased()
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "ctrl", "control":        flags.insert(.maskControl)
            case "alt", "option", "opt":   flags.insert(.maskAlternate)
            case "shift":                  flags.insert(.maskShift)
            default: break
            }
        }
        let code: CGKeyCode? = {
            switch key {
            case "return", "enter": return 36
            case "tab":             return 48
            case "space":           return 49
            case "delete":          return 51
            case "escape", "esc":   return 53
            case "left":            return 123
            case "right":           return 124
            case "down":            return 125
            case "up":              return 126
            default:
                // Single-char letters mapped by common Mac layout.
                if key.count == 1, let letter = key.first {
                    let map: [Character: CGKeyCode] = [
                        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
                        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
                        "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
                        "o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46
                    ]
                    return map[letter]
                }
                return nil
            }
        }()
        guard let virtualKey = code else { return }
        for down in [true, false] {
            if let event = CGEvent(keyboardEventSource: nil,
                                   virtualKey: virtualKey,
                                   keyDown: down) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Fallback scroll wheel emitter — no bridge case for scroll in
    /// OpenClicky today.
    private static func postScrollEvent(direction: String, amount: Int) {
        let steps = Int32(max(1, min(amount, 20)))
        var v: Int32 = 0
        var h: Int32 = 0
        switch direction.lowercased() {
        case "up":    v = steps
        case "down":  v = -steps
        case "left":  h = -steps
        case "right": h = steps
        default:      v = -steps
        }
        if let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: v * 10,
            wheel2: h * 10,
            wheel3: 0
        ) {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Browser / launch / switch

    private static func dispatchOpenURL(input: [String: Any]) -> MirageToolResult {
        guard let s = input["url"] as? String, let url = URL(string: s) else {
            return .error("open_url: missing or invalid 'url'")
        }
        let opened = NSWorkspace.shared.open(url)
        return opened ? .ok("opened \(s)") : .error("open_url: NSWorkspace refused")
    }

    private static func dispatchLaunchApp(input: [String: Any]) -> MirageToolResult {
        guard let name = input["app"] as? String, !name.isEmpty else {
            return .error("launch_app: missing 'app'")
        }
        // Try common patterns: /Applications/<Name>.app then /System/…
        let candidates = [
            "/Applications/\(name).app",
            "/Applications/\(name.capitalized).app",
            "/System/Applications/\(name).app",
            "/System/Applications/\(name.capitalized).app"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            Task { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg) }
            return .ok("launched \(path)")
        }
        return .error("launch_app: could not find '\(name)' in /Applications")
    }

    private static func dispatchSwitchToWindow(input: [String: Any]) -> MirageToolResult {
        guard let target = input["target"] as? String, !target.isEmpty else {
            return .error("switch_to_window: missing 'target'")
        }
        let lower = target.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName?.lowercased() ?? ""
            let bid = app.bundleIdentifier?.lowercased() ?? ""
            if name.contains(lower) || bid.contains(lower) {
                app.activate(options: [])
                return .ok("focused \(app.localizedName ?? bid)")
            }
        }
        return .error("switch_to_window: no running app matches '\(target)'")
    }

    // MARK: - Clipboard (same NSPasteboard the bridge uses)

    private static func dispatchClipboardRead() -> MirageToolResult {
        let s = NSPasteboard.general.string(forType: .string) ?? ""
        return .ok(s)
    }

    private static func dispatchClipboardWrite(input: [String: Any]) -> MirageToolResult {
        guard let text = input["text"] as? String else {
            return .error("clipboard_write: missing 'text'")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .ok("wrote \(text.count) chars to clipboard")
    }

    // MARK: - Memory
    //
    // Interim UserDefaults-backed impl. TODO: swap to
    // OpenClickyMessageLogStore once the store surfaces a per-key
    // fact API — the storage / drawer UI is already there, just needs
    // an addressable read/write.

    private static let memoryDefaultsKey = "openClickyMirageMemoryFacts"

    private static func dispatchStoreFact(input: [String: Any]) async -> MirageToolResult {
        guard let key = (input["key"] as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty,
              let value = input["value"] as? String else {
            return .error("store_fact: need 'key' and 'value'")
        }
        var facts = (UserDefaults.standard.dictionary(forKey: memoryDefaultsKey) as? [String: String]) ?? [:]
        facts[key] = value
        UserDefaults.standard.set(facts, forKey: memoryDefaultsKey)
        return .ok("stored \(key) = \(value)")
    }

    private static func dispatchRecallFact(input: [String: Any]) async -> MirageToolResult {
        guard let key = (input["key"] as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty else {
            return .error("recall_fact: missing 'key'")
        }
        let facts = (UserDefaults.standard.dictionary(forKey: memoryDefaultsKey) as? [String: String]) ?? [:]
        if let v = facts[key] {
            return .ok("\(key) = \(v)")
        }
        return .ok("no stored value for '\(key)'")
    }

    /// Pull recent conversation turns from OpenClickyMessageLogStore.
    /// Peeky's `recall_conversation` tool answers "what did I just ask you"
    /// / "what were we talking about". We read the most recent
    /// `openclicky.conversation.turn` events (persisted preview text) from
    /// the current-day jsonl and format them role-tagged for the model.
    private static let recallConversationMaxTurns = 20

    private static func dispatchRecallConversation() async -> MirageToolResult {
        let store = OpenClickyMessageLogStore.shared
        let file = store.currentLogFile
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            return .ok("(no conversation history for today)")
        }
        var turns: [(role: String, text: String)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (entry["event"] as? String) == "openclicky.conversation.turn",
                  let fields = entry["fields"] as? [String: Any],
                  let role = fields["role"] as? String,
                  let preview = fields["textPreview"] as? String,
                  !preview.isEmpty else { continue }
            turns.append((role: role, text: preview))
        }
        guard !turns.isEmpty else { return .ok("(no conversation turns recorded yet today)") }
        let tail = Array(turns.suffix(recallConversationMaxTurns))
        let joined = tail.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        return .ok(joined)
    }
}
