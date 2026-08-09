// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacFinderReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for FinderSelectionCapture + AppleScriptRunner.
//
// Two flavours of test:
//   * Pure parser tests — exercise `FinderSelectionCapture.parse` with
//     synthetic strings shaped exactly like Finder's AppleScript output.
//     Always safe to run headless.
//   * Live tests — invoke osascript. Skipped when running in CI/no-TCC
//     environments via `OPENCLICKY_SKIP_UI_TESTS` (same env flag the
//     FrontmostAppCaptureTests use).

import XCTest
@testable import OpenClickyContextService

// MARK: - Parser tests (pure, no osascript needed)

final class FinderSelectionParserTests: XCTestCase {

    private let RS = "\u{1E}"
    private let NUL = "\u{0}"

    // MARK: byte-identical AppleScript source

    func test_appleScriptSource_matchesEverywhereVerbatim() {
        let expected =
            "tell application \"Finder\"\n" +
            "            set NUL to (ASCII character 0)\n" +
            "            set RS to (ASCII character 30)\n" +
            "            set sel to selection\n" +
            "            set out to \"\"\n" +
            "            repeat with i in sel\n" +
            "                set out to out & POSIX path of (i as alias) & NUL\n" +
            "            end repeat\n" +
            "            try\n" +
            "                set fp to POSIX path of ((target of front window) as alias)\n" +
            "            on error\n" +
            "                set fp to \"\"\n" +
            "            end try\n" +
            "            return out & RS & fp\n" +
            "        end tell"
        XCTAssertEqual(FinderSelectionCapture.appleScriptSource, expected)
    }

    // MARK: parse — empty output

    func test_parse_emptyString_returnsEmptyInfo() {
        let info = FinderSelectionCapture.parse("")
        XCTAssertNil(info.currentFolder)
        XCTAssertEqual(info.selectedFiles.count, 0)
    }

    func test_parse_onlyRS_returnsEmptyInfo() {
        let info = FinderSelectionCapture.parse(RS)
        XCTAssertNil(info.currentFolder)
        XCTAssertEqual(info.selectedFiles.count, 0)
    }

    // MARK: parse — folder only, no selection

    func test_parse_folderOnly() {
        // Finder with an open window but nothing selected: selBlock empty,
        // folder present.
        let raw = "\(RS)/Users/example/Documents"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.currentFolder, "/Users/example/Documents")
        XCTAssertEqual(info.selectedFiles.count, 0)
    }

    func test_parse_folderEmptyString_becomesNil() {
        // Finder's `on error set fp to ""` branch — folder is present but
        // empty. C# collapses to null.
        let raw = "\(RS)"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertNil(info.currentFolder)
    }

    func test_parse_folderWhitespaceOnly_becomesNil() {
        let raw = "\(RS)   \n"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertNil(info.currentFolder)
    }

    // MARK: parse — single-file selection

    func test_parse_singleFile() {
        let raw = "/Users/x/report.pdf\(NUL)\(RS)/Users/x"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.currentFolder, "/Users/x")
        XCTAssertEqual(info.selectedFiles.count, 1)
        let f = info.selectedFiles[0]
        XCTAssertEqual(f.path, "/Users/x/report.pdf")
        XCTAssertEqual(f.name, "report.pdf")
        XCTAssertFalse(f.isDirectory)
        XCTAssertEqual(f.kindHint, "pdf")
    }

    // MARK: parse — directory (trailing slash) is detected

    func test_parse_directoryWithTrailingSlash() {
        let raw = "/Users/x/projects/\(NUL)\(RS)/Users/x"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 1)
        let f = info.selectedFiles[0]
        XCTAssertEqual(f.path, "/Users/x/projects/")
        XCTAssertEqual(f.name, "projects")
        XCTAssertTrue(f.isDirectory)
        XCTAssertEqual(f.kindHint, "folder")
    }

    // MARK: parse — filesystem probe promotes dir when trailing slash absent

    func test_parse_existingDirectoryWithoutTrailingSlash_isDetectedAsDirectory() {
        // /tmp is a real directory on every macOS host. Its Finder-emitted
        // POSIX path would end in '/' in real life; this asserts the C# safety-
        // net check for when the trailing slash is missing (paranoid fallback).
        let raw = "/tmp\(NUL)\(RS)"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 1)
        XCTAssertTrue(info.selectedFiles[0].isDirectory)
        XCTAssertEqual(info.selectedFiles[0].kindHint, "folder")
    }

    // MARK: parse — mixed selection

    func test_parse_multipleItems_preservesOrder() {
        let raw = "/a/one.txt\(NUL)/b/two.pdf\(NUL)/c/dir/\(NUL)\(RS)/root"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.currentFolder, "/root")
        XCTAssertEqual(info.selectedFiles.count, 3)
        XCTAssertEqual(info.selectedFiles[0].name, "one.txt")
        XCTAssertEqual(info.selectedFiles[0].kindHint, "text")
        XCTAssertEqual(info.selectedFiles[1].name, "two.pdf")
        XCTAssertEqual(info.selectedFiles[1].kindHint, "pdf")
        XCTAssertEqual(info.selectedFiles[2].name, "dir")
        XCTAssertTrue(info.selectedFiles[2].isDirectory)
    }

    // MARK: parse — malformed entries are filtered

    func test_parse_dropsEntriesNotStartingWithSlash() {
        let raw = "relative/path\(NUL)/absolute/keep.txt\(NUL)\(RS)/root"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 1)
        XCTAssertEqual(info.selectedFiles[0].path, "/absolute/keep.txt")
    }

    func test_parse_dropsBlankEntries() {
        // Extra NULs from a script that emitted `path\0\0`.
        let raw = "/a/x.md\(NUL)\(NUL)/b/y.md\(NUL)\(RS)/root"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 2)
    }

    func test_parse_stripsTrailingLF_only() {
        // Pure trailing LF: TrimEnd('\r') is a no-op, TrimEnd('\n') strips it.
        let raw = "/a/x.md\n\(NUL)\(RS)"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 1)
        XCTAssertEqual(info.selectedFiles[0].path, "/a/x.md")
    }

    func test_parse_stripsTrailingCR_only() {
        // Pure trailing CR: TrimEnd('\r') strips it.
        let raw = "/a/x.md\r\(NUL)\(RS)"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 1)
        XCTAssertEqual(info.selectedFiles[0].path, "/a/x.md")
    }

    func test_parse_CRLFOrder_matchesCSharpQuirk() {
        // C# does `TrimEnd('\r').TrimEnd('\n')`. On input ending in "\r\n":
        //  * TrimEnd('\r') strips trailing CR chars → no-op (last char is LF).
        //  * TrimEnd('\n') strips trailing LF → yields path ending in a single
        //    stray '\r'. This is a known C# quirk we preserve verbatim so
        //    downstream diffs against Everywhere stay byte-identical.
        let raw = "/a/x.md\r\n\(NUL)\(RS)"
        let info = FinderSelectionCapture.parse(raw)
        XCTAssertEqual(info.selectedFiles.count, 1)
        XCTAssertEqual(info.selectedFiles[0].path, "/a/x.md\r")
    }

    // MARK: kindHint — full mapping from GetFinderSelectionTool

    func test_kindHint_directoryAlwaysFolder() {
        XCTAssertEqual(
            FinderSelectionCapture.kindHintFromName("anything.pdf", isDirectory: true),
            "folder"
        )
    }

    func test_kindHint_office_mapping() {
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.pdf", isDirectory: false), "pdf")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.docx", isDirectory: false), "docx")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.xlsx", isDirectory: false), "xlsx")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.pptx", isDirectory: false), "pptx")
        // legacy binary office
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.doc", isDirectory: false), "unknown")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.xls", isDirectory: false), "unknown")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.ppt", isDirectory: false), "unknown")
    }

    func test_kindHint_web_and_text() {
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.html", isDirectory: false), "html")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.htm", isDirectory: false), "html")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.txt", isDirectory: false), "text")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.md", isDirectory: false), "text")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.rst", isDirectory: false), "text")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.log", isDirectory: false), "text")
    }

    func test_kindHint_image_mapping() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic"] {
            XCTAssertEqual(
                FinderSelectionCapture.kindHintFromName("a.\(ext)", isDirectory: false),
                "image",
                "extension .\(ext) should map to image"
            )
        }
    }

    func test_kindHint_epub() {
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("book.epub", isDirectory: false), "epub")
    }

    func test_kindHint_unknownExtension_returnsUnknown() {
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("noext", isDirectory: false), "unknown")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.weirdformat", isDirectory: false), "unknown")
    }

    func test_kindHint_isCaseInsensitiveOnExtension() {
        // GetFinderSelectionTool does `ToLowerInvariant()` on ext.
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("a.PDF", isDirectory: false), "pdf")
        XCTAssertEqual(FinderSelectionCapture.kindHintFromName("SHOUTY.JPEG", isDirectory: false), "image")
    }

    // MARK: JSON round-trip

    func test_finderSelectionInfo_roundTripsJSON() throws {
        let sample = FinderSelectionInfo(
            currentFolder: "/Users/x",
            selectedFiles: [
                FinderItem(path: "/Users/x/a.pdf", name: "a.pdf", isDirectory: false, kindHint: "pdf"),
                FinderItem(path: "/Users/x/proj/", name: "proj", isDirectory: true, kindHint: "folder"),
            ]
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FinderSelectionInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }
}

// MARK: - AppleScriptRunner tests

final class AppleScriptRunnerTests: XCTestCase {

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    func test_run_emptySource_returnsFailed() async {
        let result = await AppleScriptRunner.shared.run(source: "")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error, "empty script")
    }

    func test_run_whitespaceOnlySource_returnsFailed() async {
        let result = await AppleScriptRunner.shared.run(source: "   \n\t")
        XCTAssertEqual(result.status, .failed)
    }

    func test_run_simpleReturn_producesOutput() async throws {
        // osascript is a system binary on every macOS host. This test does
        // NOT touch Apple Events / TCC so it's safe to run in CI.
        let result = await AppleScriptRunner.shared.run(source: "return \"hello\"")
        XCTAssertEqual(result.status, .ok, "stderr: \(result.error ?? "")")
        XCTAssertEqual(result.output, "hello")
    }

    func test_run_scriptError_returnsFailed() async {
        // Deliberate syntax error — no permission is involved so this must
        // classify as .failed, not .permissionDenied.
        let result = await AppleScriptRunner.shared.run(source: "return &&&")
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.error)
    }

    func test_run_largeOutput_doesNotDeadlock() async throws {
        // Emit ~128 KB of text. The pipe drain guard in the runner is
        // exactly what prevents a hang here (osascript blocks on stdout
        // write when the pipe buffer fills at ~64 KB).
        let script = """
        set s to ""
        repeat 2000 times
            set s to s & "0123456789012345678901234567890123456789012345678901234567890\n"
        end repeat
        return s
        """
        let result = await AppleScriptRunner.shared.run(source: script)
        XCTAssertEqual(result.status, .ok)
        XCTAssertNotNil(result.output)
        XCTAssertGreaterThan(result.output?.count ?? 0, 100_000)
    }
}

// MARK: - Live Finder tests (skipped in headless environments)

final class FinderSelectionCaptureLiveTests: XCTestCase {

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    /// Best-effort activation via osascript. Returns whether Finder appears
    /// to have become frontmost. Does not fail — used only as a precondition.
    private func activateFinder(timeout: TimeInterval = 3.0) async -> Bool {
        // Direct activate call — permissions must already be granted.
        let activate = await AppleScriptRunner.shared.run(
            source: "tell application \"Finder\" to activate"
        )
        return activate.status == .ok
    }

    func test_capture_finderReachable_returnsNonNil() async throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")

        // Verify osascript can reach Finder before running the full capture.
        // If TCC blocks us, the runner returns .permissionDenied and the
        // outer capture returns nil — we skip rather than fail.
        let probe = await AppleScriptRunner.shared.run(source: "tell application \"Finder\" to return name")
        if probe.status == .permissionDenied {
            throw XCTSkip("Finder AppleScript blocked by TCC in this test environment")
        }
        if probe.status != .ok {
            throw XCTSkip("Finder not reachable: \(probe.error ?? "unknown")")
        }

        _ = await activateFinder()

        let info = await FinderSelectionCapture.capture()
        // With Finder reachable, capture must yield non-nil, even if the
        // selection is empty.
        XCTAssertNotNil(info, "Expected FinderSelectionCapture to return non-nil when osascript succeeds")
    }

    func test_capture_completesUnderRunnerTimeout() async throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")

        // 15 s is the runner budget. If the flow hangs beyond ~16 s the
        // runner has failed to kill osascript — test that this never
        // happens under normal conditions.
        let start = Date()
        _ = await FinderSelectionCapture.capture()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 16.0, "capture() must not exceed runner timeout")
    }
}

// MARK: - Stub-runner unit tests (no osascript)

private struct StubRunner: AppleScriptRunning {
    let result: AppleScriptResult
    func run(source: String) async -> AppleScriptResult { result }
}

final class FinderSelectionCaptureStubbedTests: XCTestCase {

    func test_capture_permissionDenied_returnsNil() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .permissionDenied,
            output: nil,
            error: "-1743"
        ))
        let info = await FinderSelectionCapture.capture(runner: stub)
        XCTAssertNil(info)
    }

    func test_capture_failed_returnsNil() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .failed,
            output: nil,
            error: "boom"
        ))
        let info = await FinderSelectionCapture.capture(runner: stub)
        XCTAssertNil(info)
    }

    func test_capture_okEmpty_returnsEmptyInfo() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .ok,
            output: "\u{1E}",
            error: nil
        ))
        let info = await FinderSelectionCapture.capture(runner: stub)
        XCTAssertNotNil(info)
        XCTAssertNil(info?.currentFolder)
        XCTAssertEqual(info?.selectedFiles.count, 0)
    }

    func test_capture_okWithSelection_parsesFiles() async {
        let out = "/Users/x/a.pdf\u{0}/Users/x/b.md\u{0}\u{1E}/Users/x"
        let stub = StubRunner(result: AppleScriptResult(status: .ok, output: out, error: nil))
        let info = await FinderSelectionCapture.capture(runner: stub)
        XCTAssertEqual(info?.currentFolder, "/Users/x")
        XCTAssertEqual(info?.selectedFiles.count, 2)
        XCTAssertEqual(info?.selectedFiles[0].name, "a.pdf")
        XCTAssertEqual(info?.selectedFiles[0].kindHint, "pdf")
        XCTAssertEqual(info?.selectedFiles[1].kindHint, "text")
    }
}
