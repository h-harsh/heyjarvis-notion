import XCTest
@testable import ScrollbackCore

/// The all-windows sweep, driven through the real `CaptureEngine`: each background
/// window becomes its own atomic episode, exclusions + redaction still apply, re-sweeps
/// of unchanged windows dedup, and the focused stream is never disturbed.
final class CaptureEngineAmbientSweepTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    private final class FakeAmbient: AmbientWindowProvider {
        var textByWindow: [UInt32: String] = [:]
        var sourceByWindow: [UInt32: CaptureSource] = [:]
        private(set) var calls = 0
        func snapshot(of target: AmbientWindowTarget) -> CapturedText? {
            calls += 1
            guard let text = textByWindow[target.windowID] else { return nil }
            return CapturedText(text: text, source: sourceByWindow[target.windowID] ?? .ax, confidence: 1.0)
        }
    }

    private final class RecordingSink: CaptureEventSink {
        private(set) var opened: [Episode] = []
        private(set) var closed: [Episode] = []
        private(set) var events: [CaptureEvent] = []
        func episodeOpened(_ episode: Episode) { opened.append(episode) }
        func episodeClosed(_ episode: Episode) { closed.append(episode) }
        func event(_ event: CaptureEvent) { events.append(event) }
    }

    private final class NilFocusedProvider: TextSnapshotProvider {
        func snapshot(for context: FrontmostContext) -> CapturedText? { nil }
    }

    private func target(_ id: UInt32, bundle: String = "com.google.Chrome", app: String = "Chrome",
                        title: String? = "Tab") -> AmbientWindowTarget {
        AmbientWindowTarget(
            context: FrontmostContext(pid: 10, bundleID: bundle, appName: app, windowTitle: title),
            windowID: id, area: 480_000
        )
    }

    private func makeEngine(
        sink: CaptureEventSink, ambient: AmbientWindowProvider,
        exclusions: ExclusionSet = ExclusionSet(rules: [])
    ) -> CaptureEngine {
        CaptureEngine(provider: NilFocusedProvider(), sink: sink, exclusions: exclusions, ambientProvider: ambient)
    }

    func testEachWindowBecomesItsOwnEpisode() {
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "ahrefs backlinks dashboard", 2: "zerodha order book"]
        let engine = makeEngine(sink: sink, ambient: ambient)

        engine.sweepAmbientWindows([target(1, title: "Ahrefs"), target(2, title: "Zerodha")], at: at(0))

        XCTAssertEqual(sink.opened.count, 2)
        XCTAssertEqual(sink.closed.count, 2)
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertEqual(engine.ambientStats.episodes, 2)
        XCTAssertEqual(engine.ambientStats.events, 2)
        XCTAssertEqual(Set(sink.events.map { $0.rawText }), ["ahrefs backlinks dashboard", "zerodha order book"])
    }

    func testNoAmbientProviderIsNoOp() {
        let sink = RecordingSink()
        let engine = CaptureEngine(provider: NilFocusedProvider(), sink: sink) // no ambientProvider
        engine.sweepAmbientWindows([target(1)], at: at(0))
        XCTAssertTrue(sink.opened.isEmpty)
        XCTAssertEqual(engine.ambientStats.episodes, 0)
    }

    func testAmbientCaptureIsTaggedUntrustedAmbient() {
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "some dashboard text"]
        let engine = makeEngine(sink: sink, ambient: ambient)
        engine.sweepAmbientWindows([target(1)], at: at(0))
        XCTAssertEqual(sink.events.first?.provenance, .untrustedAmbient)
    }

    func testOcrSourceIsPreserved() {
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "opaque canvas app text via ocr"]
        ambient.sourceByWindow = [1: .ocr]
        let engine = makeEngine(sink: sink, ambient: ambient)
        engine.sweepAmbientWindows([target(1)], at: at(0))
        XCTAssertEqual(sink.events.first?.source, .ocr)
    }

    func testNeverCaptureExclusionIsEnforcedInEngine() {
        // Defense in depth: even if a never-capture window reaches the engine, it's skipped.
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "vault secrets", 2: "public dashboard"]
        let rules: [ExclusionRule] = [.never(.app, "com.1password.1password")]
        let engine = makeEngine(sink: sink, ambient: ambient, exclusions: ExclusionSet(rules: rules))

        engine.sweepAmbientWindows([
            target(1, bundle: "com.1password.1password", app: "1Password", title: "Vault"),
            target(2, title: "Dashboard"),
        ], at: at(0))

        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.rawText, "public dashboard")
        XCTAssertEqual(ambient.calls, 1) // never even read the excluded window
    }

    func testRedactWindowRecordsPlaceholderWithoutReading() {
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "sensitive banking balance"]
        let rules: [ExclusionRule] = [ExclusionRule(type: .app, pattern: "com.google.Chrome", mode: .redact)]
        let engine = makeEngine(sink: sink, ambient: ambient, exclusions: ExclusionSet(rules: rules))

        engine.sweepAmbientWindows([target(1, title: "Chase — Acct 1234")], at: at(0))

        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.rawText, "[content excluded by redact rule]")
        XCTAssertEqual(sink.opened.first?.windowTitle, "[content excluded by redact rule]") // title masked too
        XCTAssertEqual(ambient.calls, 0) // redact never reads the window
    }

    func testRedactionRunsOnAmbientText() {
        // A secret on a background window is masked by the same redact chokepoint.
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "token sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA in the logs"]
        let engine = makeEngine(sink: sink, ambient: ambient)
        engine.sweepAmbientWindows([target(1)], at: at(0))
        let stored = sink.events.first?.rawText ?? ""
        XCTAssertFalse(stored.contains("sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(sink.events.first?.redactionFlags.contains(.apiKey) ?? false)
    }

    func testUnchangedWindowIsDedupedAcrossSweeps() {
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [1: "unchanged dashboard content"]
        let engine = makeEngine(sink: sink, ambient: ambient)

        engine.sweepAmbientWindows([target(1)], at: at(0))
        engine.sweepAmbientWindows([target(1)], at: at(5)) // same content, next focus change

        XCTAssertEqual(sink.events.count, 1)          // second sweep stored nothing new
        XCTAssertEqual(engine.ambientStats.episodes, 1)
        XCTAssertEqual(engine.ambientStats.dedupSkips, 1)
    }

    func testChangedWindowContentIsRecapturedAcrossSweeps() {
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        let engine = makeEngine(sink: sink, ambient: ambient)

        ambient.textByWindow = [1: "dashboard at 10am"]
        engine.sweepAmbientWindows([target(1)], at: at(0))
        ambient.textByWindow = [1: "dashboard at 11am with new numbers"]
        engine.sweepAmbientWindows([target(1)], at: at(3600))

        XCTAssertEqual(sink.events.count, 2)
        XCTAssertEqual(engine.ambientStats.episodes, 2)
    }

    func testDedupMapIsPrunedToCurrentlyVisibleWindows() {
        // The cross-sweep dedup map must evict windows no longer in the sweep, so it
        // can't grow unbounded AND a window that leaves then returns is re-captured
        // (not permanently false-skipped by a stale hash).
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        let engine = makeEngine(sink: sink, ambient: ambient)

        ambient.textByWindow = [1: "dashboard content"]
        engine.sweepAmbientWindows([target(1)], at: at(0))   // window 1 stored

        ambient.textByWindow = [2: "other window"]
        engine.sweepAmbientWindows([target(2)], at: at(5))   // window 1 gone → its hash pruned

        ambient.textByWindow = [1: "dashboard content"]      // window 1 returns, SAME content
        engine.sweepAmbientWindows([target(1)], at: at(10))  // must be re-captured, not deduped

        XCTAssertEqual(sink.events.count, 3)
        XCTAssertEqual(engine.ambientStats.episodes, 3)
        XCTAssertEqual(engine.ambientStats.dedupSkips, 0)
    }

    func testEmptyWindowTextStoresNothing() {
        let sink = RecordingSink()
        let ambient = FakeAmbient() // window 1 has no text
        let engine = makeEngine(sink: sink, ambient: ambient)
        engine.sweepAmbientWindows([target(1)], at: at(0))
        XCTAssertTrue(sink.opened.isEmpty)
        XCTAssertEqual(engine.ambientStats.episodes, 0)
        XCTAssertEqual(engine.ambientStats.providerCalls, 1) // attempted, got nil
    }

    func testSweepDoesNotDisturbTheFocusedEpisode() {
        // Open a focused episode, then sweep — the focused episode must remain open,
        // unchanged, and its counters untouched (the sweep uses ambientStats only).
        let sink = RecordingSink()
        let ambient = FakeAmbient()
        ambient.textByWindow = [9: "background window text"]
        let focusedProvider = FixtureFocused(text: "focused window text")
        let engine = CaptureEngine(provider: focusedProvider, sink: sink, ambientProvider: ambient)

        let focused = FrontmostContext(pid: 1, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs")
        engine.handleAppOrWindowChange(focused, at: at(0))
        let focusedID = engine.currentEpisode?.id
        let openedBefore = engine.stats.episodesOpened

        engine.sweepAmbientWindows([target(9, bundle: "com.google.Chrome", title: "BG")], at: at(1))

        XCTAssertEqual(engine.currentEpisode?.id, focusedID)     // same focused episode still open
        XCTAssertEqual(engine.stats.episodesOpened, openedBefore) // focused counters untouched by sweep
        XCTAssertEqual(engine.ambientStats.episodes, 1)
    }

    private final class FixtureFocused: TextSnapshotProvider {
        let text: String
        init(text: String) { self.text = text }
        func snapshot(for context: FrontmostContext) -> CapturedText? {
            CapturedText(text: text, source: .ax, confidence: 1.0)
        }
    }
}
