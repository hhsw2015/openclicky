// OpenClickyContextAwarenessPanel.swift
// cursor-buddy
//
// SwiftUI panel for the "Context Awareness" tab in
// `OpenClickySettingsWindowManager`. Phase 7 Layer 4 UX.
//
// Renders four groups:
//   1. Hotkey bindings — one recorder row per action. Row = enable
//      toggle + current chord label + "Change" button. All five default
//      unbound (matches Everywhere `ShortcutSettings.cs` @30e03e9d).
//   2. Auto capture — passive text-selection observer toggle (stub for
//      the future observer; wiring is later, this just persists the
//      preference).
//   3. Stash file — displays the fixed on-disk path so the user can
//      open it in Finder and validate a snapshot.
//   4. Sanity checks — "Fire test snapshot" + "Open stash in Finder".
//
// Recording flow: pressing "Change" opens a lightweight recorder sheet
// that installs a local `NSEvent` monitor on `.keyDown`. First matching
// keystroke (a real key + at least one modifier so the binding is
// scoped) is written into `OpenClickyContextAwarenessSettings`. Escape
// cancels.

import AppKit
import Combine
import CoreGraphics
import Foundation
import OpenClickyContextService
import SwiftUI

struct OpenClickyContextAwarenessPanel: View {
    @ObservedObject var settings: OpenClickyContextAwarenessSettings
    let hotkeys: OpenClickyContextHotkeys

    @State private var actionBeingRecorded: OpenClickyContextHotkeyAction?
    @State private var lastSnapshotMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            masterToggleGroup
            hotkeyBindingsGroup
            launchPhraseGroup
            knownAppsGroup
            autoCaptureGroup
            stashFileGroup
            hookBinaryGroup
            sanityChecksGroup
            defaultsGroup
        }
        .sheet(item: $actionBeingRecorded) { action in
            OpenClickyHotkeyRecorderSheet(
                action: action,
                onCapture: { binding in
                    settings.setBinding(binding, for: action)
                    actionBeingRecorded = nil
                },
                onCancel: { actionBeingRecorded = nil }
            )
        }
    }

    // MARK: - Groups

    private var masterToggleGroup: some View {
        settingsCard {
            HStack(spacing: 12) {
                icon("switch.2")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable context-awareness hotkeys")
                        .font(.system(size: 13, weight: .medium))
                    Text("Master switch for the five hotkeys below. Seeded on first launch with Everywhere defaults (⇧Space, ⌥C, ⌥S, ⌥D, ⌥L).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.masterEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var hotkeyBindingsGroup: some View {
        groupContainer(title: "Hotkey bindings") {
            ForEach(OpenClickyContextHotkeyAction.allCases) { action in
                hotkeyRow(action)
                if action != OpenClickyContextHotkeyAction.allCases.last {
                    Divider().padding(.leading, 46)
                }
            }
        }
    }

    private func hotkeyRow(_ action: OpenClickyContextHotkeyAction) -> some View {
        let binding = settings.binding(for: action)
        return HStack(spacing: 12) {
            icon(action.systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                Text(action.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { binding.enabled && !binding.isEmpty },
                    set: { settings.setEnabled($0, for: action) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(binding.isEmpty)

            Text(OpenClickyHotkeyLabel.describe(binding))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(binding.isEmpty ? .secondary : .primary)
                .frame(minWidth: 84, alignment: .trailing)

            Button("Change") {
                actionBeingRecorded = action
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Clear") {
                settings.setBinding(nil, for: action)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(binding.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var launchPhraseGroup: some View {
        groupContainer(title: "Launch phrase") {
            VStack(alignment: .leading, spacing: 10) {
                Text("After SnapshotContext writes the stash file, openclicky activates a target app and types a phrase. Mirrors Everywhere's `McpServer.AgentAppId` + `McpServer.LaunchPhrase`.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center, spacing: 12) {
                    Text("Target app bundle ID")
                        .frame(width: 160, alignment: .leading)
                        .font(.system(size: 12, weight: .medium))
                    TextField("e.g. cmux, com.anthropic.claude, ...", text: $settings.agentAppId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Launch phrase")
                        .frame(width: 160, alignment: .leading)
                        .font(.system(size: 12, weight: .medium))
                    TextField("e.g. take a look", text: $settings.launchPhrase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                Divider()

                Toggle(isOn: $settings.autoCaptureContext) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto capture on pin / whiteboard finish")
                            .font(.system(size: 12, weight: .medium))
                        Text("Fires SnapshotContext automatically after AgentPickElement, Whiteboard commit, or LinkRect harvest.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var knownAppsGroup: some View {
        groupContainer(title: "Known apps") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Apps that expose a discovery URL. When SnapshotContext writes the stash and the frontmost window title matches, openclicky emits [openclicky-discover] in the hint so external tools can pull state via HTTP.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(settings.knownApps.enumerated()), id: \.offset) { index, app in
                    HStack(spacing: 8) {
                        TextField("Title regex", text: Binding(
                            get: { app.titlePattern },
                            set: { newValue in
                                var updated = settings.knownApps
                                guard index < updated.count else { return }
                                updated[index] = OpenClickyKnownApp(titlePattern: newValue, discoverUrl: app.discoverUrl)
                                settings.knownApps = updated
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity)

                        TextField("Discover URL", text: Binding(
                            get: { app.discoverUrl },
                            set: { newValue in
                                var updated = settings.knownApps
                                guard index < updated.count else { return }
                                updated[index] = OpenClickyKnownApp(titlePattern: app.titlePattern, discoverUrl: newValue)
                                settings.knownApps = updated
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity)

                        Button {
                            var updated = settings.knownApps
                            guard index < updated.count else { return }
                            updated.remove(at: index)
                            settings.knownApps = updated
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    var updated = settings.knownApps
                    updated.append(OpenClickyKnownApp(titlePattern: "", discoverUrl: ""))
                    settings.knownApps = updated
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var autoCaptureGroup: some View {
        groupContainer(title: "Auto capture") {
            HStack(spacing: 12) {
                icon("text.cursor")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable auto text-selection observer (passive)")
                        .font(.system(size: 13, weight: .medium))
                    Text("Watches mouse-up over I-beam cursors and captures the current selection. Off by default; observer wiring lands with the follow-up phase.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.autoSelectionObserverEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var stashFileGroup: some View {
        groupContainer(title: "Stash file") {
            let stashURL = OpenClickyStashPaths.contextStash()
            HStack(spacing: 12) {
                icon("doc.text")
                VStack(alignment: .leading, spacing: 3) {
                    Text("context-stash.json")
                        .font(.system(size: 13, weight: .medium))
                    Text(stashURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([stashURL])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var hookBinaryGroup: some View {
        groupContainer(title: "Hook binary") {
            let hookURL = OpenClickyStashPaths.contextStash()
                .deletingLastPathComponent()
                .appendingPathComponent("openclicky-context-hook")
            HStack(spacing: 12) {
                icon("terminal")
                VStack(alignment: .leading, spacing: 3) {
                    Text("openclicky-context-hook")
                        .font(.system(size: 13, weight: .medium))
                    Text("Copy this binary onto your Claude Code / cmux UserPromptSubmit hook path so the stash is consumed on Enter.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Show install steps") {
                    showHookInstallInstructions(hookURL: hookURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var sanityChecksGroup: some View {
        groupContainer(title: "Sanity checks") {
            HStack(spacing: 12) {
                icon("bolt.horizontal.circle")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fire a test snapshot")
                        .font(.system(size: 13, weight: .medium))
                    Text(lastSnapshotMessage ?? "Writes context-stash.json with the current focused app/window/URL.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Fire") {
                    hotkeys.fireTestSnapshot()
                    lastSnapshotMessage = "Snapshot fired at \(Self.timeFormatter.string(from: Date())). Reveal the stash to confirm."
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var defaultsGroup: some View {
        groupContainer(title: "Defaults") {
            HStack(spacing: 12) {
                icon("arrow.counterclockwise")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reset to Everywhere defaults")
                        .font(.system(size: 13, weight: .medium))
                    Text("Restores the five hotkeys (⇧Space, ⌥C, ⌥S, ⌥D, ⌥L) plus cmux, \"take a look\", and xlinkBook discovery URL.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset") {
                    settings.resetToEverywhereDefaults()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Restore 5 hotkeys + cmux + take-a-look + xlinkBook defaults")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Helpers

    private func groupContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            settingsCard {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(.secondary)
            .frame(width: 22, alignment: .leading)
    }

    private func showHookInstallInstructions(hookURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Install openclicky-context-hook"
        alert.informativeText = """
        The hook binary reads context-stash.json on every Enter press \
        inside Claude Code / cmux and injects the captured context into \
        the prompt.

        1. Copy the binary next to the stash file:
           \(hookURL.path)
        2. Point your agent's UserPromptSubmit hook at this path.
        3. Verify with:
           \(hookURL.lastPathComponent) --self-test

        The hook is built separately by the openclicky-context-hook crate. \
        Ship a build via the release pipeline; this Settings row surfaces \
        the target location but does not install anything on its own.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - Recorder sheet

/// Modal sheet that installs a local key-event monitor and returns the
/// first captured chord. Requires at least one modifier so we never
/// accidentally bind a bare letter (that would eat every keystroke).
struct OpenClickyHotkeyRecorderSheet: View {
    let action: OpenClickyContextHotkeyAction
    let onCapture: (OpenClickyHotkeyBinding) -> Void
    let onCancel: () -> Void

    @State private var latest: OpenClickyHotkeyBinding = OpenClickyHotkeyBinding(keyCode: 0, modifiers: 0, enabled: true)
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record hotkey for \(action.displayTitle)")
                    .font(.system(size: 15, weight: .semibold))
                Text("Press the key combination you want to bind. Include at least one modifier (⌘, ⌃, ⌥, or ⇧).")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Text(OpenClickyHotkeyLabel.describe(latest))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                Spacer()
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onCapture(latest)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(latest.isEmpty || latest.normalisedModifiers == 0)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            let normalised = cgFlags.rawValue & OpenClickyHotkeyBinding.significantModifierMask
            // Escape (keyCode 53) cancels the recorder.
            if event.keyCode == 53 && normalised == 0 {
                onCancel()
                return nil
            }
            latest = OpenClickyHotkeyBinding(
                keyCode: event.keyCode,
                modifiers: normalised,
                enabled: true
            )
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
