//
//  OpenClickyScreenLegibilityRouter.swift
//  cursor-buddy
//
//  Decides, BEFORE a turn runs, whether the local model can answer about
//  what is on screen — or whether the frame is dense text it will
//  fabricate about and should go straight to Claude.
//
//  Today's equivalent is reactive: the turn runs, the model answers "i
//  can't read that", `shouldEscalateVoiceResponseToAgent` spots the
//  refusal, and only then escalates. That is a full round trip spent
//  discovering something a 1.2 s local look could have decided.
//
//  Measured (docs/parlor-integration-research/05-integration-plan.md
//  §12.17): 6/6, zero false-legible, 1251 ms.
//
//  The asymmetry is the whole design:
//
//    · false LEGIBLE   — the model answers about text it cannot read.
//                        That is fabrication. Unacceptable at any rate.
//    · false ILLEGIBLE — one unnecessary escalation, which is what
//                        happens today anyway. Waste, not harm.
//
//  So every ambiguity resolves toward DEFER, including every failure
//  path: no model, server down, unparseable answer.
//
//  NOTE the question form. Asking "is this legible?" or "LOCAL or DEFER?"
//  scored 1/6 false-legible — on the frame it could correctly name as an
//  "Error log" when simply asked what it was. Naming the desired verdict
//  invites assent. So: ask what the content IS, and categorise here.
//

import Foundation

enum OpenClickyScreenLegibilityDecision: Equatable {
    /// The local model may answer about this frame.
    case answerLocally
    /// Dense text or an unknown state — send it to the backend.
    case deferToBackend(reason: String)

    var isLocal: Bool { self == .answerLocally }
}

enum OpenClickyScreenLegibilityRouter {

    /// Off by default. A wrong DEFER is invisible to the user except as
    /// latency, so this must be turnable off without a rebuild — and it
    /// changes the behaviour of a path that already works.
    static let enabledDefaultsKey = "openClickyLocalLegibilityRoutingEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Content categories the local model must not answer about, matched
    /// against its own free-text description.
    ///
    /// Banned by CATEGORY, not by inspection. Told to judge for itself
    /// whether a specific terminal was readable, the model "read" a line
    /// and returned a command that had genuinely been typed minutes
    /// earlier — plausible, specific, invented (§12.4).
    static let deferCategories: Set<String> = [
        "terminal", "console", "shell", "command",
        "log", "logs", "trace", "stack",
        "code", "editor", "ide", "source", "script", "debug",
        "diff", "json", "xml", "yaml", "spreadsheet"
    ]

    /// Ask what the frame contains, then categorise.
    ///
    /// - Returns: `.answerLocally` only when a model was reachable AND its
    ///   description matched no banned category. Every other outcome —
    ///   routing disabled, no local model, request failure, empty answer —
    ///   is `.deferToBackend`, because the safe direction is a wasted round
    ///   trip rather than a fabricated answer.
    @MainActor
    static func decide(imageData: Data) async -> OpenClickyScreenLegibilityDecision {
        guard isEnabled else {
            return .deferToBackend(reason: "legibility routing disabled")
        }
        guard OpenClickyLocalLLMClient.isConfigured else {
            return .deferToBackend(reason: "no local model")
        }

        let client = OpenClickyLocalLLMClient()
        guard let description = try? await client.identify(
            image: imageData,
            question: "What kind of window or content is this?",
            maxWords: 2
        ), !description.isEmpty else {
            return .deferToBackend(reason: "local model did not answer")
        }

        if let category = matchedDeferCategory(in: description) {
            return .deferToBackend(reason: "screen looks like \(category)")
        }
        return .answerLocally
    }

    /// Which banned category a description falls into, if any. Substring
    /// matching: the model answers "error log" or "code snippet", not a
    /// bare category word.
    nonisolated static func matchedDeferCategory(in description: String) -> String? {
        let normalized = description.lowercased()
        return deferCategories.first { normalized.contains($0) }
    }
}
