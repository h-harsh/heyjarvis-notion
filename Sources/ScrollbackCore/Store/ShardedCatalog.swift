import Foundation

/// The weekly-shard store: a directory of per-ISO-week `SQLiteCatalogStore` files.
/// Writes route to the shard of the episode's start week (an episode + its events +
/// chunks live together in ONE shard so foreign keys never cross files); reads fan
/// out across the shards a query's time range touches and fuse with `HybridRanker`;
/// purge is whole-file deletion of the weeks before a cutoff — instant + provable.
///
/// Encryption is a pass-through: the `key` is handed to every shard's
/// `SQLiteCatalogStore` (the single `PRAGMA key` seam), so turning on SQLCipher
/// changes nothing here.
///
/// Synchronous-by-contract like `SQLiteCatalogStore` (confine to one actor/queue).
/// The async `RetrievalStore` conformance is a thin actor wrapper added at live
/// wiring — this owns the shard topology + fan-out, which is what needed building.
public final class ShardedCatalog {
    private let directory: URL
    private let key: String?
    private let calendar: WeekShardCalendar
    private var open: [WeekShard: SQLiteCatalogStore] = [:]

    public init(directory: URL, key: String? = nil, timeZone: TimeZone = .current) throws {
        self.directory = directory
        self.key = key
        self.calendar = WeekShardCalendar(timeZone: timeZone)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Writes (episode-atomic placement)

    /// Persist a whole episode into the shard of its start week. Events + chunks go
    /// to the SAME shard as the episode regardless of their own timestamps — an
    /// episode is one contiguous span and must not split across files (cross-file
    /// FKs don't exist).
    public func ingest(episode: Episode, events: [CaptureEvent], chunks: [Chunk]) throws {
        let store = try store(for: calendar.shard(for: episode.tsStart))
        try store.insert(episode)
        for event in events { try store.insert(event) }
        for chunk in chunks { try store.insert(chunk) }
    }

    // MARK: - Reads (fan out + fuse)

    /// Hybrid search across every shard the query's time range touches, fused into
    /// one ranking. For a time-scoped query this is usually one or two shards; for an
    /// unscoped query it's all of them. Each shard returns a self-contained ranked
    /// `[SearchResult]` (metadata included); those per-shard orderings are re-fused
    /// via RRF + diversified, so a single-shard query is identical to querying that
    /// shard directly.
    public func search(
        _ query: MemoryQuery,
        ranker: HybridRanker = HybridRanker(),
        queryVector: QuantizedEmbedding? = nil
    ) throws -> [SearchResult] {
        let shards = calendar.shards(intersecting: query.timeRange, among: try existingShards())
        guard !shards.isEmpty else { return [] }

        if shards.count == 1 {
            return try store(for: shards[0]).hybridSearch(query, ranker: ranker, queryVector: queryVector)
        }

        var resultByID: [String: SearchResult] = [:]
        var rankedLists: [[String]] = []
        var episodeOf: [String: String] = [:]
        for shard in shards {
            let hits = try store(for: shard).hybridSearch(query, ranker: ranker, queryVector: queryVector)
            rankedLists.append(hits.map { $0.chunkID.uuidString })
            for hit in hits {
                resultByID[hit.chunkID.uuidString] = hit
                episodeOf[hit.chunkID.uuidString] = hit.episodeID.uuidString
            }
        }

        let fused = ranker.rank(rankedLists: rankedLists.filter { !$0.isEmpty }, episodeOf: episodeOf, limit: query.limit)
        return fused.compactMap { entry -> SearchResult? in
            guard let hit = resultByID[entry.id] else { return nil }
            // Carry the cross-shard fused score.
            return SearchResult(chunkID: hit.chunkID, episodeID: hit.episodeID, text: hit.text,
                                score: entry.score, source: hit.source, provenance: hit.provenance, ts: hit.ts)
        }
    }

    // MARK: - Embedding (lazy, cross-shard)

    /// Embed not-yet-embedded chunks across every shard (the background/backlog pass).
    /// Returns the total number embedded. Confined to this catalog's single actor/queue
    /// like every other method — capture and indexing must not touch the store from two
    /// threads.
    @discardableResult
    public func indexEmbeddings(_ indexer: EmbeddingIndexer, batchSize: Int = 64) throws -> Int {
        var total = 0
        for shard in try existingShards() {
            total += try indexer.indexAll(in: store(for: shard), batchSize: batchSize)
        }
        return total
    }

    // MARK: - Purge (whole-file delete — the provable erase)

    /// Delete every shard file whose entire week is before `cutoff`. Returns the
    /// dropped shards. This is the privacy claim: "delete everything before X" is a
    /// file unlink, not a row scan — instant and provable.
    @discardableResult
    public func purge(before cutoff: Date) throws -> [WeekShard] {
        let dropped = calendar.droppable(before: cutoff, among: try existingShards())
        for shard in dropped {
            open[shard] = nil // release our handle so the DB closes before unlink
            for path in shardFilePaths(shard) {
                try? FileManager.default.removeItem(at: path) // .sqlite + -wal + -shm
            }
        }
        return dropped
    }

    // MARK: - Introspection

    /// Shards currently on disk (parsed from filenames), sorted oldest-first.
    public func existingShards() throws -> [WeekShard] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name in
            name.hasSuffix(".sqlite") ? WeekShard.from(id: name) : nil
        }.sorted()
    }

    // MARK: - Shard handles

    private func store(for shard: WeekShard) throws -> SQLiteCatalogStore {
        if let existing = open[shard] { return existing }
        let store = try SQLiteCatalogStore(path: fileURL(shard).path, key: key)
        open[shard] = store
        return store
    }

    private func fileURL(_ shard: WeekShard) -> URL {
        directory.appendingPathComponent(shard.fileName)
    }

    /// The DB file plus SQLite's WAL/SHM sidecars (`<db>-wal`, `<db>-shm`).
    private func shardFilePaths(_ shard: WeekShard) -> [URL] {
        let base = fileURL(shard).path
        return [base, base + "-wal", base + "-shm"].map { URL(fileURLWithPath: $0) }
    }
}
