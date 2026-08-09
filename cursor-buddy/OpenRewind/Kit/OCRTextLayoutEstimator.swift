// OCRTextLayoutEstimator.swift — heuristic character-width layout
// estimator ported from retrace (`SimpleTimelineViewModel.swift:85`).
// Used to compute sub-bbox regions for highlighting a substring
// inside an OCR node without re-running Vision.

import Foundation

public enum OpenRewindOCRTextLayoutEstimator {

    private static let narrowChars = Set("ilIjtf|!,:;.`'".map(\.self))
    private static let mediumNarrow = Set("[](){}\\/".map(\.self))
    private static let wideChars = Set("MW@%&QGODmwo".map(\.self))
    private static let mediumWide = Set("ABHNUVXY02345689#".map(\.self))

    /// Returns `(start, end)` fractions in `[0, 1]` mapping the given
    /// character range onto the node's normalized bounding box.
    public static func spanFractions(
        in text: String,
        start: Int,
        end: Int
    ) -> (start: CGFloat, end: CGFloat) {
        let chars = Array(text)
        guard !chars.isEmpty else { return (0, 1) }
        let clampedStart = min(max(start, 0), max(chars.count - 1, 0))
        let clampedEnd = min(max(end, clampedStart + 1), chars.count)
        let cumulative = cumulativeWidths(chars)
        let total = max(cumulative.last ?? 0, 1)
        let startW = cumulative[clampedStart]
        let endW = cumulative[clampedEnd]
        let minSpan = max(width(chars[clampedStart]) * 0.75, 0.01)
        let clampedEndW = min(max(endW, startW + minSpan), total)
        return (startW / total, clampedEndW / total)
    }

    private static func width(_ c: Character) -> CGFloat {
        if narrowChars.contains(c) { return 0.4 }
        if mediumNarrow.contains(c) { return 0.7 }
        if wideChars.contains(c) { return 1.3 }
        if mediumWide.contains(c) { return 1.15 }
        if c.isWhitespace { return 0.35 }
        return 1.0
    }

    private static func cumulativeWidths(_ chars: [Character]) -> [CGFloat] {
        var out = [CGFloat](repeating: 0, count: chars.count + 1)
        var running: CGFloat = 0
        for (i, c) in chars.enumerated() {
            running += width(c)
            out[i + 1] = running
        }
        return out
    }
}
