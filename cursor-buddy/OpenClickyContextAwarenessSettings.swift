// OpenClickyContextAwarenessSettings.swift
// cursor-buddy
//
// UserDefaults-backed configuration for the Context Awareness Settings
// tab (Phase 7 Layer 4 UX).
//
// First-launch defaults (2026-07-23): OpenClicky is a drop-in
// replacement for Everywhere, so on first launch we seed the five
// hotkeys / master toggle / auto-capture / agent target / launch
// phrase / known-apps list from the user's real Everywhere config
// (`~/Library/Application Support/Everywhere/settings.json`). A
// one-shot sentinel key (`openclicky.contextAwareness.seededEverywhereDefaults`)
// guarantees we only seed once; every subsequent launch reads whatever
// the user has stored (including cleared bindings). See
// `docs/ROADMAP/.impl-notes/phase7-defaults-2026-07-23.md`.
//
// Two axes of state live here:
//   1. `OpenClickyHotkeyBinding` — the per-action key/modifier pair
//      persisted as JSON under a stable UserDefaults key. Storing the
//      raw JSON (rather than two ints) lets us extend the record later
//      (e.g. adding a `label` override) without a migration.
//   2. `OpenClickyContextAwarenessSettings` — an `ObservableObject`
//      wrapping the 5 bindings + master toggle + auto text-selection
//      observer toggle. SwiftUI views observe it via `@ObservedObject`
//      or `@StateObject`; the CGEvent-tap manager
//      (`OpenClickyContextHotkeys`) reads it directly via `.shared`.
//
// The tuning constants at the top match Everywhere's
// `SnapshotContextHotkeyInitializer.cs`:
//   * `repeatSuppressionInterval = 1.5s` (aka `RepeatSuppressionMs`)
//   * `modifierReleaseDelay = 0.18s` (`MacosModifierReleaseDelayMs`)
// Keeping both here rather than inside the tap manager makes them easy
// to inspect from tests without touching CGEvent state.

import Foundation
import AppKit
import Combine

/// One of the five context-awareness hotkey slots. Serialised as its
/// raw string so UserDefaults keys stay human-readable.
enum OpenClickyContextHotkeyAction: String, CaseIterable, Identifiable {
    case snapshotContext
    case clearContextStash
    case agentPickElement
    case whiteboard
    case linkRect
    case screenHistoryOpenSearch
    case screenHistoryPauseToggle
    case screenHistoryOpenSettings

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .snapshotContext: return "Snapshot Context"
        case .clearContextStash: return "Clear Context Stash"
        case .agentPickElement: return "Agent Pick Element"
        case .whiteboard: return "Whiteboard (press-hold)"
        case .linkRect: return "LinkRect (press-drag)"
        case .screenHistoryOpenSearch: return "Screen History — Open Search"
        case .screenHistoryPauseToggle: return "Screen History — Pause / Resume"
        case .screenHistoryOpenSettings: return "Screen History — Settings"
        }
    }

    var displaySubtitle: String {
        switch self {
        case .snapshotContext:
            return "Capture the current app/window/URL/selection into context-stash.json."
        case .clearContextStash:
            return "Wipe the stash file and all in-memory pin/whiteboard/annotation state."
        case .agentPickElement:
            return "Pin the UI element under the pointer so the next agent turn can see it."
        case .whiteboard:
            return "Enter whiteboard drawing mode (drawing overlay is a later phase)."
        case .linkRect:
            return "Harvest all links inside a drag-selected screen rectangle (later phase)."
        case .screenHistoryOpenSearch:
            return "Open the Screen History timeline / search window."
        case .screenHistoryPauseToggle:
            return "Pause or resume Screen History recording without opening the app."
        case .screenHistoryOpenSettings:
            return "Jump straight to the Screen History section of Settings."
        }
    }

    var systemImageName: String {
        switch self {
        case .snapshotContext: return "camera.metering.spot"
        case .clearContextStash: return "trash"
        case .agentPickElement: return "hand.point.up.left"
        case .whiteboard: return "scribble.variable"
        case .linkRect: return "rectangle.dashed"
        case .screenHistoryOpenSearch: return "clock.arrow.circlepath"
        case .screenHistoryPauseToggle: return "pause.circle"
        case .screenHistoryOpenSettings: return "gearshape"
        }
    }

    fileprivate var defaultsKey: String {
        "openclicky.contextAwareness.hotkey.\(rawValue)"
    }
}

/// One captured key chord. Persisted as compact JSON so we can add
/// fields (e.g. a user-provided label) later without breaking readers.
///
/// `keyCode` is a CoreGraphics virtual keycode (matches
/// `CGEvent.getIntegerValueField(.keyboardEventKeycode)`).
/// `modifiers` is the raw `CGEventFlags.rawValue`, but only the four
/// user-visible modifier bits are inspected at match time so device
/// flags (e.g. `.maskNumericPad`) do not accidentally break a binding.
struct OpenClickyHotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var enabled: Bool

    /// Bit mask of the modifier flags we compare at fire time. Anything
    /// outside this mask (numpad, help, function-keys metadata) is
    /// ignored so a binding of `Cmd+K` still matches when Caps Lock is
    /// on or the keyboard is a numpad.
    static let significantModifierMask: UInt64 = {
        var mask: UInt64 = 0
        mask |= CGEventFlags.maskCommand.rawValue
        mask |= CGEventFlags.maskShift.rawValue
        mask |= CGEventFlags.maskAlternate.rawValue
        mask |= CGEventFlags.maskControl.rawValue
        return mask
    }()

    /// Returns the modifier bits masked to just the user-visible four.
    var normalisedModifiers: UInt64 {
        modifiers & OpenClickyHotkeyBinding.significantModifierMask
    }

    /// Match against an incoming CGEvent's keyCode/flags pair.
    /// Returns false when the binding is disabled or empty.
    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard enabled else { return false }
        guard self.keyCode != 0 || normalisedModifiers != 0 else { return false }
        let incoming = flags.rawValue & OpenClickyHotkeyBinding.significantModifierMask
        return self.keyCode == keyCode && normalisedModifiers == incoming
    }

    /// True when neither a key nor a modifier is set. Rendered as
    /// "Not set" in the Settings UI.
    var isEmpty: Bool {
        keyCode == 0 && normalisedModifiers == 0
    }
}

/// KnownApps entry — mirrors Everywhere's `McpServer.KnownApps` shape.
/// `titlePattern` is a case-sensitive regex tested against the frontmost
/// window title (e.g. `^xlinkBook`). `discoverUrl` is the
/// well-known agent-skills endpoint openclicky should probe when this
/// window is focused.
public struct OpenClickyKnownApp: Codable, Sendable, Equatable, Identifiable {
    public var titlePattern: String
    public var discoverUrl: String

    public init(titlePattern: String, discoverUrl: String) {
        self.titlePattern = titlePattern
        self.discoverUrl = discoverUrl
    }

    /// Identity is derived from the pattern+URL pair so SwiftUI `ForEach`
    /// keeps rows stable across edits.
    public var id: String { "\(titlePattern)\u{001F}\(discoverUrl)" }
}

/// UserDefaults-backed, `@Published` context-awareness configuration.
/// Singleton lives on `OpenClickyContextAwarenessSettings.shared`.
///
/// SwiftUI views observe it directly; the CGEvent tap manager reads
/// `.shared` at fire time so a binding change takes effect on the very
/// next keystroke without needing an explicit re-register call.
final class OpenClickyContextAwarenessSettings: ObservableObject {
    static let shared = OpenClickyContextAwarenessSettings()

    /// Master enable. Defaults `true` on first launch to match the user's
    /// existing Everywhere habit (they've had these bindings live for
    /// months). Every subsequent launch respects whatever the user set.
    static let masterEnabledDefaultsKey = "openclicky.contextAwareness.hotkeysEnabled"

    /// Passive text-selection observer. Reserved for a later phase; the
    /// toggle exists so the Settings UI can surface the switch already.
    static let autoSelectionObserverDefaultsKey = "openclicky.contextAwareness.autoSelectionObserverEnabled"

    /// Auto-capture on pin / whiteboard finish. Mirrors Everywhere's
    /// `McpServer.AutoCaptureContext`.
    static let autoCaptureContextDefaultsKey = "openclicky.contextAwareness.autoCaptureContext"

    /// Target app that receives the LaunchPhrase after SnapshotContext
    /// writes the stash. Mirrors Everywhere's `McpServer.AgentAppId`.
    static let agentAppIdDefaultsKey = "openclicky.contextAwareness.agentAppId"

    /// Text typed into `agentAppId` after activation. Mirrors
    /// Everywhere's `McpServer.LaunchPhrase`.
    static let launchPhraseDefaultsKey = "openclicky.contextAwareness.launchPhrase"

    /// OpenDia browser bridge toggle. Mirrors Everywhere's
    /// `McpServer.OpenDiaEnabled`.
    static let openDiaEnabledDefaultsKey = "openclicky.contextAwareness.openDiaEnabled"

    /// Cursor overlay (crosshair follow) toggle. Mirrors Everywhere's
    /// `McpServer.CursorOverlayEnabled`.
    static let cursorOverlayEnabledDefaultsKey = "openclicky.contextAwareness.cursorOverlayEnabled"

    /// KnownApps table. Mirrors Everywhere's `McpServer.KnownApps`.
    /// Persisted as JSON-encoded `[OpenClickyKnownApp]`.
    static let knownAppsDefaultsKey = "openclicky.contextAwareness.knownApps"

    /// One-shot sentinel: after the first launch we set this key so we
    /// never re-seed defaults on top of a user who has (deliberately)
    /// cleared a binding.
    static let seededDefaultsSentinelKey = "openclicky.contextAwareness.seededEverywhereDefaults"

    /// Repeat-suppression window applied per action inside the CGEvent
    /// tap. Matches Everywhere's `RepeatSuppressionMs = 1500`
    /// (`SnapshotContextHotkeyInitializer.cs` @30e03e9d).
    static let repeatSuppressionInterval: TimeInterval = 1.5

    /// Delay between capturing the hotkey down-edge and actually running
    /// the action. Gives the user time to release the modifiers so a
    /// downstream AX capture doesn't see a "Cmd held" flag. Matches
    /// Everywhere's `MacosModifierReleaseDelayMs = 180`.
    static let modifierReleaseDelay: TimeInterval = 0.180

    // MARK: - Everywhere-parity default values
    //
    // Values below verbatim from
    // `~/Library/Application Support/Everywhere/settings.json` on the
    // user's machine (2026-07-23). Modifier raw values come from
    // `CGEventFlags.maskShift/maskAlternate.rawValue` so the persisted
    // JSON is identical to a user-recorded binding.

    static let defaultBinding_SnapshotContext = OpenClickyHotkeyBinding(
        keyCode: 49, // kVK_Space
        modifiers: CGEventFlags.maskShift.rawValue,
        enabled: true
    )
    static let defaultBinding_ClearContextStash = OpenClickyHotkeyBinding(
        keyCode: 8, // kVK_ANSI_C
        modifiers: CGEventFlags.maskAlternate.rawValue,
        enabled: true
    )
    static let defaultBinding_AgentPickElement = OpenClickyHotkeyBinding(
        keyCode: 1, // kVK_ANSI_S
        modifiers: CGEventFlags.maskAlternate.rawValue,
        enabled: true
    )
    static let defaultBinding_Whiteboard = OpenClickyHotkeyBinding(
        keyCode: 2, // kVK_ANSI_D
        modifiers: CGEventFlags.maskAlternate.rawValue,
        enabled: true
    )
    static let defaultBinding_LinkRect = OpenClickyHotkeyBinding(
        keyCode: 37, // kVK_ANSI_L
        modifiers: CGEventFlags.maskAlternate.rawValue,
        enabled: true
    )

    /// Master toggle default. See `masterEnabledDefaultsKey`.
    static let defaultMasterEnabled = true

    /// Passive selection observer stays off by default — Everywhere has
    /// no equivalent auto-selection setting the user has enabled.
    static let defaultAutoSelectionObserverEnabled = false

    static let defaultAutoCaptureContext = true
    static let defaultAgentAppId = "cmux"
    static let defaultLaunchPhrase = "take a look"
    static let defaultOpenDiaEnabled = true
    static let defaultCursorOverlayEnabled = false
    static let defaultKnownApps: [OpenClickyKnownApp] = [
        OpenClickyKnownApp(
            titlePattern: "^xlinkBook",
            discoverUrl: "http://127.0.0.1:32123/mcp/tools?domain=xlb"
        )
    ]

    /// Returns the Everywhere-parity binding for a given action.
    static func defaultBinding(for action: OpenClickyContextHotkeyAction) -> OpenClickyHotkeyBinding {
        switch action {
        case .snapshotContext:  return defaultBinding_SnapshotContext
        case .clearContextStash: return defaultBinding_ClearContextStash
        case .agentPickElement: return defaultBinding_AgentPickElement
        case .whiteboard:       return defaultBinding_Whiteboard
        case .linkRect:         return defaultBinding_LinkRect
        // Screen History defaults are unbound; user assigns in Settings.
        case .screenHistoryOpenSearch,
             .screenHistoryPauseToggle,
             .screenHistoryOpenSettings:
            return OpenClickyHotkeyBinding(keyCode: 0, modifiers: 0, enabled: false)
        }
    }

    @Published var masterEnabled: Bool {
        didSet {
            defaults.set(masterEnabled, forKey: Self.masterEnabledDefaultsKey)
        }
    }

    @Published var autoSelectionObserverEnabled: Bool {
        didSet {
            defaults.set(autoSelectionObserverEnabled, forKey: Self.autoSelectionObserverDefaultsKey)
        }
    }

    @Published var autoCaptureContext: Bool {
        didSet {
            defaults.set(autoCaptureContext, forKey: Self.autoCaptureContextDefaultsKey)
            // Signal `OpenClickyAutoCaptureService` (which subscribes on
            // NotificationCenter to avoid a Combine dependency) so the
            // pin observer registers/unregisters on toggle. Mirrors
            // C# `PropertyChanged` route in AutoCaptureService.cs:48-54.
            NotificationCenter.default.post(
                name: OpenClickyAutoCaptureService.autoCaptureContextChanged,
                object: self
            )
        }
    }

    @Published var agentAppId: String {
        didSet {
            defaults.set(agentAppId, forKey: Self.agentAppIdDefaultsKey)
        }
    }

    @Published var launchPhrase: String {
        didSet {
            defaults.set(launchPhrase, forKey: Self.launchPhraseDefaultsKey)
        }
    }

    @Published var openDiaEnabled: Bool {
        didSet {
            defaults.set(openDiaEnabled, forKey: Self.openDiaEnabledDefaultsKey)
        }
    }

    @Published var cursorOverlayEnabled: Bool {
        didSet {
            defaults.set(cursorOverlayEnabled, forKey: Self.cursorOverlayEnabledDefaultsKey)
        }
    }

    @Published var knownApps: [OpenClickyKnownApp] {
        didSet {
            if let encoded = try? JSONEncoder().encode(knownApps) {
                defaults.set(encoded, forKey: Self.knownAppsDefaultsKey)
            }
        }
    }

    @Published private var bindingsByAction: [OpenClickyContextHotkeyAction: OpenClickyHotkeyBinding]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // First-launch seed. `object(forKey:)` returns nil only when the
        // key has never been written — perfect signal for "no user value
        // yet". Once a user clears a binding we persist the cleared
        // state (see `setBinding(nil, ...)` which removes the key AND
        // the sentinel remains set), and the seed does not re-fire.
        let alreadySeeded = defaults.bool(forKey: Self.seededDefaultsSentinelKey)

        // Master toggle: honour stored value, else default to true.
        if defaults.object(forKey: Self.masterEnabledDefaultsKey) == nil {
            self.masterEnabled = Self.defaultMasterEnabled
            defaults.set(Self.defaultMasterEnabled, forKey: Self.masterEnabledDefaultsKey)
        } else {
            self.masterEnabled = defaults.bool(forKey: Self.masterEnabledDefaultsKey)
        }

        if defaults.object(forKey: Self.autoSelectionObserverDefaultsKey) == nil {
            self.autoSelectionObserverEnabled = Self.defaultAutoSelectionObserverEnabled
        } else {
            self.autoSelectionObserverEnabled = defaults.bool(forKey: Self.autoSelectionObserverDefaultsKey)
        }

        if defaults.object(forKey: Self.autoCaptureContextDefaultsKey) == nil {
            self.autoCaptureContext = Self.defaultAutoCaptureContext
            defaults.set(Self.defaultAutoCaptureContext, forKey: Self.autoCaptureContextDefaultsKey)
        } else {
            self.autoCaptureContext = defaults.bool(forKey: Self.autoCaptureContextDefaultsKey)
        }

        if let stored = defaults.string(forKey: Self.agentAppIdDefaultsKey) {
            self.agentAppId = stored
        } else {
            self.agentAppId = Self.defaultAgentAppId
            defaults.set(Self.defaultAgentAppId, forKey: Self.agentAppIdDefaultsKey)
        }

        if let stored = defaults.string(forKey: Self.launchPhraseDefaultsKey) {
            self.launchPhrase = stored
        } else {
            self.launchPhrase = Self.defaultLaunchPhrase
            defaults.set(Self.defaultLaunchPhrase, forKey: Self.launchPhraseDefaultsKey)
        }

        if defaults.object(forKey: Self.openDiaEnabledDefaultsKey) == nil {
            self.openDiaEnabled = Self.defaultOpenDiaEnabled
            defaults.set(Self.defaultOpenDiaEnabled, forKey: Self.openDiaEnabledDefaultsKey)
        } else {
            self.openDiaEnabled = defaults.bool(forKey: Self.openDiaEnabledDefaultsKey)
        }

        if defaults.object(forKey: Self.cursorOverlayEnabledDefaultsKey) == nil {
            self.cursorOverlayEnabled = Self.defaultCursorOverlayEnabled
            defaults.set(Self.defaultCursorOverlayEnabled, forKey: Self.cursorOverlayEnabledDefaultsKey)
        } else {
            self.cursorOverlayEnabled = defaults.bool(forKey: Self.cursorOverlayEnabledDefaultsKey)
        }

        if let data = defaults.data(forKey: Self.knownAppsDefaultsKey),
           let decoded = try? JSONDecoder().decode([OpenClickyKnownApp].self, from: data) {
            self.knownApps = decoded
        } else {
            self.knownApps = Self.defaultKnownApps
            if let encoded = try? JSONEncoder().encode(Self.defaultKnownApps) {
                defaults.set(encoded, forKey: Self.knownAppsDefaultsKey)
            }
        }

        // Per-action bindings. Seed each slot from Everywhere only on
        // the very first launch (sentinel unset). After that, honour
        // whatever the user has: an existing record, or an explicit
        // clear (record absent + sentinel set → stays unbound).
        var loaded: [OpenClickyContextHotkeyAction: OpenClickyHotkeyBinding] = [:]
        for action in OpenClickyContextHotkeyAction.allCases {
            if let data = defaults.data(forKey: action.defaultsKey),
               let decoded = try? JSONDecoder().decode(OpenClickyHotkeyBinding.self, from: data) {
                loaded[action] = decoded
            } else if !alreadySeeded {
                let seed = Self.defaultBinding(for: action)
                loaded[action] = seed
                if let encoded = try? JSONEncoder().encode(seed) {
                    defaults.set(encoded, forKey: action.defaultsKey)
                }
            }
        }
        self.bindingsByAction = loaded

        if !alreadySeeded {
            defaults.set(true, forKey: Self.seededDefaultsSentinelKey)
        }
    }

    // MARK: - Reset

    /// Restore every field to the Everywhere-parity default. Used by the
    /// Settings UI "Reset to Everywhere defaults" button. Also re-arms
    /// the sentinel so it stays truthful.
    func resetToEverywhereDefaults() {
        objectWillChange.send()
        masterEnabled = Self.defaultMasterEnabled
        autoSelectionObserverEnabled = Self.defaultAutoSelectionObserverEnabled
        autoCaptureContext = Self.defaultAutoCaptureContext
        agentAppId = Self.defaultAgentAppId
        launchPhrase = Self.defaultLaunchPhrase
        openDiaEnabled = Self.defaultOpenDiaEnabled
        cursorOverlayEnabled = Self.defaultCursorOverlayEnabled
        knownApps = Self.defaultKnownApps

        for action in OpenClickyContextHotkeyAction.allCases {
            setBinding(Self.defaultBinding(for: action), for: action)
        }
        defaults.set(true, forKey: Self.seededDefaultsSentinelKey)
    }

    // MARK: - Binding access

    /// Returns the persisted binding or an empty disabled placeholder.
    /// Callers should treat `binding(for:).isEmpty` as "unbound".
    func binding(for action: OpenClickyContextHotkeyAction) -> OpenClickyHotkeyBinding {
        bindingsByAction[action] ?? OpenClickyHotkeyBinding(keyCode: 0, modifiers: 0, enabled: false)
    }

    /// Snapshot of every active binding — used by the CGEvent-tap
    /// manager. Returns only bindings that are `enabled` and non-empty.
    var activeBindings: [(OpenClickyContextHotkeyAction, OpenClickyHotkeyBinding)] {
        OpenClickyContextHotkeyAction.allCases.compactMap { action in
            let binding = self.binding(for: action)
            guard binding.enabled, !binding.isEmpty else { return nil }
            return (action, binding)
        }
    }

    /// Overwrite (or clear) a binding. Passing `nil` clears the slot
    /// entirely. Persisted immediately.
    func setBinding(_ binding: OpenClickyHotkeyBinding?, for action: OpenClickyContextHotkeyAction) {
        objectWillChange.send()
        if let binding, !binding.isEmpty {
            bindingsByAction[action] = binding
            if let encoded = try? JSONEncoder().encode(binding) {
                defaults.set(encoded, forKey: action.defaultsKey)
            }
        } else {
            bindingsByAction.removeValue(forKey: action)
            defaults.removeObject(forKey: action.defaultsKey)
        }
    }

    /// Toggle the `enabled` bit on an existing binding without touching
    /// keyCode/modifiers. No-op if the slot is empty.
    func setEnabled(_ enabled: Bool, for action: OpenClickyContextHotkeyAction) {
        guard var binding = bindingsByAction[action], !binding.isEmpty else { return }
        binding.enabled = enabled
        setBinding(binding, for: action)
    }
}

// MARK: - Human-readable key label

/// Format a binding as e.g. "⌃⌥⇧⌘K". Returns "Not set" when empty.
/// Used by the Settings UI recorder row.
enum OpenClickyHotkeyLabel {
    static func describe(_ binding: OpenClickyHotkeyBinding) -> String {
        if binding.isEmpty { return "Not set" }
        var out = ""
        let mods = binding.normalisedModifiers
        if mods & CGEventFlags.maskControl.rawValue != 0 { out += "⌃" }
        if mods & CGEventFlags.maskAlternate.rawValue != 0 { out += "⌥" }
        if mods & CGEventFlags.maskShift.rawValue != 0 { out += "⇧" }
        if mods & CGEventFlags.maskCommand.rawValue != 0 { out += "⌘" }
        out += Self.keyName(for: binding.keyCode)
        return out
    }

    /// Best-effort virtual-keycode → glyph mapping. Covers common
    /// letter/digit/arrow/function keys; anything else falls through to
    /// "key <n>" so the user can still tell two bindings apart.
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 65: return "."
        case 67: return "*"
        case 69: return "+"
        case 71: return "Clear"
        case 75: return "/"
        case 76: return "⌤"
        case 78: return "-"
        case 81: return "="
        case 82: return "0"
        case 83: return "1"
        case 84: return "2"
        case 85: return "3"
        case 86: return "4"
        case 87: return "5"
        case 88: return "6"
        case 89: return "7"
        case 91: return "8"
        case 92: return "9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "key \(keyCode)"
        }
    }
}
