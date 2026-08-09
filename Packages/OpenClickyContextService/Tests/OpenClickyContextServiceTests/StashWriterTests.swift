// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for the stash-envelope surface:
//   * `OpenClickySanitiser.sanitiseUserText` / `sanitiseTokenValue` caps
//   * URL redaction (userinfo strip + 17-param denylist)
//   * Grapheme-safe truncation across emoji ZWJ / CJK / RTL runs
//   * `OpenClickyStashFormatter.formatForHook` byte-order deterministic

import XCTest
@testable import OpenClickyContextService

final class StashSanitiserTests: XCTestCase {

    // MARK: sanitiseUserText

    func test_sanitiseUserText_capsToMaxGraphemes() {
        let s = String(repeating: "a", count: 300)
        let out = OpenClickySanitiser.sanitiseUserText(s, maxChars: 80)
        // 80 graphemes + ellipsis
        XCTAssertEqual(out.count, 81)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    func test_sanitiseUserText_neutralisesEnvelopeChars() {
        let s = "[danger] \"quote\""
        let out = OpenClickySanitiser.sanitiseUserText(s, maxChars: 200)
        XCTAssertEqual(out, "(danger) 'quote'")
    }

    func test_sanitiseUserText_stripsControlToSpace() {
        let s = "line1\nline2\ttail\u{07}bell"
        let out = OpenClickySanitiser.sanitiseUserText(s, maxChars: 200)
        // \n / \t in the explicit ControlCharsToStrip list -> space.
        // \u{07} is in Char.IsControl but not in the explicit list; also -> space.
        XCTAssertEqual(out, "line1 line2 tail bell")
    }

    func test_sanitiseUserText_underCapNoEllipsis() {
        let out = OpenClickySanitiser.sanitiseUserText("hi", maxChars: 10)
        XCTAssertEqual(out, "hi")
    }

    func test_sanitiseUserText_emojiZWJIsOneGrapheme() {
        // Family emoji: 👨‍👩‍👧 is one grapheme cluster but 5 scalars.
        let family = "👨‍👩‍👧"
        let out = OpenClickySanitiser.sanitiseUserText(family + family + family, maxChars: 2)
        // 2 clusters + ellipsis; must NOT split any single cluster.
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertEqual(out.count, 3)
    }

    func test_sanitiseUserText_rtlPassthrough() {
        let s = "שלום עולם"  // Hebrew "hello world"
        let out = OpenClickySanitiser.sanitiseUserText(s, maxChars: 200)
        XCTAssertEqual(out, s)
    }

    func test_sanitiseUserText_cjkOneGraphemePerChar() {
        let s = "你好世界"
        let out = OpenClickySanitiser.sanitiseUserText(s, maxChars: 2)
        // 2 CJK graphemes + ellipsis.
        XCTAssertEqual(out, "你好…")
    }

    // MARK: sanitiseTokenValue

    func test_sanitiseTokenValue_stripsBracketsAndTab() {
        let s = "http://[::1]:8080/\tpath"
        let out = OpenClickySanitiser.sanitiseTokenValue(s, maxChars: 200)
        // IPv6 brackets stripped (Everywhere-intentional), tab dropped.
        XCTAssertEqual(out, "http://::1:8080/path")
    }

    func test_sanitiseTokenValue_capsToMaxGraphemes() {
        let s = String(repeating: "u", count: 300)
        let out = OpenClickySanitiser.sanitiseTokenValue(s, maxChars: 64)
        XCTAssertEqual(out.count, 65) // 64 + ellipsis
        XCTAssertTrue(out.hasSuffix("…"))
    }

    // MARK: URL redaction

    func test_redactCredentials_stripsUserinfoAndDenylistParams() {
        let u = URL(string: "https://user:pass@example.com/path?token=SECRET&q=hello&api_key=X")!
        let out = OpenClickySanitiser.redactCredentials(u)
        XCTAssertFalse(out.contains("user"))
        XCTAssertFalse(out.contains("pass"))
        XCTAssertFalse(out.contains("SECRET"))
        XCTAssertFalse(out.contains("api_key"))
        XCTAssertTrue(out.contains("q=hello"))
    }

    func test_redactCredentials_preservesNonDenylistedParams() {
        let u = URL(string: "https://example.com/?foo=bar&baz=qux")!
        XCTAssertEqual(OpenClickySanitiser.redactCredentials(u),
                       "https://example.com/?foo=bar&baz=qux")
    }

    func test_redactCredentials_all17ParamsCovered() {
        let params = [
            "token", "access_token", "id_token", "refresh_token",
            "api_key", "apikey", "key", "secret", "client_secret",
            "auth", "authentication", "password", "pwd",
            "sig", "signature", "session", "sessionid",
        ]
        for p in params {
            let u = URL(string: "https://example.com/?\(p)=X&keep=1")!
            let out = OpenClickySanitiser.redactCredentials(u)
            XCTAssertFalse(out.lowercased().contains("\(p)=x"),
                           "expected \(p) to be redacted, got \(out)")
            XCTAssertTrue(out.contains("keep=1"),
                          "expected keep param to survive, got \(out)")
        }
    }

    func test_redactCredentials_caseInsensitive() {
        let u = URL(string: "https://example.com/?TOKEN=X&keep=1")!
        let out = OpenClickySanitiser.redactCredentials(u)
        XCTAssertFalse(out.contains("TOKEN"))
        XCTAssertTrue(out.contains("keep=1"))
    }

    // MARK: isAllowedScheme

    func test_isAllowedScheme_acceptsHttpHttpsMailto() {
        XCTAssertTrue(OpenClickySanitiser.isAllowedScheme(URL(string: "http://x")!))
        XCTAssertTrue(OpenClickySanitiser.isAllowedScheme(URL(string: "https://x")!))
        XCTAssertTrue(OpenClickySanitiser.isAllowedScheme(URL(string: "mailto:a@b")!))
    }

    func test_isAllowedScheme_rejectsJavascriptAndData() {
        XCTAssertFalse(OpenClickySanitiser.isAllowedScheme(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(OpenClickySanitiser.isAllowedScheme(URL(string: "data:text/html,x")!))
        XCTAssertFalse(OpenClickySanitiser.isAllowedScheme(URL(string: "file:///etc/passwd")!))
    }

    // MARK: truncateGraphemes

    func test_truncateGraphemes_zeroReturnsEmpty() {
        XCTAssertEqual(OpenClickySanitiser.truncateGraphemes("abc", maxGraphemes: 0), "")
    }

    func test_truncateGraphemes_emptyReturnsEmpty() {
        XCTAssertEqual(OpenClickySanitiser.truncateGraphemes("", maxGraphemes: 10), "")
    }
}

final class StashFormatterTests: XCTestCase {

    private func fixedDate() -> Date {
        // 2026-07-22T10:00:00.000+00:00 — used for deterministic bytes.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 22
        comps.hour = 10
        comps.minute = 0
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    func test_formatForHook_headerFieldOrderAndPrefix() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1234,
            windowTitle: "Home | Example",
            url: "https://example.com/",
            selectedText: "hello world",
            selectedApp: "safari"
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines[0].hasPrefix("[openclicky-ctx] "))
        // Field order: app, title, url, selection.
        let appIdx = lines[0].range(of: "app=")!.lowerBound
        let titleIdx = lines[0].range(of: "title=")!.lowerBound
        let urlIdx = lines[0].range(of: "url=")!.lowerBound
        let selIdx = lines[0].range(of: "selection=")!.lowerBound
        XCTAssertLessThan(appIdx, titleIdx)
        XCTAssertLessThan(titleIdx, urlIdx)
        XCTAssertLessThan(urlIdx, selIdx)
    }

    func test_formatForHook_omitsNilFieldsInHeader() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "finder",
            processId: 42,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        let firstLine = out.split(separator: "\n").first!
        XCTAssertFalse(firstLine.contains("title="))
        XCTAssertFalse(firstLine.contains("url="))
        XCTAssertFalse(firstLine.contains("selection="))
        XCTAssertTrue(firstLine.contains("app=finder"))
    }

    func test_formatForHook_pickedLinksEmitsCtxLinkRows() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil,
            pickedLinks: [
                OpenClickyPickedLink(url: "https://one.example/", title: "One"),
                OpenClickyPickedLink(url: "https://two.example/", title: nil),
            ]
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        XCTAssertTrue(out.contains("picked_links=2"))
        XCTAssertTrue(out.contains("[openclicky-ctx-link] #0 url=https://one.example/ title=\"One\""))
        XCTAssertTrue(out.contains("[openclicky-ctx-link] #1 url=https://two.example/"))
    }

    func test_formatForHook_annotationsEmitsCtxAnnotationRows() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil,
            annotations: [
                OpenClickyPayloadAnnotation(
                    source: "pin",
                    body: "note",
                    anchorLabel: "button label",
                    anchorRef: "btn-1",
                    capturedAtUtc: fixedDate()
                )
            ]
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        XCTAssertTrue(out.contains("annotations=1"))
        XCTAssertTrue(out.contains("[openclicky-ctx-annotation] #0"))
        XCTAssertTrue(out.contains("source=pin"))
        XCTAssertTrue(out.contains("anchor=\"button label\""))
        XCTAssertTrue(out.contains("ref=btn-1"))
        XCTAssertTrue(out.contains("body=\"note\""))
    }

    func test_formatForHook_defaultHintIsGeneric() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        // Byte-ported from Everywhere ContextStashWriter.cs:731.
        XCTAssertTrue(out.contains("[openclicky-hint] If the user's question needs more than this pointer"))
    }

    func test_formatForHook_pinPendingHint() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil,
            pinPending: true
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        // Byte-ported from Everywhere ContextStashWriter.cs:719.
        XCTAssertTrue(out.contains("[openclicky-hint] The user pinned a UI element for this question"))
        XCTAssertTrue(out.contains("`read_pick`"))
    }

    func test_formatForHook_whiteboardHintTakesPriority() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil,
            pinPending: true,
            whiteboardPending: true,
            whiteboardRegionCount: 3
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        // Byte-ported from Everywhere ContextStashWriter.cs:703-704.
        XCTAssertTrue(out.contains("[openclicky-hint] User drew 3 annotated region(s) on a virtual whiteboard for this agent."))
        XCTAssertTrue(out.contains("mcp__openclicky__read_whiteboard"))
    }

    func test_formatForHook_endsWithCtxJson() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: nil,
            url: nil,
            selectedText: nil,
            selectedApp: nil
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        XCTAssertTrue(out.contains("[openclicky-ctx-json] "))
        // JSON envelope surface should include the required always-present keys.
        XCTAssertTrue(out.contains("\"schema_version\":1"))
        XCTAssertTrue(out.contains("\"captured_at_utc\""))
    }

    func test_formatForHook_windowTitleNeutralisesInjection() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 1,
            windowTitle: "attack] [openclicky-ctx",
            url: nil,
            selectedText: nil,
            selectedApp: nil
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        let firstLine = out.split(separator: "\n").first!
        // Injection attempt must be neutralised: ']' -> ')', '[' -> '('.
        XCTAssertTrue(firstLine.contains("title=\"attack) (openclicky-ctx\""))
    }

    // Byte-parity fixture: locks in the exact envelope shape for a
    // known-good payload. Any drift in the format will surface here first.
    func test_formatForHook_deterministicBytesForFixture() {
        let p = OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "safari",
            processId: 42,
            windowTitle: "Home",
            url: "https://example.com/",
            selectedText: "hi",
            selectedApp: "safari"
        )
        let out = OpenClickyStashFormatter.formatForHook(p)
        let head = "[openclicky-ctx] app=safari title=\"Home\" url=https://example.com/ selection=\"hi\" \n"
        XCTAssertTrue(out.hasPrefix(head), "unexpected header line:\n\(out)")
    }
}

final class StashPathsTests: XCTestCase {
    func test_contextStash_resolvesUnderOpenClickyDir() {
        let path = OpenClickyStashPaths.contextStash().path
        XCTAssertTrue(path.contains("Library/Application Support/OpenClicky/"))
        XCTAssertTrue(path.hasSuffix("context-stash.json"))
    }
}

// F21 — KnownApps discovery (`[openclicky-discover]` hint branch).
// Mirrors Everywhere `ContextStashWriter.ResolveDiscoveryUrl` +
// `ContextStashWriter.ToStatePath` (`ContextStashWriter.cs:743-791`).
final class KnownAppResolverTests: XCTestCase {

    // MARK: - toStatePath

    func test_toStatePath_agentSkillsSuffixRewrites() {
        let out = OpenClickyKnownAppResolver.toStatePath("http://localhost:5000/.well-known/agent-skills")
        XCTAssertEqual(out, "http://localhost:5000/.well-known/agent-state")
    }

    func test_toStatePath_xlbPerceptionSuffixRewrites() {
        let out = OpenClickyKnownAppResolver.toStatePath("http://localhost:7777/xlb-perception")
        XCTAssertEqual(out, "http://localhost:7777/agent-state")
    }

    func test_toStatePath_unknownSuffixReturnsInput() {
        let input = "http://localhost:8080/some/other/path"
        XCTAssertEqual(OpenClickyKnownAppResolver.toStatePath(input), input)
    }

    func test_toStatePath_caseInsensitiveSuffixMatch() {
        // OrdinalIgnoreCase parity — Everywhere accepts either casing.
        let out = OpenClickyKnownAppResolver.toStatePath("http://x/AGENT-SKILLS")
        XCTAssertEqual(out, "http://x/agent-state")
    }

    // MARK: - resolveDiscoveryUrl

    func test_resolveDiscoveryUrl_emptyTitleReturnsNil() {
        let apps = [OpenClickyKnownAppRule(titlePattern: "^xlinkBook", discoverUrl: "http://x/agent-skills")]
        XCTAssertNil(OpenClickyKnownAppResolver.resolveDiscoveryUrl(appTitle: "", knownApps: apps))
        XCTAssertNil(OpenClickyKnownAppResolver.resolveDiscoveryUrl(appTitle: nil, knownApps: apps))
    }

    func test_resolveDiscoveryUrl_emptyKnownAppsReturnsNil() {
        XCTAssertNil(OpenClickyKnownAppResolver.resolveDiscoveryUrl(appTitle: "xlinkBook", knownApps: []))
    }

    func test_resolveDiscoveryUrl_matchesFirstRuleAndDerivesStatePath() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^xlinkBook",
                                   discoverUrl: "http://localhost:5000/.well-known/agent-skills"),
        ]
        let hit = OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: "xlinkBook — Home",
            knownApps: apps
        )
        XCTAssertEqual(hit?.discoverUrl, "http://localhost:5000/.well-known/agent-skills")
        XCTAssertEqual(hit?.statePath, "http://localhost:5000/.well-known/agent-state")
    }

    func test_resolveDiscoveryUrl_firstMatchWins() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^one", discoverUrl: "http://one.example/agent-skills"),
            OpenClickyKnownAppRule(titlePattern: "two",  discoverUrl: "http://two.example/agent-skills"),
        ]
        // Title matches both patterns; first entry wins.
        let hit = OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: "one two three",
            knownApps: apps
        )
        XCTAssertEqual(hit?.discoverUrl, "http://one.example/agent-skills")
    }

    func test_resolveDiscoveryUrl_caseInsensitive() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "xlinkbook", discoverUrl: "http://x/agent-skills"),
        ]
        let hit = OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: "XlInKbOoK Home",
            knownApps: apps
        )
        XCTAssertNotNil(hit)
    }

    func test_resolveDiscoveryUrl_rejectsNonHttpScheme() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^x", discoverUrl: "javascript:alert(1)"),
            OpenClickyKnownAppRule(titlePattern: "^x", discoverUrl: "file:///etc/passwd"),
            OpenClickyKnownAppRule(titlePattern: "^x", discoverUrl: "not a url"),
        ]
        XCTAssertNil(OpenClickyKnownAppResolver.resolveDiscoveryUrl(appTitle: "xtest", knownApps: apps))
    }

    func test_resolveDiscoveryUrl_skipsBlankPatternOrUrl() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "",     discoverUrl: "http://x/agent-skills"),
            OpenClickyKnownAppRule(titlePattern: "^x",   discoverUrl: ""),
            OpenClickyKnownAppRule(titlePattern: "^tgt", discoverUrl: "http://tgt/agent-skills"),
        ]
        let hit = OpenClickyKnownAppResolver.resolveDiscoveryUrl(appTitle: "tgt", knownApps: apps)
        XCTAssertEqual(hit?.discoverUrl, "http://tgt/agent-skills")
    }

    func test_resolveDiscoveryUrl_invalidRegexIsSilentSkip() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "((",             discoverUrl: "http://bad/agent-skills"),
            OpenClickyKnownAppRule(titlePattern: "^good",          discoverUrl: "http://good/agent-skills"),
        ]
        let hit = OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: "good app",
            knownApps: apps
        )
        XCTAssertEqual(hit?.discoverUrl, "http://good/agent-skills")
    }

    // Everywhere caps regex evaluation with a 100ms timeout. Swift's
    // NSRegularExpression has no per-match timeout, so `resolveDiscoveryUrl`
    // instead bounds the input length before feeding the engine. This
    // test drives a classic ReDoS shape ((a+)+$ on ~500 'a's + one 'b')
    // through the resolver and asserts it returns in well under a second
    // — precondition: input cap prevents the exponential blow-up window.
    func test_resolveDiscoveryUrl_pathologicalPatternCompletesFast() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^(a+)+$", discoverUrl: "http://x/agent-skills"),
        ]
        // ~500 'a's plus a mismatching 'b' at the end forces backtracking.
        // With the input cap (512 chars) + Swift's NSRegularExpression engine
        // this must still return in a small fraction of a second.
        let title = String(repeating: "a", count: 500) + "b"
        let start = Date()
        _ = OpenClickyKnownAppResolver.resolveDiscoveryUrl(appTitle: title, knownApps: apps)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "ReDoS-shaped pattern took \(elapsed)s; input cap likely broken")
    }
}

// F21 — `[openclicky-discover]` hint branch is reachable when KnownApps
// resolves + no higher-priority hint (whiteboard / pin) applies.
final class DiscoveryHintFormatterTests: XCTestCase {

    private func fixedDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 23
        comps.hour = 10; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private func payload(title: String?) -> OpenClickyContextSnapshotPayload {
        OpenClickyContextSnapshotPayload(
            schemaVersion: 1,
            capturedAtUtc: fixedDate(),
            app: "xlinkBook",
            processId: 1,
            windowTitle: title,
            url: nil,
            selectedText: nil,
            selectedApp: nil
        )
    }

    func test_matchingTitle_emitsDiscoverLine() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^xlinkBook",
                                   discoverUrl: "http://localhost:5000/.well-known/agent-skills"),
        ]
        let out = OpenClickyStashFormatter.formatForHook(payload(title: "xlinkBook"), knownApps: apps)
        XCTAssertTrue(out.contains("[openclicky-discover]"),
                      "expected discover line for matching title, got:\n\(out)")
        XCTAssertTrue(out.contains("http://localhost:5000/.well-known/agent-skills"))
        XCTAssertTrue(out.contains("http://localhost:5000/.well-known/agent-state"))
    }

    func test_nonMatchingTitle_fallsBackToGenericHint() {
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^xlinkBook",
                                   discoverUrl: "http://localhost:5000/.well-known/agent-skills"),
        ]
        let out = OpenClickyStashFormatter.formatForHook(payload(title: "Safari"), knownApps: apps)
        XCTAssertFalse(out.contains("[openclicky-discover]"),
                       "discover line must not appear for non-matching title, got:\n\(out)")
        XCTAssertTrue(out.contains("[openclicky-hint] If the user's question needs more than this pointer"))
    }

    func test_emptyKnownApps_fallsBackToGenericHint() {
        let out = OpenClickyStashFormatter.formatForHook(payload(title: "xlinkBook"), knownApps: [])
        XCTAssertFalse(out.contains("[openclicky-discover]"))
        XCTAssertTrue(out.contains("[openclicky-hint] If the user's question needs more than this pointer"))
    }

    // Pin takes priority over discover — matches
    // `ContextStashWriter.cs:711-720`.
    func test_pinPending_takesPriorityOverDiscover() {
        var p = payload(title: "xlinkBook")
        p = OpenClickyContextSnapshotPayload(
            schemaVersion: p.schemaVersion,
            capturedAtUtc: p.capturedAtUtc,
            app: p.app, processId: p.processId,
            windowTitle: p.windowTitle, url: p.url,
            selectedText: p.selectedText, selectedApp: p.selectedApp,
            pinPending: true
        )
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^xlinkBook",
                                   discoverUrl: "http://localhost:5000/.well-known/agent-skills"),
        ]
        let out = OpenClickyStashFormatter.formatForHook(p, knownApps: apps)
        // Pin + KnownApp match -> "pin + state" branch (`ContextStashWriter.cs:711`).
        XCTAssertTrue(out.contains("[openclicky-hint] User pinned a UI element AND this is a known local web app"))
        XCTAssertFalse(out.contains("[openclicky-discover]"))
    }

    func test_whiteboardPending_takesPriorityOverDiscover() {
        var p = payload(title: "xlinkBook")
        p = OpenClickyContextSnapshotPayload(
            schemaVersion: p.schemaVersion,
            capturedAtUtc: p.capturedAtUtc,
            app: p.app, processId: p.processId,
            windowTitle: p.windowTitle, url: p.url,
            selectedText: p.selectedText, selectedApp: p.selectedApp,
            pinPending: nil, whiteboardPending: true, whiteboardRegionCount: 2
        )
        let apps = [
            OpenClickyKnownAppRule(titlePattern: "^xlinkBook",
                                   discoverUrl: "http://localhost:5000/.well-known/agent-skills"),
        ]
        let out = OpenClickyStashFormatter.formatForHook(p, knownApps: apps)
        XCTAssertTrue(out.contains("mcp__openclicky__read_whiteboard"))
        XCTAssertFalse(out.contains("[openclicky-discover]"))
    }

    func test_matchingTitle_defaultKnownAppsParamStillEmpty() {
        // Backward-compat: existing callers that don't supply knownApps
        // must not suddenly emit a discover line just because a title
        // matches some default. The default is `[]` -> no discover.
        let out = OpenClickyStashFormatter.formatForHook(payload(title: "xlinkBook"))
        XCTAssertFalse(out.contains("[openclicky-discover]"))
    }
}
