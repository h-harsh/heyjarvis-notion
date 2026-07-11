import Foundation

/// Vector persistence: durable int8 embeddings in `chunk_vectors`, plus the lazy-embed
/// work list. The brute-force `VectorIndex` reads these; a future sqlite-vec `vec0`
/// index is built FROM them without changing this DAO (the `RetrievalStore` hedge).
extension SQLiteCatalogStore {

    /// int8 ↔ raw bytes (SQLite BLOB). `Int8`/`UInt8` share a bit pattern, so this is
    /// a reinterpretation, not a numeric conversion.
    static func encodeInt8Vector(_ ints: [Int8]) -> [UInt8] { ints.map { UInt8(bitPattern: $0) } }
    static func decodeInt8Vector(_ bytes: [UInt8]) -> [Int8] { bytes.map { Int8(bitPattern: $0) } }

    /// Store (or replace) a chunk's quantized embedding. Replace so a re-embed under
    /// the same model overwrites in place.
    public func insertVector(chunkID: UUID, _ vector: QuantizedEmbedding) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO chunk_vectors (chunk_id, model_id, dim, scale, embedding)
            VALUES (?,?,?,?,?)
            """,
            [
                .text(chunkID.uuidString),
                .text(vector.modelID),
                .int(Int64(vector.dim)),
                .double(Double(vector.scale)),
                .blob(Self.encodeInt8Vector(vector.ints)),
            ]
        )
    }

    /// Chunks with no vector for `modelID` yet — the lazy-embed work list. Newest
    /// first, so a fresh capture session becomes searchable-by-vector soonest. On a
    /// model change this naturally returns everything (no row for the NEW model_id),
    /// driving lazy re-embedding without rewriting history.
    public func unembeddedChunks(modelID: String, limit: Int) throws -> [(id: UUID, text: String)] {
        let statement = try db.prepare(
            """
            SELECT c.id, c.text FROM chunks c
            LEFT JOIN chunk_vectors v ON v.chunk_id = c.id AND v.model_id = ?
            WHERE v.chunk_id IS NULL
            ORDER BY c.ts_capture DESC
            LIMIT ?
            """
        )
        defer { statement.finalize() }
        try statement.bindAll([.text(modelID), .int(Int64(limit))])
        var out: [(UUID, String)] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.text(0)) else { continue }
            out.append((id, statement.text(1)))
        }
        return out
    }

    public func vectorCount(modelID: String) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM chunk_vectors WHERE model_id = ?")
        defer { statement.finalize() }
        try statement.bindAll([.text(modelID)])
        return (try statement.step()) ? Int(statement.int(0)) : 0
    }
}
