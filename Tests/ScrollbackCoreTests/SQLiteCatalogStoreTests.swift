import XCTest
@testable import ScrollbackCore

final class SQLiteCatalogStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEpisode(bundle: String = "com.apple.Safari", title: String? = "Docs") -> Episode {
        Episode(tsStart: t0, tsEnd: t0.addingTimeInterval(60), bundleID: bundle, appName: "Safari",
                windowTitle: title, entityKeys: ["ane", "metal"])
    }

    private func makeEvent(_ episodeID: UUID, text: String = "hello world") -> CaptureEvent {
        CaptureEvent(episodeID: episodeID, ts: t0, type: .screenText, source: .ax,
                     rawText: text, textHash: TextNormalizer.hash(text), redactionFlags: [.apiKey])
    }

    private func makeChunk(_ episodeID: UUID, _ eventID: UUID, text: String = "hello world") -> Chunk {
        Chunk(episodeID: episodeID, eventID: eventID, text: text, tokenCount: 2, tsCapture: t0, source: .ax)
    }

    // MARK: Schema + migrations

    func testMigrationCreatesSchemaAndSetsVersion() throws {
        let store = try SQLiteCatalogStore.inMemory()
        XCTAssertEqual(store.schemaVersion, CatalogSchema.currentVersion)
        // Every declared table exists (COUNT succeeds → table present).
        for table in ["episodes", "events", "chunks", "chunks_fts", "meetings", "audio_segments",
                      "consent_log", "exclusions", "filing_drafts", "write_ledger", "egress_ledger",
                      "agent_runs", "destinations", "schema_meta"] {
            XCTAssertEqual(try store.count(table), 0, "missing table: \(table)")
        }
    }

    func testMigrationIsIdempotentAcrossReopen() throws {
        let dir = NSTemporaryDirectory() + "sb-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let first = try SQLiteCatalogStore(path: dir)
        try first.insert(makeEpisode())
        XCTAssertEqual(first.schemaVersion, CatalogSchema.currentVersion)

        // Reopen: migrations must NOT re-run (would fail on CREATE TABLE) and data persists.
        let second = try SQLiteCatalogStore(path: dir)
        XCTAssertEqual(second.schemaVersion, CatalogSchema.currentVersion)
        XCTAssertEqual(try second.count("episodes"), 1)
    }

    // MARK: Round-trip

    func testEpisodeRoundTrips() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let episode = makeEpisode(title: "ANE docs")
        try store.insert(episode)

        let fetched = try store.fetchEpisode(id: episode.id)
        XCTAssertEqual(fetched?.bundleID, "com.apple.Safari")
        XCTAssertEqual(fetched?.windowTitle, "ANE docs")
        XCTAssertEqual(fetched?.entityKeys, ["ane", "metal"])
        XCTAssertEqual(fetched?.tsStart, episode.tsStart)
    }

    func testEventAndChunkInsertWithForeignKeys() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let episode = makeEpisode()
        let event = makeEvent(episode.id)
        let chunk = makeChunk(episode.id, event.id)
        try store.insert(episode)
        try store.insert(event)
        try store.insert(chunk)

        XCTAssertEqual(try store.count("events"), 1)
        XCTAssertEqual(try store.count("chunks"), 1)
    }

    func testInsertingEventWithoutEpisodeFailsForeignKey() throws {
        let store = try SQLiteCatalogStore.inMemory()
        XCTAssertThrowsError(try store.insert(makeEvent(UUID()))) // no such episode
    }

    // MARK: Cascade + FTS

    func testDeletingEpisodeCascadesEventsChunksAndFTS() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let episode = makeEpisode()
        let event = makeEvent(episode.id, text: "reticulating splines")
        let chunk = makeChunk(episode.id, event.id, text: "reticulating splines")
        try store.insert(episode)
        try store.insert(event)
        try store.insert(chunk)
        XCTAssertEqual(try store.searchChunkText("reticulating").count, 1)

        try store.db.run("DELETE FROM episodes WHERE id = ?", [.text(episode.id.uuidString)])

        XCTAssertEqual(try store.count("events"), 0)   // cascade
        XCTAssertEqual(try store.count("chunks"), 0)   // cascade
        XCTAssertEqual(try store.searchChunkText("reticulating").count, 0) // FTS trigger cleaned up
    }

    func testFTSSearchFindsChunk() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let episode = makeEpisode()
        let event = makeEvent(episode.id, text: "the quick brown fox")
        try store.insert(episode)
        try store.insert(event)
        try store.insert(makeChunk(episode.id, event.id, text: "the quick brown fox"))

        XCTAssertEqual(try store.searchChunkText("brown").count, 1)
        XCTAssertEqual(try store.searchChunkText("aardvark").count, 0)
    }
}
