import XCTest
@testable import ScrollbackCore

/// End-to-end hybrid retrieval against an in-memory catalog: keyword recall,
/// provenance carry, the hard time/app/entity pre-filters, FTS query sanitization,
/// and the two PRD DoD cases — "what did I do today?" (time-scoped) and a
/// one-episode-dominant query returning diversified episodes.
final class HybridSearchTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @discardableResult
    private func seed(
        _ store: SQLiteCatalogStore,
        bundle: String = "com.apple.Safari",
        app: String = "Safari",
        entities: [String] = [],
        provenance: Provenance = .untrustedAmbient,
        chunks: [(text: String, ts: Date)]
    ) throws -> Episode {
        let times = chunks.map { $0.ts }
        let episode = Episode(
            tsStart: times.min() ?? t0, tsEnd: times.max() ?? t0,
            bundleID: bundle, appName: app, windowTitle: "win", entityKeys: entities
        )
        try store.insert(episode)
        let event = CaptureEvent(
            episodeID: episode.id, ts: times.min() ?? t0, type: .screenText,
            source: .ax, rawText: "seed", provenance: provenance
        )
        try store.insert(event)
        for chunk in chunks {
            try store.insert(Chunk(
                episodeID: episode.id, eventID: event.id, text: chunk.text,
                tokenCount: 4, tsCapture: chunk.ts, source: .ax
            ))
        }
        return episode
    }

    // MARK: Keyword recall + provenance

    func testKeywordRecallAndProvenanceCarried() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, chunks: [("quarterly pricing spreadsheet review", at(10))])
        try seed(store, chunks: [("lunch menu tacos and salsa", at(20))])

        let results = try store.hybridSearch(MemoryQuery(text: "pricing"))
        XCTAssertEqual(results.first?.text, "quarterly pricing spreadsheet review")
        XCTAssertEqual(results.first?.provenance, .untrustedAmbient) // ambient default carried
        XCTAssertEqual(results.first?.source, .ax)
        XCTAssertGreaterThan(results.first?.score ?? 0, 0)
    }

    func testProvenanceReflectsTheEvent() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, provenance: .userInput, chunks: [("typed personal note", at(10))])
        let results = try store.hybridSearch(MemoryQuery(text: "typed"))
        XCTAssertEqual(results.first?.provenance, .userInput) // join reads events.provenance
    }

    // MARK: DoD 1 — "what did I do today?" (time-scoped)

    func testTimeRangePreFilterScopesToToday() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let today = try seed(store, chunks: [
            ("reviewed the deploy runbook", at(3600)),
            ("answered a batch of emails", at(7200)),
        ])
        // A week earlier — must be excluded by the hard time filter.
        try seed(store, chunks: [("old vacation photos", at(-7 * 86_400))])

        let dayRange = at(0)...at(86_400)
        // A natural-language browse query whose terms don't appear in the text — the
        // recency list (time-filtered) must carry it.
        let results = try store.hybridSearch(MemoryQuery(text: "what did I do today", timeRange: dayRange))

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.episodeID == today.id }) // old episode filtered out
    }

    // MARK: DoD 2 — one-episode-dominant query returns diversified episodes

    func testDiversificationSurfacesOtherEpisode() throws {
        let store = try SQLiteCatalogStore.inMemory()
        // Episode A: a long session, 6 chunks all about kubernetes, most recent.
        let epA = try seed(store, chunks: (1...6).map { ("kubernetes pod crashloop note \($0)", at(Double($0) * 100 + 100)) })
        // Episode B: a single older kubernetes chunk — would fall out of a top-4
        // without diversification.
        let epB = try seed(store, chunks: [("kubernetes upgrade checklist", at(50))])

        let results = try store.hybridSearch(MemoryQuery(text: "kubernetes", limit: 4)) // default cap 3
        XCTAssertEqual(results.count, 4)
        let byEpisode = Dictionary(grouping: results, by: { $0.episodeID })
        XCTAssertEqual(byEpisode[epA.id]?.count, 3)      // capped at maxPerEpisode
        XCTAssertEqual(byEpisode[epB.id]?.count, 1)      // the other episode is surfaced
    }

    // MARK: Hard pre-filters

    func testAppPreFilter() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, bundle: "com.apple.Safari", app: "Safari", chunks: [("cluster planning doc", at(10))])
        let slack = try seed(store, bundle: "com.tinyspeck.slackmacgap", app: "Slack", chunks: [("cluster chat thread", at(20))])

        let results = try store.hybridSearch(MemoryQuery(text: "cluster", app: "Slack"))
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.episodeID == slack.id })
    }

    func testEntityPreFilter() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let kube = try seed(store, entities: ["kubernetes", "prod"], chunks: [("cluster notes here", at(10))])
        try seed(store, entities: ["design"], chunks: [("cluster notes here", at(20))]) // same text, different entity

        let results = try store.hybridSearch(MemoryQuery(text: "cluster", entities: ["kubernetes"]))
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.episodeID == kube.id })
    }

    // MARK: FTS sanitization / robustness

    func testPunctuationQueryDoesNotThrowAndRecencyCarries() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, chunks: [("some recent note", at(10))])
        // Raw MATCH of this would be an FTS5 syntax error; sanitizer yields no usable
        // term → recency carries the query instead of throwing.
        let results = try store.hybridSearch(MemoryQuery(text: "!!! @#$ -"))
        XCTAssertEqual(results.first?.text, "some recent note")
    }

    func testFtsMatchQuerySanitization() {
        // "the" is a dropped stopword; content words survive as an OR expression.
        XCTAssertEqual(SQLiteCatalogStore.ftsMatchQuery(from: "the Pricing-Doc!"), "\"pricing\" OR \"doc\"")
        XCTAssertNil(SQLiteCatalogStore.ftsMatchQuery(from: "!!! a"))  // no token ≥ 2 chars
        XCTAssertNil(SQLiteCatalogStore.ftsMatchQuery(from: "   "))
        XCTAssertNil(SQLiteCatalogStore.ftsMatchQuery(from: "what is it")) // all stopwords → recency carries
        XCTAssertEqual(SQLiteCatalogStore.ftsMatchQuery(from: "what did I do today"), "\"today\"") // content word kept
    }

    func testEmptyStoreReturnsNoResults() throws {
        let store = try SQLiteCatalogStore.inMemory()
        XCTAssertTrue(try store.hybridSearch(MemoryQuery(text: "anything")).isEmpty)
    }

    func testContentQueryWithNoMatchReturnsEmptyNotRecencyNoise() throws {
        // A keyword query that matches NOTHING must return empty — NOT the most-recent
        // captures as false matches (the real-data bug: "kubernetes deployment" surfaced
        // an unrelated recent billing page via the recency list).
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, chunks: [("update your payment info card number security code", at(10))])
        try seed(store, chunks: [("cookie policy consent preferences", at(20))])

        let results = try store.hybridSearch(MemoryQuery(text: "kubernetes deployment rollout"))
        XCTAssertTrue(results.isEmpty, "no content match → empty, not recent-but-irrelevant chunks")
    }

    func testTimeScopedBrowseStillCarriesViaRecency() throws {
        // The legit browse must still work: an explicit time window returns recent
        // chunks in it even when the query words don't match their text.
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, chunks: [("annual planning offsite agenda", at(10_000))])
        let window = at(9_000)...at(11_000)
        let results = try store.hybridSearch(MemoryQuery(text: "what did I do", timeRange: window))
        XCTAssertEqual(results.first?.text, "annual planning offsite agenda")
    }

    func testAbsurdLimitIsClampedNotCrashed() throws {
        // Review finding: an unclamped huge limit trapped on `limit * 5` overflow
        // and could blow past SQLite's bind-variable cap. It must clamp, not crash.
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, chunks: [("recent note one", at(10)), ("recent note two", at(20))])

        let huge = try store.hybridSearch(MemoryQuery(text: "note", limit: .max))
        XCTAssertEqual(huge.count, 2) // clamped; returns what exists, no trap
        XCTAssertLessThanOrEqual(huge.count, SQLiteCatalogStore.maxResultLimit)
    }

    func testZeroLimitReturnsNoResults() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try seed(store, chunks: [("recent note", at(10))])
        XCTAssertTrue(try store.hybridSearch(MemoryQuery(text: "note", limit: 0)).isEmpty)
    }
}
