#!/usr/bin/env bash
# scripts/run-assist-agent-tests.sh
#
# Standalone unit-test runner for the AssistAgent parity work.
# Compiles the deterministic AssistAgent modules + a plain-XCTest-style
# runner using swiftc — no Xcode project, no other test targets.
# Bypasses the unrelated OpenClickyF32ThroughF36BridgeFixTests.swift
# breakage that blocks the main xctest target from building.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/openclicky-assist-agent-tests-$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

SRCS=(
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentJSON.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentEvent.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentSession.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentCompaction.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentFactsheet.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentPlanner.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentDetectors.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentPrompt.swift"
    "$ROOT/cursor-buddy/AssistAgent/AssistAgentLoop.swift"
)

cat > "$OUT/harness.swift" <<'SWIFT'
import Foundation

// Minimal stub of AppBundleConfiguration so AssistAgentPrompt's toggle
// check can compile inside the standalone harness. In-app the real
// symbol lives in AppBundleConfiguration+HeyClicky.swift.
enum AppBundleConfiguration {
    static func assistAgentEnabled() -> Bool { true }
}

@MainActor
func runAll() async -> Int {
    var passed = 0
    var failed = 0
    func check(_ name: String, _ cond: Bool, _ note: String = "") {
        if cond {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)  \(note)")
        }
    }

    print("── AssistAgentJSON parity ──")
    do {
        let obj = AssistAgentJSON.extract(from: #"{"步骤":"完成","答案":"ok"}"#)
        check("strict json parses", obj?["步骤"] as? String == "完成")
    }
    do {
        let raw = #"{"步骤":"需要","参数":{"路径":"foo.py"}}"#
            .replacingOccurrences(of: ":", with: "：")
            .replacingOccurrences(of: ",", with: "，")
        let obj = AssistAgentJSON.extract(from: raw)
        check("fullwidth colon+comma repaired", obj?["步骤"] as? String == "需要")
        check("nested arg unwraps",
              (obj?["参数"] as? [String: Any])?["路径"] as? String == "foo.py")
    }
    do {
        // Only double smart-quotes → valid JSON after repair.
        // Single smart-quotes remain single quotes (JSON never accepts
        // single-quoted strings) so we only assert the double-quote
        // case matches Python behaviour.
        let raw = "{\u{201C}x\u{201D}:\u{201C}y\u{201D}}"
        let obj = AssistAgentJSON.extract(from: raw)
        check("smart quotes repaired", obj?["x"] as? String == "y")
    }
    do {
        let raw = #"{"a":1,"b":2,}"#
        let obj = AssistAgentJSON.extract(from: raw)
        check("trailing comma stripped", obj?["a"] as? Int == 1)
    }
    do {
        let raw = "{\"content\":\"line1\nline2\"}"
        let obj = AssistAgentJSON.extract(from: raw)
        check("literal newline escaped",
              (obj?["content"] as? String)?.contains("line1\nline2") == true)
    }
    do {
        let raw = "```json\n{\"a\":1}\n```"
        let obj = AssistAgentJSON.extract(from: raw)
        check("code fence stripped", obj?["a"] as? Int == 1)
    }
    check("non-json returns nil",
          AssistAgentJSON.extract(from: "just prose") == nil)

    print("── AssistAgentFactsheet parity ──")
    let sheet = AssistAgentFactsheet.extract(from:
        "See /Users/w/foo.py and https://example.com plus main.swift.")
    check("path picked up", sheet.contains("/Users/w/foo.py"))
    check("url picked up", sheet.contains("https://example.com"))
    check("swift file picked up", sheet.contains("main.swift"))

    print("── AssistAgentCompaction parity ──")
    do {
        let out = assistCompactionCompactDiff(
            "@@ -1,3 +1,3 @@\n a\n-b\n+c\n d")
        check("diff drops context lines",
              out?.contains("a") == false && out?.contains("-b") == true)
    }
    do {
        let out = assistCompactionCompactStdout(
            cmd: "pytest -q",
            stdout: "platform darwin\ncachedir: .p\nrootdir: /tmp\nplugins: cov")
        check("pytest banner stripped", !out.contains("cachedir:"))
    }
    do {
        let out = assistCompactionCompactStdout(
            cmd: "",
            stdout: "2025-01-01T12:00:00Z run\n0xdeadbeef\n" +
                    "550e8400-e29b-41d4-a716-446655440000",
            budget: 5000)
        check("timestamps normalised", out.contains("<TS>"))
        check("hex addr normalised", out.contains("<ADDR>"))
        check("uuid normalised", out.contains("<UUID>"))
    }
    do {
        let session = AssistAgentSession(userTask: "t")
        session.appendStep(.init(kind: "文件内容", tool: "read_file",
            args: ["path": "a.py"], why: "", result: "1",
            raw: "old", ok: true))
        session.appendStep(.init(kind: "文件内容", tool: "read_file",
            args: ["path": "b.py"], why: "", result: "2",
            raw: "b", ok: true))
        session.appendStep(.init(kind: "文件内容", tool: "read_file",
            args: ["path": "a.py"], why: "", result: "3",
            raw: "new", ok: true))
        let stale = assistCompactionStaleReadIndices(session.steps)
        check("dedup: old read of a.py stale", stale.contains(0))
        check("dedup: b.py alive", !stale.contains(1))
        check("dedup: newest a.py alive", !stale.contains(2))
    }
    do {
        let session = AssistAgentSession(userTask: "t")
        for i in 0..<10 {
            session.appendStep(.init(kind: "文件内容", tool: "read_file",
                args: ["path": "\(i).py"], why: "",
                result: "s", raw: "very long body \(i)", ok: true))
        }
        let cleared = assistCompactionMicrocompactSession(session)
        check("microcompact clears >0", cleared > 0)
        check("microcompact keeps last-4 intact",
              session.steps[9].raw == "very long body 9")
        check("microcompact clears old bodies",
              session.steps[0].raw ==
                AssistAgentCompactionConstants.microcompactClearedMarker)
    }
    check("microcompact keeps 4 recent (Python parity)",
          AssistAgentCompactionConstants.microcompactKeepRecent == 4)

    print("── AssistAgentPlanner parity ──")
    do {
        let good = AssistAgentPlanner.Bundle(
            proposal: "## Why\nx\n## What Changes\ny\n## Impact\nz",
            tasks: "## 1. G\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c",
            progress: "# Task\nabc\n## Steps\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c\nLAST_COMPLETED: START")
        check("good bundle validates", AssistAgentPlanner.validate(good).isEmpty)
    }
    do {
        let bad = AssistAgentPlanner.Bundle(
            proposal: "## Why\nx\n## What Changes\ny",
            tasks: "## 1. G\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c",
            progress: "# Task\nabc\n## Steps\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c\nLAST_COMPLETED: START")
        check("missing Impact caught",
              AssistAgentPlanner.validate(bad).contains { $0.contains("## Impact") })
    }
    let fb = AssistAgentPlanner.fallback(from: "user wants a widget")
    check("fallback bundle validates",
          AssistAgentPlanner.validate(fb).isEmpty)

    print("── AssistAgentDetectors parity ──")
    check("refusal EN", AssistAgentDetectors.looksLikeRefusal("As an AI, I can't do that"))
    check("refusal CN", AssistAgentDetectors.looksLikeRefusal("抱歉，我无法执行"))
    check("no refusal", !AssistAgentDetectors.looksLikeRefusal("Sure, done"))
    check("memory loss EN",
          AssistAgentDetectors.looksLikeMemoryLoss("I don't recall earlier context"))
    check("memory loss CN",
          AssistAgentDetectors.looksLikeMemoryLoss("我没有印象我们之前聊了什么"))
    check("no memory loss",
          !AssistAgentDetectors.looksLikeMemoryLoss("Continuing from where we left off"))
    do {
        let session = AssistAgentSession(userTask: "t")
        session.appendStep(.init(kind: "写入完成", tool: "write_file",
            args: ["路径": "foo.py"], why: "", result: "wrote",
            raw: "", ok: true))
        let dup = #"{"步骤":"需要","类型":"写入完成","参数":{"路径":"foo.py"}}"#
        check("dup detected",
              AssistAgentDetectors.modelProposingDup(rawReply: dup, session: session))
        let crossTool = #"{"步骤":"需要","类型":"文件内容","参数":{"路径":"foo.py"}}"#
        check("cross-tool (write→read) NOT flagged",
              !AssistAgentDetectors.modelProposingDup(rawReply: crossTool, session: session))
    }
    do {
        let s = AssistAgentSession(userTask: "t")
        for _ in 0..<5 { s.appendStep(.init(kind: "x", tool: "x", args: [:],
            why: "", result: "", raw: "", ok: true)) }
        check("classify empty ceiling",
              AssistAgentDetectors.classifyEmpty(inputChars: 60_000, session: s) == .ceiling)
        let s2 = AssistAgentSession(userTask: "t")
        check("classify empty cold start",
              AssistAgentDetectors.classifyEmpty(inputChars: 1000, session: s2) == .coldStart)
    }

    print("── AssistAgentPrompt parity ──")
    do {
        // Marker + JSON schema mirrors what the main dialog receives.
        check("marker literal", AssistAgentPrompt.requestMarker == "[ASSIST]")
        let ok = AssistAgentPrompt.parseInvocation(
            from: "here goes\n[ASSIST] {\"goal\":\"read foo.py\",\"workdir\":\"/tmp\",\"max_rounds\":5}\ntrailing")
        check("parses good invocation", ok?.goal == "read foo.py")
        check("parses workdir", ok?.workdir == "/tmp")
        check("clamps max_rounds", ok?.maxRounds == 5)
        // Missing marker → nil.
        check("no marker → nil",
              AssistAgentPrompt.parseInvocation(from: "hello there") == nil)
        // Missing goal → nil.
        check("missing goal → nil",
              AssistAgentPrompt.parseInvocation(from: "[ASSIST] {}") == nil)
        // max_rounds clamped to 1..15.
        let big = AssistAgentPrompt.parseInvocation(
            from: "[ASSIST] {\"goal\":\"x\",\"max_rounds\":99}")
        check("clamps huge max_rounds ≤15", (big?.maxRounds ?? 0) == 15)
        let tiny = AssistAgentPrompt.parseInvocation(
            from: "[ASSIST] {\"goal\":\"x\",\"max_rounds\":0}")
        check("clamps zero max_rounds ≥1", (tiny?.maxRounds ?? 0) == 1)
        // effectiveSystemPrompt appends block when enabled (stub returns true).
        let wrapped = AssistAgentPrompt.effectiveSystemPrompt(base: "SYSTEM")
        check("effectiveSystemPrompt injects block",
              wrapped.contains("Assist Agent"))
        check("effectiveSystemPrompt preserves base",
              wrapped.hasPrefix("SYSTEM"))
    }

    print("── CN alias table completeness ──")
    do {
        // Every Python _CN_TO_TOOL entry must be present.
        let requiredKinds = [
            "文件内容", "文件大纲", "目录列表", "路径匹配", "搜索结果",
            "命令输出", "网页内容", "网络搜索", "重新获取图片", "查历史",
            "写入完成", "局部替换", "追加片段", "差量应用", "分派并行",
            "存记忆", "读记忆", "钉记忆", "批量替换", "待办列表"
        ]
        for k in requiredKinds {
            check("CN kind '\(k)' present",
                  AssistAgentLoop.cnToTool[k] != nil)
        }
        // Type aliases (subset — spot check the most common).
        let aliasSpotCheck: [(String, String)] = [
            ("写入文件", "写入完成"), ("编辑文件", "局部替换"),
            ("执行命令", "命令输出"), ("读文件", "文件内容"),
            ("shell", "命令输出"), ("grep", "搜索结果"),
            ("历史查询", "查历史"), ("补丁", "差量应用"),
        ]
        for (input, expected) in aliasSpotCheck {
            check("alias \(input) → \(expected)",
                  AssistAgentLoop.canonicalKind(input) == expected)
        }
        // Arg aliases spot-check.
        let argSpot: [(String, String)] = [
            ("path", "路径"), ("cmd", "命令"), ("url", "网址"),
            ("pattern", "模式"), ("limit", "最多")
        ]
        for (input, expected) in argSpot {
            check("arg alias \(input) → \(expected)",
                  AssistAgentLoop.argAliases[input] == expected)
        }
    }

    print("── Compaction: source skeleton ──")
    do {
        let py = String(repeating: "# fill\n", count: 100) + "\n" +
                 "def foo():\n    return 1\n" +
                 String(repeating: "# noise\n", count: 200) +
                 "class Bar:\n    pass\n"
        let out = assistCompactionCompactSource(py, path: "x.py", budget: 500)
        check("py skeleton keeps def", out.contains("def foo"))
        check("py skeleton keeps class", out.contains("class Bar"))
        check("py skeleton smaller than input", out.count < py.count)
    }
    do {
        let sw = String(repeating: "// comment line\n", count: 100) +
                 "func hello() {}\n" +
                 String(repeating: "// noise\n", count: 200) +
                 "public class Widget {}\n"
        let out = assistCompactionCompactSource(sw, path: "x.swift", budget: 500)
        check("swift skeleton keeps func", out.contains("func hello"))
        check("swift skeleton keeps class", out.contains("class Widget"))
    }
    do {
        // Unknown extension → head+tail fallback.
        let big = String(repeating: "line X\n", count: 2000)
        let out = assistCompactionCompactSource(big, path: "x.xyz", budget: 500)
        check("unknown ext falls back", out.count <= 500 + 50)
        check("unknown ext keeps head", out.hasPrefix("line X"))
    }

    print("── Planner: numbering drift ──")
    do {
        let mismatch = AssistAgentPlanner.Bundle(
            proposal: "## Why\nx\n## What Changes\ny\n## Impact\nz",
            tasks: "## 1. G\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c",
            progress: "# Task\nabc\n## Steps\n- [ ] 9.9 x\n- [ ] 1.2 b\n- [ ] 1.3 c\nLAST_COMPLETED: START")
        let errs = AssistAgentPlanner.validate(mismatch)
        check("numbering drift caught",
              errs.contains { $0.contains("do not match") })
    }
    do {
        let raw = "```markdown\n## Why\nneed\n## What Changes\ndo\n## Impact\nstuff\n```"
        let cleaned = AssistAgentPlanner.stripBundleHeader(body: raw, filename: "proposal.md")
        check("planner strips code fence", cleaned.hasPrefix("## Why"))
        check("planner strips backticks", !cleaned.contains("```"))
    }
    do {
        let three = """
        ## Why
        w
        ## What Changes
        c
        ## Impact
        i
        \(AssistAgentPlanner.fileSeparator)
        ## 1. G
        - [ ] 1.1 a
        - [ ] 1.2 b
        - [ ] 1.3 c
        \(AssistAgentPlanner.fileSeparator)
        # Task
        one
        ## Steps
        - [ ] 1.1 a
        - [ ] 1.2 b
        - [ ] 1.3 c
        LAST_COMPLETED: START
        """
        let bundle = AssistAgentPlanner.splitBundle(three)
        check("split extracts proposal", bundle?.proposal.hasPrefix("## Why") == true)
        check("split extracts tasks",    bundle?.tasks.hasPrefix("## 1. G") == true)
        check("split extracts progress", bundle?.progress.hasPrefix("# Task") == true)
    }

    print("── Session: adaptive AIMD ──")
    do {
        let s = AssistAgentSession(userTask: "t")
        let start = s.adaptiveResyncInterval
        check("start interval matches Python 3",
              start == AssistAgentSession.incrementalStartResync)
        // 5 successes → +5.
        for _ in 0..<5 { s.recordDeltaSuccess() }
        check("AIMD grows on success",
              s.adaptiveResyncInterval == start + 5)
        // One failure → halves.
        let prev = s.adaptiveResyncInterval
        s.recordDeltaFailure(reason: "test")
        check("AIMD halves on failure",
              s.adaptiveResyncInterval == max(prev / 2,
                AssistAgentSession.incrementalMinResync))
        check("force_full flag flipped",
              s.forceFullNextRound)
    }
    do {
        // Pin memory bounded to 32, dedup.
        let s = AssistAgentSession(userTask: "t")
        s.pinMemory("keep-a")
        s.pinMemory("keep-a")
        check("pin dedup", s.pinnedMemory.count == 1)
        for i in 0..<40 { s.pinMemory("m\(i)") }
        check("pin bounded ≤32", s.pinnedMemory.count == 32)
        check("pin drops oldest",
              !s.pinnedMemory.contains("keep-a"))
        check("pin keeps newest",
              s.pinnedMemory.contains("m39"))
    }

    print("── Constants: Python parity ──")
    check("digest max = 20k",
          AssistAgentCompactionConstants.digestMaxChars == 20_000)
    check("microcompact keep = 4",
          AssistAgentCompactionConstants.microcompactKeepRecent == 4)
    check("keep recent min = 3",
          AssistAgentCompactionConstants.keepRecentMin == 3)
    check("incremental min = 2",
          AssistAgentSession.incrementalMinResync == 2)
    check("incremental max = 30",
          AssistAgentSession.incrementalMaxResync == 30)
    check("incremental start = 3",
          AssistAgentSession.incrementalStartResync == 3)
    check("chars per token = 4",
          AssistAgentBudget.charsPerToken == 4)
    check("output reserve tokens = 16k",
          AssistAgentBudget.outputReserveTokens == 16_000)
    check("system overhead tokens = 12k",
          AssistAgentBudget.systemOverheadTokens == 12_000)
    check("default context = 200k",
          AssistAgentBudget.defaultContextTokens == 200_000)

    print("── Loop behavior: mocked transport ──")
    do {
        // Happy path: one tool call → done.
        let session = AssistAgentSession(userTask: "read foo.py")
        let transport = MockTransport(scripted: [
            #"{"步骤":"需要","类型":"文件内容","为什么":"open","参数":{"路径":"foo.py"}}"#,
            #"{"步骤":"完成","答案":"file has one function"}"#
        ])
        let tools = MockTools(canned: [
            "read_file": .init(ok: true, summary: "read foo.py 42B",
                              raw: "def foo(): pass")
        ])
        let loop = AssistAgentLoop(
            session: session, transport: transport, dispatcher: tools,
            systemPrompt: "sys", maxRounds: 5)
        do {
            let result = try await loop.run()
            check("happy path completes", result.summary == "file has one function")
            check("happy path used 1 tool", tools.calls.count == 1)
            check("happy path 1 step in session", session.steps.count == 1)
            check("happy path step is read_file",
                  session.steps.first?.tool == "read_file")
        } catch {
            check("happy path completes", false, "threw: \(error)")
        }
    }
    do {
        // Empty reply → treated as recoverable; next round completes.
        let session = AssistAgentSession(userTask: "t")
        let transport = MockTransport(scripted: [
            "",   // empty
            #"{"步骤":"完成","答案":"ok"}"#
        ])
        let loop = AssistAgentLoop(
            session: session, transport: MockTransport(scripted: transport.scripted),
            dispatcher: MockTools(), systemPrompt: "sys", maxRounds: 5)
        do {
            let result = try await loop.run()
            check("empty then done recovers", result.summary == "ok")
            check("empty tracked in session", session.consecutiveEmptyAtFloor == 0)
        } catch {
            check("empty then done recovers", false, "threw: \(error)")
        }
    }
    do {
        // Memory loss reply → info event, next round completes.
        let session = AssistAgentSession(userTask: "t")
        let scripted = [
            "我不记得之前的上下文",
            #"{"步骤":"完成","答案":"resumed"}"#
        ]
        let loop = AssistAgentLoop(
            session: session, transport: MockTransport(scripted: scripted),
            dispatcher: MockTools(), systemPrompt: "sys", maxRounds: 5)
        do {
            let result = try await loop.run()
            check("memory-loss recovers", result.summary == "resumed")
            check("memory-loss flipped force_full", session.forceFullNextRound)
        } catch {
            check("memory-loss recovers", false, "threw: \(error)")
        }
    }
    do {
        // Refusal reply → info event, then complete.
        let session = AssistAgentSession(userTask: "t")
        let scripted = [
            "As an AI, I can't do that.",
            #"{"步骤":"完成","答案":"nudged"}"#
        ]
        let loop = AssistAgentLoop(
            session: session, transport: MockTransport(scripted: scripted),
            dispatcher: MockTools(), systemPrompt: "sys", maxRounds: 5)
        do {
            let result = try await loop.run()
            check("refusal doesn't crash", result.summary == "nudged")
        } catch {
            check("refusal doesn't crash", false, "threw: \(error)")
        }
    }
    do {
        // Dup detection: model proposes to redo a completed write.
        let session = AssistAgentSession(userTask: "t")
        session.appendStep(.init(
            kind: "写入完成", tool: "write_file",
            args: ["路径": "foo.py"], why: "", result: "wrote",
            raw: "", ok: true))
        let dup = #"{"步骤":"需要","类型":"写入完成","参数":{"路径":"foo.py","内容":"x"}}"#
        let scripted = [
            dup,
            #"{"步骤":"完成","答案":"already-there"}"#
        ]
        let loop = AssistAgentLoop(
            session: session, transport: MockTransport(scripted: scripted),
            dispatcher: MockTools(), systemPrompt: "sys", maxRounds: 5)
        do {
            let result = try await loop.run()
            check("dup detection skips write", result.summary == "already-there")
            check("no new step added after dup",
                  session.steps.count == 1)
        } catch {
            check("dup detection skips write", false, "threw: \(error)")
        }
    }
    do {
        // Auto-extend: model still going at cap → doubles once.
        let session = AssistAgentSession(userTask: "t")
        // Cap = 4, but session already has 2 completed steps; loop
        // should extend once when it hits the cap.
        for _ in 0..<3 {
            session.appendStep(.init(kind: "文件内容", tool: "read_file",
                args: [:], why: "", result: "s", raw: "b", ok: true))
        }
        // Script: 4 need-more, then 1 done (5 replies for cap=4 = one extend).
        let scripted = Array(repeating:
            #"{"步骤":"需要","类型":"文件内容","参数":{"路径":"z.py"}}"#, count: 4)
            + [#"{"步骤":"完成","答案":"stretched"}"#]
        let tools = MockTools(canned: [
            "read_file": .init(ok: true, summary: "read z.py", raw: "")
        ])
        let loop = AssistAgentLoop(
            session: session, transport: MockTransport(scripted: scripted),
            dispatcher: tools, systemPrompt: "sys", maxRounds: 4)
        do {
            let result = try await loop.run()
            check("auto-extend beyond cap",
                  result.summary == "stretched")
        } catch {
            check("auto-extend beyond cap", false, "threw: \(error)")
        }
    }
    do {
        // Max rounds exhausted without extension eligibility (too few
        // completed steps to justify auto-extend).
        let session = AssistAgentSession(userTask: "t")
        let scripted = Array(repeating:
            #"{"步骤":"需要","类型":"文件内容","参数":{"路径":"z.py"}}"#, count: 10)
        let tools = MockTools(canned: [
            "read_file": .init(ok: true, summary: "r", raw: "")
        ])
        let loop = AssistAgentLoop(
            session: session, transport: MockTransport(scripted: scripted),
            dispatcher: tools, systemPrompt: "sys", maxRounds: 2)
        do {
            _ = try await loop.run()
            check("never-done throws", false, "should have thrown")
        } catch is AssistAgentLoopError {
            check("never-done throws maxRoundsExhausted", true)
        } catch {
            check("never-done throws maxRoundsExhausted", false, "wrong error: \(error)")
        }
    }

    print("\n── Summary ──")
    print("  passed=\(passed)  failed=\(failed)")
    return failed
}

// MARK: - Mock transport / tools for behavior tests

final class MockTransport: AssistAgentTransport, @unchecked Sendable {
    let scripted: [String]
    var index: Int = 0
    init(scripted: [String]) { self.scripted = scripted }
    func ask(prior: String, priorImage: Data?, systemPrompt: String)
        async throws -> AssistAgentTransportReply
    {
        let reply = index < scripted.count ? scripted[index] : ""
        index += 1
        return AssistAgentTransportReply(text: reply, elapsedMs: 1)
    }
}

@MainActor
final class MockTools: AssistAgentToolDispatcher, @unchecked Sendable {
    var canned: [String: AssistAgentToolOutcome]
    var calls: [String] = []
    init(canned: [String: AssistAgentToolOutcome] = [:]) { self.canned = canned }
    func dispatch(kind: String, tool: String,
                 args: [String: String]) async throws -> AssistAgentToolOutcome {
        calls.append(tool)
        if let out = canned[tool] { return out }
        return AssistAgentToolOutcome(
            ok: true, summary: "\(tool) executed", raw: "mock output")
    }
}

@main
struct Harness {
    static func main() async {
        let rc = await runAll()
        exit(Int32(rc))
    }
}
SWIFT

# Extract the platform SDK path
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# Concat all sources + harness.
COMPILE_LIST=("${SRCS[@]}" "$OUT/harness.swift")

# Compile as a single executable.
BIN="$OUT/harness"
xcrun swiftc -parse-as-library \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -o "$BIN" \
    "${COMPILE_LIST[@]}"

echo
echo "▶ running harness"
"$BIN"
