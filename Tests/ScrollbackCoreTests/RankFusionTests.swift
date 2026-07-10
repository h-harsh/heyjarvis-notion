import XCTest
@testable import ScrollbackCore

final class RankFusionTests: XCTestCase {

    /// Single list: scores are exactly 1/(k+rank), order preserved.
    func testSingleListExactScores() {
        let fused = RankFusion.reciprocalRankFusion(rankedLists: [["a", "b", "c"]], k: 60)

        XCTAssertEqual(fused.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(fused[0].score, 1.0 / 61.0, accuracy: 1e-12)
        XCTAssertEqual(fused[1].score, 1.0 / 62.0, accuracy: 1e-12)
        XCTAssertEqual(fused[2].score, 1.0 / 63.0, accuracy: 1e-12)
    }

    /// Two lists fuse additively; ties break deterministically by id description.
    ///
    /// keyword: [x, y, z]  → x@1, y@2, z@3
    /// vector:  [y, x, w]  → y@1, x@2, w@3
    /// x and y both score 1/61 + 1/62 (tie → "x" < "y"); z and w both score 1/63
    /// (tie → "w" < "z"). Expected fused order: x, y, w, z.
    func testTwoListsFuseAndTieBreak() {
        let fused = RankFusion.reciprocalRankFusion(
            rankedLists: [["x", "y", "z"], ["y", "x", "w"]],
            k: 60
        )

        XCTAssertEqual(fused.map(\.id), ["x", "y", "w", "z"])

        let topExpected = 1.0 / 61.0 + 1.0 / 62.0
        XCTAssertEqual(fused[0].score, topExpected, accuracy: 1e-12)
        XCTAssertEqual(fused[1].score, topExpected, accuracy: 1e-12)
        XCTAssertEqual(fused[2].score, 1.0 / 63.0, accuracy: 1e-12)
        XCTAssertEqual(fused[3].score, 1.0 / 63.0, accuracy: 1e-12)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(RankFusion.reciprocalRankFusion(rankedLists: [] as [[String]]).isEmpty)
        XCTAssertTrue(RankFusion.reciprocalRankFusion(rankedLists: [[]] as [[String]]).isEmpty)
    }
}
