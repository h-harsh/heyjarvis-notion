import Foundation

/// A nearest-neighbor index over chunk embeddings — the vector KNN list that RRF-fuses
/// with FTS5 BM25 + recency (tech-spec ranking). The PRODUCTION implementation is
/// sqlite-vec (int8, per weekly shard); this protocol is the `RetrievalStore`-style
/// hedge (sqlite-vec is single-maintainer/pre-v1, swap targets usearch/Vec1). Feature
/// code ranks against THIS, never sqlite-vec directly.
public protocol VectorIndex: AnyObject {
    /// Insert or replace the vector for a chunk.
    func add(id: UUID, vector: QuantizedEmbedding)
    /// Top-`limit` chunk ids by descending similarity to `query`.
    func search(_ query: QuantizedEmbedding, limit: Int) -> [VectorMatch]
    var count: Int { get }
}

public struct VectorMatch: Sendable, Equatable {
    public let id: UUID
    public let score: Float
    public init(id: UUID, score: Float) {
        self.id = id
        self.score = score
    }
}

/// Exhaustive (brute-force) cosine search over an in-memory map. This is the pre-v1
/// vector index AND sqlite-vec's own fallback strategy: sqlite-vec brute-forces int8
/// too, and at personal scale it's fast (time-partitioned weekly shards bound the scan
/// — tech-spec defers the ANN swap to a MEASURED ~1M-vector trigger, not speculation).
///
/// Deterministic tie-break (score desc, then id) so rankings are reproducible for tests
/// and for RRF fusion. Not thread-safe by contract (confined to one actor/queue, like
/// the rest of the store).
public final class BruteForceVectorIndex: VectorIndex {
    private var vectors: [UUID: QuantizedEmbedding] = [:]

    public init() {}

    public var count: Int { vectors.count }

    public func add(id: UUID, vector: QuantizedEmbedding) {
        vectors[id] = vector
    }

    public func remove(id: UUID) {
        vectors[id] = nil
    }

    public func search(_ query: QuantizedEmbedding, limit: Int) -> [VectorMatch] {
        guard limit > 0, !vectors.isEmpty else { return [] }
        let scored = vectors.map { id, vector in
            VectorMatch(id: id, score: Int8Quantizer.similarity(query, vector))
        }
        // Descending score; id as a stable tie-break (uuidString) for determinism.
        return scored.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(limit)
        .map { $0 }
    }
}
