//
//  AssistAgentJSONTests.swift
//  cursor-buddyTests
//
//  Locks the Swift port to the Python `_extract_json` / `_repair_json`
//  behavior. All test inputs are ones that failed against the strict
//  json.loads() in the Python reference and only succeeded after the
//  repair pass — parity means the Swift version parses them too.
//

import Foundation
import Testing
@testable import OpenClicky

struct AssistAgentJSONTests {

    @Test func extractsStrictJSON() {
        let obj = AssistAgentJSON.extract(from: #"{"步骤": "完成", "答案": "ok"}"#)
        #expect(obj?["步骤"] as? String == "完成")
        #expect(obj?["答案"] as? String == "ok")
    }

    @Test func repairsFullwidthColonAndComma() {
        let raw = #"{"步骤":"需要","类型":"读文件","参数":{"路径":"foo.py"}}"#
            .replacingOccurrences(of: ":", with: "：")
            .replacingOccurrences(of: ",", with: "，")
        let obj = AssistAgentJSON.extract(from: raw)
        #expect(obj?["步骤"] as? String == "需要")
        #expect((obj?["参数"] as? [String: Any])?["路径"] as? String == "foo.py")
    }

    @Test func repairsSmartQuotes() {
        let raw = #"{“x”:‘y’}"#
        let obj = AssistAgentJSON.extract(from: raw)
        #expect(obj?["x"] as? String == "y")
    }

    @Test func repairsTrailingCommaBeforeBrace() {
        let raw = #"{"a": 1, "b": 2,}"#
        let obj = AssistAgentJSON.extract(from: raw)
        #expect(obj?["a"] as? Int == 1)
        #expect(obj?["b"] as? Int == 2)
    }

    @Test func repairsUnescapedNewlineInsideString() {
        // Real Fable-5 misbehavior: literal newline inside a string value.
        let raw = "{\"content\": \"line1\nline2\nline3\"}"
        let obj = AssistAgentJSON.extract(from: raw)
        #expect((obj?["content"] as? String)?.contains("line1\nline2") == true)
    }

    @Test func unwrapsCodeFence() {
        let raw = """
        ```json
        {"步骤": "完成", "答案": "wrapped"}
        ```
        """
        let obj = AssistAgentJSON.extract(from: raw)
        #expect(obj?["答案"] as? String == "wrapped")
    }

    @Test func returnsNilForNonJSON() {
        #expect(AssistAgentJSON.extract(from: "hello there") == nil)
    }
}
