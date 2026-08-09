//
//  OpenClickyTaskDirectoryResolver.swift
//  cursor-buddy
//
//  Resolves the task directory openclicky will spawn codex against.
//  Two paths:
//    A. workdir-anchored:  <workdir>/.openclicky/task/
//    B. standalone:        ~/OpenClicky/<slug>/
//
//  Also probes for an existing PROGRESS.md to decide whether the
//  PlanningLoop needs to run.
//
//  Openclicky-native. No Everywhere counterpart.
//

import Foundation

public struct OpenClickyTaskDirectoryResolver: Sendable {

    public struct Resolution: Sendable {
        public let taskDir: String              // absolute path (no trailing slash)
        public let progressPath: String         // taskDir + "/PROGRESS.md"
        public let progressExists: Bool
        public let anchor: Anchor
        public enum Anchor: String, Sendable { case workdir, standalone }
    }

    /// - Parameters:
    ///   - workdir: Layer-0 resolved workdir (Finder selection or frontmost
    ///     project). Nil / empty produces the standalone variant.
    ///   - slug: dialog model's slug from [ROUTE] JSON. Nil / empty triggers
    ///     the fallback `yyyy-MM-dd-HHmm-<random6>` slug.
    public static func resolve(workdir: String?, slug: String?) -> Resolution {
        let trimmed = workdir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let taskDir = (expanded as NSString)
                .appendingPathComponent(".openclicky")
                .appending("/task")
            ensureDirectoryExists(atPath: taskDir)
            let progressPath = (taskDir as NSString).appendingPathComponent("PROGRESS.md")
            return Resolution(
                taskDir: taskDir,
                progressPath: progressPath,
                progressExists: FileManager.default.fileExists(atPath: progressPath),
                anchor: .workdir
            )
        }

        // Variant B: standalone under ~/OpenClicky/<slug>/
        let sanitized = sanitize(slug: slug)
        let baseSlug = sanitized.isEmpty ? generateFallbackSlug() : sanitized
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OpenClicky", isDirectory: true)
        let finalSlug = resolveNonCollidingSlug(baseSlug: baseSlug, root: root)
        let taskDirURL = root.appendingPathComponent(finalSlug, isDirectory: true)
        ensureDirectoryExists(atPath: taskDirURL.path)
        let progressPath = taskDirURL.appendingPathComponent("PROGRESS.md").path
        return Resolution(
            taskDir: taskDirURL.path,
            progressPath: progressPath,
            progressExists: FileManager.default.fileExists(atPath: progressPath),
            anchor: .standalone
        )
    }

    /// Collision handling for variant B: if the base slug already has a
    /// DONE-marked PROGRESS.md, append `-N` suffix (starting N=2) until the
    /// candidate path either doesn't exist or points at a NOT-DONE task
    /// (resume-friendly). Variant A (workdir-anchored) is exempt — the
    /// user's workdir is the anchor and cannot silently alias.
    /// See docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md MEDIUM #2.
    private static func resolveNonCollidingSlug(baseSlug: String, root: URL) -> String {
        var finalSlug = baseSlug
        var attempt = 1
        let regex = try? NSRegularExpression(
            pattern: "^\\s*LAST_COMPLETED:\\s*DONE\\s*$",
            options: [.anchorsMatchLines]
        )
        while attempt <= 100 {
            let candidate = root.appendingPathComponent(finalSlug, isDirectory: true)
            let progressAtCandidate = candidate.appendingPathComponent("PROGRESS.md").path
            if !FileManager.default.fileExists(atPath: progressAtCandidate) {
                return finalSlug
            }
            guard let content = try? String(
                contentsOfFile: progressAtCandidate,
                encoding: .utf8
            ) else {
                // Unreadable PROGRESS.md — reuse slug (resume-friendly bias).
                return finalSlug
            }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            let matched = regex?.firstMatch(in: content, options: [], range: range) != nil
            if !matched {
                // Not-done task — resume by reusing the slug.
                return finalSlug
            }
            attempt += 1
            finalSlug = "\(baseSlug)-\(attempt)"
        }
        return finalSlug
    }

    /// Generate a fallback slug when the model provides none.
    /// Format: `yyyy-MM-dd-HHmm-<6 random alphanumerics>` (millisecond-safe
    /// via the random tail so back-to-back invocations don't collide).
    static func generateFallbackSlug() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: Date())
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let tail = String((0..<6).map { _ in alphabet.randomElement()! })
        return "\(stamp)-\(tail)"
    }

    /// Sanitize a slug supplied by the dialog model: lowercase, keep only
    /// `[a-z0-9-]`, collapse runs of `-`, trim leading/trailing `-`, cap 64.
    static func sanitize(slug: String?) -> String {
        guard let raw = slug?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        let lowered = raw.lowercased()
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 64 {
            out = String(out.prefix(64))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    /// Best-effort mkdir -p. Errors are ignored on purpose; downstream file
    /// writes will surface any real permission problem.
    private static func ensureDirectoryExists(atPath path: String) {
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
    }
}
