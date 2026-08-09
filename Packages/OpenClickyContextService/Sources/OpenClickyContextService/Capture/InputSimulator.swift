// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacInputSimulator.cs + MacKeyCodes.cs + Interop/KeyMapping.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Native Swift port of Everywhere's `MacInputSimulator`. The C# side is
// the MCP `click` / `type_text` / `press_key` / `scroll` / `drag`
// backend for Everywhere. In openclicky, OCCU (via `LibAxHelper.dylib`)
// remains the primary MCP-tool implementation; this port serves
// openclicky-native use cases that do not go through MCP:
//
//   * LaunchPhrase injection (mirrors Everywhere's
//     `ContextStashWriter.TryFireLaunchPhrase`, which drives
//     `MacInputSimulator.PressKey` directly).
//   * Targeted keystroke / mouse dispatch from HUDs and macros where
//     the round-trip through OCCU + MCP would add unnecessary latency.
//
// Renamed from `MacInputSimulator` to `InputSimulator` deliberately —
// the "MCP" affiliation lives on the OCCU path, not here.
//
// Everywhere's C# posts events through P/Invoke to CoreGraphics; this
// port uses Swift's `CGEvent` API. Semantics preserved:
//
//   * Event tap = `.cghidEventTap` (HID system tap, byte-identical to
//     the C# `CGEventTapLocation.HidEventTap = 0`). Everywhere's own
//     comment (MacInputSimulator.cs L224-227) explains why: HID sits
//     below the session layer, so SwiftUI's gesture recognizers see
//     the events. Session-tap posts get filtered out and produce
//     regressions like the "Calculator '7' click looks fine but does
//     nothing". `SelectedTextCapture` in this package uses the same
//     tap for the same reason.
//   * Event source state = `.hidSystemState` (matches Everywhere's
//     non-targeted path). Targeted (per-pid) posting is not exposed
//     yet because the task's five public verbs are pid-less.
//   * `typeText` walks by extended grapheme cluster (Swift `for c in
//     text`) and posts via `CGEventKeyboardSetUnicodeString` in chunks
//     capped at 64 UTF-16 units — same limit OCCU / Everywhere use.
//   * `pressKey` accepts xdotool-style names, resolves the last token
//     as the main key and the earlier tokens as modifiers via the same
//     lookup tables as `MacKeyCodes.KeyByName` / `MacKeyCodes.Modifiers`.
//     Modifier keydowns run forward, keyups reverse — matches C#.
//   * `click` posts `MouseMoved` first, then `<btn>Down` + `<btn>Up`
//     with `mouseEventClickState` set to the click count (so double /
//     triple click land).
//   * `drag` uses 10 linearly interpolated `LeftMouseDragged` steps.
//   * `scroll` posts a two-axis `CGScrollEventUnit.Line` event.

import Foundation
import CoreGraphics
import Carbon.HIToolbox

// MARK: - MouseButton

/// Mouse buttons `InputSimulator.click` can dispatch. Mirrors
/// Everywhere `Everywhere.Mcp.Input.MouseButton` (used from
/// `MacInputSimulator.Click`). Kept file-local — no wire format yet.
public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

// MARK: - InputSimulator

/// Native input injection for openclicky. See file header for scope.
///
/// All functions are `@MainActor`-safe but do **not** require the main
/// actor — `CGEvent.post` is thread-safe. Callers may invoke from any
/// queue; each verb posts and returns immediately.
public enum InputSimulator {

    // MARK: Errors

    /// Errors raised by `pressKey` when the caller-supplied xdotool
    /// string cannot be resolved. Matches Everywhere's
    /// `ArgumentException` cases in `MacInputSimulator.PressKey`.
    public enum KeyError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case unknownModifier(String)
        /// `CGEvent(keyboardEventSource:virtualKey:keyDown:)` returned
        /// nil for the main key. Everywhere raises
        /// `InvalidOperationException("Failed to create key event.")`
        /// in the equivalent branch (`MacInputSimulator.cs:154-158`);
        /// mirrored here so LaunchPhrase can log a broken chord instead
        /// of dispatching a partial one.
        case eventCreationFailed(key: String)

        public var description: String {
            switch self {
            case .empty:
                return "key name is empty"
            case .unknownKey(let name):
                return "unsupported key '\(name)'"
            case .unknownModifier(let name):
                return "unsupported modifier '\(name)'"
            case .eventCreationFailed(let name):
                return "failed to create key event for '\(name)'"
            }
        }
    }

    // MARK: typeText

    /// Type UTF-8 text into the frontmost app, walking by extended
    /// grapheme cluster so ZWJ / flag / family emoji survive intact.
    ///
    /// Mirrors `MacInputSimulator.TypeText`:
    ///
    /// * Chunk cap: 64 UTF-16 code units (`maxUnitsPerChunk`). This is
    ///   the same limit OCCU's `keyboardUnicodeChunks` enforces —
    ///   CGEvent's Unicode payload gets unreliable past that size.
    /// * A single grapheme longer than the cap is posted alone; we
    ///   never split mid-cluster (ZWJ sequences would break).
    /// * Between chunks: 20 ms sleep so downstream apps can advance
    ///   their input state before the next chunk arrives.
    ///
    /// - Parameters:
    ///   - text: text to inject; empty string is a no-op.
    ///   - delayMs: sleep between chunks in milliseconds. Default 20
    ///     matches `MacInputSimulator.cs:96,105` — Everywhere posts
    ///     `Thread.Sleep(20)` between chunks. `minChunkDelayMicros`
    ///     still enforces a 20 ms floor so callers passing a smaller
    ///     `delayMs` land back on the parity value.
    public static func typeText(_ text: String, delayMs: Int = 20) {
        guard !text.isEmpty else { return }
        let chunks = graphemeChunks(text, maxUnits: maxUnitsPerChunk)
        let delay = max(minChunkDelayMicros, useconds_t(max(0, delayMs) * 1_000))
        CaptureLog.log(
            "openclicky.input.type_text",
            [
                "chunks": "\(chunks.count)",
                "text_len": "\(text.count)",
                "delay_us": "\(delay)"
            ]
        )
        for (index, chunk) in chunks.enumerated() {
            postUnicodeChunk(chunk)
            if index < chunks.count - 1 {
                usleep(delay)
            }
        }
    }

    // MARK: pressKey

    /// Press one key (optionally with modifiers) using an xdotool-style
    /// name. Mirrors `MacInputSimulator.PressKey`.
    ///
    /// Two shapes:
    ///
    /// * `pressKey("Return")` — bare key, no modifiers.
    /// * `pressKey("c", modifiers: ["cmd"])` — modifiers supplied
    ///   separately.
    /// * `pressKey("cmd+shift+c")` — fused xdotool string; parsed by
    ///   splitting on `+`, last token = main key.
    ///
    /// - Throws: `KeyError.empty` when the key resolves to nothing,
    ///   `.unknownKey(_)` when the main key name is unknown,
    ///   `.unknownModifier(_)` when a modifier token is unknown.
    public static func pressKey(_ key: String, modifiers: [String] = []) throws {
        let (mainName, modifierNames) = try splitChord(key: key, extraModifiers: modifiers)
        let (mainCode, resolvedModifiers) = try resolveChord(
            mainName: mainName,
            modifierNames: modifierNames
        )
        CaptureLog.log(
            "openclicky.input.press_key",
            [
                "main": mainName,
                "main_code": "\(mainCode)",
                "modifier_count": "\(resolvedModifiers.count)"
            ]
        )

        var activeFlags: CGEventFlags = []

        // 1) Modifier key-down sequence, forward order.
        for (flag, modCode) in resolvedModifiers {
            activeFlags.insert(flag)
            guard let ev = CGEvent(
                keyboardEventSource: nil,
                virtualKey: modCode,
                keyDown: true
            ) else { continue }
            ev.flags = activeFlags
            ev.post(tap: .cghidEventTap)
        }

        // 2) Main key down + up with the full flag set.
        // Everywhere throws `InvalidOperationException("Failed to create
        // key event.")` when either CGEvent factory returns null
        // (`MacInputSimulator.cs:154-158`); we surface the same failure
        // as `KeyError.eventCreationFailed` so LaunchPhrase logs a
        // broken chord instead of leaving modifiers held down.
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: mainCode,
            keyDown: true
        ) else {
            releaseHeldModifiers(activeFlags, resolvedModifiers)
            throw KeyError.eventCreationFailed(key: mainName)
        }
        guard let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: mainCode,
            keyDown: false
        ) else {
            releaseHeldModifiers(activeFlags, resolvedModifiers)
            throw KeyError.eventCreationFailed(key: mainName)
        }
        down.flags = activeFlags
        down.post(tap: .cghidEventTap)
        up.flags = activeFlags
        up.post(tap: .cghidEventTap)

        // 3) Modifier key-up sequence, reverse order.
        // Post the keyup with the modifier flag STILL SET, then clear
        // (mirrors `MacInputSimulator.cs:170-179` — `activeFlags &= ~flag`
        // runs after `PostEvent`).
        for (flag, modCode) in resolvedModifiers.reversed() {
            guard let ev = CGEvent(
                keyboardEventSource: nil,
                virtualKey: modCode,
                keyDown: false
            ) else {
                activeFlags.remove(flag)
                continue
            }
            ev.flags = activeFlags
            ev.post(tap: .cghidEventTap)
            activeFlags.remove(flag)
        }

        // Everywhere sleeps 100 ms after the chord so downstream apps
        // can process the event before the next call arrives.
        usleep(postChordDelayMicros)
    }

    // MARK: click

    /// Click at a screen point. Mirrors `MacInputSimulator.Click`.
    ///
    /// * `MouseMoved` first so the app registers the pointer at the
    ///   target coords before the button press.
    /// * `<btn>Down` + `<btn>Up`, with `mouseEventClickState` on both
    ///   set to `clickCount`. Double-click / triple-click semantics
    ///   land because macOS derives the click count from that field
    ///   plus event timing.
    /// * Everywhere sleeps 30 ms after each `PostMouse` call. Same
    ///   cadence here.
    public static func click(
        at point: CGPoint,
        button: MouseButton = .left,
        clickCount: Int = 1
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        let (cgButton, downType, upType) = mapButton(button)
        let clicks = Int64(max(1, clickCount))

        CaptureLog.log(
            "openclicky.input.click",
            [
                "x": "\(Int(point.x))",
                "y": "\(Int(point.y))",
                "button": button.rawValue,
                "click_count": "\(clicks)"
            ]
        )

        postMouse(source: source, type: .mouseMoved, at: point, button: cgButton, clickState: clicks)
        postMouse(source: source, type: downType, at: point, button: cgButton, clickState: clicks)
        postMouse(source: source, type: upType, at: point, button: cgButton, clickState: clicks)
    }

    // MARK: scroll

    /// Post a two-axis scroll wheel event at `point`.
    ///
    /// Mirrors `MacInputSimulator.Scroll` in wire shape: creates
    /// `CGEventCreateScrollWheelEvent2(_, .line, 2, dy, dx, 0)` and
    /// stamps its location. Wheel1 is vertical, wheel2 horizontal —
    /// same axis assignment Everywhere uses.
    ///
    /// - Parameters:
    ///   - point: screen point the wheel event fires at.
    ///   - dx: horizontal line delta (positive = right).
    ///   - dy: vertical line delta (positive = up).
    public static func scroll(at point: CGPoint, dx: Int32, dy: Int32) {
        if dx == 0 && dy == 0 { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            CaptureLog.log("openclicky.input.scroll_alloc_failed",
                           direction: "error",
                           ["dx": "\(dx)", "dy": "\(dy)"])
            return
        }
        CaptureLog.log(
            "openclicky.input.scroll",
            [
                "x": "\(Int(point.x))",
                "y": "\(Int(point.y))",
                "dx": "\(dx)",
                "dy": "\(dy)"
            ]
        )
        ev.location = point
        ev.post(tap: .cghidEventTap)
        usleep(postScrollDelayMicros)
    }

    /// Direction alias for the pages-based scroll overload.
    public enum ScrollDirection: String, Sendable {
        case up, down, left, right
    }

    /// Pages-based scroll, mirroring `MacInputSimulator.Scroll(x, y,
    /// direction, pages)` at `MacInputSimulator.cs:186-212`. Delta is
    /// computed via `ComputeScrollDelta`: `round(12 * pages)` clamped
    /// to `[1, Int32.max]`, then routed to wheel1 (vertical) or wheel2
    /// (horizontal) with the sign matching the direction.
    public static func scroll(
        at point: CGPoint,
        direction: ScrollDirection,
        pages: Double = 1
    ) {
        let delta = computeScrollDelta(pages: pages)
        let dx: Int32
        let dy: Int32
        switch direction {
        case .up:    (dx, dy) = (0,  delta)
        case .down:  (dx, dy) = (0, -delta)
        case .left:  (dx, dy) = (-delta, 0)
        case .right: (dx, dy) = ( delta, 0)
        }
        scroll(at: point, dx: dx, dy: dy)
    }

    /// Mirrors `MacInputSimulator.ComputeScrollDelta` at
    /// `MacInputSimulator.cs:214-219`: `round(12 * pages)` with
    /// `MidpointRounding.AwayFromZero`, clamped to `[1, Int32.max]`.
    /// Exposed as `internal` for the test suite.
    internal static func computeScrollDelta(pages: Double) -> Int32 {
        let raw = (12.0 * pages).rounded(.toNearestOrAwayFromZero)
        let clamped = min(Double(Int32.max), max(1.0, raw))
        return Int32(clamped)
    }

    // MARK: drag

    /// Drag from `from` to `to` with the left mouse button.
    ///
    /// Mirrors `MacInputSimulator.DragTo`:
    ///
    /// 1. `MouseMoved` at `from`.
    /// 2. `LeftMouseDown` at `from`.
    /// 3. 10 `LeftMouseDragged` steps, `p = step / 10.0` linear lerp.
    /// 4. `LeftMouseUp` at `to`.
    public static func drag(from: CGPoint, to: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CaptureLog.log(
            "openclicky.input.drag",
            [
                "from_x": "\(Int(from.x))", "from_y": "\(Int(from.y))",
                "to_x": "\(Int(to.x))", "to_y": "\(Int(to.y))",
                "steps": "\(dragInterpolationSteps)"
            ]
        )
        postMouse(source: source, type: .mouseMoved, at: from, button: .left, clickState: 1)
        postMouse(source: source, type: .leftMouseDown, at: from, button: .left, clickState: 1)
        for step in 1...dragInterpolationSteps {
            let p = CGFloat(step) / CGFloat(dragInterpolationSteps)
            let interp = CGPoint(
                x: from.x + (to.x - from.x) * p,
                y: from.y + (to.y - from.y) * p
            )
            postMouse(source: source, type: .leftMouseDragged, at: interp, button: .left, clickState: 1)
        }
        postMouse(source: source, type: .leftMouseUp, at: to, button: .left, clickState: 1)
    }

    // MARK: - Internal helpers (visible to tests)

    /// Break `text` into chunks each `<= maxUnits` UTF-16 units, never
    /// splitting an extended grapheme cluster. If a single cluster is
    /// larger than `maxUnits` it is emitted alone.
    internal static func graphemeChunks(_ text: String, maxUnits: Int) -> [String] {
        var chunks: [String] = []
        var buffer = ""
        var bufferUnits = 0
        for cluster in text {
            let clusterUnits = cluster.utf16.count
            // `>` (not `>=`) to match `MacInputSimulator.cs:102` — a
            // cluster whose UTF-16 length exactly equals `maxUnits`
            // still fits in a chunk on its own without triggering the
            // pathological-single-cluster path.
            if clusterUnits > maxUnits {
                if !buffer.isEmpty {
                    chunks.append(buffer)
                    buffer = ""
                    bufferUnits = 0
                }
                chunks.append(String(cluster))
                continue
            }
            if bufferUnits + clusterUnits > maxUnits {
                chunks.append(buffer)
                buffer = String(cluster)
                bufferUnits = clusterUnits
            } else {
                buffer.append(cluster)
                bufferUnits += clusterUnits
            }
        }
        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
    }

    /// Resolve a bare key name (e.g. `"return"`) to its `CGKeyCode`.
    /// Case-insensitive. Returns `nil` when the name is unknown.
    internal static func resolveKey(_ name: String) -> CGKeyCode? {
        return keyByName[name.lowercased()]
    }

    /// Resolve a modifier name (e.g. `"cmd"`) to its
    /// `(CGEventFlags, CGKeyCode)` pair. Case-insensitive.
    internal static func resolveModifier(_ name: String) -> (CGEventFlags, CGKeyCode)? {
        return modifiersByName[name.lowercased()]
    }

    /// Parse and validate a chord like `"cmd+shift+c"` (or a bare key
    /// with a separate `modifiers` array). Exposed as `internal` so
    /// tests can round-trip the parse without posting events.
    internal static func splitChord(
        key: String,
        extraModifiers: [String]
    ) throws -> (mainName: String, modifierNames: [String]) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw KeyError.empty
        }

        // The C# form is a single `+`-separated string. If the caller
        // used the fused form (no separate `extraModifiers`), split it.
        //
        // Per-token normalisation mirrors `MacInputSimulator.cs:120`:
        // `t.ToLowerInvariant().Replace(" ", string.Empty)` — strip
        // ALL whitespace (including internal) so aliases like
        // `"page up"` / `"kp equal"` resolve.
        let tokens: [String]
        if extraModifiers.isEmpty {
            tokens = trimmed
                .split(separator: "+", omittingEmptySubsequences: true)
                .map { Self.normaliseChordToken(String($0)) }
                .filter { !$0.isEmpty }
        } else {
            tokens = (extraModifiers.map { Self.normaliseChordToken($0) }
                        + [Self.normaliseChordToken(trimmed)])
                .filter { !$0.isEmpty }
        }

        guard let last = tokens.last else {
            throw KeyError.empty
        }
        let modifiers = Array(tokens.dropLast())
        return (last, modifiers)
    }

    /// Given a parsed `(mainName, modifierNames)`, resolve every token
    /// to its `CGKeyCode` / flag. Throws on any unknown name.
    internal static func resolveChord(
        mainName: String,
        modifierNames: [String]
    ) throws -> (main: CGKeyCode, modifiers: [(CGEventFlags, CGKeyCode)]) {
        var resolved: [(CGEventFlags, CGKeyCode)] = []
        resolved.reserveCapacity(modifierNames.count)
        for name in modifierNames {
            guard let pair = resolveModifier(name) else {
                throw KeyError.unknownModifier(name)
            }
            resolved.append(pair)
        }
        guard let mainCode = resolveKey(mainName) else {
            throw KeyError.unknownKey(mainName)
        }
        return (mainCode, resolved)
    }

    // MARK: - Private helpers

    /// Lower-case + strip every whitespace scalar. Mirrors
    /// `MacInputSimulator.cs:120` `t.ToLowerInvariant().Replace(" ",
    /// string.Empty)` — accepts aliases like `"page up"` and
    /// `"kp equal"` by folding them to `"pageup"` / `"kpequal"`.
    internal static func normaliseChordToken(_ token: String) -> String {
        var out = ""
        out.reserveCapacity(token.count)
        for ch in token.lowercased() {
            if !ch.isWhitespace {
                out.append(ch)
            }
        }
        return out
    }

    /// Release any modifier keys still held after a mid-chord failure
    /// so the user is not left with a stuck Shift/Cmd/etc.
    /// Everywhere's CFRelease-in-finally is the analogous cleanup; our
    /// equivalent is posting explicit keyups for the modifiers we
    /// pressed.
    private static func releaseHeldModifiers(
        _ startingFlags: CGEventFlags,
        _ modifiers: [(CGEventFlags, CGKeyCode)]
    ) {
        var flags = startingFlags
        for (flag, modCode) in modifiers.reversed() {
            guard let ev = CGEvent(
                keyboardEventSource: nil,
                virtualKey: modCode,
                keyDown: false
            ) else {
                flags.remove(flag)
                continue
            }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
            flags.remove(flag)
        }
    }

    private static func postUnicodeChunk(_ chunk: String) {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ) else { return }
        guard let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        ) else { return }

        let units = Array(chunk.utf16)
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postMouse(
        source: CGEventSource?,
        type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        clickState: Int64
    ) {
        guard let ev = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clickState)
        ev.post(tap: .cghidEventTap)
        usleep(postMouseDelayMicros)
    }

    private static func mapButton(_ button: MouseButton) -> (CGMouseButton, CGEventType, CGEventType) {
        switch button {
        case .left:
            return (.left, .leftMouseDown, .leftMouseUp)
        case .right:
            return (.right, .rightMouseDown, .rightMouseUp)
        case .middle:
            return (.center, .otherMouseDown, .otherMouseUp)
        }
    }

    // MARK: - Constants

    /// CGEvent Unicode-string payload cap, in UTF-16 code units. Same
    /// value OCCU / Everywhere use.
    private static let maxUnitsPerChunk: Int = 64

    /// Inter-chunk sleep floor (20 ms). Everywhere sleeps 20 ms between
    /// chunks in `TypeText`.
    private static let minChunkDelayMicros: useconds_t = 20_000

    /// Post-chord sleep (100 ms). Matches `MacInputSimulator.PressKey`.
    private static let postChordDelayMicros: useconds_t = 100_000

    /// Post-mouse sleep (30 ms). Matches `MacInputSimulator.PostMouse`.
    private static let postMouseDelayMicros: useconds_t = 30_000

    /// Post-scroll sleep (100 ms). Matches `MacInputSimulator.Scroll`.
    private static let postScrollDelayMicros: useconds_t = 100_000

    /// Linear interpolation step count for `drag`. Matches
    /// `MacInputSimulator.DragTo`.
    private static let dragInterpolationSteps: Int = 10

    // MARK: - Lookup tables (byte-parity with MacKeyCodes.cs)

    /// xdotool-style key name → CGKeyCode. Byte-for-byte port of
    /// `MacKeyCodes.KeyByName`.
    internal static let keyByName: [String: CGKeyCode] = [
        // Letters
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02,
        "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
        "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
        "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
        "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,

        // Digits
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
        "8": 0x1C, "9": 0x19,

        // Editing / navigation
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31, "spacebar": 0x31,
        "escape": 0x35, "esc": 0x35,
        "backspace": 0x33, "delete": 0x33,
        "del": 0x75, "forwarddelete": 0x75,
        "insert": 0x72,

        "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "page_up": 0x74, "prior": 0x74,
        "pagedown": 0x79, "page_down": 0x79, "next": 0x79,
        "caps_lock": 0x39,

        // Function keys
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,

        // Keypad
        "kp_0": 0x52, "kp_1": 0x53, "kp_2": 0x54, "kp_3": 0x55,
        "kp_4": 0x56, "kp_5": 0x57, "kp_6": 0x58, "kp_7": 0x59,
        "kp_8": 0x5B, "kp_9": 0x5C,
        "kp_enter": 0x4C, "kp_equal": 0x51, "kp_multiply": 0x43,
        "kp_add": 0x45, "kp_subtract": 0x4E, "kp_decimal": 0x41,
        "kp_divide": 0x4B, "kp_delete": 0x41,
        "kp_home": 0x73, "kp_left": 0x7B, "kp_up": 0x7E,
        "kp_right": 0x7C, "kp_down": 0x7D,
        "kp_prior": 0x74, "kp_page_up": 0x74,
        "kp_next": 0x79, "kp_page_down": 0x79,
        "kp_end": 0x77, "kp_insert": 0x72,
    ]

    /// xdotool-style modifier name → `(CGEventFlags, CGKeyCode)`.
    /// Byte-for-byte port of `MacKeyCodes.Modifiers`. Flag values
    /// come from `CGEventFlags` (shift=0x00020000, control=0x00040000,
    /// alternate=0x00080000, command=0x00100000).
    internal static let modifiersByName: [String: (CGEventFlags, CGKeyCode)] = [
        "cmd":      (.maskCommand,   0x37),
        "command":  (.maskCommand,   0x37),
        "super":    (.maskCommand,   0x37),
        "meta":     (.maskCommand,   0x37),
        "shift":    (.maskShift,     0x38),
        "option":   (.maskAlternate, 0x3A),
        "alt":      (.maskAlternate, 0x3A),
        "control":  (.maskControl,   0x3B),
        "ctrl":     (.maskControl,   0x3B),
    ]
}
