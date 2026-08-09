// F32 chat_bus unit tests. Ported semantics from Everywhere @ 30e03e9dcfdd4247fd679828ed86e9042f32d809:
//   src/Everywhere.Mcp/OpenDia/OpenDiaChatBus.cs
//   src/Everywhere.Mcp/Tools/ChatBusTools.cs

import XCTest
@testable import OpenClickyContextService

final class OpenClickyChatBusTests: XCTestCase {

    // MARK: - TTL

    func test_send_expires_after_ttl() {
        var clockNow: Double = 1_000
        let bus = OpenClickyChatBus(ttl: 60, maxQueue: 200, clock: { clockNow })
        _ = try? bus.send(kind: "toast", body: "hi")
        XCTAssertEqual(bus.historyCount(), 1)
        clockNow = 1_000 + 61
        XCTAssertEqual(bus.historyCount(), 0, "message should be pruned once age > ttl")
    }

    func test_send_within_ttl_survives() {
        var clockNow: Double = 1_000
        let bus = OpenClickyChatBus(ttl: 60, maxQueue: 200, clock: { clockNow })
        _ = try? bus.send(kind: "toast", body: "hi")
        clockNow = 1_000 + 59
        XCTAssertEqual(bus.historyCount(), 1)
    }

    // MARK: - Queue caps

    func test_queue_cap_drops_oldest_fifo() throws {
        var clockNow: Double = 1_000
        let bus = OpenClickyChatBus(ttl: 3600, maxQueue: 3, clock: { clockNow })
        for i in 0..<5 {
            clockNow += 1
            _ = try bus.send(kind: "k", body: "msg-\(i)")
        }
        // Only the last 3 survive.
        XCTAssertEqual(bus.historyCount(), 3)
        let msgs = bus.subscribe(sinceTs: 0)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs.map { $0.body }, ["msg-2", "msg-3", "msg-4"])
    }

    // MARK: - Filters + cursor advance

    func test_subscribe_filters_by_kind() throws {
        let bus = OpenClickyChatBus()
        _ = try bus.send(kind: "toast", body: "a")
        _ = try bus.send(kind: "hint", body: "b")
        _ = try bus.send(kind: "toast", body: "c")
        let toasts = bus.subscribe(kindFilter: "toast", sinceTs: 0)
        XCTAssertEqual(toasts.map { $0.body }, ["a", "c"])
    }

    func test_subscribe_filters_by_from() throws {
        let bus = OpenClickyChatBus()
        _ = try bus.send(kind: "k", body: "a", from: "alice")
        _ = try bus.send(kind: "k", body: "b", from: "bob")
        let alice = bus.subscribe(from: "alice", sinceTs: 0)
        XCTAssertEqual(alice.map { $0.body }, ["a"])
    }

    func test_subscribe_persistent_cursor_advances() throws {
        var clockNow: Double = 1_000
        let bus = OpenClickyChatBus(ttl: 3600, maxQueue: 200, clock: { clockNow })
        clockNow += 1; _ = try bus.send(kind: "k", body: "a")
        clockNow += 1; _ = try bus.send(kind: "k", body: "b")

        let first = bus.subscribe(subscriptionID: "sub-1", sinceTs: 0)
        XCTAssertEqual(first.map { $0.body }, ["a", "b"])

        // Repeat call — cursor advanced, nothing new.
        let second = bus.subscribe(subscriptionID: "sub-1")
        XCTAssertEqual(second.count, 0)

        clockNow += 1; _ = try bus.send(kind: "k", body: "c")
        let third = bus.subscribe(subscriptionID: "sub-1")
        XCTAssertEqual(third.map { $0.body }, ["c"])
    }

    func test_send_returns_delivered_count_only_for_matching_subscribers() throws {
        let bus = OpenClickyChatBus()
        // Register 2 subscribers, one for kind=match, one open.
        _ = bus.subscribe(subscriptionID: "s1", kindFilter: "match", sinceTs: 0)
        _ = bus.subscribe(subscriptionID: "s2", sinceTs: 0)
        let result = try bus.send(kind: "match", body: "x")
        XCTAssertEqual(result.deliveredTo, 2)

        let miss = try bus.send(kind: "other", body: "y")
        XCTAssertEqual(miss.deliveredTo, 1)
    }

    // MARK: - Tool dispatch (bridge shape)

    /// Every tool return is now wrapped in the MCP content text
    /// envelope `{type:"text", text:"<json>"}` so `executeSensorTool`
    /// can splice it straight into `result.content[]`. Tests decode
    /// the inner JSON to inspect the payload shape.
    private func decodeEnvelope(_ envelope: [String: Any]) -> [String: Any] {
        guard envelope["type"] as? String == "text",
              let text = envelope["text"] as? String,
              let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("expected MCP text envelope; got \(envelope)")
            return [:]
        }
        return obj
    }

    func test_chat_send_tool_returns_ok_envelope() {
        let bus = OpenClickyChatBus()
        let (envelope, isError) = OpenClickyChatBusTools.handleSend(
            arguments: ["kind": "toast", "body": "hi", "from": "test"],
            bus: bus
        )
        XCTAssertFalse(isError)
        let payload = decodeEnvelope(envelope)
        XCTAssertEqual(payload["schema_version"] as? String, "1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertNotNil(payload["message_id"])
        XCTAssertEqual(payload["delivered_to"] as? Int, 0)
    }

    func test_chat_send_tool_rejects_missing_kind() {
        let (envelope, isError) = OpenClickyChatBusTools.handleSend(
            arguments: ["body": "hi"],
            bus: OpenClickyChatBus()
        )
        XCTAssertTrue(isError)
        let payload = decodeEnvelope(envelope)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, "INVALID_ROLE")
        XCTAssertNotNil(payload["message"])
    }

    func test_chat_subscribe_tool_returns_messages_array() throws {
        let bus = OpenClickyChatBus()
        _ = try bus.send(kind: "toast", body: "hello")
        let (envelope, isError) = OpenClickyChatBusTools.handleSubscribe(
            arguments: ["kind_filter": "toast", "since": 0],
            bus: bus
        )
        XCTAssertFalse(isError)
        let payload = decodeEnvelope(envelope)
        XCTAssertEqual(payload["schema_version"] as? String, "1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        guard let items = payload["messages"] as? [[String: Any]] else {
            XCTFail("messages should be array of dicts")
            return
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["kind"] as? String, "toast")
        XCTAssertEqual(items[0]["body"] as? String, "hello")
        XCTAssertNotNil(items[0]["message_id"])
    }

    func test_chat_send_return_shape_matches_mcp_text_envelope() {
        let bus = OpenClickyChatBus()
        let (envelope, _) = OpenClickyChatBusTools.handleSend(
            arguments: ["kind": "toast", "body": "hi"],
            bus: bus
        )
        XCTAssertEqual(envelope["type"] as? String, "text")
        XCTAssertNotNil(envelope["text"] as? String)
    }

    func test_descriptors_contain_both_tools() {
        let names = OpenClickyChatBusTools.descriptorsRaw.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("chat_send"))
        XCTAssertTrue(names.contains("chat_subscribe"))
    }
}
