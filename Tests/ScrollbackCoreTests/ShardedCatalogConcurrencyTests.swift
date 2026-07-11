import XCTest
@testable import ScrollbackCore

/// Serve-while-capturing (`scrollbackd run` now serves recall while capturing) opens a
/// SECOND `ShardedCatalog` — its own SQLite connections — to READ the same store the
/// capture path writes. This pins the load-bearing invariant that makes that safe: a
/// separate reader connection sees a separate writer connection's committed data with
/// no corruption and no stale snapshot (WAL: one writer + N readers).
final class ShardedCatalogConcurrencyTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-concurrency-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func ingest(_ store: ShardedCatalog, at ts: Date, text: String) throws {
        let episode = Episode(tsStart: ts, tsEnd: ts, bundleID: "com.apple.Safari", appName: "Safari",
                              windowTitle: "win", entityKeys: [])
        let event = CaptureEvent(episodeID: episode.id, ts: ts, type: .screenText, source: .ax,
                                 rawText: "seed", provenance: .untrustedAmbient)
        let chunk = Chunk(episodeID: episode.id, eventID: event.id, text: text, tokenCount: 6,
                          tsCapture: ts, source: .ax)
        try store.ingest(episode: episode, events: [event], chunks: [chunk])
    }

    func testSeparateReaderSeesWriterCommits() throws {
        let writer = try ShardedCatalog(directory: dir, timeZone: utc) // the capture path
        let reader = try ShardedCatalog(directory: dir, timeZone: utc) // the recall path

        let ts = Date(timeIntervalSince1970: 1_800_000_000)
        try ingest(writer, at: ts, text: "kubernetes rollout notes")

        // The independent reader connection sees the writer's commit (WAL cross-conn).
        let first = try reader.search(MemoryQuery(text: "kubernetes", limit: 5))
        XCTAssertTrue(first.contains { $0.text.contains("kubernetes") }, "reader must see the first commit")

        // A later write is visible on a re-query — no stale snapshot pinned on the reader.
        try ingest(writer, at: ts.addingTimeInterval(60), text: "grafana dashboard latency")
        let second = try reader.search(MemoryQuery(text: "grafana", limit: 5))
        XCTAssertTrue(second.contains { $0.text.contains("grafana") }, "reader must see later commits too")
    }

    /// The reader opened FIRST (before the shard file exists) must still pick up shards
    /// the writer creates afterwards — `existingShards()` is read fresh per search, so a
    /// recall server that started before capture wrote anything still finds new weeks.
    func testReaderOpenedBeforeAnyWriteDiscoversNewShards() throws {
        let reader = try ShardedCatalog(directory: dir, timeZone: utc)
        XCTAssertTrue(try reader.search(MemoryQuery(text: "anything", limit: 5)).isEmpty)

        let writer = try ShardedCatalog(directory: dir, timeZone: utc)
        try ingest(writer, at: Date(timeIntervalSince1970: 1_800_000_000), text: "prometheus alert rules")

        let hits = try reader.search(MemoryQuery(text: "prometheus", limit: 5))
        XCTAssertTrue(hits.contains { $0.text.contains("prometheus") }, "reader discovers a shard created after it opened")
    }
}
