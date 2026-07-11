import Foundation

/// The catalog store: opens the SQLite DB, runs migrations, and persists the
/// capture model (episodes → events → chunks) with `ON DELETE CASCADE` end to
/// end. Synchronous by contract (confine to one actor/queue); the async
/// `RetrievalStore` surface and sharding are layered on later.
///
/// Encryption is transparent here: pass a `key` and the underlying DB is SQLCipher
/// once linked — every method below is identical.
public final class SQLiteCatalogStore {
    public let db: SQLiteDatabase

    public init(path: String, key: String? = nil) throws {
        self.db = try SQLiteDatabase(path: path, key: key)
        try migrate()
    }

    /// In-memory catalog (tests / ephemeral). `:memory:` is never encrypted.
    public static func inMemory() throws -> SQLiteCatalogStore {
        try SQLiteCatalogStore(path: ":memory:")
    }

    // MARK: - Migrations

    private func migrate() throws {
        try db.transaction {
            let current = db.userVersion
            for migration in CatalogSchema.migrations where migration.version > current {
                try db.exec(migration.sql)
                try db.exec("PRAGMA user_version = \(migration.version)")
            }
        }
    }

    public var schemaVersion: Int { db.userVersion }

    // MARK: - Writes

    public func insert(_ episode: Episode) throws {
        try db.run(
            """
            INSERT INTO episodes (id, ts_start, ts_end, bundle_id, app_name, window_title, url, summary, entity_keys)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(episode.id.uuidString),
                .double(episode.tsStart.timeIntervalSince1970),
                .double(episode.tsEnd.timeIntervalSince1970),
                .text(episode.bundleID),
                .text(episode.appName),
                optionalText(episode.windowTitle),
                optionalText(episode.url),
                optionalText(episode.summary),
                .text(Self.encodeJSON(episode.entityKeys)),
            ]
        )
    }

    public func insert(_ event: CaptureEvent) throws {
        try db.run(
            """
            INSERT INTO events (id, episode_id, ts, event_type, source, confidence, raw_text, text_hash, redaction_flags, provenance)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(event.id.uuidString),
                .text(event.episodeID.uuidString),
                .double(event.ts.timeIntervalSince1970),
                .text(event.type.rawValue),
                .text(event.source.rawValue),
                .double(event.confidence),
                .text(event.rawText),
                optionalText(event.textHash),
                .int(Int64(event.redactionFlags.rawValue)),
                .text(event.provenance.rawValue),
            ]
        )
    }

    public func insert(_ chunk: Chunk) throws {
        try db.run(
            """
            INSERT INTO chunks (id, episode_id, event_id, text, token_count, ts_capture, ts_event, source, model_id, dim, minhash)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(chunk.id.uuidString),
                .text(chunk.episodeID.uuidString),
                .text(chunk.eventID.uuidString),
                .text(chunk.text),
                .int(Int64(chunk.tokenCount)),
                .double(chunk.tsCapture.timeIntervalSince1970),
                chunk.tsEvent.map { SQLiteValue.double($0.timeIntervalSince1970) } ?? .null,
                .text(chunk.source.rawValue),
                optionalText(chunk.modelID),
                chunk.dim.map { SQLiteValue.int(Int64($0)) } ?? .null,
                .null, // minhash — filled by the MinHash pass
            ]
        )
    }

    // MARK: - Reads (enough for tests + early wiring)

    public func count(_ table: String) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table)")
        defer { statement.finalize() }
        return (try statement.step()) ? Int(statement.int(0)) : 0
    }

    /// FTS keyword search over chunk text → matching chunk ids (rowid-joined).
    public func searchChunkText(_ query: String, limit: Int = 8) throws -> [String] {
        let statement = try db.prepare(
            """
            SELECT c.id FROM chunks_fts f
            JOIN chunks c ON c.rowid = f.rowid
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        )
        defer { statement.finalize() }
        try statement.bindAll([.text(query), .int(Int64(limit))])
        var ids: [String] = []
        while try statement.step() { ids.append(statement.text(0)) }
        return ids
    }

    public func fetchEpisode(id: UUID) throws -> Episode? {
        let statement = try db.prepare(
            "SELECT ts_start, ts_end, bundle_id, app_name, window_title, url, summary, entity_keys FROM episodes WHERE id = ?"
        )
        defer { statement.finalize() }
        try statement.bindAll([.text(id.uuidString)])
        guard try statement.step() else { return nil }
        return Episode(
            id: id,
            tsStart: Date(timeIntervalSince1970: statement.double(0)),
            tsEnd: Date(timeIntervalSince1970: statement.double(1)),
            bundleID: statement.text(2),
            appName: statement.text(3),
            windowTitle: statement.textOrNil(4),
            url: statement.textOrNil(5),
            summary: statement.textOrNil(6),
            entityKeys: Self.decodeJSON(statement.textOrNil(7))
        )
    }

    // MARK: - Helpers

    private func optionalText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    static func encodeJSON(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}
