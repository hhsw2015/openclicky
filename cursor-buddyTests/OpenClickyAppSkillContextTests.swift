// OpenClickyAppSkillContextTests.swift
// cursor-buddyTests
//
// The app-skill fragment is injected into the *dynamic* system block on
// every voice turn, so it is paid for repeatedly and never cached. It was
// the only dynamic context source with no size cap; entries had grown to
// ~2.5 KB (Blender 3029 chars, ≈850 tokens).
//
// These tests pin the two properties that matter: the cap actually holds
// for every shipped entry, and trimming never eats the grounding content.

import XCTest
@testable import OpenClicky

final class OpenClickyAppSkillContextTests: XCTestCase {

    /// A new or edited entry must not push the fragment past the budget.
    /// Only the workflow list is trimmable, so an entry whose tagline +
    /// systemPrompt + concepts alone exceed the cap will fail here rather
    /// than silently ship an oversized prompt.
    func test_promptFragment_staysWithinCharacterCap() {
        let cap = OpenClickyAppSkillContext.promptFragmentCharacterCap
        for context in OpenClickyAppSkillContext.all {
            let fragment = context.promptFragment
            XCTAssertLessThanOrEqual(
                fragment.count, cap,
                "\(context.appName) fragment is \(fragment.count) chars, cap is \(cap). "
                + "Shorten its systemPrompt or concepts — workflows are already trimmed first."
            )
        }
    }

    /// Trimming drops whole workflows off the tail. It must never touch the
    /// parts a voice answer is grounded in.
    func test_promptFragment_preservesGroundingContent() {
        for context in OpenClickyAppSkillContext.all {
            let fragment = context.promptFragment
            XCTAssertTrue(fragment.contains(context.tagline),
                          "\(context.appName): tagline was trimmed")
            XCTAssertTrue(fragment.contains(context.systemPrompt),
                          "\(context.appName): interface description was trimmed")
            for concept in context.concepts {
                XCTAssertTrue(fragment.contains(concept),
                              "\(context.appName): concept trimmed — \(concept)")
            }
            XCTAssertTrue(
                fragment.hasSuffix("point at visible app areas when useful."),
                "\(context.appName): usage trailer was trimmed. Without it the model "
                + "may announce that a skill loaded."
            )
        }
    }

    /// Workflows are dropped whole, never sliced mid-step — a half-emitted
    /// instruction is worse than an absent one.
    func test_promptFragment_doesNotTruncateMidWorkflow() {
        for context in OpenClickyAppSkillContext.all {
            let fragment = context.promptFragment
            for workflow in context.workflows where fragment.contains("\(workflow.name):") {
                for step in workflow.steps {
                    XCTAssertTrue(
                        fragment.contains(step),
                        "\(context.appName): workflow '\(workflow.name)' is present but "
                        + "step '\(step)' is missing — it was sliced mid-block."
                    )
                }
            }
        }
    }
}
