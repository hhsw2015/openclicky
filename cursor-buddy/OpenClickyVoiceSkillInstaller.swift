//
//  OpenClickyVoiceSkillInstaller.swift
//  cursor-buddy
//
//  Installs the bundled openclicky-voice SKILL.md into every detected
//  CLI agent home directory so Claude Code / Codex / etc. auto-load it.
//

import Foundation

/// One CLI agent's install status. Mirrors SKI's onboarding row model
/// (name + install path + detected/installed/missing/error).
struct OpenClickyDetectedAgent: Identifiable, Equatable {
    let id: String
    let label: String
    let homeDirectory: URL
    let skillTargetDirectory: URL
    /// true when `homeDirectory` exists on disk (the CLI is installed).
    var isPresent: Bool
    /// true when `skillTargetDirectory` already resolves to our bundled skill.
    var isInstalled: Bool
    /// Non-nil when the last install attempt for this row failed.
    var lastError: String?
}

enum OpenClickyVoiceSkillInstaller {
    static let skillFolderName = "openclicky-voice"

    /// Absolute path to the bundled skill folder inside the .app.
    /// The Xcode "Copy OpenClicky App Resources" script copies
    /// `AppResources/OpenClicky/skills/` into
    /// `<app>/Contents/Resources/skills/` (flattened — the
    /// `OpenClicky` segment is stripped by ditto), so we look there
    /// first. Legacy paths are also probed for older builds.
    static var bundledSkillFolder: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("skills/\(skillFolderName)"),
            resourceURL.appendingPathComponent("OpenClicky/skills/\(skillFolderName)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Per-agent home directories we probe. Each expects a `skills/`
    /// subfolder that CLI agents auto-load.
    static var candidates: [(id: String, label: String, home: String)] {
        [
            ("claude",   "Claude Code",   ".claude"),
            ("codex",    "Codex",         ".codex"),
            ("gemini",   "Gemini CLI",    ".gemini"),
            ("cursor",   "Cursor",        ".cursor"),
            ("windsurf", "Windsurf",      ".windsurf"),
            ("cline",    "Cline",         ".cline"),
            ("continue", "Continue",      ".continue"),
            ("kilo",     "Kilo",          ".kilo"),
            ("agents",   "Agents",        ".agents"),
        ]
    }

    static func detectAgents() -> [OpenClickyDetectedAgent] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return candidates.map { entry in
            let agentHome = home.appendingPathComponent(entry.home, isDirectory: true)
            let target = agentHome.appendingPathComponent("skills/\(skillFolderName)", isDirectory: true)
            let present = FileManager.default.fileExists(atPath: agentHome.path)
            let installed = isTargetLinkedToBundle(target)
            return OpenClickyDetectedAgent(
                id: entry.id,
                label: entry.label,
                homeDirectory: agentHome,
                skillTargetDirectory: target,
                isPresent: present,
                isInstalled: installed,
                lastError: nil
            )
        }
    }

    private static func isTargetLinkedToBundle(_ target: URL) -> Bool {
        // Detects "installed" by presence of the SKILL.md file. We
        // don't care whether it's a symlink or a real copy — a broken
        // symlink still returns false because fileExists follows links.
        let skillMD = target.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: skillMD.path)
    }

    /// Install skill into ONE agent's home by COPYING the bundle to
    /// the agent's skills dir. Copy (not symlink) so:
    ///   - `.app` moves / uninstalls don't create dangling links
    ///   - the installed file is stable across OpenClicky updates
    ///     until the user explicitly clicks Update
    ///   - CLI agents that don't traverse symlinks still see it
    static func install(_ agent: OpenClickyDetectedAgent) -> OpenClickyDetectedAgent {
        var updated = agent
        guard let source = bundledSkillFolder,
              FileManager.default.fileExists(atPath: source.path) else {
            updated.lastError = "Bundled skill folder missing."
            return updated
        }
        guard agent.isPresent else {
            updated.lastError = "\(agent.label) not detected on this Mac."
            return updated
        }
        let parent = agent.skillTargetDirectory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: agent.skillTargetDirectory.path) {
                try FileManager.default.removeItem(at: agent.skillTargetDirectory)
            }
            try FileManager.default.copyItem(at: source, to: agent.skillTargetDirectory)
            updated.isInstalled = true
            updated.lastError = nil
        } catch {
            updated.lastError = error.localizedDescription
        }
        return updated
    }

    /// Remove skill from ONE agent's home.
    static func uninstall(_ agent: OpenClickyDetectedAgent) -> OpenClickyDetectedAgent {
        var updated = agent
        if FileManager.default.fileExists(atPath: agent.skillTargetDirectory.path) {
            do {
                try FileManager.default.removeItem(at: agent.skillTargetDirectory)
                updated.isInstalled = false
                updated.lastError = nil
            } catch {
                updated.lastError = error.localizedDescription
            }
        } else {
            updated.isInstalled = false
        }
        return updated
    }
}
