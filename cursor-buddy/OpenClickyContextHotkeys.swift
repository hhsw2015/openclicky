// OpenClickyContextHotkeys.swift
// cursor-buddy
//
// Global CGEvent tap that dispatches the five Layer 4 "Context
// Awareness" hotkeys (Phase 7):
//
//   1. SnapshotContext     — write context-stash.json
//   2. ClearContextStash   — wipe stash file + PickStash/AnnotationStash/
//                            WhiteboardStash
//   3. AgentPickElement    — AX-pick the element under the pointer and
//                            push it into PickStash
//   4. Whiteboard          — press-hold placeholder (stub; drawing
//                            overlay is later)
//   5. LinkRect            — press-drag placeholder (stub)
//
// All five bindings live in `OpenClickyContextAwarenessSettings`.
// Defaults are seeded to match the user's live Everywhere config:
//   SnapshotContext    ⇧Space
//   ClearContextStash  ⌥C
//   AgentPickElement   ⌥S
//   Whiteboard         ⌥D
//   LinkRect           ⌥L
// One-shot seeding is guarded by `seededDefaultsSentinelKey`; cleared
// bindings stay cleared on relaunch (`OpenClickyContextAwarenessSettings.swift:222-246`).
//
// Design notes vs. `GlobalPushToTalkShortcutMonitor.swift`
// (the sibling CGEvent tap we mirror):
//   * We register a single `.defaultTap` tap for the whole app rather
//     than one tap per action. Matched hotkeys return nil from the
//     callback so the OS swallows the keystroke (Shift+Space won't
//     leak a literal space into the frontmost text field). Unmatched
//     events pass through unchanged.
//   * We suppress rapid re-fires per action (1.5s window), matching
//     Everywhere's `SnapshotContextHotkeyInitializer.RepeatSuppressionMs
//     = 1500` @30e03e9d.
//   * We delay the actual action by 180ms after the keyDown edge
//     (`OpenClickyContextAwarenessSettings.modifierReleaseDelay`),
//     matching Everywhere's `MacosModifierReleaseDelayMs = 180` so the
//     downstream AX / clipboard capture doesn't observe the still-held
//     Command flag.
//   * Actions run on the main queue since three of the five poke UI
//     state (PickStash notifications, WhiteboardStash) or need
//     `@MainActor` (`OpenClickyContextStashWriter.captureAsync`).
//
// The tap is started by `CompanionManager` inside its accessibility
// permission gate (accessibility is required for AX-pick and for
// CGEvent taps generally on modern macOS).

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import OpenClickyContextService

final class OpenClickyContextHotkeys: ObservableObject {
    /// The single writer used by SnapshotContext / ClearContextStash.
    /// Routes through `OpenClickyContextStashWriter.shared` so
    /// `writeLock` and `_phraseInFlight` guards coalesce with the
    /// auto-capture paths (whiteboard commit, pin release, LinkRect)
    /// that also reach for the shared singleton. Previously this was
    /// a fresh instance so the two singletons never coalesced — see
    /// audit note "Two singletons for the stash writer" in
    /// hotkey-path-audit-2026-07-23.md. Computed rather than stored
    /// because `.shared` is `@MainActor`-isolated and this class is
    /// not (started from the CGEvent tap thread).
    @MainActor
    private var stashWriter: OpenClickyContextStashWriter {
        OpenClickyContextStashWriter.shared
    }

    /// Snapshot of the settings singleton. Held so we can unsubscribe
    /// cleanly and read `activeBindings` without hopping through Combine
    /// on the hot CGEvent thread.
    private let settings: OpenClickyContextAwarenessSettings

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Per-action last-fire timestamp for repeat suppression.
    /// Accessed only from the main queue (see `handleActionFired`).
    private var lastFireByAction: [OpenClickyContextHotkeyAction: Date] = [:]

    /// Small logging helper so tests / users can grep the stub actions.
    private static let logCategory = "openclicky.contextAwareness.hotkey"

    init(settings: OpenClickyContextAwarenessSettings = .shared) {
        self.settings = settings
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Idempotent. Safe to call multiple times — the tap is only
    /// installed once and subsequent calls are no-ops.
    func start() {
        guard eventTap == nil else { return }

        // Toggle semantics: every action (including whiteboard) fires on
        // keyDown only. Whiteboard's first press opens the overlay, a
        // second keyDown commits (matches Everywhere OnHotkey @30e03e9d).
        let monitoredTypes: [CGEventType] = [.keyDown]
        let eventMask = monitoredTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let owner = Unmanaged<OpenClickyContextHotkeys>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            // Returns true when the event matched a hotkey binding and
            // was consumed. In that case we return nil so the OS drops
            // the event before it reaches the frontmost app (so
            // Shift+Space doesn't leak a literal space into whatever
            // text field is focused). Matches Everywhere's
            // `CGEventShortcutListener.HandleKeyDown` at
            // `src/Everywhere.Mac/Interop/CGEventShortcutListener.cs:84`
            // where `cgEventRef = 0` swallows the event.
            let consumed = owner.handleGlobalEventTap(eventType: eventType, event: event)
            if consumed {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // HID tap matches Everywhere's `CGEventTapLocation.HID`
        // (`Everywhere.Mac/Interop/CGEventListener.cs:70`). HID sees
        // events earlier in the stream than `.cgSessionEventTap`,
        // catching key repeats and remapped keys before session-level
        // filtering.
        //
        // macOS 26 REGRESSION FIX: `.defaultTap` requires the Input
        // Monitoring TCC surface (kIOHIDCheckAccess) IN ADDITION TO
        // Accessibility. Older macOS granted `.defaultTap` on
        // Accessibility alone. On macOS 26 the tap silently fails to
        // install without Input Monitoring, so no keystroke ever
        // reaches the callback. Fall back to `.listenOnly` which
        // Accessibility alone satisfies. The trade-off: matched
        // hotkeys can't be swallowed, so Shift+Space will leak a
        // literal space into the frontmost text field. That's the
        // Everywhere baseline behaviour (`CGEventTapOptions.ListenOnly`
        // in `Everywhere.Mac/Interop/CGEventListener.cs`).
        // TODO: when Input Monitoring is confirmed granted, upgrade to
        // .defaultTap so we can swallow matched keystrokes.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("\(Self.logCategory): couldn't create CGEvent tap (accessibility permission missing?)")
            // Layer 5 byte-exact audit (2026-07-23): surface the install
            // failure in Settings -> Logs so users can diagnose macOS 26
            // Input Monitoring / Accessibility permission drift without
            // grepping Console.app. Payload mirrors the Everywhere
            // `PermissionHelper.EnsureAccessibilityTrusted` throw path
            // in `Everywhere.Mac/Interop/CGEventListener.cs:36`.
            HeyClickyLog.log(
                "openclicky.hotkey.tap_install_failed",
                lane: "system",
                direction: "error",
                ["reason": "CGEvent.tapCreate returned nil (accessibility permission missing?)"]
            )
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            NSLog("\(Self.logCategory): couldn't create run loop source")
            HeyClickyLog.log(
                "openclicky.hotkey.tap_install_failed",
                lane: "system",
                direction: "error",
                ["reason": "CFMachPortCreateRunLoopSource returned nil"]
            )
            return
        }

        self.eventTap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Success telemetry — the F22 fix note calls out that on macOS 26
        // the tap can silently fail to install without Input Monitoring
        // (see the `.listenOnly` comment above). Emitting a positive
        // event here means "tap alive on this launch" is greppable from
        // the log viewer without attaching a debugger.
        HeyClickyLog.log(
            "openclicky.hotkey.tap_installed",
            lane: "system",
            [
                "location": "cghidEventTap",
                "options": "listenOnly",
                "event_mask": String(eventMask, radix: 16)
            ]
        )
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - CGEvent tap callback

    /// Returns `true` when the event was consumed (matched a hotkey
    /// binding) and should be swallowed. The tap callback drops the
    /// event before it reaches the frontmost app in that case.
    private func handleGlobalEventTap(eventType: CGEventType, event: CGEvent) -> Bool {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        guard eventType == .keyDown else { return false }

        // Cheap early-out. `activeBindings` is O(5) but we still skip
        // touching the settings singleton on every keystroke when the
        // master toggle is off.
        guard settings.masterEnabled else { return false }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // Toggle semantics (Everywhere `WhiteboardHotkeyInitializer.OnHotkey`
        // @30e03e9d: `if (_activeOverlay is not null) Commit(); else open`).
        // Only keyDown matters — keyUp is ignored for every action.
        for (action, binding) in settings.activeBindings {
            if binding.matches(keyCode: keyCode, flags: flags) {
                HeyClickyLog.log(
                    "openclicky.hotkey.matched_binding",
                    lane: "system",
                    [
                        "action": action.rawValue,
                        "keycode": Int(keyCode),
                        "modifiers": String(binding.normalisedModifiers, radix: 16)
                    ]
                )
                enqueueAction(action)
                return true
            }
        }
        // Layer 5 audit: log the unmatched keystroke ONLY when the user
        // was actually holding a modifier. Matched keystrokes are
        // covered by `matched_binding` above; without the modifier
        // gate this would fire for every literal keypress during
        // normal typing. `flags_masked` is what we actually compare
        // against (`OpenClickyHotkeyBinding.significantModifierMask`).
        let masked = flags.rawValue & OpenClickyHotkeyBinding.significantModifierMask
        if masked != 0 {
            HeyClickyLog.log(
                "openclicky.hotkey.raw_event",
                lane: "system",
                [
                    "keycode": Int(keyCode),
                    "flags_raw": String(flags.rawValue, radix: 16),
                    "flags_masked": String(masked, radix: 16)
                ]
            )
        }
        return false
    }

    /// Called from the CGEvent tap thread. Hops to main and applies
    /// repeat suppression. Non-whiteboard actions defer by
    /// `modifierReleaseDelay` so downstream AX / clipboard captures
    /// don't see the still-held modifier bits. Whiteboard skips the
    /// delay because the toggle branch (`performWhiteboardBegin`)
    /// reads `OpenClickyWhiteboardOverlayWindow.shared.isActive`
    /// directly, so the "open" vs "commit" decision must happen
    /// synchronously to stay in sync with the CGEvent stream.
    private func enqueueAction(_ action: OpenClickyContextHotkeyAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastFireByAction[action],
               now.timeIntervalSince(last) < OpenClickyContextAwarenessSettings.repeatSuppressionInterval {
                // Matches Everywhere's suppression log at
                // `SnapshotContextHotkeyInitializer.cs:130`
                // (`"Snapshot hotkey re-fired within {Ms}ms; ignoring"`).
                let elapsedMs = Int(now.timeIntervalSince(last) * 1000)
                HeyClickyLog.log(
                    "openclicky.hotkey.repeat_suppressed",
                    lane: "system",
                    [
                        "action": action.rawValue,
                        "elapsed_ms": elapsedMs
                    ]
                )
                return
            }
            self.lastFireByAction[action] = now
            if action == .whiteboard {
                // Toggle semantics: performWhiteboardBegin handles both
                // "open overlay" and "commit active overlay" branches.
                // Skip the modifier-release delay so the overlay opens
                // (or commits) with no perceptible latency.
                self.performAction(action)
                return
            }
            // Everywhere's `MacosModifierReleaseDelayMs = 180`
            // (`SnapshotContextHotkeyInitializer.cs:107`) is applied
            // before every non-whiteboard action so the downstream AX
            // capture doesn't observe the still-held modifier bits.
            let delayMs = Int(OpenClickyContextAwarenessSettings.modifierReleaseDelay * 1000)
            HeyClickyLog.log(
                "openclicky.hotkey.modifier_release_delay_start",
                lane: "system",
                [
                    "action": action.rawValue,
                    "delay_ms": delayMs
                ]
            )
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OpenClickyContextAwarenessSettings.modifierReleaseDelay
            ) { [weak self] in
                self?.performAction(action)
            }
        }
    }

    /// Whiteboard toggle semantics: keyDown opens the overlay, second
    /// keyDown commits (see `performWhiteboardBegin`). There is no
    /// keyUp path — the CGEvent tap only monitors `.keyDown`.

    // MARK: - Actions

    @MainActor
    private func performAction(_ action: OpenClickyContextHotkeyAction) {
        switch action {
        case .snapshotContext:
            performSnapshotContext()
        case .clearContextStash:
            performClearContextStash()
        case .agentPickElement:
            performAgentPickElement()
        case .whiteboard:
            performWhiteboardBegin()
        case .linkRect:
            performLinkRectStub()
        case .screenHistoryOpenSearch:
            // Toggle semantics: press once to show, press again to hide.
            ScreenHistoryWindowManager.shared.toggle()
        case .screenHistoryPauseToggle:
            ScreenHistoryState.shared.isPaused.toggle()
        case .screenHistoryOpenSettings:
            NotificationCenter.default.post(
                name: .screenHistoryOpenSettings, object: nil)
        }
    }

    @MainActor
    private func performSnapshotContext() {
        NSLog("\(Self.logCategory): snapshotContext fired")
        HeyClickyLog.log(
            "openclicky.hotkey.snapshot_context.fired",
            lane: "system"
        )
        let writer = stashWriter
        Task { @MainActor in
            await writer.captureAsync()
        }
    }

    @MainActor
    private func performClearContextStash() {
        NSLog("\(Self.logCategory): clearContextStash fired")
        stashWriter.clearStash()
        PickStash.shared.clearWithEvent()
        AnnotationStash.shared.clearWithEvent()
        WhiteboardStash.shared.clearWithEvent()
    }

    @MainActor
    private func performAgentPickElement() {
        NSLog("\(Self.logCategory): agentPickElement fired -> pick overlay")
        HeyClickyLog.log(
            "openclicky.hotkey.agent_pick_element.fired",
            lane: "system"
        )
        // Phase 7.1: hand off to the visual crosshair overlay. The
        // overlay renders per-screen dim + green outline for the AX
        // element under the pointer, and on click writes into
        // PickStash.shared (and OpenClickyPinnedAXElementRegistry so
        // the annotation badge overlay can install its AXFollower).
        OpenClickyPickElementOverlay.shared.begin()
    }

    @MainActor
    /// Whiteboard hotkey — TOGGLE semantics matching Everywhere.
    /// First press opens the overlay; the user then makes as many
    /// strokes as they want. Second press of the same hotkey commits
    /// (via OverlayWindow.end() which runs the classifier + OCR +
    /// stash). Esc still cancels without committing.
    /// See Everywhere `WhiteboardHotkeyInitializer.OnHotkey` @30e03e9d
    /// (`_activeOverlay is not null → Commit()`).
    private func performWhiteboardBegin() {
        // Read the overlay's actual isActive rather than a local mirror
        // so an Escape-cancel that drops the overlay independently
        // still resets our view of the state. Matches Everywhere's
        // `_activeOverlay is not null` check (`WhiteboardHotkeyInitializer.cs:144`).
        if OpenClickyWhiteboardOverlayWindow.shared.isActive {
            NSLog("\(Self.logCategory): whiteboard hotkey (already active) -> end() commit")
            OpenClickyWhiteboardOverlayWindow.shared.end()
            return
        }
        NSLog("\(Self.logCategory): whiteboard hotkey -> begin()")
        OpenClickyWhiteboardOverlayWindow.shared.begin()
    }

    /// Guards against re-entrancy: while the overlay is up, further
    /// LinkRect presses are ignored (Everywhere runs a single
    /// `LinkRectSession` at a time — same policy here).
    private var linkRectOverlay: OpenClickyLinkRectOverlayWindow?

    @MainActor
    private func performLinkRectStub() {
        NSLog("\(Self.logCategory): linkrect hotkey pressed")
        guard linkRectOverlay == nil else {
            NSLog("\(Self.logCategory): linkrect already active — ignoring re-fire")
            return
        }
        linkRectOverlay = OpenClickyLinkRectOverlayWindow.present { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                NSLog("\(Self.logCategory): linkrect cancelled")
                // Overlay already dismissed itself on the .cancelled
                // branch (see OpenClickyLinkRectOverlayWindow.ended).
                self.linkRectOverlay = nil
                return
            case .rect(let dragRect):
                NSLog("\(Self.logCategory): linkrect drag=\(dragRect) — harvesting")
                // Byte-exact port of VisualElementContext.LinkRect.cs:57-72:
                // OnLeftButtonUp resolves the promise WITHOUT closing;
                // HarvestAsync then runs HarvestLinks with the overlay
                // still visible, and calls `Close()` in the finally
                // block AFTER harvest is done. This keeps the drag
                // rect painted through harvest so the user sees the
                // capture area until the overlay drops, and prevents
                // the launch-phrase-fires-before-overlay-dismisses
                // race.
                self.harvestAndPersistLinkRect(dragRect: dragRect)
            }
        }
    }

    @MainActor
    private func harvestAndPersistLinkRect(dragRect: CGRect) {
        // Grab the overlay ref on the main actor so we can dismiss
        // it without racing with a subsequent Alt+L press. Cleared
        // here so the reentrancy guard in performLinkRectStub sees
        // "no active overlay" after this returns.
        let overlayRef = linkRectOverlay
        linkRectOverlay = nil
        // Harvest is CPU-bound (AX walk up to 50k nodes); hop off
        // main so we don't stall the run loop on wide multi-app
        // rects. The write itself is main-actor so we hop back for
        // dismiss + captureLinks.
        Task.detached(priority: .userInitiated) {
            let result = OpenClickyLinkRectHarvester.harvest(dragRect: dragRect)
            NSLog(
                "\(OpenClickyContextHotkeys.logCategory): linkrect harvest picks=\(result.picks.count) " +
                "candidates=\(result.candidatesSeen) nodes=\(result.nodesVisited) " +
                "budgetExhausted=\(result.budgetExhausted)")
            let pairs: [(title: String, url: String)] = result.picks.map {
                (title: $0.title ?? "", url: $0.url)
            }
            let flashRects = result.pickBounds.filter { $0.width > 0 && $0.height > 0 }
            // Byte-exact port of VisualElementContext.LinkRect.cs:57-70:
            // paint the aqua highlight over every captured anchor rect
            // BEFORE closing the overlay, wait 700ms so the user sees
            // which links were harvested, then hop back to main and
            // dismiss the overlay before firing the launch phrase.
            //
            // Only paint when we actually harvested links; a zero-pick
            // result matches Everywhere's `if (harvested.Count > 0)`
            // guard at LinkRect.cs:60 that skips the flash entirely
            // when there is nothing to highlight.
            if !flashRects.isEmpty {
                await MainActor.run {
                    overlayRef?.highlightCapturedLinks(rects: flashRects)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                await MainActor.run {
                    overlayRef?.logFlashEnd(rectCount: flashRects.count)
                }
            }
            // Hop back to main so we can dismiss the overlay on the
            // UI thread BEFORE captureLinks fires the launch phrase.
            // Matches Everywhere's VisualElementContext.LinkRect.cs:69
            // `await Dispatcher.UIThread.InvokeAsync(window!.Close)`
            // running before `LinkRectHotkeyInitializer.cs:165`
            // calls `CaptureLinksAsync`.
            await MainActor.run {
                overlayRef?.dismiss()
            }
            // Unified capture flow (divergence from Everywhere): don't
            // direct-ship. Only stage the links in `LinkRectStash`;
            // Shift+Space (SnapshotContext) is the sole flush point.
            // This keeps Alt+L / Alt+D / Alt+S / clipboard all queued
            // under one envelope so consumers (cmux OR voice) see a
            // consistent context bundle.
            let picked = pairs.map { OpenClickyPickedLink(url: $0.url, title: $0.title.isEmpty ? nil : $0.title) }
            await MainActor.run {
                LinkRectStash.shared.set(picked)
            }
        }
    }

    /// Public entry point used by the Settings "Fire test snapshot"
    /// action so the user can verify the wiring without picking a
    /// hotkey first.
    func fireTestSnapshot() {
        DispatchQueue.main.async { [weak self] in
            self?.performSnapshotContext()
        }
    }

    // AX hit-testing lives inside OpenClickyPickElementOverlay now
    // (Phase 7.1). The legacy inline helpers were removed with the
    // move to the visual overlay.
}
