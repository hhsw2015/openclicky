//
//  AssistAgentDetectors.swift
//  cursor-buddy
//
//  Text-classification helpers ported from heyclicky_agent/agent.py:
//    · _looks_like_refusal         → refusal patterns EN + CN
//    · _looks_like_memory_loss     → session-drop patterns EN + CN
//    · _model_proposing_dup        → dup-work detector (same kind + path)
//    · _classify_empty_cause       → empty reply → suggested recovery
//
//  Each carries the SAME regex Python does so the two ports agree on
//  what counts as a refusal / memory-loss / dup.
//

import Foundation

public enum AssistAgentDetectors {

    // MARK: - Refusal

    /// Matches `_REFUSAL_PATTERNS` (agent.py:469). Case-insensitive.
    private static let refusalPatterns: NSRegularExpression = {
        let pat = "(i can't|i cannot|i'm not able|i am not able|as an ai|" +
                  "i'm heyclicky|i am heyclicky|voice assistant|" +
                  "my role is|i'm designed to|i am designed to|" +
                  "抱歉,?我(不能|无法|没办法)|作为(AI|助手)|我(不能|无法|没办法)执行)"
        return try! NSRegularExpression(pattern: pat, options: [.caseInsensitive])
    }()

    public static func looksLikeRefusal(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // Python parity (agent.py:601): if there's no `{` at all, the
        // model is answering in prose when we asked for JSON — that's
        // a refusal by shape, not just by keyword.
        if !t.contains("{") { return true }
        let ns = t as NSString
        let hit = refusalPatterns.firstMatch(
            in: t, range: NSRange(location: 0, length: ns.length)) != nil
        // Refusal prose sometimes trails valid JSON. Only count as a
        // refusal when the pattern fires BEFORE the first `{`.
        if hit, let brace = t.firstIndex(of: "{") {
            let prefix = String(t[..<brace])
            let pns = prefix as NSString
            return refusalPatterns.firstMatch(
                in: prefix, range: NSRange(location: 0, length: pns.length)) != nil
        }
        return hit
    }

    // MARK: - Memory loss

    /// Matches `_MEMORY_LOSS_PATTERNS` (agent.py:478). When a reply
    /// carries this, the next round should force a full prior baseline
    /// so the model gets its history back.
    private static let memoryLossPatterns: NSRegularExpression = {
        let pat = "(我(不记得|没有印象|忘了|看不见|没看到)|" +
                  "i don'?t (recall|remember|see)|no memory of|cannot find (any )?prior|" +
                  "没有(相关|之前的)(上下文|记录|信息)|你之前(没有|未曾)|" +
                  "上下文中(没有|未|不存在))"
        return try! NSRegularExpression(pattern: pat, options: [.caseInsensitive])
    }()

    public static func looksLikeMemoryLoss(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let ns = text as NSString
        return memoryLossPatterns.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // MARK: - Duplicate work proposal

    /// Port of `_model_proposing_dup` (agent.py:493). Refined to only
    /// flag SAME-tool dups (write→write, read→read). Cross-tool flows
    /// like write→read (verify) or read→edit (modify) are legitimate.
    ///
    /// Extracts (类型, 路径) from the raw reply and checks whether the
    /// last 4 steps already did the same kind on the same path
    /// successfully. Returns true → the loop should nudge the model,
    /// not accept the proposal.
    @MainActor
    public static func modelProposingDup(rawReply: String,
                                        session: AssistAgentSession) -> Bool {
        guard !rawReply.isEmpty, !session.steps.isEmpty else { return false }
        let ns = rawReply as NSString
        let range = NSRange(location: 0, length: ns.length)

        let kindRE = try? NSRegularExpression(pattern: #""类型"\s*:\s*"([^"]{1,80})""#)
        let pathCN = try? NSRegularExpression(pattern: #""路径"\s*:\s*"([^"]{1,200})""#)
        let pathEN = try? NSRegularExpression(pattern: #""path"\s*:\s*"([^"]{1,200})""#)
        guard let path = firstCapture(pathCN, in: rawReply, range: range, ns: ns)
                ?? firstCapture(pathEN, in: rawReply, range: range, ns: ns),
              let kind = firstCapture(kindRE, in: rawReply, range: range, ns: ns) else {
            return false
        }
        let proposedKind = kind.trimmingCharacters(in: .whitespaces)
        let proposedPath = path.trimmingCharacters(in: .whitespaces)
        if proposedKind.isEmpty || proposedPath.isEmpty { return false }
        let look = session.steps.suffix(4)
        for st in look where st.ok {
            let prevPath = st.args["路径"] ?? st.args["path"] ?? ""
            if prevPath == proposedPath && st.kind == proposedKind {
                return true
            }
        }
        return false
    }

    private static func firstCapture(_ re: NSRegularExpression?,
                                    in text: String,
                                    range: NSRange,
                                    ns: NSString) -> String? {
        guard let re,
              let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges >= 2 else { return nil }
        let g = m.range(at: 1)
        if g.location == NSNotFound { return nil }
        return ns.substring(with: g)
    }

    // MARK: - Empty-cause classifier (Python parity)

    public enum EmptyCause: String, Sendable {
        case ceiling, network, refusal, memoryLoss, coldStart, unknown
    }

    /// Compact version of `_classify_empty_cause` (agent.py:540). We
    /// don't have the network fault flag / model-family split at this
    /// layer, so we lean on session state + input size.
    @MainActor
    public static func classifyEmpty(inputChars: Int,
                                    session: AssistAgentSession,
                                    query: String = "")
        -> EmptyCause
    {
        // Ceiling: matches Python threshold in agent.py:449-455.
        if inputChars >= 42_000 { return .ceiling }
        // Cold start: first ~2 rounds of a session — no baseline yet.
        if session.steps.count <= 2 { return .coldStart }
        // Python parity (agent.py:585-597): sensitive-keyword sniff.
        // Server-side content filter fires deterministically on these
        // — hopping won't help, only rewording will.
        let sensitiveHints = [
            "system prompt", "jailbreak", "ignore previous",
            "act as", "roleplay",
            "password", "credit card", "ssn", "api key",
            "how to make", "explosive", "weapon", "malware",
            "hacking", "exploit", "vulnerability",
            "porn", "nsfw", "explicit",
        ]
        let qLow = query.lowercased()
        for kw in sensitiveHints where qLow.contains(kw) {
            return .refusal
        }
        return .unknown
    }
}
