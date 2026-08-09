// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacIdleTimeReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Captures the seconds since the user last touched any input device on
// macOS. 1:1 semantic port of Everywhere's `MacIdleTimeReader`:
//   - Backing API: CoreGraphics `CGEventSourceSecondsSinceLastEventType`.
//   - `stateID` = combined session state (Everywhere passes literal `0`;
//     Swift's typed enum equivalent is `.combinedSessionState`, whose
//     `rawValue` is `0`).
//   - `eventType` = the "any input event" sentinel. Everywhere passes
//     `uint.MaxValue` (`0xFFFFFFFF`, aka `~0`); CoreGraphics documents
//     that any out-of-range event-type value returns the age of the most
//     recent event of any type. Swift's `CGEventType` is a strict enum,
//     so we construct the sentinel via `CGEventType(rawValue: ~0)!`. This
//     matches Apple's own sample-code convention (kCGAnyInputEventType).
//
// Behavioural deviations from Everywhere:
//   - Everywhere returns `0` when the underlying call throws. openclicky
//     returns `nil` from `capture()` when the reading is unusable (the
//     framework returned a negative value, which is documented as
//     "invalid"). Real readings, including `0.0`, produce a non-nil
//     `IdleTimeInfo`. Callers who need Everywhere's exact "coalesce to
//     zero" shape can do `capture()?.seconds ?? 0`.
//   - Return type is wrapped in `IdleTimeInfo` for parity with sibling
//     captures (`FrontmostAppInfo`, `ClipboardInfo`). The underlying
//     numeric value and unit (seconds, floating point) are unchanged.

import Foundation
import CoreGraphics

/// Reads the seconds since the last input event of any type on macOS.
///
/// Wraps `CGEventSourceSecondsSinceLastEventType` - the canonical
/// CoreGraphics API for user-idle detection and the same source
/// Everywhere reads (via P/Invoke) in `MacIdleTimeReader.cs`.
public enum IdleTimeCapture {

    /// Sentinel event type meaning "any input event". Matches
    /// Everywhere's literal `uint.MaxValue` (`0xFFFFFFFF`). CoreGraphics
    /// documents this as `kCGAnyInputEventType` in its C API.
    private static let anyInputEventType: CGEventType = {
        // `CGEventType(rawValue: ~0)` is always non-nil because the
        // enum's storage is `UInt32` and Swift's raw-value init accepts
        // any bit pattern (there's no discrete-case validation for
        // `CGEventType`). Force-unwrap is safe.
        return CGEventType(rawValue: ~0)!
    }()

    /// Returns the current idle-time reading, or `nil` if the underlying
    /// CoreGraphics call reports an invalid (negative) value.
    ///
    /// Semantic parity with Everywhere:
    ///   * Non-negative reading -> `IdleTimeInfo(seconds: reading)`.
    ///     Includes `0.0` (matches Everywhere's "user just typed"
    ///     return).
    ///   * Negative reading (documented as "invalid" by CoreGraphics)
    ///     -> `nil`. Everywhere's C# path never observes this because
    ///     P/Invoke does not surface it; on the Swift side we prefer
    ///     to surface the failure than silently coalesce to `0`.
    public static func capture() -> IdleTimeInfo? {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEventType
        )
        if seconds < 0 {
            CaptureLog.log("openclicky.idle.negative_reading",
                           direction: "error",
                           ["seconds": "\(seconds)"])
            return nil
        }
        CaptureLog.log("openclicky.idle.capture",
                       ["seconds": String(format: "%.2f", seconds)])
        return IdleTimeInfo(seconds: seconds)
    }
}
