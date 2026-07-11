import Foundation

/// Hybrid retrieval over the catalog: hard time/app/entity pre-filters in SQL, then
/// Reciprocal Rank Fusion of a BM25 keyword list and a recency list, then
/// per-episode diversification (`HybridRanker`). Vector similarity slots in as a
/// third fused list once embeddings land — the fusion + diversification policy does
/// not change.
///
/// Synchronous like the rest of the store (confine to one actor/queue). The async
/// `RetrievalStore.search` conformance is a thin actor wrapper added when the store
/// is wired as the live sink (alongside encryption); the retrieval BEHAVIOR is fully
/// exercised here against an in-memory DB.
extension SQLiteCatalogStore {

    /// Hard ceiling on results per query — a recall returning more than this is
    /// nonsensical, and the clamp keeps the `IN(...)` bind-list far under SQLite's
    /// variable cap and the pool multiply overflow-safe.
    static let maxResultLimit = 200

    /// Vector candidates below this cosine are NOT real semantic matches — brute-force
    /// KNN always returns *some* nearest neighbor, so without a floor a no-match query
    /// returns its least-dissimilar (irrelevant) chunks. Tuned for the lexical hashing
    /// FALLBACK: large captured chunks (a full page of text) collide with a short query
    /// in enough hash buckets to reach ~0.1–0.2 by chance, so the floor sits above that
    /// — a genuine word-overlap match scores higher (~0.35+). The real EmbeddingGemma is
    /// collision-free dense vectors and wants its OWN (lower) floor — retune on swap.
    static let minVectorSimilarity: Float = 0.3

    public func hybridSearch(
        _ query: MemoryQuery,
        ranker: HybridRanker = HybridRanker(),
        queryVector: QuantizedEmbedding? = nil,
        candidatePool: Int? = nil
    ) throws -> [SearchResult] {
        // Clamp the caller-supplied limit at the retrieval boundary (no upstream
        // clamp exists yet). This keeps the IN(...) bind-list well under SQLite's
        // variable cap AND avoids a trapping Int-overflow in the `limit * 5` pool
        // multiply on an absurd limit — a latent crash on the public API.
        let limit = min(max(query.limit, 0), Self.maxResultLimit)
        guard limit > 0 else { return [] }
        let pool = candidatePool ?? max(limit * 5, 50)
        let filters = buildFilters(query)

        let ftsIDs = try ftsCandidates(query.text, filters: filters, limit: pool)
        // Vector KNN slots in as a third RRF list (tech-spec ranking) when the caller
        // supplies an embedded query; the fusion + diversification policy is unchanged.
        // Thresholded so a query with no real semantic match doesn't return its
        // least-dissimilar neighbors as if they were hits.
        let vectorIDs = try queryVector.map {
            try vectorCandidates(queryVector: $0, filters: filters, limit: pool)
        } ?? []

        // Recency is a BROWSE list ("what did I do today"), not a content-match source:
        // include it only for a pure browse (no usable query terms) or an explicitly
        // time-scoped query. For a content query with real terms, keyword + vector must
        // carry — otherwise the most-recent captures flood in as false matches (a real
        // query for "kubernetes" surfacing an unrelated recent page).
        let isBrowse = Self.ftsMatchQuery(from: query.text) == nil || query.timeRange != nil
        let recencyIDs = isBrowse ? try recencyCandidates(filters: filters, limit: pool) : []

        // Map every candidate to its episode for diversification.
        var episodeOf: [String: String] = [:]
        for (chunkID, episodeID) in ftsIDs { episodeOf[chunkID] = episodeID }
        for (chunkID, episodeID) in recencyIDs { episodeOf[chunkID] = episodeID }
        for (chunkID, episodeID) in vectorIDs { episodeOf[chunkID] = episodeID }

        let rankedLists = [ftsIDs.map { $0.chunkID }, recencyIDs.map { $0.chunkID }, vectorIDs.map { $0.chunkID }]
            .filter { !$0.isEmpty }
        guard !rankedLists.isEmpty else { return [] }

        let ranked = ranker.rank(rankedLists: rankedLists, episodeOf: episodeOf, limit: limit)
        guard !ranked.isEmpty else { return [] }

        let metadata = try fetchResultMetadata(ids: ranked.map { $0.id })
        return ranked.compactMap { entry in
            guard var result = metadata[entry.id] else { return nil }
            result.score = entry.score
            return result.searchResult
        }
    }

    // MARK: - Candidate lists

    private func ftsCandidates(
        _ text: String, filters: FilterClause, limit: Int
    ) throws -> [(chunkID: String, episodeID: String)] {
        guard let match = Self.ftsMatchQuery(from: text) else { return [] }
        var sql = """
        SELECT c.id, c.episode_id FROM chunks_fts f
        JOIN chunks c ON c.rowid = f.rowid
        JOIN episodes e ON e.id = c.episode_id
        WHERE chunks_fts MATCH ?
        """
        if !filters.sql.isEmpty { sql += " AND " + filters.sql }
        sql += " ORDER BY rank LIMIT ?"

        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll([.text(match)] + filters.params + [.int(Int64(limit))])
        return try collectIDPairs(statement)
    }

    private func recencyCandidates(
        filters: FilterClause, limit: Int
    ) throws -> [(chunkID: String, episodeID: String)] {
        var sql = """
        SELECT c.id, c.episode_id FROM chunks c
        JOIN episodes e ON e.id = c.episode_id
        """
        if !filters.sql.isEmpty { sql += " WHERE " + filters.sql }
        sql += " ORDER BY c.ts_capture DESC LIMIT ?"

        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(filters.params + [.int(Int64(limit))])
        return try collectIDPairs(statement)
    }

    private func collectIDPairs(_ statement: Statement) throws -> [(chunkID: String, episodeID: String)] {
        var out: [(String, String)] = []
        while try statement.step() { out.append((statement.text(0), statement.text(1))) }
        return out
    }

    /// Vector-KNN candidates: brute-force cosine of `queryVector` against every stored
    /// vector for its model that ALSO passes the hard pre-filters (time/app/entity are
    /// applied in SQL first, so a semantic hit outside the requested window can't leak
    /// in). Returns the top `limit` chunk ids, similarity-descending, chunkId as a
    /// deterministic tie-break. Only same-model vectors are compared (dimension match);
    /// cross-model rows are excluded by the `model_id` predicate.
    private func vectorCandidates(
        queryVector: QuantizedEmbedding, filters: FilterClause, limit: Int
    ) throws -> [(chunkID: String, episodeID: String)] {
        var sql = """
        SELECT v.chunk_id, c.episode_id, v.dim, v.scale, v.embedding
        FROM chunk_vectors v
        JOIN chunks c ON c.id = v.chunk_id
        JOIN episodes e ON e.id = c.episode_id
        WHERE v.model_id = ?
        """
        if !filters.sql.isEmpty { sql += " AND " + filters.sql }

        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll([.text(queryVector.modelID)] + filters.params)

        var scored: [(chunkID: String, episodeID: String, score: Float)] = []
        while try statement.step() {
            let dim = Int(statement.int(2))
            let bytes = statement.blob(4)
            guard bytes.count == dim else { continue } // corrupt/legacy row — skip, don't crash
            let stored = QuantizedEmbedding(
                ints: Self.decodeInt8Vector(bytes),
                scale: Float(statement.double(3)),
                modelID: queryVector.modelID
            )
            let score = Int8Quantizer.similarity(queryVector, stored)
            guard score >= Self.minVectorSimilarity else { continue } // not a real match — drop
            scored.append((statement.text(0), statement.text(1), score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.chunkID < $1.chunkID }
        return scored.prefix(limit).map { ($0.chunkID, $0.episodeID) }
    }

    // MARK: - Result metadata (join events for provenance)

    private struct RawResult {
        let chunkID: UUID, episodeID: UUID, text: String
        var score: Double
        let source: CaptureSource, provenance: Provenance, ts: Date

        var searchResult: SearchResult {
            SearchResult(chunkID: chunkID, episodeID: episodeID, text: text,
                         score: score, source: source, provenance: provenance, ts: ts)
        }
    }

    private func fetchResultMetadata(ids: [String]) throws -> [String: RawResult] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let statement = try db.prepare(
            """
            SELECT c.id, c.episode_id, c.text, c.ts_capture, c.source, ev.provenance
            FROM chunks c JOIN events ev ON ev.id = c.event_id
            WHERE c.id IN (\(placeholders))
            """
        )
        defer { statement.finalize() }
        try statement.bindAll(ids.map(SQLiteValue.text))

        var out: [String: RawResult] = [:]
        while try statement.step() {
            let chunkIDText = statement.text(0)
            guard let chunkID = UUID(uuidString: chunkIDText),
                  let episodeID = UUID(uuidString: statement.text(1)) else { continue }
            out[chunkIDText] = RawResult(
                chunkID: chunkID,
                episodeID: episodeID,
                text: statement.text(2),
                score: 0,
                source: CaptureSource(rawValue: statement.text(4)) ?? .ax,
                // Fail safe to the MORE restrictive label if somehow unknown — an
                // untrusted span must never be mislabelled as trusted.
                provenance: Provenance(rawValue: statement.text(5)) ?? .untrustedAmbient,
                ts: Date(timeIntervalSince1970: statement.double(3))
            )
        }
        return out
    }

    // MARK: - Pre-filters

    struct FilterClause { let sql: String; let params: [SQLiteValue] }

    /// Hard pre-filters (time/app/entity), ANDed. Applied to a `chunks c JOIN
    /// episodes e` base so time filters use `chunks`, app/entity use `episodes`.
    private func buildFilters(_ query: MemoryQuery) -> FilterClause {
        var clauses: [String] = []
        var params: [SQLiteValue] = []

        if let range = query.timeRange {
            clauses.append("c.ts_capture >= ? AND c.ts_capture <= ?")
            params.append(.double(range.lowerBound.timeIntervalSince1970))
            params.append(.double(range.upperBound.timeIntervalSince1970))
        }
        if let app = query.app, !app.isEmpty {
            clauses.append("(e.app_name = ? OR e.bundle_id = ?)")
            params.append(.text(app)); params.append(.text(app))
        }
        for entity in query.entities where !entity.isEmpty {
            // entity_keys is a JSON array of strings → each key appears as `"key"`.
            clauses.append(#"e.entity_keys LIKE ? ESCAPE '\'"#)
            params.append(.text("%\"\(Self.escapeLike(entity))\"%"))
        }
        return FilterClause(sql: clauses.joined(separator: " AND "), params: params)
    }

    // MARK: - Query sanitization

    /// Turn free-text into a safe FTS5 MATCH expression: alphanumeric tokens (≥2
    /// chars, deduped, stop-worded, capped), each a quoted string literal, ORed
    /// together. Raw user text through MATCH would AND every term (near-zero recall
    /// on natural-language queries) and could be a syntax error on punctuation.
    /// Returns nil when no usable term remains (the recency list then carries the
    /// query). Stopwords are dropped because OR-ing a word like "the" matches nearly
    /// every chunk, flooding the candidate pool with irrelevant rows that then win
    /// on recency — a real precision loss the retrieval bench caught.
    static func ftsMatchQuery(from text: String) -> String? {
        var seen = Set<String>()
        var tokens: [String] = []
        for piece in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(piece)
            guard token.count >= 2, !stopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
            if tokens.count == 12 { break }
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Ultra-common function words that carry no retrieval intent. Deliberately
    /// small — content words (incl. "today", "meeting", app/entity names) are NEVER
    /// dropped; only words that would match nearly everything.
    static let stopwords: Set<String> = [
        "the", "an", "and", "or", "of", "to", "in", "on", "at", "as", "by", "for",
        "from", "with", "is", "am", "are", "was", "were", "be", "been", "being",
        "it", "its", "this", "that", "these", "those", "here", "there",
        "do", "does", "did", "done", "what", "when", "which", "who", "how", "why",
        "we", "our", "you", "your", "my", "me", "if", "then", "so", "but",
    ]

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
