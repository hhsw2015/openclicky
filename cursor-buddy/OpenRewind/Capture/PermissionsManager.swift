// PermissionsManager — TCC checks + prompts for Screen Recording,
// Accessibility, Microphone, Input Monitoring.
//
// Uses:
//   • CGRequestScreenCaptureAccess / CGPreflightScreenCaptureAccess
//   • AXIsProcessTrustedWithOptions
//   • AVCaptureDevice.requestAccess(for: .audio)
//   • IOHIDCheckAccess (soft; the framework's constants aren't uniformly
//     exposed in every SDK, so we bracket with #if canImport(IOKit.hid))
//
// This file has zero side effects until `requestAll()` is called.

import Foundation
import CoreGraphics
import AVFoundation
import ApplicationServices
#if canImport(IOKit)
import IOKit.hid
#endif

public actor PermissionsManager {

    public enum Status: String, Sendable {
        case granted, denied, notDetermined, unknown
    }

    public struct Snapshot: Sendable {
        public var screenRecording: Status
        public var accessibility: Status
        public var microphone: Status
        public var inputMonitoring: Status
        public init(screenRecording: Status,
                    accessibility: Status,
                    microphone: Status,
                    inputMonitoring: Status) {
            self.screenRecording = screenRecording
            self.accessibility = accessibility
            self.microphone = microphone
            self.inputMonitoring = inputMonitoring
        }
        public var allGranted: Bool {
            screenRecording == .granted &&
            accessibility == .granted &&
            microphone == .granted &&
            inputMonitoring == .granted
        }
    }

    public init() {}

    // MARK: Checks

    public func status() -> Snapshot {
        Snapshot(
            screenRecording: screenRecordingStatus(),
            accessibility: accessibilityStatus(),
            microphone: microphoneStatus(),
            inputMonitoring: inputMonitoringStatus()
        )
    }

    public func screenRecordingStatus() -> Status {
        // CGPreflightScreenCaptureAccess is macOS 10.15+; returns Bool.
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    public func accessibilityStatus() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    public func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:      return .granted
        case .denied:          return .denied
        case .restricted:      return .denied
        case .notDetermined:   return .notDetermined
        @unknown default:      return .unknown
        }
    }

    public func inputMonitoringStatus() -> Status {
        #if canImport(IOKit)
        // IOHIDCheckAccess is available macOS 10.15+ but the `kIOHIDRequestTypeListenEvent`
        // constant isn't exposed in every SDK. Use its raw value (0).
        let listenEvent: UInt32 = 0
        let req = IOHIDRequestType(rawValue: listenEvent)
        let raw = IOHIDCheckAccess(req)
        switch raw {
        case kIOHIDAccessTypeGranted:      return .granted
        case kIOHIDAccessTypeDenied:       return .denied
        case kIOHIDAccessTypeUnknown:      return .notDetermined
        default:                           return .unknown
        }
        #else
        return .unknown
        #endif
    }

    // MARK: Requests

    /// Request every capability we care about. Non-blocking system prompts
    /// where possible; falls back to opening System Settings otherwise.
    @discardableResult
    public func requestAll() async -> Snapshot {
        _ = requestScreenRecording()
        _ = requestAccessibility()
        _ = await requestMicrophone()
        _ = requestInputMonitoring()
        return status()
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        // Triggers the system prompt if not previously determined.
        return CGRequestScreenCaptureAccess()
    }

    @discardableResult
    public func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    @discardableResult
    public func requestInputMonitoring() -> Bool {
        #if canImport(IOKit)
        // FIX(review-2026-07-28) C-L (LOW "unreachable return false"): the
        // trailing return was dead code; deleted.
        let listenEvent: UInt32 = 0
        let req = IOHIDRequestType(rawValue: listenEvent)
        return IOHIDRequestAccess(req)
        #else
        return false
        #endif
    }
}
