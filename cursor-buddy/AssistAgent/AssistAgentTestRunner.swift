//
//  AssistAgentTestRunner.swift
//  cursor-buddy
//
//  Self-test loop for the assist agent — a thin structured layer
//  over `run_shell` that turns "run the tests" into a machine-
//  readable pass/fail + failure snippet so the model doesn't have
//  to reinvent output parsing every turn.
//
//  Also carries the fix-loop policy: after 3 consecutive same-
//  signature failures we surrender and return a "please diagnose"
//  result so the model stops burning rounds on a stuck test.
//

import Foundation

public struct AssistAgentTestOutcome: Sendable {
    public enum Verdict: String, Sendable {
        case pass, fail, error, unknown
    }
    public let verdict: Verdict
    public let cmd: String
    public let exitCode: Int32
    public let elapsedSec: Double
    public let passed: Int
    public let failed: Int
    /// The 1-2 most useful lines pointing at the failure — file + line
    /// + short message. Empty on pass.
    public let firstFailureExcerpt: String
    /// Rolling signature so the fix-loop can spot the "same failure
    /// again" case and give up.
    public let signature: String

    public var summary: String {
        switch verdict {
        case .pass:
            return "PASS \(passed) tests in \(String(format: "%.1f", elapsedSec))s"
        case .fail:
            return "FAIL \(failed)/\(passed + failed) tests · \(String(format: "%.1f", elapsedSec))s · \(firstFailureExcerpt.prefix(120))"
        case .error:
            return "ERR exit=\(exitCode) · \(firstFailureExcerpt.prefix(120))"
        case .unknown:
            return "UNKNOWN exit=\(exitCode) · \(firstFailureExcerpt.prefix(120))"
        }
    }
}

@MainActor
public final class AssistAgentTestRunner {

    /// Consecutive same-signature failures allowed before we say
    /// "give up, diagnose". The 3 threshold matches the Python
    /// same_error_streak circuit-breaker.
    public static let sameFailureGiveUp = 3

    private var lastSignature: String = ""
    private var sameStreak: Int = 0

    public init() {}

    /// Run a shell command as a "test", parse the output, produce a
    /// structured verdict. `cmd` is passed to `/bin/zsh -lc`.
    public func run(cmd: String, timeoutSec: Double = 300) async -> AssistAgentTestOutcome {
        let started = Date()
        let (exit, combined) = await Self.runShell(cmd: cmd, timeoutSec: timeoutSec)
        let elapsed = Date().timeIntervalSince(started)
        let (passed, failed, firstFailure) = Self.parseOutput(combined)
        let verdict: AssistAgentTestOutcome.Verdict
        if exit == 0 && failed == 0 {
            verdict = .pass
        } else if failed > 0 {
            verdict = .fail
        } else if exit != 0 {
            verdict = .error
        } else {
            verdict = .unknown
        }
        let sig = Self.signature(exit: exit, firstFailure: firstFailure)
        if sig == lastSignature && verdict != .pass {
            sameStreak += 1
        } else {
            lastSignature = sig
            sameStreak = (verdict == .pass ? 0 : 1)
        }
        return AssistAgentTestOutcome(
            verdict: verdict, cmd: cmd, exitCode: exit,
            elapsedSec: elapsed, passed: passed, failed: failed,
            firstFailureExcerpt: firstFailure, signature: sig)
    }

    /// Should the agent stop trying? True once we've hit
    /// `sameFailureGiveUp` consecutive same-signature failures.
    public var shouldGiveUp: Bool { sameStreak >= Self.sameFailureGiveUp }

    /// Reset the streak — call after any successful test-code edit
    /// so a fresh attempt starts fresh.
    public func resetStreak() {
        lastSignature = ""
        sameStreak = 0
    }

    // MARK: - Shell

    private static func runShell(cmd: String, timeoutSec: Double)
        async -> (exit: Int32, combined: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.launchPath = "/bin/zsh"
                proc.arguments = ["-lc", cmd]
                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do { try proc.run() } catch {
                    cont.resume(returning: (-1, "launch failed: \(error)"))
                    return
                }
                let deadline = Date().addingTimeInterval(timeoutSec)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    proc.terminate()
                    cont.resume(returning: (-1, "timeout after \(timeoutSec)s"))
                    return
                }
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let combined = out + (err.isEmpty ? "" : "\n[stderr]\n" + err)
                cont.resume(returning: (proc.terminationStatus, combined))
            }
        }
    }

    // MARK: - Output parser (pytest / go test / npm test / xctest / swift test)

    private static let pytestSummary = try? NSRegularExpression(
        pattern: "^==+ (?:(\\d+) passed)?(?:, (\\d+) failed)? .*==+$",
        options: [.anchorsMatchLines])
    private static let pytestFail = try? NSRegularExpression(
        pattern: "^FAILED (\\S+::\\S+).*$", options: [.anchorsMatchLines])
    private static let swiftFail = try? NSRegularExpression(
        pattern: "^(.+\\.swift):(\\d+):.*(?:error|failed): (.+)$",
        options: [.anchorsMatchLines])
    private static let goFail = try? NSRegularExpression(
        pattern: "^--- FAIL: (\\S+) .*$", options: [.anchorsMatchLines])

    /// Return (passed, failed, firstFailureExcerpt).
    static func parseOutput(_ text: String) -> (Int, Int, String) {
        let ns = text as NSString

        // pytest summary line first — most authoritative.
        if let re = pytestSummary,
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let passStr = m.range(at: 1).location != NSNotFound
                ? ns.substring(with: m.range(at: 1)) : "0"
            let failStr = m.range(at: 2).location != NSNotFound
                ? ns.substring(with: m.range(at: 2)) : "0"
            let passed = Int(passStr) ?? 0
            let failed = Int(failStr) ?? 0
            var excerpt = ""
            if failed > 0, let f = pytestFail,
               let fm = f.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                excerpt = ns.substring(with: fm.range)
            }
            return (passed, failed, excerpt)
        }

        // Swift compiler errors / XCTest failures.
        if let re = swiftFail,
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let excerpt = ns.substring(with: m.range)
            let failCount = re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
            return (0, failCount, excerpt)
        }

        // Go test.
        if let re = goFail,
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let excerpt = ns.substring(with: m.range)
            let failCount = re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
            return (0, failCount, excerpt)
        }

        // Fallback: look for the word "FAIL" or "error:" — return the
        // first hit as the excerpt.
        let lower = text.lowercased()
        if lower.contains("fail") || lower.contains("error:") {
            let excerpt = text
                .split(separator: "\n")
                .first(where: { line in
                    let l = line.lowercased()
                    return l.contains("fail") || l.contains("error:")
                }).map(String.init) ?? ""
            return (0, 1, excerpt)
        }
        return (0, 0, "")
    }

    private static func signature(exit: Int32, firstFailure: String) -> String {
        // Signature key: exit code + first ~80 chars of the failure line
        // stripped of paths (which change per run).
        var s = firstFailure
        // Strip repo prefixes.
        s = s.replacingOccurrences(of: "/Users/[^/]+/", with: "~/",
                                   options: .regularExpression)
        let head = String(s.prefix(80))
        return "\(exit):\(head)"
    }
}
