import Foundation

struct TestCase {
    enum Kind {
        case lookupNames(query: String, limit: Int)          // A / B / F edge
        case graphPath(from: String, to: String)             // C
        case graphExplore(from: String, hops: Int)           // D
        case graphHubs(limit: Int)                           // E1
        case graphCommunity(topic: String)                   // E2 (known divergent)
        case meta(topic: String)                             // G
    }
    let id: String            // e.g. "A1"
    let title: String
    let kind: Kind
}

enum Fixtures {
    static let all: [TestCase] = [

        // A. Topic lookup - exact (5)
        TestCase(id: "A1", title: "exact \"AI Model\"",         kind: .lookupNames(query: "AI Model",       limit: 10)),
        TestCase(id: "A2", title: "exact \"Vibe Coding\"",       kind: .lookupNames(query: "Vibe Coding",    limit: 10)),
        TestCase(id: "A3", title: "exact \"Awesome Search\"",    kind: .lookupNames(query: "Awesome Search", limit: 10)),
        TestCase(id: "A4", title: "exact \"Deep Learning\"",     kind: .lookupNames(query: "Deep Learning",  limit: 10)),
        TestCase(id: "A5", title: "exact \"MCP\"",               kind: .lookupNames(query: "MCP",            limit: 10)),

        // A. Topic lookup - substring (5)
        TestCase(id: "A6",  title: "substring \"vibe cod\"", kind: .lookupNames(query: "vibe cod", limit: 10)),
        TestCase(id: "A7",  title: "substring \"deep lea\"", kind: .lookupNames(query: "deep lea", limit: 10)),
        TestCase(id: "A8",  title: "substring \"awesome\"",  kind: .lookupNames(query: "awesome",  limit: 10)),
        TestCase(id: "A9",  title: "substring \"model\"",    kind: .lookupNames(query: "model",    limit: 10)),
        TestCase(id: "A10", title: "substring \"docker\"",   kind: .lookupNames(query: "docker",   limit: 10)),

        // B. Fuzzy ?? (5)
        TestCase(id: "B1", title: "fuzzy ??vibe",           kind: .lookupNames(query: "vibe",          limit: 20)),
        TestCase(id: "B2", title: "fuzzy ??deep learning",  kind: .lookupNames(query: "deep learning", limit: 20)),
        TestCase(id: "B3", title: "fuzzy ??cursor",         kind: .lookupNames(query: "cursor",        limit: 20)),
        TestCase(id: "B4", title: "fuzzy ??rust",           kind: .lookupNames(query: "rust",          limit: 20)),
        TestCase(id: "B5", title: "fuzzy ??paper",          kind: .lookupNames(query: "paper",         limit: 20)),

        // C. Graph path (5)
        TestCase(id: "C1", title: "path Vibe Coding -> AI",             kind: .graphPath(from: "Vibe Coding",  to: "AI")),
        TestCase(id: "C2", title: "path Vibe Coding -> LLM",            kind: .graphPath(from: "Vibe Coding",  to: "LLM")),
        TestCase(id: "C3", title: "path Vibe Coding -> Cursor",         kind: .graphPath(from: "Vibe Coding",  to: "Cursor")),
        TestCase(id: "C4", title: "path PyTorch -> AI Model",           kind: .graphPath(from: "PyTorch",      to: "AI Model")),
        TestCase(id: "C5", title: "path Deep Learning -> Transformer",  kind: .graphPath(from: "Deep Learning", to: "Transformer")),

        // D. Graph explore (5)
        TestCase(id: "D1", title: "explore AI Model hops=1",    kind: .graphExplore(from: "AI Model",    hops: 1)),
        TestCase(id: "D2", title: "explore Vibe Coding hops=1", kind: .graphExplore(from: "Vibe Coding", hops: 1)),
        TestCase(id: "D3", title: "explore PyTorch hops=2",     kind: .graphExplore(from: "PyTorch",     hops: 2)),
        TestCase(id: "D4", title: "explore Docker hops=1",      kind: .graphExplore(from: "Docker",      hops: 1)),
        TestCase(id: "D5", title: "explore MCP hops=1",         kind: .graphExplore(from: "MCP",         hops: 1)),

        // E. Hubs + community (2)
        TestCase(id: "E1", title: "hubs top 10",                    kind: .graphHubs(limit: 10)),
        TestCase(id: "E2", title: "community peers of AI Model",    kind: .graphCommunity(topic: "AI Model")),

        // F. Fuzzy edge cases (3)
        TestCase(id: "F1", title: "case-insensitive \"vibe coding\"", kind: .lookupNames(query: "vibe coding", limit: 10)),
        TestCase(id: "F2", title: "alias probe \"gpt-4\"",           kind: .lookupNames(query: "gpt-4",       limit: 10)),
        TestCase(id: "F3", title: "category ref \"#AI\"",            kind: .lookupNames(query: "AI",          limit: 20)),

        // G. Meta output (5)
        TestCase(id: "G1", title: "meta AI Model",      kind: .meta(topic: "AI Model")),
        TestCase(id: "G2", title: "meta Vibe Coding",   kind: .meta(topic: "Vibe Coding")),
        TestCase(id: "G3", title: "meta Deep Learning", kind: .meta(topic: "Deep Learning")),
        TestCase(id: "G4", title: "meta Docker",        kind: .meta(topic: "Docker")),
        TestCase(id: "G5", title: "meta MCP",           kind: .meta(topic: "MCP")),
    ]
}
