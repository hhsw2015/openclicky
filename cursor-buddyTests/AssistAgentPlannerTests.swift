//
//  AssistAgentPlannerTests.swift
//  cursor-buddyTests
//
//  Parity coverage for AssistAgentPlanner vs Python planner.py.
//  Validator rules are what agent runs check when it fabricates a
//  plan bundle — same set of rules on both sides is essential.
//

import Foundation
import Testing
@testable import OpenClicky

struct AssistAgentPlannerTests {

    @Test func splitsBundleOnSeparator() {
        let raw = """
        ## Why
        need
        ## What Changes
        do
        ## Impact
        stuff
        \(AssistAgentPlanner.fileSeparator)
        ## 1. Foo
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
        let bundle = AssistAgentPlanner.splitBundle(raw)
        #expect(bundle != nil)
        #expect(bundle!.proposal.contains("## Why"))
        #expect(bundle!.tasks.contains("- [ ] 1.1"))
        #expect(bundle!.progress.contains("LAST_COMPLETED"))
    }

    @Test func validateAcceptsWellFormedBundle() {
        let bundle = AssistAgentPlanner.Bundle(
            proposal: "## Why\nx\n## What Changes\ny\n## Impact\nz",
            tasks: "## 1. G\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c",
            progress: "# Task\nabc\n## Steps\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c\nLAST_COMPLETED: START")
        let errs = AssistAgentPlanner.validate(bundle)
        #expect(errs.isEmpty, "unexpected: \(errs)")
    }

    @Test func validateRejectsMissingImpact() {
        let bundle = AssistAgentPlanner.Bundle(
            proposal: "## Why\nx\n## What Changes\ny",   // no ## Impact
            tasks: "## 1. G\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c",
            progress: "# Task\nabc\n## Steps\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c\nLAST_COMPLETED: START")
        let errs = AssistAgentPlanner.validate(bundle)
        #expect(errs.contains { $0.contains("## Impact") })
    }

    @Test func validateRejectsNumberingDrift() {
        let bundle = AssistAgentPlanner.Bundle(
            proposal: "## Why\nx\n## What Changes\ny\n## Impact\nz",
            tasks: "## 1. G\n- [ ] 1.1 a\n- [ ] 1.2 b\n- [ ] 1.3 c",
            progress: "# Task\nabc\n## Steps\n- [ ] 9.9 x\n- [ ] 1.2 b\n- [ ] 1.3 c\nLAST_COMPLETED: START")
        let errs = AssistAgentPlanner.validate(bundle)
        #expect(errs.contains { $0.contains("do not match") })
    }

    @Test func fallbackBundleValidates() {
        let bundle = AssistAgentPlanner.fallback(from: "user wants a widget")
        let errs = AssistAgentPlanner.validate(bundle)
        #expect(errs.isEmpty, "fallback bundle should self-validate; got: \(errs)")
        #expect(bundle.proposal.contains("user wants a widget"))
    }

    @Test func stripsCodeFenceAroundBundle() {
        let raw = "```markdown\n## Why\nneed\n## What Changes\ndo\n## Impact\nstuff\n```"
        let cleaned = AssistAgentPlanner.stripBundleHeader(body: raw, filename: "proposal.md")
        #expect(cleaned.hasPrefix("## Why"))
        #expect(!cleaned.contains("```"))
    }
}
