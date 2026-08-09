//
//  ScreenHistoryState.swift
//  cursor-buddy
//
//  Observable state published by OpenRewindBridge. All UI (notch,
//  menu bar, settings, response cards) binds to this shared instance
//  so the whole App stays in sync.
//
//  Fields default to "off" when Screen History is disabled; the bridge
//  writes values into them once capture starts.
//

import Foundation
import Combine

@MainActor
public final class ScreenHistoryState: ObservableObject {
    public static let shared = ScreenHistoryState()

    /// True when the user enabled Screen History in Settings and the
    /// bridge successfully initialised (permissions granted / passphrase
    /// loaded / capture coordinator boot).
    @Published public var isEnabled: Bool = false

    /// Whether the coordinator is paused (user pressed pause hotkey /
    /// panel button / low-power mode kicked in).
    @Published public var isPaused: Bool = false

    /// Per-modality live indicators.
    @Published public var isRecordingScreen: Bool = false
    @Published public var isRecordingMic: Bool = false
    @Published public var isRecordingSystemAudio: Bool = false

    /// Session counters, refreshed once/sec while capture runs.
    @Published public var frameCount: Int = 0
    @Published public var sessionDurationSeconds: TimeInterval = 0
    @Published public var lastFrameAt: Date? = nil

    /// Total vault size on disk in bytes. Cached, refreshed once per
    /// minute so we don't hammer the filesystem.
    @Published public var vaultBytes: Int64 = 0

    /// Non-nil when the coordinator failed to start (permission
    /// revoked, disk full, encoder crash budget exhausted). UI shows
    /// a warning affordance.
    @Published public var lastError: String? = nil

    private init() {}
}
