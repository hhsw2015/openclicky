//
//  OpenClickyProgressMarkerCheck.swift
//  cursor-buddy
//
//  F28 progress-driven auto-continue substrate. This helper answers the
//  single question the `turn/completed` observer needs to make its
//  dispatch decision: "Does <workdir>/PROGRESS.md have the DONE marker
//  on its own line right now?"
//
//  Contract mirrored from the agent-side template at
//  AppResources/OpenClicky/AGENTS-longrun-template.md:52,107,112 which
//  requires the agent to write `LAST_COMPLETED: DONE` on its own line
//  once the whole checklist is finished. Line-anchored match (case
//  sensitive) — see F28 review Issue #5 for why substring matching is
//  rejected (would false-positive on "NOTES: not DONE yet" etc).
//
//  Semantics for exceptional cases (F28 review Issue #6):
//    - File missing            -> return false (fire continue; matches
//                                 template's turn-1 planning path when
//                                 no PROGRESS.md yet exists).
//    - File exists but unread  -> return false + log warning. Persistent
//                                 read failures will accumulate against
//                                 the existing 3-attempt / 300s cooldown
//                                 budget in HeyClickyObserverStore.
//    - Marker regex fails      -> return false (defensive; treat as not
//                                 done rather than "done" so a corrupted
//                                 marker string does not silently stop
//                                 the loop).
//
//  Review pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809 (informational —
//  Everywhere does not run Codex, so no byte parity applies).
//

import Foundation

enum OpenClickyProgressMarkerCheck {
    /// Line-anchored check for the completion marker. Case-sensitive by
    /// design so lowercase transcripts of the marker string ("done") do
    /// not falsely halt the loop.
    /// - Parameters:
    ///   - path: absolute filesystem path to PROGRESS.md
    ///   - marker: literal marker string, e.g. "LAST_COMPLETED: DONE"
    /// - Returns: true if `marker` appears on a line by itself
    ///   (leading/trailing whitespace tolerated), false otherwise.
    static func isDone(path: String, marker: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }
        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            HeyClickyLog.log(
                "openclicky.f28.progress_read_failed",
                lane: "agent",
                direction: "error",
                ["path": path, "error": String(describing: error)]
            )
            return false
        }
        let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
        let pattern = "^\\s*\(escapedMarker)\\s*$"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return false
        }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.firstMatch(in: contents, options: [], range: range) != nil
    }
}
