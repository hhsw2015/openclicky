// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacFinderReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Reads the current Finder selection via AppleScript. Uses ASCII control
// characters (NUL between paths, RS between the selection block and the
// front-window folder) so filenames containing newlines are not fragmented.
// See sibling doc `docs/ROADMAP/.impl-notes/phase1-finder-2026-07-22.md` for
// the byte-level parser reference.
//
// Public API deliberately narrower than the C# `FinderResult`:
//   * `capture()` returns `FinderSelectionInfo?`.
//     * `nil` — AppleScript failed, was denied, or timed out. Callers should
//       treat as "no Finder context available".
//     * non-nil with empty `selectedFiles` — Finder is reachable but nothing
//       is selected. Legit "OK, empty" case.
// The richer `AppleScriptStatus` distinction is still accessible via the
// internal `run(runner:)` entry point for a future MCP tool port that needs
// to surface `permission_denied` to end users.

import Foundation

/// Captures the current Finder selection on macOS.
///
/// Mirrors Everywhere's `MacFinderReader` — same AppleScript source, same
/// parser rules, same handling of the `Failed` status (mapped to nil here,
/// mapped to `PermissionDenied` in the C# code). The AppleScript text is
/// preserved byte-identically; do not reformat.
public enum FinderSelectionCapture {

    /// AppleScript source — byte-identical to `MacFinderReader.Source`.
    /// Indentation must not be altered because the string constant is
    /// compared verbatim by the parity audit.
    internal static let appleScriptSource: String =
        #"""
        tell application "Finder"
                    set NUL to (ASCII character 0)
                    set RS to (ASCII character 30)
                    set sel to selection
                    set out to ""
                    repeat with i in sel
                        set out to out & POSIX path of (i as alias) & NUL
                    end repeat
                    try
                        set fp to POSIX path of ((target of front window) as alias)
                    on error
                        set fp to ""
                    end try
                    return out & RS & fp
                end tell
        """#

    /// Returns a snapshot of the current Finder selection, or `nil` when
    /// AppleScript could not be invoked (permission denied, timeout, spawn
    /// failure, or non-macOS host).
    ///
    /// `async` because AppleScript runs out-of-process via `osascript(1)`.
    /// Runs off the main queue via the shared `AppleScriptRunner`.
    public static func capture() async -> FinderSelectionInfo? {
        await capture(runner: AppleScriptRunner.shared)
    }

    /// Overload for tests / DI — accepts any `AppleScriptRunning`.
    internal static func capture(runner: AppleScriptRunning) async -> FinderSelectionInfo? {
        let result = await runner.run(source: appleScriptSource)
        switch result.status {
        case .ok:
            let parsed = parse(result.output ?? "")
            CaptureLog.log(
                "openclicky.finder.capture",
                [
                    "selected_count": "\(parsed.selectedFiles.count)",
                    "has_folder": parsed.currentFolder == nil ? "false" : "true",
                    "raw_len": "\(result.output?.count ?? 0)"
                ]
            )
            return parsed
        case .notSupported, .permissionDenied, .failed:
            // Matches C# behavior at MacFinderReader.cs:33-41 where every
            // non-Ok status collapses into "no data". C# preserves the
            // status enum in FinderResult; we drop it because the public
            // API surface for openclicky Layer 0 is `Info?`.
            CaptureLog.log(
                "openclicky.finder.applescript_failed",
                direction: "error",
                ["status": result.status.rawValue]
            )
            return nil
        }
    }

    // MARK: - Parsing (mirrors MacFinderReader.cs:43-69 byte-for-byte)

    /// Deterministic pure function. Exposed `internal` so
    /// `FinderSelectionCaptureTests` can exercise it without spawning
    /// osascript. Semantics MUST NOT drift from the C# reference.
    ///
    /// Rules (from `MacFinderReader.cs`):
    ///   1. Locate first `\u{1E}` (RS). Everything before is the selection
    ///      block; everything after, trimmed, is the folder (empty -> nil).
    ///   2. Split selection block on `\u{0}` (NUL).
    ///   3. For each entry: trim trailing `\r\n`, drop empty, drop entries
    ///      not starting with `/`.
    ///   4. `isDirectory` = trailing `/`. Canonical path drops trailing `/`.
    ///   5. Name = filename component of canonical, fallback to full path.
    ///   6. Best-effort `FileManager.fileExists(atPath:isDirectory:)` bump
    ///      of `isDirectory` when the path did not end in `/`.
    internal static func parse(_ raw: String) -> FinderSelectionInfo {
        // Split at first RS (0x1E). String.split can't easily do "first
        // occurrence only", so use range-based slicing to preserve embedded
        // separators (Finder never emits multiple RS bytes, but this keeps
        // the parser byte-equivalent to `IndexOf('\x1E')`).
        let rsChar: Character = "\u{1E}"
        let selBlock: String
        let folderRaw: String?
        if let rsIdx = raw.firstIndex(of: rsChar) {
            selBlock = String(raw[..<rsIdx])
            let afterRS = raw.index(after: rsIdx)
            folderRaw = String(raw[afterRS...])
        } else {
            selBlock = raw
            folderRaw = nil
        }

        var folder: String? = folderRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if folder?.isEmpty == true { folder = nil }

        // Split on NUL. Swift's `split(separator:)` skips trailing empties;
        // C# `Split('\0')` keeps them but we filter empties below anyway.
        // Using `split(separator:omittingEmptySubsequences: false)` keeps
        // parity in case a future maintainer relies on positional indices.
        let entries = selBlock.split(
            separator: "\u{0}",
            omittingEmptySubsequences: false
        )

        var files: [FinderItem] = []
        files.reserveCapacity(entries.count)

        for entrySlice in entries {
            // C#: entry.TrimEnd('\r').TrimEnd('\n') — first strips all trailing
            // CR, then all trailing LF. Order matters (e.g. "\r\n" becomes
            // "\r"). Operates on Unicode scalars because Swift folds "\r\n"
            // into a single grapheme cluster, which would otherwise defeat
            // `hasSuffix("\n")`.
            var scalars = String(entrySlice).unicodeScalars
            while scalars.last == UnicodeScalar(0x0D) { scalars.removeLast() }
            while scalars.last == UnicodeScalar(0x0A) { scalars.removeLast() }
            let path = String(scalars)

            if path.isEmpty { continue }
            if !path.hasPrefix("/") { continue }

            var isDir = path.hasSuffix("/")
            let canonical: String
            if isDir {
                // Drop *all* trailing slashes to match Path.GetFileName's
                // pruning. `MacFinderReader` calls `TrimEnd('/')` once.
                canonical = String(path.reversed().drop(while: { $0 == "/" }).reversed())
            } else {
                canonical = path
            }

            let name: String
            let baseName = (canonical as NSString).lastPathComponent
            if baseName.isEmpty {
                // Matches C# fallback: `if (string.IsNullOrEmpty(name)) name = path;`
                name = path
            } else {
                name = baseName
            }

            if !isDir {
                // Best-effort filesystem check. Any error (including nonexistent
                // path) leaves `isDir` untouched — matches the C# try/catch.
                var isDirOut: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirOut),
                   isDirOut.boolValue {
                    isDir = true
                }
            }

            let kindHint = kindHintFromName(name, isDirectory: isDir)
            files.append(FinderItem(
                path: path,
                name: name,
                isDirectory: isDir,
                kindHint: kindHint
            ))
        }

        return FinderSelectionInfo(currentFolder: folder, selectedFiles: files)
    }

    // MARK: - Kind hint (mirrors GetFinderSelectionTool.KindHintFromExtension)

    /// Coarse content classifier. Exact port of
    /// `GetFinderSelectionTool.KindHintFromExtension` at
    /// `src/Everywhere.Mcp/Tools/GetFinderSelectionTool.cs:67-85`.
    /// The set of tokens (`pdf`, `docx`, ..., `folder`, `unknown`) is public
    /// contract — do not rename without cross-checking C# callers.
    internal static func kindHintFromName(_ name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "pdf"
        case "docx": return "docx"
        case "xlsx": return "xlsx"
        case "pptx": return "pptx"
        // Legacy binary Office formats are not OOXML — OpenXml readers
        // can't open them. C# comment preserved.
        case "doc", "xls", "ppt": return "unknown"
        case "epub": return "epub"
        case "html", "htm": return "html"
        case "txt", "md", "rst", "log": return "text"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic":
            return "image"
        default: return "unknown"
        }
    }
}
