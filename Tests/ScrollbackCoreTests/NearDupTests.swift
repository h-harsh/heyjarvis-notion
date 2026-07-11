import XCTest
@testable import ScrollbackCore

/// Guards the MinHash near-dup collapse that runs pre-embedding: exact-hash dedup
/// catches byte-identical re-reads, this catches the scrolled / lightly-edited
/// re-read that would otherwise burn the embedding + vector budget twice.
final class NearDupTests: XCTestCase {

    // Deterministic word-namespace docs so shingle sets are controllable.
    private func doc(_ namespace: String, words: Int) -> String {
        (0..<words).map { "\(namespace)\($0)" }.joined(separator: " ")
    }

    // MARK: MinHasher — determinism & Jaccard estimation

    func testSignatureIsDeterministicAcrossInstances() {
        let text = doc("a", words: 40)
        let sigA = MinHasher().signature(for: text)
        let sigB = MinHasher().signature(for: text) // fresh instance, same fixed seed
        XCTAssertEqual(sigA, sigB)
        XCTAssertEqual(sigA.count, 128)
    }

    func testIdenticalTextIsJaccardOne() {
        let hasher = MinHasher()
        let sig = hasher.signature(for: doc("a", words: 30))
        XCTAssertEqual(MinHasher.estimatedJaccard(sig, sig), 1.0, accuracy: 1e-9)
    }

    func testDisjointTextIsJaccardNearZero() {
        let hasher = MinHasher()
        let lhs = hasher.signature(for: doc("a", words: 40))
        let rhs = hasher.signature(for: doc("b", words: 40)) // no shared words → no shared shingles
        XCTAssertLessThan(MinHasher.estimatedJaccard(lhs, rhs), 0.05)
    }

    func testEstimateTracksTrueJaccard() {
        // Two docs sharing exactly half their shingles should estimate ~0.33
        // (|A∩B| / |A∪B| = s / (2·s − s) where overlap = s of each 2s union... )
        // Use a concrete overlap: 60-word docs sharing a 40-word prefix.
        let shared = doc("s", words: 40)
        let lhs = shared + " " + doc("x", words: 20)
        let rhs = shared + " " + doc("y", words: 20)
        let hasher = MinHasher()
        let est = MinHasher.estimatedJaccard(hasher.signature(for: lhs), hasher.signature(for: rhs))
        // True Jaccard is well within (0.35, 0.75); the estimate must land in-band,
        // proving it's neither ~0 (missed overlap) nor ~1 (false identity).
        XCTAssertGreaterThan(est, 0.30)
        XCTAssertLessThan(est, 0.80)
    }

    func testShortTextStillSignaturesAndMatches() {
        let hasher = MinHasher() // shingleSize 3, but these are 2-word texts
        let sig1 = hasher.signature(for: "hello world")
        let sig2 = hasher.signature(for: "hello world")
        let sig3 = hasher.signature(for: "goodbye moon")
        XCTAssertEqual(MinHasher.estimatedJaccard(sig1, sig2), 1.0, accuracy: 1e-9)
        XCTAssertLessThan(MinHasher.estimatedJaccard(sig1, sig3), 0.05)
    }

    func testEmptyTextSignatureMatchesOnlyEmpties() {
        let hasher = MinHasher()
        let empty1 = hasher.signature(for: "   ")
        let empty2 = hasher.signature(for: "")
        XCTAssertEqual(MinHasher.estimatedJaccard(empty1, empty2), 1.0, accuracy: 1e-9)
        XCTAssertLessThan(MinHasher.estimatedJaccard(empty1, hasher.signature(for: doc("a", words: 30))), 0.05)
    }

    // MARK: NearDupCollapser — collapse behavior

    func testScrolledRereadCollapsesIntoOriginal() {
        let collapser = NearDupCollapser()
        let base = doc("a", words: 40)
        XCTAssertEqual(collapser.add(base), .unique(index: 0))
        // "Scrolling" appends a couple more words — >0.9 Jaccard, must collapse.
        if case .duplicate(let of, let j) = collapser.add(base + " a40 a41") {
            XCTAssertEqual(of, 0)
            XCTAssertGreaterThanOrEqual(j, 0.85)
        } else {
            XCTFail("scrolled re-read should collapse into the original")
        }
        XCTAssertEqual(collapser.retained, 1)
        XCTAssertEqual(collapser.collapsed, 1)
    }

    func testDistinctDocsAreAllRetained() {
        let collapser = NearDupCollapser()
        for namespace in ["a", "b", "c", "d"] {
            XCTAssertEqual(collapser.add(doc(namespace, words: 40)).isUnique, true)
        }
        XCTAssertEqual(collapser.retained, 4)
        XCTAssertEqual(collapser.collapsed, 0)
    }

    func testBelowThresholdEditIsRetainedNotCollapsed() {
        // ~50% shingle overlap is below the 0.85 gate → must be treated as distinct.
        let collapser = NearDupCollapser()
        let shared = doc("s", words: 30)
        _ = collapser.add(shared + " " + doc("x", words: 30))
        let result = collapser.add(shared + " " + doc("y", words: 30))
        XCTAssertEqual(result.isUnique, true)
        XCTAssertEqual(collapser.retained, 2)
    }

    func testThresholdIsConfigurable() {
        // A permissive threshold collapses a ~one-third-overlap pair the default
        // keeps. Banding is widened (rows=1) so the low-Jaccard candidate surfaces
        // at all — otherwise the LSH pre-filter, not the threshold, would gate it.
        let collapser = NearDupCollapser(config: NearDupConfig(permutations: 128, bands: 128, threshold: 0.2))
        let shared = doc("s", words: 30)
        _ = collapser.add(shared + " " + doc("x", words: 30))
        let result = collapser.add(shared + " " + doc("y", words: 30))
        XCTAssertEqual(result.isUnique, false)
    }

    func testFirstSeenWinsAsRepresentative() {
        let collapser = NearDupCollapser()
        _ = collapser.add(doc("a", words: 40))          // index 0
        _ = collapser.add(doc("a", words: 40) + " a40")  // collapses into 0, NOT retained
        // A third scrolled variant must still collapse into 0 (the original), proving
        // the collapsed variant was never indexed as a new representative.
        if case .duplicate(let of, _) = collapser.add(doc("a", words: 40) + " a40 a41 a42") {
            XCTAssertEqual(of, 0)
        } else {
            XCTFail("should collapse into the original representative")
        }
        XCTAssertEqual(collapser.retained, 1)
        XCTAssertEqual(collapser.collapsed, 2)
    }

    // MARK: DoD — repetitive fixture shows a substantial volume cut

    func testRepetitiveStreamCutsVolume() {
        // A realistic mix: 10 distinct documents, each re-read as it "scrolls"
        // (1–2 near-variants). 10 originals + 15 near-dups = 25 offered, 10 retained.
        let collapser = NearDupCollapser()
        var offered = 0
        let namespaces = (0..<10).map { "n\($0)" }
        for (i, namespace) in namespaces.enumerated() {
            let base = doc(namespace, words: 50)
            _ = collapser.add(base); offered += 1
            _ = collapser.add(base + " \(namespace)50"); offered += 1                 // scroll +1
            if i < 5 { _ = collapser.add(base + " \(namespace)50 \(namespace)51"); offered += 1 } // scroll +2
        }
        XCTAssertEqual(offered, 25)
        XCTAssertEqual(collapser.retained, 10)
        let cut = Double(collapser.collapsed) / Double(offered)
        XCTAssertGreaterThanOrEqual(cut, 0.5) // DoD: 50–70% cut on a repetitive stream
        XCTAssertLessThanOrEqual(cut, 0.7)
    }
}

private extension NearDupResult {
    var isUnique: Bool { if case .unique = self { return true }; return false }
}
