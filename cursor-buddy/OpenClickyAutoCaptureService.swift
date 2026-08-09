// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/AutoCaptureService.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Auto-refresh the OpenClicky context stash whenever the user pins a UI
// element via AgentPickElement. Selection / clipboard auto-capture were
// intentionally removed upstream — they fired on terminal cursor moves and
// any-app Cmd-C, leaking noise into every Claude Code prompt. Only
// deliberate pin actions trigger here. The manual SnapshotContext hotkey
// still works as an explicit override.
//
// Gated on `OpenClickyContextAwarenessSettings.autoCaptureContext`: when
// the toggle flips, we (de)register the pin observer. Stash file lifetime
// and Take semantics are unchanged.
//
// C# subscribes to `PickStash.Pinned`; the Swift port subscribes to the
// `pickStashDidChange` NotificationCenter event (PickStash.swift:36) which
// fires on set/take/clear. We debounce and re-check `hasFreshPin` so the
// clear/take transitions do not double-fire captureAsync().

import Foundation
import OpenClickyContextService

/// Process-wide auto-capture arbiter. One instance mounted from
/// `CompanionManager` alongside `contextAwarenessHotkeys`.
///
/// Mirrors `Everywhere.Mcp.Snapshot.AutoCaptureService`
/// (AutoCaptureService.cs:20-107).
@MainActor
public final class OpenClickyAutoCaptureService {

    /// Process-wide singleton. `CompanionManager` boot path (start() call)
    /// aligns with the same accessibility gate `contextAwarenessHotkeys`
    /// uses so we never subscribe before AX permission lands.
    public static let shared = OpenClickyAutoCaptureService()

    /// Debounce window between rapid `pickStashDidChange` events. Everywhere
    /// hands off the event to the Avalonia UI thread via `Dispatcher.UIThread.Post`
    /// which naturally coalesces same-tick fires; we get the same effect by
    /// dropping events that arrive inside the window. Sized ~100ms per the
    /// task spec ("Everywhere uses ~100ms"). Enough headroom to absorb
    /// pickStashDidChange from `set`->immediate `take` chains without
    /// silently dropping the actual pin write.
    private static let debounceInterval: TimeInterval = 0.1

    private let settings: OpenClickyContextAwarenessSettings
    private let writer: OpenClickyContextStashWriter
    private let pickStash: PickStash
    private let notificationCenter: NotificationCenter

    private var observer: NSObjectProtocol?
    private var settingsObservation: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false
    /// Guards against re-entrant `writer.captureAsync()` — mirrors
    /// `Interlocked.Exchange(ref _running, 1)` (AutoCaptureService.cs:83).
    private var captureInFlight = false

    init(
        settings: OpenClickyContextAwarenessSettings = .shared,
        writer: OpenClickyContextStashWriter? = nil,
        pickStash: PickStash = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.settings = settings
        self.writer = writer ?? OpenClickyContextStashWriter.shared
        self.pickStash = pickStash
        self.notificationCenter = notificationCenter
    }

    // MARK: - Lifecycle

    /// Apply the current `autoCaptureContext` toggle and start listening
    /// for toggle changes. Idempotent — safe to call multiple times.
    /// Mirrors `AutoCaptureService.InitializeAsync` (AutoCaptureService.cs:45-56).
    public func start() {
        guard settingsObservation == nil else { return }
        apply(enabled: settings.autoCaptureContext)
        settingsObservation = notificationCenter.addObserver(
            forName: Self.autoCaptureContextChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(enabled: self.settings.autoCaptureContext)
            }
        }
    }

    /// Tear down subscriptions. Mirrors `AutoCaptureService.Dispose`
    /// (AutoCaptureService.cs:102-106).
    public func stop() {
        if let obs = settingsObservation {
            notificationCenter.removeObserver(obs)
            settingsObservation = nil
        }
        stopPickListener()
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Kept in sync with settings toggle. Mirrors `Apply(bool)`
    /// (AutoCaptureService.cs:58-63).
    private func apply(enabled: Bool) {
        if enabled { startPickListener() } else { stopPickListener() }
    }

    private func startPickListener() {
        guard !isRunning else { return }
        isRunning = true
        observer = notificationCenter.addObserver(
            forName: .pickStashDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pickStashDidChange()
            }
        }
    }

    private func stopPickListener() {
        guard isRunning else { return }
        isRunning = false
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    // MARK: - Event -> capture pipeline

    /// Fires on every `pickStashDidChange` (set/take/clearWithEvent).
    /// Only trigger a capture when a fresh pin is still present -- the
    /// take/clear notifications also flow through here and we do NOT
    /// want to capture on a cleared stash. Mirrors Everywhere's
    /// `TryCapture(IVisualElement)` (AutoCaptureService.cs:81-100), which
    /// only fires from `PickStash.Pinned` and never from Cleared.
    private func pickStashDidChange() {
        guard pickStash.hasFreshPin else { return }
        // Coalesce burst notifications so a `set(...)` immediately
        // followed by a `.set(...)` replacement produces one capture,
        // not two. Cancel any in-flight timer and start a fresh one.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Re-check after the sleep: the pin may have been taken in
            // the debounce window, in which case Everywhere would never
            // have raised Pinned in the first place.
            guard self.pickStash.hasFreshPin else { return }
            await self.tryCapture()
        }
    }

    /// Ported from `AutoCaptureService.TryCapture` (AutoCaptureService.cs:81-100).
    /// Re-entrancy guard mirrors `Interlocked.Exchange(ref _running, 1)` --
    /// a second pin landing while writer.captureAsync is still awaiting
    /// its own single-flight lock silently coalesces.
    ///
    /// Note: Everywhere's Pinned event carries the element; the Swift
    /// side stores it in the singleton and the writer picks it up via
    /// `PickStash.shared.hasFreshPin` inside captureCoreAsync. This
    /// path calls `captureAsync()` without a seed — auto-capture is a
    /// pin-driven refresh, not a manual user event, so
    /// drainAnnotations stays false (`captureAsync` is manual; direct
    /// core call with drain=false matches Everywhere's `CaptureAsync(seed)`
    /// which passes drainAnnotations=false at ContextStashWriter.cs:180).
    private func tryCapture() async {
        if captureInFlight { return }
        captureInFlight = true
        defer { captureInFlight = false }
        await writer.captureAutoPin()
    }

    // MARK: - Settings-change signalling

    /// Emitted by `OpenClickyContextAwarenessSettings` when
    /// `autoCaptureContext` flips so this service can re-apply without a
    /// direct Combine dependency. Setter posts unconditionally on set
    /// (mirrors C# `PropertyChanged` semantics, AutoCaptureService.cs:48-54).
    public static let autoCaptureContextChanged = Notification.Name(
        "com.jkneen.openclicky.OpenClickyAutoCaptureService.AutoCaptureContextChanged"
    )
}
