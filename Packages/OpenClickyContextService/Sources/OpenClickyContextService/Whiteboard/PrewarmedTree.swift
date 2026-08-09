// Ported from Everywhere: src/Everywhere.Mcp/Whiteboard/AnnotationSnapper.cs
//   PrewarmedTree nested class @ :647-812
// pin @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Flat DFS snapshot of the focused-window AX subtree, taken once when the
// whiteboard overlay appears. Snap-time queries do rect-intersect scans
// over `nodes` instead of paying 5-15s Chromium AX walks on every commit.
//
// Byte-parity checkpoints:
//   * Total-visited cap: 25 000 (`AnnotationSnapper.cs:703`).
//   * Yield cap in QueryRect: 5 000 (`:786-811`).
//   * Skip zero-bbox leaves in QueryRect (:805) — LIVE walk keeps them for
//     prune decisions, but the flat sink is leaf-role only where a zero
//     bbox is AX noise.
//   * Don't recurse into `Label` or `Image` (:759-761) — but DO recurse
//     into `Hyperlink` so we can populate the hyperlinkHasImage /
//     hyperlinkHasText sidecars.
//   * Empty-bbox nodes still recurse (`:768-771`) — Chromium wrapper chains.

import CoreGraphics
import Foundation

/// Nodes-in-rect snapshot with the two ancestor sidecars Everywhere's
/// image-collect phase reads. Public so `WhiteboardSnapOrchestrator` can
/// build one on overlay show and pass it into `AnnotationSnapper.snap`.
public final class PrewarmedTree {
    /// DFS pre-order flat list of leaf-role nodes (`.label` / `.hyperlink`
    /// / `.image`) with the bbox we already fetched during the walk.
    /// Preserved order matches Everywhere `AnnotationSnapper.cs:649-651` —
    /// LeafAtPoint / NearestLeaf rely on rect prune + cap on top, so this
    /// is safe to iterate linearly at query time.
    public let nodes: [(node: AXVisualElement, bbox: CGRect)]

    /// Empty-text Hyperlinks that have an Image descendant. Precomputed
    /// during Build so the image-collect phase doesn't retraverse
    /// (`AnnotationSnapper.cs:731-750`).
    public let hyperlinkHasImage: Set<AXVisualElement>

    /// Empty-text Hyperlinks that have a text-bearing Label descendant.
    public let hyperlinkHasText: Set<AXVisualElement>

    /// True when Build() bailed at the 25k node cap. Callers should treat
    /// hyperlink sidecars as POTENTIALLY incomplete (`:660-664`).
    public let capHit: Bool

    public init(
        nodes: [(node: AXVisualElement, bbox: CGRect)],
        hyperlinkHasImage: Set<AXVisualElement>,
        hyperlinkHasText: Set<AXVisualElement>,
        capHit: Bool
    ) {
        self.nodes = nodes
        self.hyperlinkHasImage = hyperlinkHasImage
        self.hyperlinkHasText = hyperlinkHasText
        self.capHit = capHit
    }

    /// Build the flat node list + hyperlink sidecars in one rect-pruned
    /// walk. Total-visit cap is 25 000 to keep the walk under the 8-second
    /// safety window Everywhere's overlay uses
    /// (see `WhiteboardHotkeyInitializer.cs:440-458`).
    ///
    /// The `isCancelled` closure is polled after every recursion step so
    /// the caller can bail from the show-overlay path if the user commits
    /// their gesture before the prewarm finishes.
    public static func build(
        root: AXVisualElement,
        isCancelled: @escaping () -> Bool = { false }
    ) -> PrewarmedTree {
        // Constrain the walk to the focused window's own bbox. Off-screen
        // subtrees (long virtualised pages) get pruned at parent level,
        // freeing the 25k budget for the viewport
        // (`AnnotationSnapper.cs:684-695`).
        let rootBb = root.boundingRect
        let viewport: CGRect
        if rootBb.width > 0 && rootBb.height > 0 {
            viewport = rootBb
        } else {
            // Same "no-viewport" sentinel as Everywhere at :693-695 —
            // ~2e9 wide, centered on 0.
            viewport = CGRect(x: -1e9, y: -1e9, width: 2e9, height: 2e9)
        }
        var state = BuildState()
        Self.buildImpl(
            node: root,
            nodeBb: rootBb,
            expanded: viewport,
            ancestorHyperlink: nil,
            state: &state,
            cap: 25_000,
            isCancelled: isCancelled
        )
        return PrewarmedTree(
            nodes: state.nodes,
            hyperlinkHasImage: state.hyperlinkHasImage,
            hyperlinkHasText: state.hyperlinkHasText,
            capHit: state.capHit
        )
    }

    /// Filter the flat list to nodes whose bbox intersects `query`
    /// expanded by `slack`. 1:1 with `PrewarmedTree.QueryRect`
    /// (`AnnotationSnapper.cs:786-811`), including:
    ///   * `maxYield` cap of 5 000 (same shape as live walk).
    ///   * Skip zero-bbox nodes — see the file header for rationale.
    public func queryRect(_ query: CGRect, slack: CGFloat = 8.0, maxYield: Int = 5000)
        -> [(node: AXVisualElement, bbox: CGRect)]
    {
        let expanded = CGRect(
            x: query.origin.x - slack,
            y: query.origin.y - slack,
            width: query.width + 2 * slack,
            height: query.height + 2 * slack
        )
        var out: [(AXVisualElement, CGRect)] = []
        out.reserveCapacity(min(nodes.count, 256))
        for entry in nodes {
            if out.count >= maxYield { break }
            let bb = entry.bbox
            if bb.width <= 0 || bb.height <= 0 { continue }
            let inter = bb.intersection(expanded)
            if inter.isNull || inter.width <= 0 || inter.height <= 0 { continue }
            out.append(entry)
        }
        return out
    }

    // MARK: - Walk state
    //
    // Everywhere passes a bag of ref parameters through recursion; Swift's
    // inout-friendly variant is a single struct-ref parameter. Functionally
    // identical.

    private struct BuildState {
        var nodes: [(AXVisualElement, CGRect)] = []
        var visited: Set<AXVisualElement> = []
        var hyperlinkHasImage: Set<AXVisualElement> = []
        var hyperlinkHasText: Set<AXVisualElement> = []
        var capHit: Bool = false
    }

    /// Mirrors `AnnotationSnapper.PrewarmedTree.BuildImpl` (`:707-777`).
    private static func buildImpl(
        node: AXVisualElement,
        nodeBb: CGRect,
        expanded: CGRect,
        ancestorHyperlink: AXVisualElement?,
        state: inout BuildState,
        cap: Int,
        isCancelled: () -> Bool
    ) {
        // Cap on TOTAL visited (not sink size) — Arc has ~80k nodes but
        // only ~2k are leaf-role; capping by sink would let the walk run
        // uncapped through wrappers (`:716-718`).
        if state.visited.count >= cap { state.capHit = true; return }
        if isCancelled() { return }
        if !state.visited.insert(node).inserted { return }

        // Only emit leaf-role nodes into the sink (`:723-729`).
        switch node.type {
        case .label, .hyperlink, .image:
            state.nodes.append((node, nodeBb))
        case .other:
            break
        }

        // Ancestor tracking for the image-collect precompute
        // (`:731-750`). GetText may fail on transient AX nodes so we
        // wrap access in a fallback that returns "" when the underlying
        // read returns empty.
        var nextAncestor = ancestorHyperlink
        if node.type == .hyperlink && nextAncestor == nil {
            let sample = node.getText(maxLength: 1)
            if sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nextAncestor = node
            }
        }
        if let a = ancestorHyperlink {
            if node.type == .image {
                state.hyperlinkHasImage.insert(a)
            } else if node.type == .label {
                let sample = node.getText(maxLength: 1)
                if !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.hyperlinkHasText.insert(a)
                }
            }
        }

        // Don't recurse into Label or Image — per-glyph child explosion
        // (`:759-761`). DO recurse into Hyperlink so image descendants
        // inside <a><img> anchors get counted.
        if node.type == .label || node.type == .image { return }

        for child in node.children() {
            if isCancelled() { return }
            let cBb = child.boundingRect
            if cBb.width > 0 && cBb.height > 0 {
                let inter = cBb.intersection(expanded)
                if inter.isNull || inter.width <= 0 || inter.height <= 0 {
                    continue
                }
            }
            // Empty-bbox children (Chromium wrappers) still recurse.
            buildImpl(
                node: child,
                nodeBb: cBb,
                expanded: expanded,
                ancestorHyperlink: nextAncestor,
                state: &state,
                cap: cap,
                isCancelled: isCancelled
            )
        }
    }
}
