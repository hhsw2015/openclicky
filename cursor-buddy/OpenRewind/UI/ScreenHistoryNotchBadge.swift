//
//  ScreenHistoryNotchBadge.swift
//  cursor-buddy
//
//  Compact indicator badge shown in the notch when Screen History is
//  recording. Observes ScreenHistoryState.shared and mirrors macOS's
//  own screen-recording purple dot — an obvious "this app is capturing
//  right now" affordance the user can trust.
//
//  Three states:
//    · off — hidden entirely (returns EmptyView)
//    · paused — yellow pause icon
//    · recording — red dot pulsing softly
//
//  Additionally shows secondary icons when mic / system-audio capture
//  is on, so the user knows exactly what's being recorded.
//

import SwiftUI

public struct ScreenHistoryNotchBadge: View {
    @ObservedObject private var state = ScreenHistoryState.shared

    public init() {}

    public var body: some View {
        if !state.isEnabled {
            EmptyView()
        } else if state.isPaused {
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 10, weight: .bold))
            }
            .accessibilityLabel("Screen History paused")
        } else {
            HStack(spacing: 3) {
                if state.isRecordingScreen {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                }
                if state.isRecordingMic {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 8, weight: .bold))
                }
                if state.isRecordingSystemAudio {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .accessibilityLabel("Screen History recording")
        }
    }
}

/// Larger status row for the expanded notch panel. Shows the three
/// per-modality toggles plus a Pause / Open Search / Settings row.
public struct ScreenHistoryNotchPanelSection: View {
    @ObservedObject private var state = ScreenHistoryState.shared
    @AppStorage(ScreenHistoryDefaults.captureScreenKey) private var captureScreen: Bool = true
    @AppStorage(ScreenHistoryDefaults.captureMicKey) private var captureMic: Bool = false
    @AppStorage(ScreenHistoryDefaults.captureSystemAudioKey) private var captureSystemAudio: Bool = false

    public init() {}

    public var body: some View {
        if !state.isEnabled {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                modalityRow
                buttonRow
            }
            .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if state.isPaused {
            Image(systemName: "pause.circle.fill").foregroundColor(.yellow)
        } else if state.isRecordingScreen || state.isRecordingMic || state.isRecordingSystemAudio {
            Circle().fill(Color.red).frame(width: 8, height: 8)
        } else {
            Circle().fill(Color.gray.opacity(0.4)).frame(width: 8, height: 8)
        }
    }

    private var statusText: String {
        if state.isPaused { return "Paused" }
        if state.isRecordingScreen || state.isRecordingMic || state.isRecordingSystemAudio {
            let mins = Int(state.sessionDurationSeconds / 60)
            return "Recording · \(state.frameCount)f · \(mins)m"
        }
        return "Idle"
    }

    private var modalityRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $captureScreen) {
                Label("Screen", systemImage: "display")
            }
            .toggleStyle(.button)
            // FIX(mic-toggle-removed-2026-08-01): notch no longer
            // shows the passive Mic capture toggle. PTT audio keeps
            // transcribing via HeyClickyRealtime.
            let _ = captureMic
            Toggle(isOn: $captureSystemAudio) {
                Label("System", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.button)
        }
        .font(.system(size: 10, weight: .medium))
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button {
                state.isPaused.toggle()
            } label: {
                Label(state.isPaused ? "Resume" : "Pause",
                      systemImage: state.isPaused ? "play.fill" : "pause.fill")
            }
            Button {
                // Wired once ScreenHistoryWindowManager lands
                NotificationCenter.default.post(
                    name: .screenHistoryOpenSearch, object: nil)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            Button {
                NotificationCenter.default.post(
                    name: .screenHistoryOpenSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .buttonStyle(.bordered)
        .font(.system(size: 11))
    }
}

extension Notification.Name {
    public static let screenHistoryOpenSearch = Notification.Name("openclicky.screenHistory.openSearch")
    public static let screenHistoryOpenSettings = Notification.Name("openclicky.screenHistory.openSettings")
    /// Fired by `openrewind.showFrame` so AppState can seek the
    /// timeline to a specific past moment. userInfo["date"] = Date.
    public static let screenHistoryJumpToDate = Notification.Name("openclicky.screenHistory.jumpToDate")
}

/// Compact status pill for the notch top rail — renders a small badge
/// (red dot + relative time) when Screen History is recording, or a
/// paused icon when paused. Nothing when disabled. Click opens the
/// Screen History search window.
public struct ScreenHistoryStatusPill: View {
    @ObservedObject private var state = ScreenHistoryState.shared

    public init() {}

    public var body: some View {
        if !state.isEnabled {
            EmptyView()
        } else {
            Button {
                NotificationCenter.default.post(name: .screenHistoryOpenSearch, object: nil)
            } label: {
                HStack(spacing: 4) {
                    dot
                    Text(labelText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(state.isPaused ? "Resume recording" : "Pause recording") {
                    state.isPaused.toggle()
                }
                Button("Open Screen History") {
                    NotificationCenter.default.post(name: .screenHistoryOpenSearch, object: nil)
                }
                Divider()
                Button("Settings…") {
                    NotificationCenter.default.post(name: .screenHistoryOpenSettings, object: nil)
                }
            }
            .help("Screen History status. Right-click for quick controls.")
        }
    }

    @ViewBuilder
    private var dot: some View {
        if state.isPaused {
            Image(systemName: "pause.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 8, weight: .bold))
        } else {
            Circle().fill(Color.red).frame(width: 6, height: 6)
        }
    }

    private var labelText: String {
        if state.isPaused { return "Paused" }
        let f = state.frameCount
        return f == 0 ? "Recording" : "\(f) frames"
    }
}
