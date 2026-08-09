//
//  AssistAgentPlanDriven.swift
//  cursor-buddy
//
//  Plan-driven mode: `[free-agent-longrun]` header parser + PROGRESS.md
//  helpers. Ported from heyclicky_agent/agent.py:2899-3081 so long-run
//  tasks driven by a PROGRESS.md marker behave identically to the
//  Python reference.
//

import Foundation

public enum AssistAgentPlanDriven {

    public struct Header {
        public let cleanedTask: String
        public let taskDir: String?
        public let progressMarker: String  // default "LAST_COMPLETED: DONE"
        public let cwd: String?
    }

    /// Pop the LAST `[free-agent-longrun]` block out of `task`. Any
    /// earlier occurrence is almost certainly a user-pasted spec doc
    /// mentioning the marker in an example.
    public static func extractHeader(_ task: String) -> Header {
        let pattern = "\\[free-agent-longrun\\]\\s*([\\s\\S]*?)(?:\\n\\s*\\n|$)"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return Header(cleanedTask: task, taskDir: nil,
                          progressMarker: "LAST_COMPLETED: DONE", cwd: nil)
        }
        let ns = task as NSString
        let matches = re.matches(in: task, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else {
            return Header(cleanedTask: task, taskDir: nil,
                          progressMarker: "LAST_COMPLETED: DONE", cwd: nil)
        }
        let body = ns.substring(with: last.range(at: 1))
        var fields: [String: String] = [:]
        for line in body.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            for key in ["task_dir", "progress_marker", "cwd"] {
                let prefix = "\(key):"
                if s.hasPrefix(prefix) {
                    fields[key] = String(s.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        // Splice the header out of the task string.
        let head = ns.substring(with: NSRange(location: 0, length: last.range.location))
        let tail = ns.substring(from: last.range.location + last.range.length)
        let cleaned = (head + tail).trimmingCharacters(in: .whitespacesAndNewlines)
        return Header(
            cleanedTask: cleaned,
            taskDir: fields["task_dir"],
            progressMarker: fields["progress_marker"] ?? "LAST_COMPLETED: DONE",
            cwd: fields["cwd"])
    }

    public static func readProgress(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    public static func markerReached(progressText: String, marker: String) -> Bool {
        let target = marker.trimmingCharacters(in: .whitespaces)
        return progressText.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == target }
    }

    /// Return the body of every `- [ ]` line, in order.
    public static func uncheckedSteps(_ progressText: String) -> [String] {
        var out: [String] = []
        for line in progressText.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("- [ ] ") {
                out.append(String(s.dropFirst("- [ ] ".count))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    /// Flip the first matching `- [ ]` line to `- [x]` and update
    /// `LAST_COMPLETED:`. Tolerant of paraphrase (exact → N.M prefix
    /// → first-30-chars prefix). Returns true when file rewritten.
    @discardableResult
    public static func markStepDone(path: String, stepText: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let target = stepText.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return false }

        let targetNum = matchLeadingNumber(target)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        func bodyOf(_ raw: String) -> String? {
            let s = raw.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("- [ ] ")
                ? String(s.dropFirst("- [ ] ".count)).trimmingCharacters(in: .whitespaces)
                : nil
        }

        var hitI: Int? = nil
        var hitBody: String? = nil

        // Pass 1: exact match.
        for (i, raw) in lines.enumerated() {
            if let b = bodyOf(raw), b == target {
                hitI = i; hitBody = b; break
            }
        }
        // Pass 2: N.M match.
        if hitI == nil, let tn = targetNum {
            for (i, raw) in lines.enumerated() {
                guard let b = bodyOf(raw) else { continue }
                if matchLeadingNumber(b) == tn {
                    hitI = i; hitBody = b; break
                }
            }
        }
        // Pass 3: 30-char prefix.
        if hitI == nil && target.count >= 30 {
            let head = String(target.prefix(30))
            for (i, raw) in lines.enumerated() {
                if let b = bodyOf(raw), b.hasPrefix(head) {
                    hitI = i; hitBody = b; break
                }
            }
        }
        guard let idx = hitI, let body = hitBody else { return false }

        let raw = lines[idx]
        let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
        lines[idx] = "\(indent)- [x] \(body)"

        // Update or append LAST_COMPLETED.
        var replaced = false
        for (i, r) in lines.enumerated()
        where r.trimmingCharacters(in: .whitespaces).hasPrefix("LAST_COMPLETED:") {
            lines[i] = "LAST_COMPLETED: \(body)"
            replaced = true
            break
        }
        if !replaced {
            lines.append("LAST_COMPLETED: \(body)")
        }
        var out = lines.joined(separator: "\n")
        if content.hasSuffix("\n") { out += "\n" }
        return atomicWrite(path: path, content: out)
    }

    /// Replace `LAST_COMPLETED:` line with the terminal marker.
    public static func markAllDone(path: String, marker: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var replaced = false
        for (i, r) in lines.enumerated()
        where r.trimmingCharacters(in: .whitespaces).hasPrefix("LAST_COMPLETED:") {
            lines[i] = marker
            replaced = true
            break
        }
        if !replaced { lines.append(marker) }
        var out = lines.joined(separator: "\n")
        if content.hasSuffix("\n") { out += "\n" }
        _ = atomicWrite(path: path, content: out)
    }

    // MARK: - Private helpers

    private static func matchLeadingNumber(_ s: String) -> String? {
        let pattern = "^(\\d+(?:\\.\\d+)*)\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func atomicWrite(path: String, content: String) -> Bool {
        let tmp = path + ".tmp"
        do {
            try content.write(toFile: tmp, atomically: false, encoding: .utf8)
            try FileManager.default.replaceItem(
                at: URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tmp),
                backupItemName: nil, options: [],
                resultingItemURL: nil)
            return true
        } catch {
            // Fallback: direct write.
            return (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        }
    }
}
