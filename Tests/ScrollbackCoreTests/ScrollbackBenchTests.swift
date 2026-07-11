import XCTest
@testable import ScrollbackCore

/// ScrollbackBench — a retrieval-QUALITY regression net. It seeds a small, varied
/// corpus of realistic episodes, runs a golden set of "what was that thing I saw?"
/// queries, and asserts the right episode lands in the top-3. Search silently
/// getting worse as we add code is the failure this catches.
///
/// The corpus + queries are SYNTHETIC for now; the real golden set gets seeded from
/// founder dogfood data at the M1 gate run (that half is data-blocked). The harness
/// — seed → query → measure recall@3 — is what's built here and wired into CI (it
/// runs under `swift test`).
final class ScrollbackBenchTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    /// One labelled episode plus its chunk texts.
    private struct Doc {
        let label: String
        let bundle: String
        let app: String
        let entities: [String]
        let chunks: [String]
        let hoursAgo: Double
    }

    /// A golden query and the episode label it should recall in the top-3.
    private struct Probe { let query: String; let expect: String }

    private let corpus: [Doc] = [
        Doc(label: "pricing", bundle: "com.apple.Safari", app: "Safari", entities: ["pricing", "finance"],
            chunks: ["reviewed the Q3 pricing spreadsheet and enterprise discount tiers",
                     "finance wants the annual pricing model refreshed before the board deck"],
            hoursAgo: 2),
        Doc(label: "kubernetes", bundle: "com.googlecode.iterm2", app: "iTerm2", entities: ["kubernetes", "infra"],
            chunks: ["kubernetes pod stuck in crashloopbackoff in the staging cluster",
                     "kubectl logs showed an out-of-memory kill on the ingest worker",
                     "bumped the memory limit and the deployment stabilised"],
            hoursAgo: 5),
        Doc(label: "lunch", bundle: "com.tinyspeck.slackmacgap", app: "Slack", entities: ["team"],
            chunks: ["team lunch at the taco place downtown on friday",
                     "someone suggested the ramen spot next time"],
            hoursAgo: 27),
        Doc(label: "design", bundle: "com.figma.Desktop", app: "Figma", entities: ["design", "onboarding"],
            chunks: ["figma mockups for the onboarding flow walkthrough review",
                     "changed the primary button colour to accent teal"],
            hoursAgo: 30),
        Doc(label: "hiring", bundle: "com.google.Chrome", app: "Chrome", entities: ["hiring"],
            chunks: ["interview debrief for the backend engineering candidate",
                     "strong on distributed systems, weaker on frontend"],
            hoursAgo: 52),
        Doc(label: "standup", bundle: "com.tinyspeck.slackmacgap", app: "Slack", entities: ["team"],
            chunks: ["the daily standup is moved to friday this week per the team"],
            hoursAgo: 1),
    ]

    private let probes: [Probe] = [
        Probe(query: "that pricing spreadsheet I reviewed", expect: "pricing"),
        Probe(query: "kubernetes crashloop in staging", expect: "kubernetes"),
        Probe(query: "the taco lunch spot", expect: "lunch"),
        Probe(query: "figma onboarding mockups", expect: "design"),
        Probe(query: "backend interview candidate debrief", expect: "hiring"),
        Probe(query: "when is standup this week", expect: "standup"),
    ]

    private func seed(_ store: SQLiteCatalogStore) throws -> [UUID: String] {
        var labelOf: [UUID: String] = [:]
        for doc in corpus {
            let ts = at(-doc.hoursAgo)
            let episode = Episode(tsStart: ts, tsEnd: ts, bundleID: doc.bundle, appName: doc.app,
                                  windowTitle: doc.label, entityKeys: doc.entities)
            try store.insert(episode)
            labelOf[episode.id] = doc.label
            let event = CaptureEvent(episodeID: episode.id, ts: ts, type: .screenText,
                                     source: .ax, rawText: "seed", provenance: .untrustedAmbient)
            try store.insert(event)
            for text in doc.chunks {
                try store.insert(Chunk(episodeID: episode.id, eventID: event.id, text: text,
                                       tokenCount: 8, tsCapture: ts, source: .ax))
            }
        }
        return labelOf
    }

    func testGoldenQueriesRecallAtTop3() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let labelOf = try seed(store)

        var hits = 0
        for probe in probes {
            let top3 = try store.hybridSearch(MemoryQuery(text: probe.query, limit: 8))
                .prefix(3)
                .compactMap { labelOf[$0.episodeID] }
            let hit = top3.contains(probe.expect)
            XCTAssertTrue(hit, "query \"\(probe.query)\" expected \(probe.expect) in top-3, got \(top3)")
            if hit { hits += 1 }
        }

        let recall = Double(hits) / Double(probes.count)
        // The synthetic golden set is chosen to be fully recallable; a regression
        // that drops any probe out of the top-3 fails here.
        XCTAssertEqual(recall, 1.0, accuracy: 0.0001, "recall@3 regressed to \(recall)")
    }

    func testTimeScopedBenchQuery() throws {
        // "what did I do in the last few hours" → only the recent episodes, provably
        // excluding the day-old ones (hard time pre-filter over the same corpus).
        let store = try SQLiteCatalogStore.inMemory()
        let labelOf = try seed(store)

        let recentWindow = at(-6)...at(1)
        let labels = Set(try store.hybridSearch(MemoryQuery(text: "what was I working on", timeRange: recentWindow))
            .compactMap { labelOf[$0.episodeID] })

        XCTAssertTrue(labels.isSuperset(of: ["standup", "pricing", "kubernetes"])) // within 6h
        XCTAssertFalse(labels.contains("hiring")) // 52h ago — filtered out
        XCTAssertFalse(labels.contains("design")) // 30h ago — filtered out
    }
}
