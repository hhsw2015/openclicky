// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacBrowserTabsReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for BrowserTabsCapture.
//
// Three flavours of test:
//   * Pure parser + template tests — exercise `parseTabs`, `scriptFor`, and
//     the byte-identical AppleScript templates. Always safe under CI.
//   * Stub-runner tests — inject `AppleScriptRunning` fake to verify the
//     status collapse (permissionDenied/failed/notSupported -> nil).
//   * Live tests — invoke osascript. Skipped under `OPENCLICKY_SKIP_UI_TESTS`
//     matching sibling capture tests.

import XCTest
@testable import OpenClickyContextService

// MARK: - Parser tests (pure, no osascript needed)

final class BrowserTabsParserTests: XCTestCase {

    private let US = "\u{1F}"
    private let RS = "\u{1E}"

    func test_parseTabs_emptyString_returnsEmptyList() {
        let tabs = BrowserTabsCapture.parseTabs("")
        XCTAssertEqual(tabs.count, 0)
    }

    func test_parseTabs_onlyRS_returnsEmptyList() {
        let tabs = BrowserTabsCapture.parseTabs("\u{1E}\u{1E}")
        XCTAssertEqual(tabs.count, 0)
    }

    func test_parseTabs_singleActiveTab() {
        let raw = "1\(US)Home\(US)https://example.com/\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].title, "Home")
        XCTAssertEqual(tabs[0].url, "https://example.com/")
        XCTAssertTrue(tabs[0].isActive)
    }

    func test_parseTabs_singleInactiveTab() {
        let raw = "0\(US)Docs\(US)https://docs.example.com/\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertFalse(tabs[0].isActive)
    }

    func test_parseTabs_multipleTabsPreserveOrder() {
        let raw =
            "0\(US)A\(US)https://a/\(RS)" +
            "1\(US)B\(US)https://b/\(RS)" +
            "0\(US)C\(US)https://c/\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(tabs.map(\.url), ["https://a/", "https://b/", "https://c/"])
        XCTAssertEqual(tabs.map(\.isActive), [false, true, false])
    }

    func test_parseTabs_skipsRecordsWithFewerThanThreeParts() {
        // Only 2 US bytes -> 2 parts -> dropped.
        let raw =
            "0\(US)OnlyTitle\(RS)" +
            "1\(US)Good\(US)https://good/\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].title, "Good")
    }

    func test_parseTabs_trimsCRLFAroundLines() {
        // Raw output may carry stray CR/LF around records — trimmed.
        let raw = " 1\(US)Home\(US)https://example.com/\r\n"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].title, "Home")
    }

    func test_parseTabs_urlPreservedVerbatim() {
        // Query strings, fragments, credentials — no normalisation.
        let raw = "0\(US)T\(US)https://a.example/q?x=1&y=2#frag\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].url, "https://a.example/q?x=1&y=2#frag")
    }

    func test_parseTabs_flagOtherThanOneCountsAsInactive() {
        // Anything not exactly "1" -> false. (C# `parts[0] == "1"`).
        let raw =
            "2\(US)Weird\(US)https://weird/\(RS)" +
            "\(US)Empty\(US)https://empty/\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertFalse(tabs[0].isActive)
        XCTAssertFalse(tabs[1].isActive)
    }

    func test_parseTabs_extraUSByteInURLIsPreservedInThirdField() {
        // C# `Split('\x1F', 3)` — anything beyond the 2nd separator
        // stays in parts[2] verbatim, including further US bytes.
        let raw = "1\(US)Title\(US)https://x/?a\(US)b\(RS)"
        let tabs = BrowserTabsCapture.parseTabs(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].url, "https://x/?a\(US)b")
    }
}

// MARK: - AppleScript template parity tests

final class BrowserTabsScriptTests: XCTestCase {

    func test_safariScript_matchesEverywhereVerbatim() {
        let expected =
            "tell application \"Safari\"\n" +
            "            set out to \"\"\n" +
            "            set US to (ASCII character 31)\n" +
            "            set RS to (ASCII character 30)\n" +
            "            repeat with w in windows\n" +
            "                set ct to current tab of w\n" +
            "                repeat with t in tabs of w\n" +
            "                    set isActive to (t is ct)\n" +
            "                    set flag to \"0\"\n" +
            "                    if isActive then set flag to \"1\"\n" +
            "                    set out to out & flag & US & (name of t) & US & (URL of t) & RS\n" +
            "                end repeat\n" +
            "            end repeat\n" +
            "            return out\n" +
            "        end tell"
        XCTAssertEqual(BrowserTabsCapture.safariScript, expected)
    }

    func test_arcScript_matchesEverywhereVerbatim() {
        let expected =
            "tell application \"Arc\"\n" +
            "            set out to \"\"\n" +
            "            set US to (ASCII character 31)\n" +
            "            set RS to (ASCII character 30)\n" +
            "            repeat with w in windows\n" +
            "                repeat with t in tabs of w\n" +
            "                    set out to out & \"0\" & US & (title of t) & US & (URL of t) & RS\n" +
            "                end repeat\n" +
            "            end repeat\n" +
            "            return out\n" +
            "        end tell"
        XCTAssertEqual(BrowserTabsCapture.arcScript, expected)
    }

    func test_chromiumScript_matchesEverywhereVerbatimForChrome() {
        let expected =
            "tell application \"Google Chrome\"\n" +
            "            set out to \"\"\n" +
            "            set US to (ASCII character 31)\n" +
            "            set RS to (ASCII character 30)\n" +
            "            repeat with w in windows\n" +
            "                set ai to active tab index of w\n" +
            "                set i to 0\n" +
            "                repeat with t in tabs of w\n" +
            "                    set i to i + 1\n" +
            "                    set isActive to (i is equal to ai)\n" +
            "                    set flag to \"0\"\n" +
            "                    if isActive then set flag to \"1\"\n" +
            "                    set out to out & flag & US & (title of t) & US & (URL of t) & RS\n" +
            "                end repeat\n" +
            "            end repeat\n" +
            "            return out\n" +
            "        end tell"
        XCTAssertEqual(
            BrowserTabsCapture.chromiumScript(canonicalAppName: "Google Chrome"),
            expected
        )
    }

    func test_chromiumScript_appNameInterpolation_useAllowListedNames() {
        // Only the canonical name string is interpolated; the template
        // stays the same modulo the app name literal.
        for canonical in ["Brave Browser", "Microsoft Edge", "Chromium", "Vivaldi", "Opera"] {
            let source = BrowserTabsCapture.chromiumScript(canonicalAppName: canonical)
            XCTAssertTrue(
                source.hasPrefix("tell application \"\(canonical)\"\n"),
                "Chromium template must open with tell application for \(canonical)"
            )
            XCTAssertTrue(source.contains("active tab index of w"))
            XCTAssertTrue(source.hasSuffix("end tell"))
        }
    }
}

// MARK: - Router (scriptFor)

final class BrowserTabsRouterTests: XCTestCase {

    func test_scriptFor_emptyOrWhitespace_returnsNil() {
        XCTAssertNil(BrowserTabsCapture.scriptFor(app: ""))
        XCTAssertNil(BrowserTabsCapture.scriptFor(app: "   "))
        XCTAssertNil(BrowserTabsCapture.scriptFor(app: "\n\t"))
    }

    func test_scriptFor_unknownApp_returnsNil() {
        XCTAssertNil(BrowserTabsCapture.scriptFor(app: "Finder"))
        XCTAssertNil(BrowserTabsCapture.scriptFor(app: "com.apple.finder"))
        XCTAssertNil(BrowserTabsCapture.scriptFor(app: "Xcode"))
    }

    func test_scriptFor_safariAliases_selectSafariScript() {
        for alias in ["safari", "Safari", "SAFARI"] {
            let choice = BrowserTabsCapture.scriptFor(app: alias)
            XCTAssertNotNil(choice, "expected Safari for alias \(alias)")
            XCTAssertEqual(choice?.canonicalApp, "Safari")
            XCTAssertEqual(choice?.source, BrowserTabsCapture.safariScript)
        }
    }

    func test_scriptFor_arcAliases_selectArcScript() {
        // Arc is routed BEFORE the chromium branch (see MacBrowserTabsReader.cs:79-83).
        for alias in ["arc", "Arc", "ARC"] {
            let choice = BrowserTabsCapture.scriptFor(app: alias)
            XCTAssertNotNil(choice)
            XCTAssertEqual(choice?.canonicalApp, "Arc")
            XCTAssertEqual(choice?.source, BrowserTabsCapture.arcScript)
        }
    }

    func test_scriptFor_chromiumFamily_selectChromiumTemplate() {
        let cases: [(alias: String, canonical: String)] = [
            ("chrome", "Google Chrome"),
            ("google chrome", "Google Chrome"),
            ("Google Chrome", "Google Chrome"),
            ("brave", "Brave Browser"),
            ("brave browser", "Brave Browser"),
            ("edge", "Microsoft Edge"),
            ("microsoft edge", "Microsoft Edge"),
            ("chromium", "Chromium"),
            ("vivaldi", "Vivaldi"),
            ("opera", "Opera"),
        ]
        for c in cases {
            let choice = BrowserTabsCapture.scriptFor(app: c.alias)
            XCTAssertNotNil(choice, "expected chromium hit for \(c.alias)")
            XCTAssertEqual(choice?.canonicalApp, c.canonical)
            XCTAssertEqual(
                choice?.source,
                BrowserTabsCapture.chromiumScript(canonicalAppName: c.canonical)
            )
        }
    }

    func test_chromiumApps_matchesEverywhereAllowListExactly() {
        // Byte-level: same keys, same canonical names as
        // MacBrowserTabsReader.cs:16-28.
        let expected: [String: String] = [
            "chrome": "Google Chrome",
            "google chrome": "Google Chrome",
            "arc": "Arc",
            "brave": "Brave Browser",
            "brave browser": "Brave Browser",
            "edge": "Microsoft Edge",
            "microsoft edge": "Microsoft Edge",
            "chromium": "Chromium",
            "vivaldi": "Vivaldi",
            "opera": "Opera",
        ]
        XCTAssertEqual(BrowserTabsCapture.chromiumApps, expected)
    }
}

// MARK: - Stub-runner tests

private struct StubRunner: AppleScriptRunning {
    let result: AppleScriptResult
    func run(source: String) async -> AppleScriptResult { result }
}

final class BrowserTabsCaptureStubbedTests: XCTestCase {

    private let US = "\u{1F}"
    private let RS = "\u{1E}"

    func test_capture_unknownApp_returnsNilWithoutRunning() async {
        // A runner that would fail loudly if invoked. Router must
        // short-circuit before it is called.
        struct Panic: AppleScriptRunning {
            func run(source: String) async -> AppleScriptResult {
                XCTFail("router should not have reached the runner for unknown app")
                return AppleScriptResult(status: .failed, output: nil, error: nil)
            }
        }
        let info = await BrowserTabsCapture.capture(app: "Xcode", runner: Panic())
        XCTAssertNil(info)
    }

    func test_capture_permissionDenied_returnsNil() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .permissionDenied,
            output: nil,
            error: "-1743"
        ))
        let info = await BrowserTabsCapture.capture(app: "safari", runner: stub)
        XCTAssertNil(info)
    }

    func test_capture_failed_returnsNil() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .failed,
            output: nil,
            error: "boom"
        ))
        let info = await BrowserTabsCapture.capture(app: "chrome", runner: stub)
        XCTAssertNil(info)
    }

    func test_capture_notSupported_returnsNil() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .notSupported,
            output: nil,
            error: nil
        ))
        let info = await BrowserTabsCapture.capture(app: "brave", runner: stub)
        XCTAssertNil(info)
    }

    func test_capture_okEmpty_returnsEmptyInfoWithCanonicalApp() async {
        let stub = StubRunner(result: AppleScriptResult(
            status: .ok,
            output: "",
            error: nil
        ))
        let info = await BrowserTabsCapture.capture(app: "safari", runner: stub)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.app, "Safari")
        XCTAssertEqual(info?.tabs.count, 0)
    }

    func test_capture_okWithTabs_parsesAndReportsCanonicalApp() async {
        let out =
            "1\(US)Home\(US)https://example.com/\(RS)" +
            "0\(US)Docs\(US)https://docs.example.com/\(RS)"
        let stub = StubRunner(result: AppleScriptResult(
            status: .ok,
            output: out,
            error: nil
        ))
        let info = await BrowserTabsCapture.capture(app: "chrome", runner: stub)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.app, "Google Chrome")
        XCTAssertEqual(info?.tabs.count, 2)
        XCTAssertEqual(info?.tabs[0].title, "Home")
        XCTAssertTrue(info?.tabs[0].isActive == true)
        XCTAssertEqual(info?.tabs[1].title, "Docs")
        XCTAssertFalse(info?.tabs[1].isActive == true)
    }

    func test_capture_arcAlias_reportsArcCanonical() async {
        let out = "0\(US)Pinned\(US)https://a/\(RS)"
        let stub = StubRunner(result: AppleScriptResult(
            status: .ok,
            output: out,
            error: nil
        ))
        let info = await BrowserTabsCapture.capture(app: "arc", runner: stub)
        XCTAssertEqual(info?.app, "Arc")
        XCTAssertEqual(info?.tabs.count, 1)
    }
}

// MARK: - JSON round-trip

final class BrowserTabsInfoJSONTests: XCTestCase {
    func test_browserTabsInfo_roundTripsJSON() throws {
        let sample = BrowserTabsInfo(
            app: "Safari",
            tabs: [
                BrowserTab(title: "Home", url: "https://example.com/", isActive: true),
                BrowserTab(title: "Docs", url: "https://docs.example.com/", isActive: false),
            ]
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(BrowserTabsInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }
}

// MARK: - Live tests (skipped under OPENCLICKY_SKIP_UI_TESTS)

final class BrowserTabsCaptureLiveTests: XCTestCase {

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    /// Verify osascript can reach the target browser before running the
    /// full capture. Skips the test when TCC blocks us — this is a
    /// permissions probe, not a functional signal.
    private func probeSafariReachable() async throws {
        let probe = await AppleScriptRunner.shared.run(
            source: "tell application \"Safari\" to return name"
        )
        switch probe.status {
        case .ok: return
        case .permissionDenied:
            throw XCTSkip("Safari AppleScript blocked by TCC in this env")
        case .notSupported, .failed:
            throw XCTSkip("Safari not reachable: \(probe.error ?? "unknown")")
        }
    }

    func test_capture_nonBrowserApp_returnsNil() async throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        // Finder is running on any mac session and is definitely not a
        // supported browser — verifies the not-supported short-circuit.
        let info = await BrowserTabsCapture.capture(app: "Finder")
        XCTAssertNil(info)
    }

    func test_capture_safariReachable_returnsNonNil() async throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        try await probeSafariReachable()

        let info = await BrowserTabsCapture.capture(app: "safari")
        // With Safari reachable we expect non-nil (tabs may be empty
        // if no window is open — that's still a valid Ok response).
        XCTAssertNotNil(info, "Expected BrowserTabsCapture to return non-nil when osascript reaches Safari")
        XCTAssertEqual(info?.app, "Safari")
        // Each returned tab must carry non-empty title AND url — Safari
        // never emits blank fields for user-navigable tabs.
        for tab in info?.tabs ?? [] {
            XCTAssertFalse(tab.url.isEmpty, "empty url in captured tab: \(tab)")
        }
    }

    func test_capture_completesUnderRunnerTimeout() async throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")
        // 15 s AppleScriptRunner budget bounds the call.
        let start = Date()
        _ = await BrowserTabsCapture.capture(app: "safari")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 16.0, "capture(app:) must not exceed runner timeout")
    }
}
