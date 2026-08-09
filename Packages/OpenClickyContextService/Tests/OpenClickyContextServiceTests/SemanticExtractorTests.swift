// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/SemanticExtractor.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for SemanticExtractor. Everywhere's C# side unit-tests
// `BuildFocusedPath` against synthetic IndexedNode lists; openclicky
// operates against live AX (there is no fake AX tree in this package),
// so the tests split into:
//
//   * Pure guard tests — safe on headless CI (pid <= 0, unknown pid,
//     test host pid). Assert nil / empty defaults.
//   * A gated Finder integration test — runs when a WindowServer
//     session is available and `OPENCLICKY_SKIP_UI_TESTS` is unset.
//   * JSON round-trip tests to pin the wire shape of `SemanticNode`
//     and `SemanticFocusPath`.
//
// The path-length bound is asserted regardless of live vs synthetic:
// the internal cap (`kMaxPathDepth = 64`, matching Everywhere's
// `UpstreamConstants.AccessibilityTreeMaxDepth`) makes the resulting
// array finite even if AX hands back a parent=self loop.

import XCTest
import AppKit
@testable import OpenClickyContextService

final class SemanticExtractorTests: XCTestCase {

    // MARK: - Guard behaviour (headless-safe)

    func test_focusedPath_returnsEmpty_forZeroPid() {
        let path = SemanticExtractor.focusedPath(pid: 0)
        XCTAssertEqual(path.pid, 0)
        XCTAssertTrue(path.nodes.isEmpty)
    }

    func test_focusedPath_returnsEmpty_forNegativePid() {
        let path = SemanticExtractor.focusedPath(pid: -1)
        XCTAssertTrue(path.nodes.isEmpty)

        let extreme = SemanticExtractor.focusedPath(pid: Int32.min)
        XCTAssertTrue(extreme.nodes.isEmpty)
    }

    func test_focusedPath_returnsEmpty_forBogusPid() {
        // Astronomically-unlikely pid. AXUIElementCreateApplication
        // hands back a ref anyway; the subsequent
        // AXFocusedUIElement read fails so the path stays empty.
        let path = SemanticExtractor.focusedPath(pid: Int32.max)
        XCTAssertTrue(path.nodes.isEmpty)
    }

    func test_focusedPath_returnsEmpty_forTestHost() {
        // Swift test host has no windows and no focused UI element.
        // `AXFocusedUIElement` misses -> empty path (no crash).
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = SemanticExtractor.focusedPath(pid: pid)
        XCTAssertEqual(path.pid, pid)
        XCTAssertTrue(path.nodes.isEmpty)
    }

    func test_focused_returnsNil_forZeroPid() {
        XCTAssertNil(SemanticExtractor.focused(pid: 0))
    }

    func test_focused_returnsNil_forBogusPid() {
        XCTAssertNil(SemanticExtractor.focused(pid: Int32.max))
    }

    func test_selected_returnsEmpty_forZeroPid() {
        XCTAssertTrue(SemanticExtractor.selected(pid: 0).isEmpty)
    }

    func test_selected_returnsEmpty_forBogusPid() {
        XCTAssertTrue(SemanticExtractor.selected(pid: Int32.max).isEmpty)
    }

    // MARK: - Path length bound
    //
    // Even under a hostile / cyclic AX tree the path must stay
    // finite. The internal cap (`kMaxPathDepth = 64`, 1:1 with
    // Everywhere's `UpstreamConstants.AccessibilityTreeMaxDepth`)
    // plus the CFHash-based visited set enforce this. Verify via
    // the guard path — empty is `<= 64` trivially — plus a live
    // check when available (below).

    func test_focusedPath_isBounded_forTestHost() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = SemanticExtractor.focusedPath(pid: pid)
        XCTAssertLessThanOrEqual(path.nodes.count, 64,
                                 "path must never exceed the internal depth cap")
    }

    // MARK: - Live capture (gated)

    private var shouldSkipUITests: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil
    }

    func test_focusedPath_forFrontmostApp_producesBoundedPath() throws {
        try XCTSkipIf(shouldSkipUITests, "UI test skipped by env flag")

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw XCTSkip("No frontmost app — no WindowServer session")
        }
        if frontmost.bundleIdentifier == "com.apple.loginwindow" {
            throw XCTSkip("Login window frontmost — no user session")
        }

        let path = SemanticExtractor.focusedPath(pid: frontmost.processIdentifier)

        // A missing AX consent OR a frontmost app with no focused
        // element is legitimate (many menu-bar utilities). Skip
        // rather than fail — the guard tests already prove the
        // no-op path.
        try XCTSkipIf(path.nodes.isEmpty,
                      "frontmost \(frontmost.bundleIdentifier ?? "?") has no focused element or no AX consent")

        XCTAssertEqual(path.pid, frontmost.processIdentifier)
        XCTAssertLessThanOrEqual(path.nodes.count, 32)
        XCTAssertGreaterThanOrEqual(path.nodes.count, 1)

        // Every node must carry a non-empty type. Everywhere's map
        // falls through to `"Unknown"` rather than nil / empty.
        for node in path.nodes {
            XCTAssertFalse(node.type.isEmpty)
        }

        // Focused/leaf helper must produce a node with type
        // consistent with the tail of the path.
        if let leaf = SemanticExtractor.focused(pid: frontmost.processIdentifier) {
            XCTAssertEqual(leaf.type, path.nodes.last?.type)
        }
    }

    // MARK: - Wire shape

    func test_semanticNode_roundTripsJSON_withAllFields() throws {
        let sample = SemanticNode(
            type: "Button",
            text: "Save",
            states: ["Focused", "Selected"],
            availableActions: ["click", "perform_secondary_action"]
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SemanticNode.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_semanticNode_omitsNilFieldsInWireForm() throws {
        // Regression pin for F02 fix E.b: `SemanticNode` must OMIT nil
        // optionals (matching Everywhere's `SemanticItem`
        // `[JsonIgnore(Condition = WhenWritingNull)]`), not emit them
        // as explicit `null`. Downstream consumers use presence-of-key
        // as an existence check.
        let sample = SemanticNode(type: "Panel")
        let data = try JSONEncoder().encode(sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("null"),
                       "nil optionals must be omitted, got: \(json)")
        XCTAssertFalse(json.contains("\"text\""),
                       "text key must be omitted when nil: \(json)")
        XCTAssertFalse(json.contains("\"states\""),
                       "states key must be omitted when nil: \(json)")
        XCTAssertFalse(json.contains("\"available_actions\""),
                       "available_actions key must be omitted when nil: \(json)")
        XCTAssertTrue(json.contains("\"type\":\"Panel\""),
                      "type must always be present: \(json)")
        let decoded = try JSONDecoder().decode(SemanticNode.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertNil(decoded.text)
        XCTAssertNil(decoded.states)
        XCTAssertNil(decoded.availableActions)
    }

    func test_semanticNode_partialFieldsOmitOnlyNil() throws {
        // Only `text` present — states/available_actions must still
        // drop off the wire, not appear as `null`.
        let sample = SemanticNode(type: "Label", text: "Hello")
        let data = try JSONEncoder().encode(sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("null"), "no explicit nulls: \(json)")
        XCTAssertTrue(json.contains("\"text\":\"Hello\""), "text kept: \(json)")
        XCTAssertFalse(json.contains("\"states\""), "states dropped: \(json)")
        XCTAssertFalse(json.contains("\"available_actions\""), "actions dropped: \(json)")
    }

    func test_semanticNode_usesSnakeCasedActionsKey() throws {
        // `SemanticItem` on the C# side declares
        // [JsonPropertyName("available_actions")]. Downstream tools
        // depend on the snake_case key.
        let sample = SemanticNode(
            type: "TextEdit",
            availableActions: ["set_value", "click"]
        )
        let data = try JSONEncoder().encode(sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"available_actions\""),
                      "expected snake_case wire key, got: \(json)")
        XCTAssertFalse(json.contains("\"availableActions\""),
                       "camelCase key must not leak to the wire: \(json)")
    }

    func test_semanticFocusPath_roundTripsJSON() throws {
        let sample = SemanticFocusPath(
            pid: 4242,
            nodes: [
                SemanticNode(type: "TopLevel", text: "Downloads",
                             states: ["Main"], availableActions: nil),
                SemanticNode(type: "TreeView", text: nil,
                             states: nil, availableActions: ["scroll", "expand_element"]),
                SemanticNode(type: "TreeViewItem", text: "README.md",
                             states: ["Focused"], availableActions: ["click", "perform_secondary_action"])
            ]
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SemanticFocusPath.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.nodes.count, 3)
        XCTAssertEqual(decoded.nodes.first?.type, "TopLevel")
        XCTAssertEqual(decoded.nodes.last?.text, "README.md")
    }

    func test_semanticFocusPath_emptyNodesRoundTrip() throws {
        let sample = SemanticFocusPath(pid: 1, nodes: [])
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SemanticFocusPath.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertTrue(decoded.nodes.isEmpty)
    }
}
