import XCTest
@testable import ScrollbackCore

/// Vector persistence + lazy indexing + fused semantic search over the real SQLite
/// store (in-memory). Proves the pipeline the environment-blocked EmbeddingGemma will
/// drop into: chunks captured WITHOUT vectors, embedded lazily, then fused into search.
final class VectorPersistenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let embedder = HashingEmbeddingProvider(dimension: 512)

    /// Insert an episode + one event + one chunk carrying `text`; return the chunk id.
    @discardableResult
    private func seedChunk(_ store: SQLiteCatalogStore, text: String, at ts: Date,
                           app: String = "Safari", bundle: String = "com.apple.Safari") throws -> UUID {
        let episode = Episode(tsStart: ts, tsEnd: ts, bundleID: bundle, appName: app, windowTitle: "win")
        try store.insert(episode)
        let event = CaptureEvent(episodeID: episode.id, ts: ts, type: .screenText, source: .ax, rawText: text)
        try store.insert(event)
        let chunk = Chunk(episodeID: episode.id, eventID: event.id, text: text,
                          tokenCount: text.count, tsCapture: ts, source: .ax)
        try store.insert(chunk)
        return chunk.id
    }

    // MARK: - Schema + persistence

    func testMigrationTwoAddsVectorTableIdempotently() throws {
        let store = try SQLiteCatalogStore.inMemory()
        XCTAssertEqual(store.schemaVersion, CatalogSchema.currentVersion)
        XCTAssertGreaterThanOrEqual(CatalogSchema.currentVersion, 2)
        XCTAssertEqual(try store.count("chunk_vectors"), 0) // table exists, empty
    }

    func testVectorRoundTripsThroughBlob() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let id = try seedChunk(store, text: "quarterly pricing spreadsheet review", at: at(0))
        let vector = Int8Quantizer.quantize(embedder.embed("quarterly pricing spreadsheet review", kind: .document))

        try store.insertVector(chunkID: id, vector)
        XCTAssertEqual(try store.vectorCount(modelID: embedder.modelID), 1)

        // Re-embedding the same chunk REPLACES (no duplicate row).
        try store.insertVector(chunkID: id, vector)
        XCTAssertEqual(try store.vectorCount(modelID: embedder.modelID), 1)
    }

    // MARK: - Lazy indexer

    func testIndexerEmbedsOnlyUnembeddedChunks() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seedChunk(store, text: "kubernetes pod crashloop in staging", at: at(0))
        try seedChunk(store, text: "reviewed the quarterly pricing spreadsheet", at: at(1))
        let indexer = EmbeddingIndexer(provider: embedder)

        XCTAssertEqual(try indexer.indexAll(in: store), 2) // both embedded
        XCTAssertEqual(try store.vectorCount(modelID: embedder.modelID), 2)
        XCTAssertEqual(try indexer.indexAll(in: store), 0) // idempotent — nothing left
    }

    func testModelChangeReEmbedsEverything() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seedChunk(store, text: "release checklist complete", at: at(0))
        try EmbeddingIndexer(provider: HashingEmbeddingProvider(dimension: 512, modelID: "old")).indexAll(in: store)

        // A different model has no vectors for these chunks → all are "unembedded" for it.
        let newIndexer = EmbeddingIndexer(provider: HashingEmbeddingProvider(dimension: 512, modelID: "new"))
        XCTAssertEqual(try newIndexer.indexAll(in: store), 1)
    }

    // MARK: - Fused semantic search

    func testVectorListIsFusedIntoSearchResults() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seedChunk(store, text: "kubernetes pod crashloop in staging cluster", at: at(0))
        try seedChunk(store, text: "reviewed the quarterly pricing spreadsheet", at: at(1))
        try seedChunk(store, text: "lunch at the taco place downtown", at: at(2))
        let indexer = EmbeddingIndexer(provider: embedder)
        try indexer.indexAll(in: store)

        let queryVector = indexer.queryVector(for: "pricing spreadsheet")
        let results = try store.hybridSearch(MemoryQuery(text: "pricing spreadsheet", limit: 8), queryVector: queryVector)
        XCTAssertEqual(results.first?.text, "reviewed the quarterly pricing spreadsheet")
    }

    func testVectorSearchWorksWhenKeywordListIsEmpty() throws {
        // Query whose only tokens are stopwords/too-short → FTS returns nil; the vector
        // (+recency) list must still carry the query and return the semantic match.
        let store = try SQLiteCatalogStore.inMemory()
        try seedChunk(store, text: "kubernetes deployment rollout", at: at(0))
        let indexer = EmbeddingIndexer(provider: embedder)
        try indexer.indexAll(in: store)

        XCTAssertNil(SQLiteCatalogStore.ftsMatchQuery(from: "the on a")) // confirm FTS list is empty
        let queryVector = indexer.queryVector(for: "kubernetes deployment")
        let results = try store.hybridSearch(MemoryQuery(text: "the on a", limit: 8), queryVector: queryVector)
        XCTAssertEqual(results.first?.text, "kubernetes deployment rollout")
    }

    func testVectorCandidatesRespectHardTimeFilter() throws {
        // A semantically-matching chunk OUTSIDE the requested window must not leak in.
        let store = try SQLiteCatalogStore.inMemory()
        try seedChunk(store, text: "pricing spreadsheet review", at: at(0))          // old
        try seedChunk(store, text: "pricing spreadsheet review", at: at(100_000))    // in-window
        let indexer = EmbeddingIndexer(provider: embedder)
        try indexer.indexAll(in: store)

        let queryVector = indexer.queryVector(for: "pricing spreadsheet")
        let window = at(99_000)...at(101_000)
        let results = try store.hybridSearch(
            MemoryQuery(text: "pricing spreadsheet", timeRange: window, limit: 8), queryVector: queryVector
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.ts, at(100_000)) // only the in-window chunk
    }

    // MARK: - Cross-shard (ShardedCatalog)

    func testShardedCatalogIndexesAndFusesSemanticSearch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sb-vec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try ShardedCatalog(directory: dir, timeZone: TimeZone(identifier: "UTC")!)

        let ep = Episode(tsStart: at(0), tsEnd: at(0), bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "w")
        let ev = CaptureEvent(episodeID: ep.id, ts: at(0), type: .screenText, source: .ax,
                              rawText: "annual revenue projection meeting notes")
        let ch = Chunk(episodeID: ep.id, eventID: ev.id, text: "annual revenue projection meeting notes",
                       tokenCount: 6, tsCapture: at(0), source: .ax)
        try catalog.ingest(episode: ep, events: [ev], chunks: [ch])

        let indexer = EmbeddingIndexer(provider: embedder)
        XCTAssertEqual(try catalog.indexEmbeddings(indexer), 1)

        let queryVector = indexer.queryVector(for: "revenue projection")
        let results = try catalog.search(MemoryQuery(text: "revenue projection", limit: 8), queryVector: queryVector)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.text, "annual revenue projection meeting notes")
    }
}
