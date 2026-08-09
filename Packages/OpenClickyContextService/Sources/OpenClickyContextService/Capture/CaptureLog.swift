// Package-local logging hook.
//
// The SPM package has no dependency on the main-app HeyClickyLog store
// (which forwards into OpenClickyMessageLogStore, surfaced via
// `curl /agent/log/tail`). Rather than reach across the boundary from
// inside Capture/, every AX/platform boundary in this package emits a
// structured event through `CaptureLog.log`, and the main app installs
// a sink via `CaptureLog.setSink { ... HeyClickyLog.log(...) }` early in
// startup.
//
// Design:
//   * Zero cost when no sink is installed (single load + nil check).
//   * Thread-safe via NSLock; sink invocations happen on the caller
//     thread so a slow sink cannot back up capture work — the main-app
//     sink itself is expected to be async (dispatch to
//     OpenClickyMessageLogStore's writeQueue).
//   * NO PII fields are captured here. `fields` values must be small
//     Sendable primitives (Int/Double/Bool/String) already sanitised by
//     the caller — we do not walk them or redact.
//   * Byte-exact audit trail: each caller passes `event` in the form
//     `openclicky.<subsystem>.<action>` — the layer-0 audit report at
//     docs/ROADMAP/.review-notes/layer0-ax-platform-byte-exact-*.md
//     enumerates them.

import Foundation

/// Structured event emitted by any capture-boundary call inside the
/// package. The main app installs a sink that forwards to
/// `OpenClickyMessageLogStore` via `HeyClickyLog.log`.
public struct CaptureLogEvent: Sendable {
    /// Dotted event id, e.g. `openclicky.ax.focused_element`.
    public let event: String

    /// Lane bucket for the log viewer. Matches OpenClickyMessageLogStore
    /// lanes: `voice`, `agent`, `system`, `sensor`, `overlay`, `pick`,
    /// `whiteboard`. Capture events use `sensor` by default.
    public let lane: String

    /// `internal` | `outgoing` | `incoming` | `error`. Capture events
    /// use `internal` (side-effect-free reads) or `error` (AX/API
    /// failure).
    public let direction: String

    /// String-serialisable fields. Caller is responsible for keeping the
    /// payload small and PII-free.
    public let fields: [String: String]

    public init(event: String, lane: String, direction: String, fields: [String: String]) {
        self.event = event
        self.lane = lane
        self.direction = direction
        self.fields = fields
    }
}

public enum CaptureLog {

    /// Sink type. `@Sendable` so the closure can hop threads freely.
    public typealias Sink = @Sendable (CaptureLogEvent) -> Void

    private static let lock = NSLock()
    private static var _sink: Sink?

    /// Install the process-wide log sink. Passing nil clears the sink.
    /// The main app calls this once at app-delegate startup.
    public static func setSink(_ sink: Sink?) {
        lock.lock()
        _sink = sink
        lock.unlock()
    }

    /// Emit a structured event. No-op when no sink is installed.
    ///
    /// `event` naming convention: `openclicky.<subsystem>.<action>`. The
    /// layer-0 audit report enumerates every emit point.
    public static func log(
        _ event: String,
        lane: String = "sensor",
        direction: String = "internal",
        _ fields: [String: String] = [:]
    ) {
        lock.lock()
        let s = _sink
        lock.unlock()
        guard let s else { return }
        s(CaptureLogEvent(event: event, lane: lane, direction: direction, fields: fields))
    }

    /// Fast-check for gated instrumentation (e.g. per-node walk logs
    /// that a caller wants to skip when no sink is installed).
    public static var isSinkInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _sink != nil
    }
}
