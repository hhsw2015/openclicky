// OpenClickyContextAwarenessDefaultsTests.swift
// cursor-buddyTests
//
// Verifies that on first launch OpenClicky seeds the Context Awareness
// settings from the user's Everywhere config
// (`~/Library/Application Support/Everywhere/settings.json`, 2026-07-23):
//   Shortcuts:
//     SnapshotContext   = Shift+Space  enabled=true
//     ClearContextStash = Alt+C        enabled=true
//     AgentPickElement  = Alt+S        enabled=true
//     Whiteboard        = Alt+D        enabled=true
//     LinkRect          = Alt+L        enabled=true
//   McpServer:
//     AutoCaptureContext   = true
//     AgentAppId           = "cmux"
//     LaunchPhrase         = "take a look"
//     OpenDiaEnabled       = true
//     CursorOverlayEnabled = false
//     KnownApps            = [{ "^xlinkBook",
//                               "http://localhost:5000/.well-known/agent-skills" }]
// Master toggle defaults to true so the bindings are live on first
// launch (matches the user's Everywhere `IsEnabled=true` habit).

import CoreGraphics
import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyContextAwarenessDefaultsTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenClickyContextAwarenessDefaultsTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Everywhere byte-parity: hotkey bindings

    @Test func snapshotContextDefaultsToShiftSpaceEnabled() {
        let defaults = freshDefaults("snapshotContext")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        let binding = settings.binding(for: .snapshotContext)
        #expect(binding.keyCode == 49)
        #expect(binding.normalisedModifiers == CGEventFlags.maskShift.rawValue)
        #expect(binding.enabled)
    }

    @Test func clearContextStashDefaultsToAltC() {
        let defaults = freshDefaults("clearContextStash")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        let binding = settings.binding(for: .clearContextStash)
        #expect(binding.keyCode == 8)
        #expect(binding.normalisedModifiers == CGEventFlags.maskAlternate.rawValue)
        #expect(binding.enabled)
    }

    @Test func agentPickElementDefaultsToAltS() {
        let defaults = freshDefaults("agentPickElement")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        let binding = settings.binding(for: .agentPickElement)
        #expect(binding.keyCode == 1)
        #expect(binding.normalisedModifiers == CGEventFlags.maskAlternate.rawValue)
        #expect(binding.enabled)
    }

    @Test func whiteboardDefaultsToAltD() {
        let defaults = freshDefaults("whiteboard")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        let binding = settings.binding(for: .whiteboard)
        #expect(binding.keyCode == 2)
        #expect(binding.normalisedModifiers == CGEventFlags.maskAlternate.rawValue)
        #expect(binding.enabled)
    }

    @Test func linkRectDefaultsToAltL() {
        let defaults = freshDefaults("linkRect")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        let binding = settings.binding(for: .linkRect)
        #expect(binding.keyCode == 37)
        #expect(binding.normalisedModifiers == CGEventFlags.maskAlternate.rawValue)
        #expect(binding.enabled)
    }

    // MARK: - Everywhere byte-parity: scalar fields

    @Test func masterToggleDefaultsOn() {
        let defaults = freshDefaults("master")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(settings.masterEnabled)
    }

    @Test func autoCaptureContextDefaultsOn() {
        let defaults = freshDefaults("autoCapture")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(settings.autoCaptureContext)
    }

    @Test func agentAppIdDefaultsToCmux() {
        let defaults = freshDefaults("agentAppId")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(settings.agentAppId == "cmux")
    }

    @Test func launchPhraseDefaultsToTakeALook() {
        let defaults = freshDefaults("launchPhrase")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(settings.launchPhrase == "take a look")
    }

    @Test func openDiaEnabledDefaultsOn() {
        let defaults = freshDefaults("openDia")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(settings.openDiaEnabled)
    }

    @Test func cursorOverlayEnabledDefaultsOff() {
        let defaults = freshDefaults("cursorOverlay")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(!settings.cursorOverlayEnabled)
    }

    @Test func knownAppsDefaultsToXlinkBookEntry() {
        let defaults = freshDefaults("knownApps")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        #expect(settings.knownApps.count == 1)
        let first = settings.knownApps.first
        #expect(first?.titlePattern == "^xlinkBook")
        #expect(first?.discoverUrl == "http://localhost:5000/.well-known/agent-skills")
    }

    // MARK: - Override + persistence

    @Test func userOverridePersistsAcrossReinit() {
        let defaults = freshDefaults("override")
        let first = OpenClickyContextAwarenessSettings(defaults: defaults)
        let custom = OpenClickyHotkeyBinding(
            keyCode: 40, // K
            modifiers: CGEventFlags.maskCommand.rawValue,
            enabled: true
        )
        first.setBinding(custom, for: .snapshotContext)

        let second = OpenClickyContextAwarenessSettings(defaults: defaults)
        let reloaded = second.binding(for: .snapshotContext)
        #expect(reloaded.keyCode == 40)
        #expect(reloaded.normalisedModifiers == CGEventFlags.maskCommand.rawValue)
    }

    @Test func clearedBindingStaysClearedAfterReinit() {
        let defaults = freshDefaults("cleared")
        let first = OpenClickyContextAwarenessSettings(defaults: defaults)
        first.setBinding(nil, for: .whiteboard)

        let second = OpenClickyContextAwarenessSettings(defaults: defaults)
        // Sentinel is set → seed does not re-fire, so the slot stays
        // unbound after the user explicitly cleared it.
        #expect(second.binding(for: .whiteboard).isEmpty)
    }

    @Test func launchPhraseOverridePersists() {
        let defaults = freshDefaults("launchPhraseOverride")
        let first = OpenClickyContextAwarenessSettings(defaults: defaults)
        first.launchPhrase = "hey clicky"

        let second = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(second.launchPhrase == "hey clicky")
    }

    @Test func agentAppIdOverridePersists() {
        let defaults = freshDefaults("agentAppIdOverride")
        let first = OpenClickyContextAwarenessSettings(defaults: defaults)
        first.agentAppId = "com.anthropic.claude"

        let second = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(second.agentAppId == "com.anthropic.claude")
    }

    @Test func knownAppsOverridePersists() {
        let defaults = freshDefaults("knownAppsOverride")
        let first = OpenClickyContextAwarenessSettings(defaults: defaults)
        let replacement = [
            OpenClickyKnownApp(titlePattern: "^Terminal", discoverUrl: "https://example.com/skills")
        ]
        first.knownApps = replacement

        let second = OpenClickyContextAwarenessSettings(defaults: defaults)
        #expect(second.knownApps == replacement)
    }

    // MARK: - Reset button

    @Test func resetRestoresEverywhereDefaultsAfterUserOverride() {
        let defaults = freshDefaults("reset")
        let settings = OpenClickyContextAwarenessSettings(defaults: defaults)

        settings.setBinding(nil, for: .snapshotContext)
        settings.setBinding(nil, for: .linkRect)
        settings.agentAppId = "com.other.app"
        settings.launchPhrase = ""
        settings.autoCaptureContext = false
        settings.knownApps = []

        settings.resetToEverywhereDefaults()

        #expect(settings.binding(for: .snapshotContext) == OpenClickyContextAwarenessSettings.defaultBinding_SnapshotContext)
        #expect(settings.binding(for: .linkRect) == OpenClickyContextAwarenessSettings.defaultBinding_LinkRect)
        #expect(settings.agentAppId == "cmux")
        #expect(settings.launchPhrase == "take a look")
        #expect(settings.autoCaptureContext)
        #expect(settings.knownApps == OpenClickyContextAwarenessSettings.defaultKnownApps)
    }
}
