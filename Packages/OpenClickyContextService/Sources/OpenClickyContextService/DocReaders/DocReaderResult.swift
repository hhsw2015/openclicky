// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReaderResult.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Shared plumbing for the Layer-2 doc readers. Corresponds to
// Everywhere's `DocReaderResult` static helper - text truncation,
// encoding fallback (UTF-8 -> GB18030 -> Latin-1), and file-not-found
// preflight. Everywhere returns JSON `{text, metadata:{...}}` from
// `Build`; the Swift side surfaces a strongly-typed `DocReaderResult`
// struct (declared in `Types/CaptureTypes.swift`) instead so callers
// don't reparse JSON.
//
// Zip archive readers (docx / xlsx / pptx / epub) share
// `ZipEntryReader` which shells out to `/usr/bin/unzip` for entry
// listing and extraction. Everywhere reaches equivalent behaviour via
// `System.IO.Packaging`; on macOS `/usr/bin/unzip` is always present
// and provides the same content without pulling an SPM dependency.

import Foundation

/// Default text-length cap. Matches Everywhere's
/// `DocReaderResult.DefaultMaxChars = 2_000_000`.
public let docReaderDefaultMaxChars = 2_000_000

enum DocReaderShared {

    /// Truncate `text` to `docReaderDefaultMaxChars`, appending a
    /// `truncated` warning when the cap fires. Mirrors Everywhere's
    /// `Build` which decorates the metadata dict with `truncated=true`.
    static func capped(_ text: String, warnings: inout [String]) -> String {
        if text.count > docReaderDefaultMaxChars {
            warnings.append("truncated=true")
            return String(text.prefix(docReaderDefaultMaxChars))
        }
        return text
    }

    /// UTF-8 -> GB18030 -> Latin-1 fallback for text files. Mirrors
    /// Everywhere's `ReadAllTextWithFallback`. Latin-1 decoding never
    /// fails (all 256 byte values are valid), so this always returns.
    static func readTextWithFallback(_ url: URL) throws -> (text: String, encoding: String) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocReaderError.fileNotFound(url.path)
        }
        if let s = String(data: data, encoding: .utf8) {
            return (s, "utf-8")
        }
        // Bridge Cocoa's GB18030 identifier explicitly. Some Swift
        // stdlib snapshots don't expose `.gb18030` on String.Encoding.
        let gbCF = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let gbNS = CFStringConvertEncodingToNSStringEncoding(gbCF)
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbNS)) {
            return (s, "gb18030")
        }
        // Latin-1 accepts any byte pattern.
        if let s = String(data: data, encoding: .isoLatin1) {
            return (s, "latin1")
        }
        throw DocReaderError.encodingFailed(url.path)
    }

    /// Preflight the file existence check that every Everywhere reader
    /// does before opening its parser.
    static func requireExists(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            throw DocReaderError.fileNotFound(url.path)
        }
    }
}

/// Minimal reader over a zip archive backed by `/usr/bin/unzip`. Used
/// by docx / xlsx / pptx / epub. Public within the module so each
/// reader file can call `list` and `readEntry` without duplicating
/// process plumbing.
enum ZipEntryReader {

    static let unzipPath = "/usr/bin/unzip"

    /// Return every entry path in the archive. Entries are the "Name"
    /// column of `unzip -Z1`. Directories end in `/`.
    static func listEntries(archive: URL) throws -> [String] {
        let out = try runProcess(args: ["-Z1", archive.path])
        return out.split(separator: "\n").map(String.init)
    }

    /// Extract one entry as `Data`. `entry` must be the full path
    /// inside the archive (case-sensitive).
    static func readEntry(archive: URL, entry: String) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: unzipPath)
        proc.arguments = ["-p", archive.path, entry]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw DocReaderError.archiveInvalid("unzip spawn failed: \(error.localizedDescription)")
        }
        // Read on background thread(s) to avoid deadlock on large entries.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw DocReaderError.archiveInvalid("unzip exit=\(proc.terminationStatus) entry=\(entry)")
        }
        return data
    }

    /// Optional read: returns nil when the entry doesn't exist (no
    /// error). Used for parts that may legally be absent (e.g. a
    /// docx with no footnotes).
    static func readEntryIfPresent(archive: URL, entry: String) throws -> Data? {
        let entries = try listEntries(archive: archive)
        guard entries.contains(entry) else { return nil }
        return try readEntry(archive: archive, entry: entry)
    }

    private static func runProcess(args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: unzipPath)
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw DocReaderError.archiveInvalid("unzip spawn failed: \(error.localizedDescription)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw DocReaderError.archiveInvalid("unzip -Z1 exit=\(proc.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Return the local (namespace-stripped) name of an XML element - i.e.
/// `t` for both `w:t` and `a:t`. Used by every zip-based reader
/// because Everywhere's `OpenXml` API works on the schema-typed nodes
/// (`Paragraph`, `Text`) which are already namespace-normalised.
func docXMLLocalName(_ n: String) -> String {
    if let colon = n.firstIndex(of: ":") {
        return String(n[n.index(after: colon)...])
    }
    return n
}
