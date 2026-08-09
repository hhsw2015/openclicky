//
//  OpenClickyF32ThroughF36BridgeFixTests.swift
//  cursor-buddyTests
//
//  Regression tests for the F32-F36 review-fix bundle
//  (docs/ROADMAP/.impl-notes/f32-f36-fix-report-2026-07-23.md):
//
//  * F32/F34: MCP content envelope wrapper + schema_version + message
//    key on every return path.
//  * F35: ExtractionRulesStore.upsert must not deadlock on the
//    internal NSLock (previously re-entrant via loadUnsafe).
//  * F36: capture_draft / capture_publish must be observably distinct
//    lifecycle states; capture_list filters by status.
//

import Foundation
import XCTest
@testable import OpenClicky

final class OpenClickyF32ThroughF36BridgeFixTests: XCTestCase {

    // MARK: - Helpers

    /// Every bridge tool now returns `{type:"text", text:"<json>"}`.
    /// Decode that JSON string back into a dict so tests can inspect
    /// the payload shape.
    private func decodeEnvelope(_ envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard envelope["type"] as? String == "text",
              let text = envelope["text"] as? String,
              let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Expected MCP content text envelope; got \(envelope)", file: file, line: line)
            return [:]
        }
        return obj
    }

    /// Decode an envelope whose `text` field carries a JSON array
    /// (adapter_list_local returns a bare array per Everywhere).
    private func decodeEnvelopeArray(_ envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> [Any] {
        guard envelope["type"] as? String == "text",
              let text = envelope["text"] as? String,
              let data = text.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            XCTFail("Expected MCP content text envelope with array body; got \(envelope)", file: file, line: line)
            return []
        }
        return arr
    }

    // MARK: - F35 Issue 2 — ExtractionRulesStore no re-entrant deadlock

    /// Regression: previously `upsert -> loadUnsafe` acquired the same
    /// NSLock twice on one thread and hung forever. The current
    /// implementation acquires the lock ONCE via loadLocked helpers.
    /// This test finishes in milliseconds; a regression would time out.
    func test_extraction_rules_upsert_does_not_deadlock() throws {
        let store = ExtractionRulesStore.shared
        let rule = ExtractionRulesStore.Rule(
            urlPattern: "^https://example.test/regression-fix$",
            kind: "css",
            selector: ".test-only-marker-\(UUID().uuidString.prefix(6))",
            priority: 0
        )

        let expectation = XCTestExpectation(description: "upsert returns without deadlock")
        DispatchQueue.global().async {
            do {
                try store.upsert(rule)
                expectation.fulfill()
            } catch {
                XCTFail("upsert threw: \(error)")
            }
        }
        wait(for: [expectation], timeout: 2.0)

        // Match should also complete without deadlock and find the rule.
        XCTAssertNotNil(store.match("https://example.test/regression-fix"))
    }

    // MARK: - F36 Issue 4 — capture_draft vs capture_publish observable split

    /// After the split, capture_draft persists status="draft" and
    /// capture_list (default) does NOT surface it. capture_publish
    /// promotes the same entry to status="published"; capture_list
    /// (default) then surfaces it.
    func test_capture_draft_publish_lifecycle_is_observable() async throws {
        // Isolate under a unique name so parallel runs don't collide.
        let name = "regression-\(UUID().uuidString.prefix(8))-fix"

        // Force self-expand ON for this run (gate defaults to on when
        // env-var is unset — we don't override it).
        let selfExpandEnabled = OpenClickyMetaSelfExpandGate.isEnabled
        guard selfExpandEnabled else {
            throw XCTSkip("OPENCLICKY_MCP_SELFEXPAND=0 disables the capture surface; skipping.")
        }

        // Draft
        let (draftEnv, draftIsError) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_draft",
            arguments: ["name": name]
        )
        XCTAssertFalse(draftIsError)
        let draftPayload = decodeEnvelope(draftEnv)
        XCTAssertEqual(draftPayload["ok"] as? Bool, true)
        XCTAssertEqual(draftPayload["status"] as? String, "draft")

        // capture_list default: does NOT surface the draft.
        let (listNoDraftsEnv, _) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_list",
            arguments: [:]
        )
        let listNoDraftsPayload = decodeEnvelope(listNoDraftsEnv)
        let listNoDraftsRows = (listNoDraftsPayload["captures"] as? [[String: Any]]) ?? []
        XCTAssertFalse(
            listNoDraftsRows.contains(where: { ($0["name"] as? String) == name }),
            "capture_list default should hide draft entries"
        )

        // capture_list include_drafts=true: draft is visible.
        let (listWithDraftsEnv, _) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_list",
            arguments: ["include_drafts": true]
        )
        let listWithDraftsPayload = decodeEnvelope(listWithDraftsEnv)
        let listWithDraftsRows = (listWithDraftsPayload["captures"] as? [[String: Any]]) ?? []
        let draftRow = listWithDraftsRows.first { ($0["name"] as? String) == name }
        XCTAssertEqual(draftRow?["status"] as? String, "draft")

        // Publish
        let (publishEnv, publishIsError) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_publish",
            arguments: ["name": name]
        )
        XCTAssertFalse(publishIsError)
        let publishPayload = decodeEnvelope(publishEnv)
        XCTAssertEqual(publishPayload["status"] as? String, "published")

        // capture_list default: NOW surfaces the entry as published.
        let (listAfterPublishEnv, _) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_list",
            arguments: [:]
        )
        let listAfterPublishPayload = decodeEnvelope(listAfterPublishEnv)
        let listAfterPublishRows = (listAfterPublishPayload["captures"] as? [[String: Any]]) ?? []
        let publishedRow = listAfterPublishRows.first { ($0["name"] as? String) == name }
        XCTAssertEqual(publishedRow?["status"] as? String, "published")

        // Cleanup
        _ = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_delete",
            arguments: ["name": name]
        )
    }

    /// capture_publish on a non-existent name returns TEMPLATE_NOT_FOUND
    /// (guards against silent no-op the previous alias-to-draft impl
    /// exhibited).
    func test_capture_publish_without_draft_returns_template_not_found() async throws {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            throw XCTSkip("OPENCLICKY_MCP_SELFEXPAND=0 disables the capture surface; skipping.")
        }
        let name = "regression-nope-\(UUID().uuidString.prefix(6))"
        let (env, isError) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_publish",
            arguments: ["name": name]
        )
        XCTAssertTrue(isError)
        let payload = decodeEnvelope(env)
        XCTAssertEqual(payload["code"] as? String, "TEMPLATE_NOT_FOUND")
        XCTAssertNotNil(payload["message"] as? String)
    }

    // MARK: - F33 Issue 1 — adapter_list_local returns bare array

    func test_adapter_list_local_returns_bare_array() async throws {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            throw XCTSkip("OPENCLICKY_MCP_SELFEXPAND=0 disables the adapter surface; skipping.")
        }
        let (env, isError) = await OpenClickyAdapterAuthoringBridgeTools.execute(
            name: "adapter_list_local",
            arguments: [:]
        )
        XCTAssertFalse(isError)
        let arr = decodeEnvelopeArray(env)
        // No adapters registered locally yet — Everywhere returns an empty array.
        XCTAssertEqual(arr.count, 0)
    }

    // MARK: - F32/F34 Issue 1 — All returns wrapped in MCP text envelope

    func test_web_search_missing_query_returns_wrapped_error() async {
        let (env, isError) = await OpenClickyWebBridgeTools.execute(
            name: "web_search",
            arguments: [:]
        )
        XCTAssertTrue(isError)
        XCTAssertEqual(env["type"] as? String, "text")
        let payload = decodeEnvelope(env)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, "invalid_input")
        XCTAssertEqual(payload["schema_version"] as? String, "1")
        // Everywhere-pin: error text is under `message`, not `error`.
        XCTAssertNotNil(payload["message"] as? String)
        XCTAssertNil(payload["error"] as? String)
    }

    func test_web_fetch_url_missing_url_returns_wrapped_error() async {
        let (env, isError) = await OpenClickyWebBridgeTools.execute(
            name: "web_fetch_url",
            arguments: [:]
        )
        XCTAssertTrue(isError)
        let payload = decodeEnvelope(env)
        XCTAssertEqual(payload["schema_version"] as? String, "1")
        XCTAssertEqual(payload["code"] as? String, "invalid_input")
        XCTAssertNotNil(payload["message"] as? String)
    }

    // MARK: - Error-key consistency: F33/F35/F36 use `message`

    func test_adapter_verify_argument_error_uses_message_key() async throws {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            throw XCTSkip("OPENCLICKY_MCP_SELFEXPAND=0 disables the adapter surface; skipping.")
        }
        let (env, isError) = await OpenClickyAdapterAuthoringBridgeTools.execute(
            name: "adapter_verify",
            arguments: [:]
        )
        XCTAssertTrue(isError)
        let payload = decodeEnvelope(env)
        XCTAssertEqual(payload["code"] as? String, "ARGUMENT_ERROR")
        XCTAssertNotNil(payload["message"] as? String)
        XCTAssertNil(payload["error"] as? String)
    }

    func test_page_save_extraction_rule_argument_error_uses_message_key() async throws {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            throw XCTSkip("OPENCLICKY_MCP_SELFEXPAND=0 disables the page surface; skipping.")
        }
        let (env, isError) = await OpenClickyPageBridgeTools.execute(
            name: "page_save_extraction_rule",
            arguments: [:]
        )
        XCTAssertTrue(isError)
        let payload = decodeEnvelope(env)
        XCTAssertEqual(payload["code"] as? String, "ARGUMENT_ERROR")
        XCTAssertNotNil(payload["message"] as? String)
        XCTAssertNil(payload["error"] as? String)
    }

    func test_capture_stop_missing_session_uses_message_key() async throws {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            throw XCTSkip("OPENCLICKY_MCP_SELFEXPAND=0 disables the capture surface; skipping.")
        }
        let (env, isError) = await OpenClickyCaptureAuthoringBridgeTools.execute(
            name: "capture_stop",
            arguments: [:]
        )
        XCTAssertTrue(isError)
        let payload = decodeEnvelope(env)
        XCTAssertEqual(payload["code"] as? String, "ARGUMENT_ERROR")
        XCTAssertNotNil(payload["message"] as? String)
        XCTAssertNil(payload["error"] as? String)
    }

    // MARK: - F33 Issue 2 — adapter_verify accepts fixture_override

    func test_adapter_verify_descriptor_declares_fixture_override() {
        let descs = OpenClickyAdapterAuthoringBridgeTools.descriptorsRaw
        guard let verify = descs.first(where: { ($0["name"] as? String) == "adapter_verify" }),
              let schema = verify["inputSchema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any] else {
            XCTFail("adapter_verify descriptor is missing or malformed")
            return
        }
        XCTAssertNotNil(props["fixture_override"])
    }
}
