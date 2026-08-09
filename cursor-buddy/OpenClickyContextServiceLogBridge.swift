//
//  OpenClickyContextServiceLogBridge.swift
//  cursor-buddy
//
//  Forwards `CaptureLog` events emitted from the OpenClickyContextService
//  SPM package into the main-app `HeyClickyLog` + `OpenClickyMessageLogStore`
//  pipe, so every AX / AppleScript / CGEvent boundary in the package is
//  visible via `curl /agent/log/tail` at runtime.
//
//  The package itself carries no dependency on the main app (see
//  Capture/CaptureLog.swift). This bridge installs a process-wide sink
//  exactly once at app-delegate startup.
//

import Foundation
import OpenClickyContextService

enum OpenClickyContextServiceLogBridge {

    /// Install the CaptureLog -> HeyClickyLog forwarder. Called from
    /// `CompanionAppDelegate.applicationDidFinishLaunching`.
    static func install() {
        CaptureLog.setSink { event in
            // Convert the package's `[String: String]` field bag into the
            // main-app store's `[String: Any]` shape without wrapping the
            // strings in any extra decoration — layer-0 auditing wants
            // byte-identical field values from the source AX/API call.
            var fields: [String: Any] = [:]
            fields.reserveCapacity(event.fields.count)
            for (k, v) in event.fields { fields[k] = v }
            HeyClickyLog.log(
                event.event,
                lane: event.lane,
                direction: event.direction,
                fields
            )
        }
        HeyClickyLog.log(
            "capture_service.log_sink_installed",
            lane: "system",
            direction: "internal",
            ["sink": "context_service"]
        )
    }
}
