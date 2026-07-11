import XCTest
@testable import ScrollbackCore

/// Guards the weekly-shard store: episode-atomic routing, cross-shard search
/// fan-out + fusion, time-scoped shard pruning, and purge-by-file (the provable
/// erase). Runs against plaintext file-backed shards in a temp dir; SQLCipher is a
/// pass-through `key`, so this exercises the real topology.
final class ShardedCatalogTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private lazy var cal = WeekShardCalendar(timeZone: utc)
    private lazy var iso: Calendar = {
        var c = Calendar(identifier: .iso8601); c.timeZone = utc; return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        iso.date(from: DateComponents(year: y, month: m, day: day, hour: 10))!
    }

    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-shard-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func ingest(_ store: ShardedCatalog, at ts: Date, text: String, entities: [String] = []) throws {
        let episode = Episode(tsStart: ts, tsEnd: ts, bundleID: "com.apple.Safari", appName: "Safari",
                              windowTitle: "win", entityKeys: entities)
        let event = CaptureEvent(episodeID: episode.id, ts: ts, type: .screenText, source: .ax,
                                 rawText: "seed", provenance: .untrustedAmbient)
        let chunk = Chunk(episodeID: episode.id, eventID: event.id, text: text, tokenCount: 6,
                          tsCapture: ts, source: .ax)
        try store.ingest(episode: episode, events: [event], chunks: [chunk])
    }

    private func texts(_ store: ShardedCatalog, _ query: MemoryQuery) throws -> [String] {
        try store.search(query).map { $0.text }
    }

    func testWritesRouteToTheEpisodeStartWeekShard() throws {
        let store = try ShardedCatalog(directory: dir, timeZone: utc)
        let tsA = d(2026, 1, 6)  // W02
        let tsB = d(2026, 3, 3)  // a later week
        try ingest(store, at: tsA, text: "kubernetes cluster crashloop notes")
        try ingest(store, at: tsB, text: "quarterly pricing spreadsheet notes")

        let shards = try store.existingShards()
        XCTAssertEqual(shards.count, 2)
        XCTAssertTrue(shards.contains(cal.shard(for: tsA)))
        XCTAssertTrue(shards.contains(cal.shard(for: tsB)))
    }

    func testCrossShardSearchFusesBothShards() throws {
        let store = try ShardedCatalog(directory: dir, timeZone: utc)
        try ingest(store, at: d(2026, 1, 6), text: "kubernetes cluster crashloop notes")
        try ingest(store, at: d(2026, 3, 3), text: "quarterly pricing spreadsheet notes")

        // "notes" is in both shards → fan-out + fusion returns both.
        let found = try texts(store, MemoryQuery(text: "notes"))
        XCTAssertTrue(found.contains("kubernetes cluster crashloop notes"))
        XCTAssertTrue(found.contains("quarterly pricing spreadsheet notes"))
    }

    func testTimeScopedSearchPrunesOtherShards() throws {
        let store = try ShardedCatalog(directory: dir, timeZone: utc)
        let tsA = d(2026, 1, 6)
        try ingest(store, at: tsA, text: "kubernetes cluster crashloop notes")
        try ingest(store, at: d(2026, 3, 3), text: "quarterly pricing spreadsheet notes")

        // Scope to A's week only — B's shard is never consulted.
        let week = cal.range(of: cal.shard(for: tsA))
        let scoped = try texts(store, MemoryQuery(text: "notes",
                                                  timeRange: week.lowerBound...week.upperBound.addingTimeInterval(-1)))
        XCTAssertTrue(scoped.contains("kubernetes cluster crashloop notes"))
        XCTAssertFalse(scoped.contains("quarterly pricing spreadsheet notes")) // pruned by time
    }

    func testPurgeDropsWholeShardFilesProvably() throws {
        let store = try ShardedCatalog(directory: dir, timeZone: utc)
        let tsA = d(2026, 1, 6)
        let tsB = d(2026, 3, 3)
        try ingest(store, at: tsA, text: "kubernetes cluster crashloop notes")
        try ingest(store, at: tsB, text: "quarterly pricing spreadsheet notes")

        let cutoff = cal.range(of: cal.shard(for: tsB)).lowerBound
        let dropped = try store.purge(before: cutoff)

        XCTAssertEqual(dropped, [cal.shard(for: tsA)])
        XCTAssertEqual(try store.existingShards(), [cal.shard(for: tsB)])

        // A's data is gone from search; B survives.
        let all = try texts(store, MemoryQuery(text: "notes"))
        XCTAssertFalse(all.contains("kubernetes cluster crashloop notes"))
        XCTAssertTrue(all.contains("quarterly pricing spreadsheet notes"))

        // Provable erase: the shard file is physically gone from disk.
        let purgedFile = dir.appendingPathComponent(cal.shard(for: tsA).fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: purgedFile.path))
    }

    func testEmptyStoreSearchIsEmpty() throws {
        let store = try ShardedCatalog(directory: dir, timeZone: utc)
        XCTAssertTrue(try store.search(MemoryQuery(text: "anything")).isEmpty)
        XCTAssertTrue(try store.existingShards().isEmpty)
    }

    func testReopenSeesExistingShards() throws {
        let tsA = d(2026, 1, 6)
        do {
            let store = try ShardedCatalog(directory: dir, timeZone: utc)
            try ingest(store, at: tsA, text: "kubernetes cluster crashloop notes")
        }
        // A fresh manager over the same directory discovers the shard on disk.
        let reopened = try ShardedCatalog(directory: dir, timeZone: utc)
        XCTAssertEqual(try reopened.existingShards(), [cal.shard(for: tsA)])
        XCTAssertFalse(try reopened.search(MemoryQuery(text: "kubernetes")).isEmpty)
    }
}
