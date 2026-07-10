import Foundation

/// Reciprocal Rank Fusion — merges several ranked lists (e.g. BM25 keyword,
/// vector similarity, recency) into one ranking without having to calibrate
/// their incompatible score scales.
///
///     score(item) = Σ over lists of  1 / (k + rank)
///
/// where `rank` is 1-based within each list and higher fused score ranks first.
/// `k = 60` is the standard constant. This is the retrieval-ranking primitive
/// referenced in tech-spec.md §1 (D5) and docs/decisions.md.
public enum RankFusion {

    /// - Parameters:
    ///   - rankedLists: each inner array is one ranked list, best-first. An item
    ///     may appear in any subset of the lists; missing = no contribution.
    ///   - k: RRF damping constant (must be > 0). Default 60.
    /// - Returns: items sorted by fused score, best-first. Ties break by a stable
    ///   ordering of the id's description, so output is deterministic.
    public static func reciprocalRankFusion<ID: Hashable>(
        rankedLists: [[ID]],
        k: Int = 60
    ) -> [(id: ID, score: Double)] {
        precondition(k > 0, "RRF constant k must be positive")

        var scores: [ID: Double] = [:]
        for list in rankedLists {
            for (index, id) in list.enumerated() {
                let rank = index + 1
                scores[id, default: 0] += 1.0 / Double(k + rank)
            }
        }

        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return String(describing: lhs.key) < String(describing: rhs.key)
                }
                return lhs.value > rhs.value
            }
            .map { (id: $0.key, score: $0.value) }
    }
}
