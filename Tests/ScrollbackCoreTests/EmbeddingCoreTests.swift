import XCTest
@testable import ScrollbackCore

/// The semantic-retrieval core: a deterministic embedder, int8 Matryoshka quantization,
/// and a brute-force vector index — the whole vector pipeline verified headless so the
/// real EmbeddingGemma + sqlite-vec drop into the seams unchanged.
final class EmbeddingCoreTests: XCTestCase {

    private let embedder = HashingEmbeddingProvider(dimension: 512)

    private func cosine(_ a: Embedding, _ b: Embedding) -> Float {
        zip(a.values, b.values).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    // MARK: - HashingEmbeddingProvider

    func testDeterministic() {
        let a = embedder.embed("the release checklist is complete", kind: .document)
        let b = embedder.embed("the release checklist is complete", kind: .document)
        XCTAssertEqual(a.values, b.values)
        XCTAssertEqual(a.dim, 512)
    }

    func testL2Normalized() {
        let e = embedder.embed("kubernetes pod crashloop in staging", kind: .document)
        let norm = e.values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
    }

    func testSimilarTextScoresHigherThanUnrelated() {
        let query = embedder.embed("kubernetes deployment", kind: .query)
        let related = embedder.embed("kubernetes pod crashloop in staging cluster", kind: .document)
        let unrelated = embedder.embed("lunch at the taco place downtown", kind: .document)
        XCTAssertGreaterThan(cosine(query, related), cosine(query, unrelated))
    }

    func testQueryAndMatchingDocumentStayClose() {
        // Regression: salting by kind would push a query and its answer into orthogonal
        // subspaces — they must share the term subspace and score > 0.
        let query = embedder.embed("pricing spreadsheet", kind: .query)
        let doc = embedder.embed("reviewed the quarterly pricing spreadsheet", kind: .document)
        XCTAssertGreaterThan(cosine(query, doc), 0.2)
    }

    func testEmptyTextIsZeroVector() {
        let e = embedder.embed("   ", kind: .document)
        XCTAssertTrue(e.values.allSatisfy { $0 == 0 })
    }

    // MARK: - Int8Quantizer

    func testQuantizeDequantizeRoundTripsApproximately() {
        let e = embedder.embed("quarterly revenue projections and headcount plan", kind: .document)
        let q = Int8Quantizer.quantize(e, dim: 512)
        let recovered = Int8Quantizer.dequantize(q)
        // Re-normalized truncation + int8 error stays small; cosine to the original ~1.
        let dot = zip(e.values, recovered).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(dot, 1.0, accuracy: 0.02)
        XCTAssertTrue(q.ints.allSatisfy { $0 >= -127 && $0 <= 127 }) // symmetric, never -128
    }

    func testQuantizedSimilarityPreservesOrdering() {
        let query = Int8Quantizer.quantize(embedder.embed("kubernetes deployment", kind: .query))
        let related = Int8Quantizer.quantize(embedder.embed("kubernetes crashloop staging", kind: .document))
        let unrelated = Int8Quantizer.quantize(embedder.embed("taco lunch downtown", kind: .document))
        XCTAssertGreaterThan(Int8Quantizer.similarity(query, related),
                             Int8Quantizer.similarity(query, unrelated))
    }

    func testIdenticalVectorsSimilarityNearOne() {
        let q = Int8Quantizer.quantize(embedder.embed("the same exact text", kind: .document))
        XCTAssertEqual(Int8Quantizer.similarity(q, q), 1.0, accuracy: 0.02)
    }

    func testSignedEmbeddingQuantizesAcrossFullInt8Range() {
        // The real EmbeddingGemma produces SIGNED vectors (the hashing fallback is
        // non-negative), so exercise the negative half of the int8 range explicitly.
        let signed = Embedding(values: [0.8, -0.6, 0.0, 0.1, -0.3], modelID: "signed-test")
        let q = Int8Quantizer.quantize(signed, dim: 5)
        XCTAssertTrue(q.ints.contains { $0 < 0 })  // negatives survive quantization
        XCTAssertTrue(q.ints.contains { $0 > 0 })
        XCTAssertEqual(Int8Quantizer.similarity(q, q), 1.0, accuracy: 0.02)
        // A near-opposite vector scores much lower than itself.
        let opposite = Int8Quantizer.quantize(Embedding(values: [-0.8, 0.6, 0.0, -0.1, 0.3], modelID: "signed-test"), dim: 5)
        XCTAssertLessThan(Int8Quantizer.similarity(q, opposite), Int8Quantizer.similarity(q, q))
    }

    func testMatryoshkaTruncationToSmallerDim() {
        let e = embedder.embed("matryoshka truncation keeps a valid prefix embedding", kind: .document)
        let q256 = Int8Quantizer.quantize(e, dim: 256)
        XCTAssertEqual(q256.dim, 256)
        XCTAssertEqual(Int8Quantizer.similarity(q256, q256), 1.0, accuracy: 0.02)
    }

    func testDimensionMismatchSimilarityIsZeroNotCrash() {
        let a = Int8Quantizer.quantize(embedder.embed("hello world", kind: .document), dim: 512)
        let b = Int8Quantizer.quantize(embedder.embed("hello world", kind: .document), dim: 256)
        XCTAssertEqual(Int8Quantizer.similarity(a, b), 0)
    }

    // MARK: - BruteForceVectorIndex

    func testIndexReturnsNearestFirst() {
        let index = BruteForceVectorIndex()
        let docs = [
            "kubernetes pod crashloop in staging",
            "reviewed the quarterly pricing spreadsheet",
            "lunch at the taco place downtown",
        ]
        var ids: [UUID] = []
        for doc in docs {
            let id = UUID()
            ids.append(id)
            index.add(id: id, vector: Int8Quantizer.quantize(embedder.embed(doc, kind: .document)))
        }
        XCTAssertEqual(index.count, 3)

        let query = Int8Quantizer.quantize(embedder.embed("pricing spreadsheet review", kind: .query))
        let hits = index.search(query, limit: 3)
        XCTAssertEqual(hits.first?.id, ids[1]) // the pricing doc ranks first
    }

    func testIndexDeterministicTieBreakAndLimit() {
        let index = BruteForceVectorIndex()
        // Two identical vectors → equal score → stable id tie-break; limit respected.
        let v = Int8Quantizer.quantize(embedder.embed("identical content here", kind: .document))
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        index.add(id: id2, vector: v)
        index.add(id: id1, vector: v)
        let hits = index.search(v, limit: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, id1) // lower uuidString wins the tie
    }

    func testEmptyIndexAndZeroLimit() {
        let index = BruteForceVectorIndex()
        let q = Int8Quantizer.quantize(embedder.embed("anything", kind: .query))
        XCTAssertTrue(index.search(q, limit: 5).isEmpty)
        index.add(id: UUID(), vector: q)
        XCTAssertTrue(index.search(q, limit: 0).isEmpty)
    }
}
