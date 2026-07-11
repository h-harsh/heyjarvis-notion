import Foundation

/// One recognized text run from Vision, reduced to what ordering needs: the
/// string plus the top and left of its bounding box in Vision's normalized,
/// bottom-left-origin coordinate space (so `top` = box `maxY`, and a larger
/// `top` is higher on screen). Keeping this a plain value type lets the
/// reading-order assembly be pure and unit-tested without a real image.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let top: Double
    public let left: Double

    public init(text: String, top: Double, left: Double) {
        self.text = text
        self.top = top
        self.left = left
    }
}

/// Orders Vision's text observations into natural reading order and joins them.
/// Vision returns line-level observations in no guaranteed order and in a
/// bottom-left-origin space, so we sort top-to-bottom (descending `top`) then
/// left-to-right (ascending `left`), bucketing observations whose tops fall
/// within `lineEpsilon` into the same visual line.
///
/// Pure + public so the risky ordering logic is regression-tested (the Vision
/// call itself needs pixels and a Screen Recording grant and can't run in CI).
public enum OCRTextAssembler {
    /// Normalized-coordinate tolerance for "same line". ~1.2% of window height
    /// keeps a single wrapped line together without merging separate rows.
    public static let lineEpsilon = 0.012

    public static func assemble(_ observations: [OCRObservation]) -> String {
        guard !observations.isEmpty else { return "" }

        // Sort by a STRICT WEAK ORDERING: `top` descending (higher on screen
        // first), ties broken by `left` ascending. A pairwise-epsilon comparator
        // would be intransitive (A~B, B~C, but A≠C when the span exceeds epsilon),
        // and Swift's `sorted(by:)` returns an unspecified permutation for a
        // non-strict-weak predicate — so line grouping is done separately below.
        let sorted = observations.sorted { a, b in
            a.top != b.top ? a.top > b.top : a.left < b.left
        }

        // Group into visual lines: a run joins the current line while its `top`
        // stays within `lineEpsilon` of the line's anchor (its topmost run);
        // anchoring to the first run — not a running value — stops gradual drift
        // from merging a whole staircase into one line.
        var lines: [[OCRObservation]] = [[sorted[0]]]
        var anchorTop = sorted[0].top
        for obs in sorted.dropFirst() {
            if abs(obs.top - anchorTop) <= lineEpsilon {
                lines[lines.count - 1].append(obs)
            } else {
                lines.append([obs])
                anchorTop = obs.top
            }
        }

        // Within a line, read left-to-right regardless of sub-pixel top jitter.
        return lines
            .map { line in line.sorted { $0.left < $1.left }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
