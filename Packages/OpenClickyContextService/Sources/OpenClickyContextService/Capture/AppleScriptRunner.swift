// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacAppleScriptRunner.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Runs AppleScript via `/usr/bin/osascript -e <source>` and returns a
// discriminated result. Contract mirrors `MacAppleScriptRunner`:
//   * 15 s timeout — the C# comment justifies this with Arc browser users
//     hitting ~200 tabs at ~15 ms per tab. Keep the constant identical so
//     porting BrowserTabsCapture later doesn't need to retune it.
//   * Async pipe drain — Everywhere concurrently reads stdout & stderr to
//     avoid the 64 KB PIPE buffer deadlock when a script emits big output
//     (e.g. Finder with a huge selection, or Safari with hundreds of tabs).
//     Swift's `FileHandle.readabilityHandler` accomplishes the same thing.
//   * Permission sniffing — parses stderr for the three sentinel strings the
//     C# runner keys on (`-1743`, `not allowed assistive access`,
//     `not authorized to send Apple events`).
//
// Deliberate deviations:
//   * Uses `Process` (NSTask), not `NSAppleScript`/`OSAKit`. Rationale: the
//     production TCC prompt users see is the "osascript wants to control
//     Finder" dialog. Running via the same binary keeps that grant reusable.
//     `NSAppleScript` runs in-process and would trigger a *separate* TCC
//     prompt against our own bundle id.
//   * `run(source:)` is `async` (returns via a continuation). Underlying
//     Process work is scheduled on `DispatchQueue.global(qos: .userInitiated)`
//     to keep Main clean during voice / hotkey flows.

import Foundation

/// Coarse status returned by an AppleScript invocation. Mirrors
/// `AppleScriptStatus` in `Everywhere.Mac/Mcp/AppleScriptResult.cs`.
public enum AppleScriptStatus: String, Codable, Sendable, Equatable {
    /// Script exited 0. `output` carries stdout (trimmed of trailing `\n`).
    case ok

    /// Script or runner did not run (empty source, missing osascript, etc.).
    case notSupported

    /// TCC / Apple Events permission denied. `error` describes the sniff hit.
    case permissionDenied

    /// Any other non-zero exit / timeout / IO error.
    case failed
}

/// Discriminated result matching `AppleScriptResult` in Everywhere.
public struct AppleScriptResult: Sendable, Equatable {
    public let status: AppleScriptStatus
    public let output: String?
    public let error: String?

    public init(status: AppleScriptStatus, output: String?, error: String?) {
        self.status = status
        self.output = output
        self.error = error
    }
}

/// AppleScript execution surface. Made a protocol so future capture tests can
/// inject a stub. Not currently used by `FinderSelectionCapture.capture()`
/// (which relies on the default) but the parity audit permits swap-in.
public protocol AppleScriptRunning: Sendable {
    /// Execute `source` and return the outcome. Never throws; every failure
    /// mode is surfaced through `AppleScriptResult.status`.
    func run(source: String) async -> AppleScriptResult
}

/// Concrete `/usr/bin/osascript` backed runner.
///
/// Thread-safe: each `run` spawns a fresh `Process` and never touches shared
/// mutable state. Instances can be shared freely; the type-level `shared`
/// singleton is provided for convenience.
public struct AppleScriptRunner: AppleScriptRunning {

    /// Same 15 000 ms budget the C# runner uses.
    public static let timeoutMilliseconds: Int = 15_000

    /// Shared default — safe to reuse from any actor.
    public static let shared = AppleScriptRunner()

    public init() {}

    public func run(source: String) async -> AppleScriptResult {
        // Empty / whitespace-only guard — matches C#'s `IsNullOrWhiteSpace`.
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppleScriptResult(status: .failed, output: nil, error: "empty script")
        }

        let scriptHash = String(source.hashValue, radix: 16)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                let result = Self.runBlocking(source: source)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                CaptureLog.log(
                    "openclicky.applescript.run",
                    direction: result.status == .ok ? "internal" : "error",
                    [
                        "script_hash": scriptHash,
                        "status": result.status.rawValue,
                        "elapsed_ms": "\(ms)",
                        "stdout_len": "\(result.output?.count ?? 0)",
                        "err_len": "\(result.error?.count ?? 0)"
                    ]
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Internals

    /// Synchronous body. Called off the main queue by `run(source:)`.
    private static func runBlocking(source: String) -> AppleScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently to avoid the >64KB buffer deadlock.
        // Uses a dedicated queue + a NSLock instead of readabilityHandler so
        // we can synchronously fetch the totals after the process exits.
        var stdoutData = Data()
        var stderrData = Data()
        let dataLock = NSLock()

        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "openclicky.applescript.drain", attributes: .concurrent)

        drainGroup.enter()
        drainQueue.async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock()
            stdoutData = data
            dataLock.unlock()
            drainGroup.leave()
        }

        drainGroup.enter()
        drainQueue.async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock()
            stderrData = data
            dataLock.unlock()
            drainGroup.leave()
        }

        do {
            try process.run()
        } catch {
            // Ensure the drain tasks unblock. Closing the write ends causes
            // readDataToEndOfFile above to return immediately with EOF.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            drainGroup.wait()
            return AppleScriptResult(
                status: .failed,
                output: nil,
                error: "failed to spawn osascript: \(error.localizedDescription)"
            )
        }

        // Wait with timeout. `Process.waitUntilExit` blocks unconditionally,
        // so we poll `isRunning` on the drain queue. This mirrors the C# code
        // which uses `Process.WaitForExit(TimeoutMs)`.
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1000.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            // Give it a 1 s grace period, then hard kill via SIGKILL.
            let killDeadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            drainGroup.wait()
            return AppleScriptResult(
                status: .failed,
                output: nil,
                error: "osascript timed out (\(timeoutMilliseconds)ms)"
            )
        }

        // Ensure both readers observed EOF.
        drainGroup.wait()

        dataLock.lock()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        dataLock.unlock()

        if process.terminationStatus != 0 {
            let status: AppleScriptStatus = isPermissionDenied(stderr: stderr) ? .permissionDenied : .failed
            let errText = stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr
            return AppleScriptResult(status: status, output: nil, error: errText)
        }

        // Trim the final newline osascript appends but preserve embedded ones.
        let trimmed = stdout.hasSuffix("\n") ? String(stdout.dropLast()) : stdout
        return AppleScriptResult(status: .ok, output: trimmed, error: nil)
    }

    /// The exact three heuristics used by `MacAppleScriptRunner.Run`.
    ///   * `-1743` is TCC error `errAEEventNotPermitted`
    ///     (Apple Events denial).
    ///   * The two string checks catch some macOS versions where stderr
    ///     doesn't include the numeric code.
    private static func isPermissionDenied(stderr: String) -> Bool {
        if stderr.contains("-1743") { return true }
        let lower = stderr.lowercased()
        if lower.contains("not allowed assistive access") { return true }
        if lower.contains("not authorized to send apple events") { return true }
        return false
    }
}
