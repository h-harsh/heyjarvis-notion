import Foundation

/// Drives lazy embedding: pulls not-yet-embedded chunks from a store, embeds them as
/// documents, quantizes to int8, and persists the vectors. Called in small batches off
/// the capture-critical path (a background pass in the daemon, and a backlog-clear at
/// search time) so capture stays inside the <5% CPU budget — capture writes chunks with
/// NO vector; embedding happens after.
///
/// Model-swap-safe: it embeds under `provider.modelID` and `unembeddedChunks` keys on
/// that model, so pointing it at a new provider re-embeds everything under the new model
/// lazily (old-model vectors linger harmlessly until purged), never rewriting history.
public final class EmbeddingIndexer {
    private let provider: EmbeddingProvider
    private let dim: Int

    public init(provider: EmbeddingProvider, dim: Int = Int8Quantizer.defaultDim) {
        self.provider = provider
        // Matryoshka-truncate to at most the model's native width.
        self.dim = min(dim, provider.dimension)
    }

    public var modelID: String { provider.modelID }

    /// Embed up to `batchSize` not-yet-embedded chunks in one store (one shard).
    /// Returns how many were embedded — 0 means the shard's backlog is clear.
    @discardableResult
    public func indexBatch(in store: SQLiteCatalogStore, batchSize: Int = 64) throws -> Int {
        let pending = try store.unembeddedChunks(modelID: provider.modelID, limit: batchSize)
        for (id, text) in pending {
            let vector = Int8Quantizer.quantize(provider.embed(text, kind: .document), dim: dim)
            try store.insertVector(chunkID: id, vector)
        }
        return pending.count
    }

    /// Drain one store's backlog entirely (batches until nothing remains). Bounded by a
    /// max-rounds guard so a persist bug can't spin forever. Returns total embedded.
    @discardableResult
    public func indexAll(in store: SQLiteCatalogStore, batchSize: Int = 64, maxRounds: Int = 100_000) throws -> Int {
        var total = 0
        for _ in 0..<maxRounds {
            let n = try indexBatch(in: store, batchSize: batchSize)
            total += n
            if n < batchSize { break } // last (partial) batch → backlog clear
        }
        return total
    }

    /// Build the query-side quantized vector for a search text.
    public func queryVector(for text: String) -> QuantizedEmbedding {
        Int8Quantizer.quantize(provider.embed(text, kind: .query), dim: dim)
    }
}
