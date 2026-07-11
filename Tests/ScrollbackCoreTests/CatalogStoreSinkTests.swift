import XCTest
@testable import ScrollbackCore

/// The walking-skeleton end-to-end test (minus live TCC): drive capture events
/// through CatalogStoreSink into a real weekly-shard catalog, then search it back.
/// This proves capture → store → search works as a loop.
final class CatalogStoreSinkTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sb-sink-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeCatalog() throws -> ShardedCatalog {
        try ShardedCatalog(directory: dir, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// Drive one episode (open → events → close) through the sink.
    private func capture(_ sink: CatalogStoreSink, bundle: String = "com.apple.Safari",
                         app: String = "Safari", texts: [String], start: Date) {
        var episode = Episode(tsStart: start, tsEnd: start, bundleID: bundle, appName: app, windowTitle: "win")
        sink.episodeOpened(episode)
        for (index, text) in texts.enumerated() {
            let ts = start.addingTimeInterval(TimeInterval(index))
            sink.event(CaptureEvent(episodeID: episode.id, ts: ts, type: .screenText, source: .ax, rawText: text))
        }
        episode.tsEnd = start.addingTimeInterval(TimeInterval(texts.count))
        sink.episodeClosed(episode)
    }

    func testCapturedTextIsSearchable() throws {
        let catalog = try makeCatalog()
        let sink = CatalogStoreSink(catalog: catalog)
        capture(sink, texts: ["reviewed the quarterly pricing spreadsheet"], start: at(0))

        XCTAssertEqual(sink.episodesStored, 1)
        let hits = try catalog.search(MemoryQuery(text: "pricing"))
        XCTAssertEqual(hits.first?.text, "reviewed the quarterly pricing spreadsheet")
        XCTAssertEqual(hits.first?.provenance, .untrustedAmbient) // provenance survives the round-trip
    }

    func testMultipleEpisodesAllSearchable() throws {
        let catalog = try makeCatalog()
        let sink = CatalogStoreSink(catalog: catalog)
        capture(sink, texts: ["kubernetes pod crashloop in staging"], start: at(0))
        capture(sink, texts: ["lunch at the taco place downtown"], start: at(100))

        XCTAssertEqual(sink.episodesStored, 2)
        XCTAssertFalse(try catalog.search(MemoryQuery(text: "kubernetes")).isEmpty)
        XCTAssertFalse(try catalog.search(MemoryQuery(text: "taco")).isEmpty)
    }

    func testEmptyEpisodeIsNotStored() throws {
        let catalog = try makeCatalog()
        let sink = CatalogStoreSink(catalog: catalog)
        let episode = Episode(tsStart: at(0), tsEnd: at(1), bundleID: "com.apple.Safari", appName: "Safari")
        sink.episodeOpened(episode)
        sink.episodeClosed(episode) // no events
        XCTAssertEqual(sink.episodesStored, 0)
        XCTAssertTrue(try catalog.existingShards().isEmpty)
    }

    func testInnerSinkIsForwarded() throws {
        let catalog = try makeCatalog()
        let spy = SpySink()
        let sink = CatalogStoreSink(catalog: catalog, inner: spy)
        capture(sink, texts: ["hello world"], start: at(0))
        // The inner sink (e.g. the JSONL spike) still sees the full stream.
        XCTAssertEqual(spy.opened, 1)
        XCTAssertEqual(spy.events, 1)
        XCTAssertEqual(spy.closed, 1)
    }

    func testDuplicateReadsCollapseButRemainSearchable() throws {
        let catalog = try makeCatalog()
        let sink = CatalogStoreSink(catalog: catalog)
        // Same text captured in two episodes → dedup drops the re-read chunk, but the
        // content is still searchable (via the first episode's chunk).
        capture(sink, texts: ["the release checklist is complete"], start: at(0))
        capture(sink, texts: ["the release checklist is complete"], start: at(100))
        XCTAssertEqual(sink.episodesStored, 2) // both episodes stored (events kept)
        XCTAssertFalse(try catalog.search(MemoryQuery(text: "checklist")).isEmpty)
    }

    func testInterleavedAmbientEpisodeDoesNotCorruptFocused() throws {
        // The all-windows sweep opens/closes a short ambient episode INSIDE the open
        // focused episode. Both must persist as distinct, complete episodes.
        let catalog = try makeCatalog()
        let sink = CatalogStoreSink(catalog: catalog)

        var focused = Episode(tsStart: at(0), tsEnd: at(0), bundleID: "com.apple.Safari",
                              appName: "Safari", windowTitle: "Focused Docs")
        sink.episodeOpened(focused)
        sink.event(CaptureEvent(episodeID: focused.id, ts: at(0), type: .screenText, source: .ax,
                                rawText: "focused window first read"))

        // --- ambient episode fully opens/closes while `focused` is still open ---
        var ambient = Episode(tsStart: at(1), tsEnd: at(1), bundleID: "com.google.Chrome",
                              appName: "Chrome", windowTitle: "Background Ahrefs")
        sink.episodeOpened(ambient)
        sink.event(CaptureEvent(episodeID: ambient.id, ts: at(1), type: .screenText, source: .ocr,
                                rawText: "background ahrefs dashboard numbers"))
        ambient.tsEnd = at(1)
        sink.episodeClosed(ambient)

        // --- focused episode keeps going, then closes ---
        sink.event(CaptureEvent(episodeID: focused.id, ts: at(2), type: .screenText, source: .ax,
                                rawText: "focused window second read"))
        focused.tsEnd = at(2)
        sink.episodeClosed(focused)

        XCTAssertEqual(sink.episodesStored, 2)
        // Both windows' content is independently searchable (not merged/lost).
        XCTAssertFalse(try catalog.search(MemoryQuery(text: "ahrefs")).isEmpty)
        XCTAssertFalse(try catalog.search(MemoryQuery(text: "focused")).isEmpty)
        // The focused episode kept BOTH its reads despite the ambient flush in between.
        let focusedHits = try catalog.search(MemoryQuery(text: "second"))
        XCTAssertEqual(focusedHits.first?.episodeID, focused.id)
    }

    private final class SpySink: CaptureEventSink {
        var opened = 0, closed = 0, events = 0
        func episodeOpened(_ episode: Episode) { opened += 1 }
        func episodeClosed(_ episode: Episode) { closed += 1 }
        func event(_ event: CaptureEvent) { events += 1 }
    }
}
