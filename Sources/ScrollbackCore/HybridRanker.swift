import Foundation

/// The retrieval-ranking POLICY, kept pure so it's provable without a database:
/// fuse several ranked candidate lists (BM25 keyword, recency, and — once embeddings
/// land — vector similarity) with Reciprocal Rank Fusion, then diversify the fused
/// order so a single chatty episode can't monopolize the results.
///
/// Candidate GENERATION (the SQL that produces each ranked list, plus the hard
/// time/app/entity pre-filters) lives in the store; this type only decides the final
/// order + shape. That split is what lets the DoD — "a one-episode-dominant query
/// returns diversified episodes" — be asserted deterministically in a unit test.
public struct HybridRanker: Sendable {
    /// RRF damping constant (higher → flatter contribution across ranks).
    public var k: Int
    /// Diversification cap: at most this many chunks per episode in the first pass.
    public var maxPerEpisode: Int

    public init(k: Int = 60, maxPerEpisode: Int = 3) {
        precondition(k > 0, "RRF constant k must be positive")
        precondition(maxPerEpisode > 0, "maxPerEpisode must be positive")
        self.k = k
        self.maxPerEpisode = maxPerEpisode
    }

    /// Fuse `rankedLists` (each best-first), then diversify by episode, returning up
    /// to `limit` `(id, fused score)` pairs best-first.
    ///
    /// Diversification is a soft cap: a first pass takes ≤ `maxPerEpisode` per
    /// episode in fused order; if that leaves slots and there are still candidates,
    /// a backfill pass fills them from the leftover fused order (cap relaxed) so a
    /// corpus with few episodes still returns `limit` results.
    public func rank<ID: Hashable, Episode: Hashable>(
        rankedLists: [[ID]],
        episodeOf: [ID: Episode],
        limit: Int
    ) -> [(id: ID, score: Double)] {
        guard limit > 0 else { return [] }

        let fused = RankFusion.reciprocalRankFusion(rankedLists: rankedLists, k: k)

        var chosen: [(id: ID, score: Double)] = []
        var perEpisode: [Episode: Int] = [:]
        var deferred: [(id: ID, score: Double)] = []

        // Pass 1 — respect the per-episode cap.
        for entry in fused {
            guard chosen.count < limit else { break }
            // A chunk with no known episode can't crowd an episode → always eligible.
            guard let episode = episodeOf[entry.id] else { chosen.append(entry); continue }
            if perEpisode[episode, default: 0] < maxPerEpisode {
                chosen.append(entry)
                perEpisode[episode, default: 0] += 1
            } else {
                deferred.append(entry)
            }
        }

        // Pass 2 — backfill any remaining slots from capped-out episodes, preserving
        // fused order.
        if chosen.count < limit {
            for entry in deferred where chosen.count < limit {
                chosen.append(entry)
            }
        }

        return chosen
    }
}
