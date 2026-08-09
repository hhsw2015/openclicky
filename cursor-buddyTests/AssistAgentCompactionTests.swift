//
//  AssistAgentCompactionTests.swift
//  cursor-buddyTests
//
//  Parity coverage for the text-compaction stack. All expected
//  behaviors mirror what heyclicky_agent/agent.py enforces so the
//  Swift port stays interchangeable with the Python reference.
//

import Foundation
import Testing
@testable import OpenClicky

struct AssistAgentCompactionTests {

    @Test func jsonCompactionShrinksLongStringAndArray() {
        let obj = [
            "arr": Array(1...20),
            "long": String(repeating: "x", count: 400),
            "short": "keep"
        ] as [String: Any]
        let raw = try! String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        let compact = assistCompactionCompactJSON(raw, budget: 500)
        #expect(compact != nil)
        #expect(compact!.count < raw.count)
        #expect(compact!.contains("keep"))
        #expect(compact!.contains("more items") || compact!.contains("truncated"))
    }

    @Test func diffCompactionDropsContext() {
        let diff = """
        @@ -1,4 +1,4 @@
         unchanged1
        -old
        +new
         unchanged2
        """
        let out = assistCompactionCompactDiff(diff)
        #expect(out != nil)
        #expect(out!.contains("-old"))
        #expect(out!.contains("+new"))
        #expect(!out!.contains("unchanged1"))   // context stripped
    }

    @Test func stdoutCompactionStripsPytestBanners() {
        let out = """
        platform darwin
        cachedir: .pytest_cache
        rootdir: /tmp
        plugins: cov-4.0
        ====================== 3 passed in 0.5s =======================
        """
        let compacted = assistCompactionCompactStdout(cmd: "pytest -q", stdout: out)
        #expect(!compacted.contains("cachedir:"))
        #expect(!compacted.contains("rootdir:"))
        #expect(!compacted.contains("plugins:"))
    }

    @Test func stdoutCompactionNormalizesTimestamps() {
        let out = "2025-11-01T12:34:56.789Z run finished\n0xdeadbeef object at that address\nuuid=550e8400-e29b-41d4-a716-446655440000"
        let compacted = assistCompactionCompactStdout(cmd: "", stdout: out, budget: 5000)
        #expect(compacted.contains("<TS>"))
        #expect(compacted.contains("<ADDR>"))
        #expect(compacted.contains("<UUID>"))
    }

    @Test func factsheetPullsPathsAndURLs() {
        let text = """
        See /Users/w/foo.py at line 42, also https://example.com/x
        and hash 0123456789abcdef, plus main.swift.
        """
        let sheet = AssistAgentFactsheet.extract(from: text)
        #expect(sheet.contains("/Users/w/foo.py"))
        #expect(sheet.contains("https://example.com/x"))
        #expect(sheet.contains("main.swift"))
    }

    @Test @MainActor func staleReadDedupKeepsNewest() {
        let session = AssistAgentSession(userTask: "t")
        session.appendStep(.init(kind: "文件内容", tool: "read_file",
                                args: ["path": "a.py"], why: "", result: "1",
                                raw: "old body", ok: true))
        session.appendStep(.init(kind: "文件内容", tool: "read_file",
                                args: ["path": "b.py"], why: "", result: "2",
                                raw: "body b", ok: true))
        session.appendStep(.init(kind: "文件内容", tool: "read_file",
                                args: ["path": "a.py"], why: "", result: "3",
                                raw: "new body", ok: true))
        let stale = assistCompactionStaleReadIndices(session.steps)
        #expect(stale.contains(0))   // first read of a.py is stale
        #expect(!stale.contains(1))  // only read of b.py is live
        #expect(!stale.contains(2))  // newest read of a.py stays
    }

    @Test @MainActor func microcompactClearsOldRawKeepsRecent() {
        let session = AssistAgentSession(userTask: "t")
        for i in 0..<10 {
            session.appendStep(.init(
                kind: "文件内容", tool: "read_file",
                args: ["path": "\(i).py"], why: "",
                result: "sum \(i)", raw: "very long body \(i)",
                ok: true))
        }
        let cleared = assistCompactionMicrocompactSession(session)
        #expect(cleared > 0)
        // First step's raw is cleared (marker); last 6 unchanged.
        #expect(session.steps[0].raw == AssistAgentCompactionConstants.microcompactClearedMarker)
        #expect(session.steps[9].raw == "very long body 9")
    }

    @Test @MainActor func microcompactPreservesEditKinds() {
        let session = AssistAgentSession(userTask: "t")
        for i in 0..<10 {
            let kind = i == 0 ? "写入完成" : "文件内容"
            let tool = i == 0 ? "write_file" : "read_file"
            session.appendStep(.init(
                kind: kind, tool: tool,
                args: ["path": "\(i).py"], why: "",
                result: "sum", raw: "raw \(i)", ok: true))
        }
        _ = assistCompactionMicrocompactSession(session)
        // Edit step at index 0 must not be cleared.
        #expect(session.steps[0].raw == "raw 0")
    }

    @Test @MainActor func digestTrimActivatesAtBudget() {
        let session = AssistAgentSession(userTask: "t")
        session.digest = String(repeating: "x", count: 25_000)
        let did = assistCompactionTrimDigestIfBloated(session)
        #expect(did)
        #expect(session.digest.count < 25_000)
        #expect(session.digest.contains("older digest trimmed"))
    }
}
