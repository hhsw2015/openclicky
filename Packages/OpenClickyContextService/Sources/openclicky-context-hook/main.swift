// Ported from Everywhere: tools/everywhere-context-hook/src/main.rs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Tiny binary invoked by Claude Code's UserPromptSubmit hook. Stats the
// well-known OpenClicky context-stash file; if it exists and is fresh
// (<5 min), atomically claims it (rename to `.consumed-<pid>-<nanos>.json`),
// reads + unlinks it, validates the envelope, and prints a Claude Code
// hook-shaped JSON response on stdout. Otherwise exits 0 silently so a
// routine Enter key press pays close to zero overhead.
//
// Built for ~10 ms cold start on macOS (Swift startup is heavier than
// Rust's; the writer's `Darwin.rename` + guard checks still keep this well
// inside the UserPromptSubmit budget). Path resolution mirrors
// `OpenClickyContextStashWriter.stashPath` on the Swift side; both agree.

import Foundation
import Darwin
import OpenClickyContextService

// MARK: - Constants

/// 5 min TTL — anything older is treated as abandoned and unlinked without
/// injection. Matches Rust `TTL_SECS = 5 * 60`.
let ttlSeconds: TimeInterval = 5 * 60

/// 64 KB payload ceiling. Real payloads are 200-1500 bytes; anything larger
/// is rejected as malformed. Matches Rust `body.len() > 64 * 1024`.
let maxPayloadBytes = 64 * 1024

/// Header prefix (trailing space is load-bearing — matches
/// `ContextStashWriter.FormatForHook` byte-for-byte).
let ctxHeaderPrefix = "[openclicky-ctx] "

// MARK: - Entry point

let path = resolveStashPath()

// Existence + stale check. Missing -> exit 0 silently (99% case).
guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
    exit(0)
}
if let mtime = attrs[.modificationDate] as? Date,
   Date().timeIntervalSince(mtime) > ttlSeconds {
    _ = Darwin.unlink(path)
    exit(0)
}

// Atomic claim: rename to unique sibling so concurrent hooks racing on
// rapid Enter-spam each claim their own copy (or ENOENT out).
let claimName = "context-stash.consumed-\(getpid())-\(nowNanos()).json"
let dir = (path as NSString).deletingLastPathComponent
let claimed = (dir as NSString).appendingPathComponent(claimName)
if Darwin.rename(path, claimed) != 0 {
    let err = errno
    if err == ENOENT { exit(0) }
    FileHandle.standardError.write(Data(
        "openclicky-context-hook: rename claim failed: \(String(cString: strerror(err)))\n".utf8))
    exit(0)
}

// Read the claimed copy. We own it; always unlink on the way out (even
// if the read failed).
let body: Data
do {
    body = try Data(contentsOf: URL(fileURLWithPath: claimed))
} catch {
    FileHandle.standardError.write(Data(
        "openclicky-context-hook: read failed: \(error.localizedDescription)\n".utf8))
    _ = Darwin.unlink(claimed)
    exit(0)
}
_ = Darwin.unlink(claimed)

// Validate: reject empty, oversized, or bytes without the expected
// envelope header prefix.
if !isValidPayload(body) {
    FileHandle.standardError.write(Data(
        "openclicky-context-hook: discarded malformed stash (\(body.count) bytes)\n".utf8))
    exit(0)
}

// Compose Claude Code hook response.
let bodyStr = String(data: body, encoding: .utf8) ?? ""
let summary = summariseFirstCtxLine(body)
let payload = buildHookResponse(additionalContext: bodyStr, summary: summary)

FileHandle.standardOutput.write(Data(payload.utf8))
exit(0)

// MARK: - Path resolution

/// Mirrors `OpenClickyStashPaths.contextStash()` on the writer side.
/// Delegates to the shared helper so writer and hook stay locked.
func resolveStashPath() -> String {
    OpenClickyStashPaths.contextStash().path
}

// MARK: - Validation

/// Mirrors Rust `is_valid_payload` (`main.rs:142-148`).
func isValidPayload(_ body: Data) -> Bool {
    if body.isEmpty || body.count > maxPayloadBytes { return false }
    guard let prefix = ctxHeaderPrefix.data(using: .utf8) else { return false }
    if body.count < prefix.count { return false }
    return body.prefix(prefix.count) == prefix
}

// MARK: - Hook response

/// Hand-rolled JSON to keep the binary tiny + startup fast. Both fields
/// carry user-controlled bytes (selection / window title) which the writer
/// already scrubbed of control chars + brackets, so only JSON meta-chars
/// need escaping here. Matches Rust `build_hook_response` shape exactly.
func buildHookResponse(additionalContext: String, summary: String) -> String {
    let ctx = jsonEscape(additionalContext)
    // Everywhere (main.rs:115) wraps the raw summary as
    // "✓ Everywhere context injected: {summary}" so the user-visible
    // warning line above the prompt tells them why the extra context
    // appeared. Openclicky uses the rebranded prefix — same UX affordance.
    let msg = jsonEscape("✓ OpenClicky context injected: \(summary)")
    return "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\(ctx)},\"systemMessage\":\(msg)}\n"
}

/// Mirrors Rust `json_escape` (`main.rs:107-137`).
func jsonEscape(_ s: String) -> String {
    var out = "\""
    out.reserveCapacity(s.count + 2)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out.append("\\\"")
        case "\\": out.append("\\\\")
        case "\n": out.append("\\n")
        case "\r": out.append("\\r")
        case "\t": out.append("\\t")
        case "\u{08}": out.append("\\b")
        case "\u{0C}": out.append("\\f")
        default:
            if scalar.value < 0x20 {
                out.append(String(format: "\\u%04x", scalar.value))
            } else {
                out.append(Character(scalar))
            }
        }
    }
    out.append("\"")
    return out
}

// MARK: - Summary extraction

/// Mirrors Rust `summarise_first_ctx_line` (`main.rs:153-174`).
func summariseFirstCtxLine(_ body: Data) -> String {
    let bodyStr = String(data: body, encoding: .utf8) ?? ""
    let line = bodyStr
        .split(separator: "\n", omittingEmptySubsequences: false)
        .first(where: { $0.hasPrefix(ctxHeaderPrefix) })
        .map(String.init)
        ?? ""
    let kv = line.hasPrefix(ctxHeaderPrefix)
        ? String(line.dropFirst(ctxHeaderPrefix.count))
        : ""

    let app = extractSimple(kv, "app=") ?? "?"
    let title = extractQuoted(kv, "title=\"")
    let hasSelection = kv.contains("selection=\"")

    var out = "app=\(app)"
    if let t = title {
        let trimmed = String(t.prefix(60))
        out.append(" title=\"\(trimmed)\"")
    }
    if hasSelection {
        out.append(" +selection")
    }
    return out
}

/// Mirrors Rust `extract_simple`. `key=value ` (space terminated).
func extractSimple(_ s: String, _ key: String) -> String? {
    guard let range = s.range(of: key) else { return nil }
    let rest = s[range.upperBound...]
    if let space = rest.firstIndex(of: " ") {
        return String(rest[..<space])
    }
    return String(rest)
}

/// Mirrors Rust `extract_quoted`. `key="value"` (double-quote terminated).
func extractQuoted(_ s: String, _ key: String) -> String? {
    guard let range = s.range(of: key) else { return nil }
    let rest = s[range.upperBound...]
    guard let close = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<close])
}

// MARK: - Time helpers

/// Nanoseconds since the UNIX epoch — matches Rust's
/// `SystemTime::now().duration_since(UNIX_EPOCH).as_nanos()`.
func nowNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
