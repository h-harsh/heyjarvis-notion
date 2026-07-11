import XCTest
@testable import ScrollbackCore

/// Guards the pure ranking POLICY: RRF fusion + per-episode diversification with
/// backfill. The store's SQL candidate generation is exercised separately in
/// HybridSearchTests; here the fusion/diversification behavior is proven with no DB.
final class HybridRankerTests: XCTestCase {

    private func ids(_ ranked: [(id: String, score: Double)]) -> [String] { ranked.map { $0.id } }

    func testFusionRanksSharedItemsHigher() {
        let ranker = HybridRanker()
        let ranked = ranker.rank(
            rankedLists: [["x", "y", "z"], ["x", "y"]],
            episodeOf: [String: String](), // distinct/unknown episodes → no diversification pressure
            limit: 3
        )
        XCTAssertEqual(ids(ranked), ["x", "y", "z"]) // x in both lists at rank 1 → top
        // Scores are the RRF sums, strictly descending here.
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
        XCTAssertGreaterThan(ranked[1].score, ranked[2].score)
    }

    func testDiversificationPromotesOtherEpisode() {
        // Episode A dominates the fused list; a single B item sits last. With a cap
        // of 2, B must be pulled into a limit-3 result over A's 3rd/4th/5th chunk.
        let ranker = HybridRanker(maxPerEpisode: 2)
        let fusedOrder = ["a1", "a2", "a3", "a4", "a5", "b1"]
        let episodeOf = ["a1": "A", "a2": "A", "a3": "A", "a4": "A", "a5": "A", "b1": "B"]
        let ranked = ranker.rank(rankedLists: [fusedOrder], episodeOf: episodeOf, limit: 3)
        XCTAssertEqual(ids(ranked), ["a1", "a2", "b1"]) // not a1,a2,a3 — B diversifies in
    }

    func testBackfillWhenTooFewEpisodes() {
        // Only episode A exists; a cap of 2 must not starve a limit-4 request —
        // backfill relaxes the cap to fill remaining slots in fused order.
        let ranker = HybridRanker(maxPerEpisode: 2)
        let fusedOrder = ["a1", "a2", "a3", "a4", "a5"]
        let episodeOf = ["a1": "A", "a2": "A", "a3": "A", "a4": "A", "a5": "A"]
        let ranked = ranker.rank(rankedLists: [fusedOrder], episodeOf: episodeOf, limit: 4)
        XCTAssertEqual(ids(ranked), ["a1", "a2", "a3", "a4"]) // capped pass then backfill
    }

    func testLimitIsRespected() {
        let ranker = HybridRanker()
        let ranked = ranker.rank(rankedLists: [["a", "b", "c", "d"]], episodeOf: [String: String](), limit: 2)
        XCTAssertEqual(ids(ranked), ["a", "b"])
    }

    func testZeroLimitReturnsEmpty() {
        XCTAssertTrue(HybridRanker().rank(rankedLists: [["a"]], episodeOf: [String: String](), limit: 0).isEmpty)
    }

    func testUnknownEpisodeItemsAreAlwaysEligible() {
        // Items with no episode mapping never count against a cap.
        let ranker = HybridRanker(maxPerEpisode: 1)
        let ranked = ranker.rank(
            rankedLists: [["u1", "u2", "u3"]],
            episodeOf: [String: String](), // all unknown
            limit: 3
        )
        XCTAssertEqual(ids(ranked), ["u1", "u2", "u3"])
    }
}
