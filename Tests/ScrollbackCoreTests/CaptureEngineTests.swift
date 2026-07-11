import XCTest
@testable import ScrollbackCore

private final class FixtureProvider: TextSnapshotProvider {
    var textByContextKey: [String: String] = [:]
    private(set) var calls = 0
    func snapshot(for context: FrontmostContext) -> CapturedText? {
        calls += 1
        guard let text = textByContextKey[context.key] else { return nil }
        return CapturedText(text: text, source: .ax, confidence: 1.0)
    }
}

private final class RecordingSink: CaptureEventSink {
    private(set) var opened: [Episode] = []
    private(set) var closed: [Episode] = []
    private(set) var events: [CaptureEvent] = []
    func episodeOpened(_ episode: Episode) { opened.append(episode) }
    func episodeClosed(_ episode: Episode) { closed.append(episode) }
    func event(_ event: CaptureEvent) { events.append(event) }
    var screenEvents: [CaptureEvent] { events.filter { $0.type == .screenText } }
    var clipboardEvents: [CaptureEvent] { events.filter { $0.type == .clipboard } }
}

final class CaptureEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    private let safari = FrontmostContext(
        pid: 1, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs"
    )
    private let slack = FrontmostContext(
        pid: 2, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#general"
    )

    private func makeEngine(
        provider: FixtureProvider,
        sink: RecordingSink,
        config: CaptureConfig = CaptureConfig()
    ) -> CaptureEngine {
        CaptureEngine(provider: provider, sink: sink, config: config)
    }

    // MARK: Episodes

    func testAppSwitchOpensEpisodeAndCaptures() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "hello world"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))

        XCTAssertEqual(sink.opened.count, 1)
        XCTAssertEqual(sink.opened[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events[0].type, .screenText)
        XCTAssertEqual(sink.events[0].source, .ax)
        XCTAssertEqual(sink.events[0].provenance, .untrustedAmbient) // the invariant
        XCTAssertNotNil(sink.events[0].textHash)
        XCTAssertEqual(sink.events[0].episodeID, sink.opened[0].id)
    }

    func testWindowChangeInSameAppOpensNewEpisode() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "page one"
        let otherTab = FrontmostContext(
            pid: 1, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Other Tab"
        )
        provider.textByContextKey[otherTab.key] = "page two"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.handleAppOrWindowChange(otherTab, at: at(10))

        XCTAssertEqual(sink.opened.count, 2)
        XCTAssertEqual(sink.closed.count, 1)
        XCTAssertEqual(sink.closed[0].windowTitle, "Docs")
        XCTAssertEqual(sink.events.count, 2)
    }

    func testSameContextChangeDoesNotReopenWhileEpisodeOpen() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "text"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.handleAppOrWindowChange(safari, at: at(5)) // duplicate notification

        XCTAssertEqual(sink.opened.count, 1)
        XCTAssertEqual(sink.closed.count, 0)
        XCTAssertEqual(engine.stats.episodesOpened, 1)
    }

    // MARK: Resume after idle (fixes: capture must not stall permanently)

    func testResumeAfterIdleViaActivityReopensEpisode() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "content"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.tick(at: at(301)) // idle → close ep1
        XCTAssertEqual(sink.closed.count, 1)

        // User returns and scrolls/reads → runtime reports real activity.
        engine.noteUserActivity(at: at(400))

        XCTAssertEqual(sink.opened.count, 2) // ep2 reopened for last-known window
        XCTAssertEqual(sink.screenEvents.count, 2) // captured again (per-episode dedup cleared)
    }

    func testResumeAfterIdleViaSameWindowActivationReopens() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "content"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.tick(at: at(301)) // idle close
        engine.handleAppOrWindowChange(safari, at: at(400)) // same window re-activated

        XCTAssertEqual(sink.opened.count, 2)
        XCTAssertEqual(sink.screenEvents.count, 2)
    }

    // MARK: App-driven content must not defeat idle (the "always-on app" bug)

    func testAppDrivenContentChangesDoNotPreventIdle() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "log line 1"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // real activity at t0; capture #1

        // App emits its own content changes (tail -f / incoming chat) — NOT user activity.
        provider.textByContextKey[safari.key] = "log line 2"
        engine.handleTextChangeSignal(safari, at: at(100))
        engine.tick(at: at(102)) // capture #2 (content changed, still within active window)

        provider.textByContextKey[safari.key] = "log line 3"
        engine.handleTextChangeSignal(safari, at: at(250))
        engine.tick(at: at(252)) // capture #3

        // Idle is governed by last REAL activity (t0), not content churn.
        engine.tick(at: at(305)) // 305s since t0 ≥ 300 → idle, close
        XCTAssertEqual(sink.closed.count, 1)

        // Further app content changes are ignored while idle.
        provider.textByContextKey[safari.key] = "log line 4"
        engine.handleTextChangeSignal(safari, at: at(310))
        engine.tick(at: at(313))

        XCTAssertEqual(sink.screenEvents.count, 3) // line 4 never captured
    }

    // MARK: Debounce

    func testTypingDebounceFiresOnlyAfterQuietPeriod() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "v1"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // capture v1
        provider.textByContextKey[safari.key] = "v2 after typing"

        let deadline = engine.handleTextChangeSignal(safari, at: at(5))
        XCTAssertEqual(deadline, at(7)) // 2s debounce

        engine.tick(at: at(6)) // before deadline → nothing
        XCTAssertEqual(sink.events.count, 1)

        engine.tick(at: at(7.1)) // after deadline → capture
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertTrue(sink.events[1].rawText.contains("v2"))
    }

    func testRollingDebounceReplacesDeadline() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "v1"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        provider.textByContextKey[safari.key] = "v2"
        engine.handleTextChangeSignal(safari, at: at(5)) // deadline 7
        engine.handleTextChangeSignal(safari, at: at(6)) // rolls to 8

        engine.tick(at: at(7.5)) // old deadline passed, new one not
        XCTAssertEqual(sink.events.count, 1)
        engine.tick(at: at(8.1))
        XCTAssertEqual(sink.events.count, 2)
    }

    func testWindowSwitchClearsPendingTyping() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "v1"
        provider.textByContextKey[slack.key] = "slack text"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.handleTextChangeSignal(safari, at: at(5)) // pending for safari
        engine.handleAppOrWindowChange(slack, at: at(6)) // switch clears it

        engine.tick(at: at(8)) // stale safari capture must NOT fire
        XCTAssertEqual(sink.events.count, 2) // safari open-capture + slack open-capture only
        XCTAssertEqual(sink.events.map(\.type), [.screenText, .screenText])
    }

    func testTextChangeSignalIgnoredWhenNoOpenEpisode() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "content"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.tick(at: at(301)) // idle close → no open episode

        let deadline = engine.handleTextChangeSignal(safari, at: at(310))
        XCTAssertEqual(deadline, at(310)) // no debounce scheduled
        engine.tick(at: at(315))
        XCTAssertEqual(sink.screenEvents.count, 1) // nothing new captured
    }

    // MARK: Dedup

    func testIdenticalTextIsDeduped() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "same content"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // capture
        engine.handleTextChangeSignal(safari, at: at(5))
        engine.tick(at: at(7.1)) // same text → dedup

        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(engine.stats.dedupSkips, 1)
        XCTAssertEqual(engine.stats.providerCalls, 2)
    }

    func testNewEpisodeSameContentStillCaptures() {
        // Per-episode dedup: reopening the same window after idle must record
        // its content even though it is identical to the previous episode's.
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "unchanged page"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // ep1 capture
        engine.tick(at: at(301)) // idle close
        engine.noteUserActivity(at: at(400)) // ep2 reopen + capture, same content

        XCTAssertEqual(sink.screenEvents.count, 2)
        XCTAssertEqual(engine.stats.dedupSkips, 0)
    }

    func testNormalizationMakesWhitespaceVariantsEqual() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "alpha   beta\n\tgamma"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        provider.textByContextKey[safari.key] = "alpha beta gamma" // same normalized
        engine.handleTextChangeSignal(safari, at: at(5))
        engine.tick(at: at(7.1))

        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(engine.stats.dedupSkips, 1)
        XCTAssertEqual(sink.events[0].rawText, "alpha beta gamma") // screen text stored normalized
    }

    // MARK: Clipboard

    func testClipboardEmitsNormalizedTextWithProvenance() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "page"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.handleClipboard("copied  snippet\nwith breaks", context: safari, at: at(3))

        XCTAssertEqual(engine.stats.clipboardEvents, 1)
        let clip = sink.clipboardEvents.last
        // Normalized (whitespace collapsed), not verbatim — so the single redaction
        // pass sees the same canonical form the dedup hash does (no verbatim leak).
        XCTAssertEqual(clip?.rawText, "copied snippet with breaks")
        XCTAssertEqual(clip?.provenance, .untrustedAmbient)
    }

    func testDuplicateClipboardIsDeduped() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "page"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.handleClipboard("copied snippet", context: safari, at: at(3))
        engine.handleClipboard("copied snippet", context: safari, at: at(4))

        XCTAssertEqual(engine.stats.clipboardEvents, 1)
        XCTAssertEqual(engine.stats.dedupSkips, 1)
    }

    // MARK: Idle

    func testIdleClosesEpisodeAndSuppressesCapture() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "text"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        let callsBeforeIdle = provider.calls

        engine.tick(at: at(301)) // past the 300s idle threshold
        XCTAssertEqual(sink.closed.count, 1)

        engine.tick(at: at(400)) // still idle: zero capture cycles
        engine.tick(at: at(500))
        XCTAssertEqual(provider.calls, callsBeforeIdle)
        XCTAssertEqual(engine.stats.idleProviderCalls, 0)
    }

    func testIdleCloseDoesNotRegressTsEndBelowLastEvent() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "v1"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // capture, tsEnd=0
        provider.textByContextKey[safari.key] = "v2"
        engine.handleTextChangeSignal(safari, at: at(5))
        engine.tick(at: at(7)) // capture, tsEnd advanced to 7 (lastActivity stays 0)

        engine.tick(at: at(307)) // idle: close at lastActivity(0), but must not regress tsEnd
        XCTAssertEqual(sink.closed.count, 1)
        XCTAssertEqual(sink.closed[0].tsEnd, at(7))
    }

    // MARK: Fallback (activity-gated, never fixed-interval)

    func testFallbackCapturesChangedContentAfterActivity() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "first"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // capture "first"
        provider.textByContextKey[safari.key] = "scrolled to new content"

        engine.noteUserActivity(at: at(31)) // user active (scrolling)
        engine.tick(at: at(31)) // ≥30s since last capture AND activity since → fallback fires

        XCTAssertEqual(sink.events.count, 2)
        XCTAssertTrue(sink.events[1].rawText.contains("scrolled"))
    }

    func testFallbackDoesNotFireWithoutActivitySinceLastCapture() {
        // The Never-rule guard: no user activity → no capture, regardless of timers.
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "static page"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0)) // capture; lastActivity == lastCapture == t0
        provider.textByContextKey[safari.key] = "changed but user did nothing"

        engine.tick(at: at(31)) // 31s elapsed but NO activity since capture → no fallback
        engine.tick(at: at(120))
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(engine.stats.providerCalls, 1)
    }

    // MARK: Shutdown

    func testFinishClosesOpenEpisode() {
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "text"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))
        engine.finish(at: at(10))

        XCTAssertEqual(sink.closed.count, 1)
        XCTAssertEqual(sink.closed[0].tsEnd, at(10))
        XCTAssertEqual(engine.stats.episodesClosed, 1)
    }

    // MARK: Redaction at the emit chokepoint

    func testCapturedSecretIsMaskedInEvent() {
        // A secret on screen must never reach the sink unmasked — redaction is at
        // the shared emit path, so screen capture is covered without special-casing.
        let provider = FixtureProvider()
        provider.textByContextKey[safari.key] = "deploy key sk-abcDEF0123456789ghXYZ ready"
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleAppOrWindowChange(safari, at: at(0))

        XCTAssertEqual(sink.screenEvents.count, 1)
        let event = sink.screenEvents[0]
        XCTAssertFalse(event.rawText.contains("sk-abcDEF0123456789"))
        XCTAssertTrue(event.rawText.contains("[redacted:apiKey]"))
        XCTAssertTrue(event.redactionFlags.contains(.apiKey))
    }

    func testCopiedSecretIsMaskedInClipboardEvent() {
        let provider = FixtureProvider()
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleClipboard("4111 1111 1111 1111", context: safari, at: at(0))

        XCTAssertEqual(sink.clipboardEvents.count, 1)
        let event = sink.clipboardEvents[0]
        XCTAssertFalse(event.rawText.contains("4111"))
        XCTAssertTrue(event.redactionFlags.contains(.creditCard))
    }

    func testTabSeparatedClipboardCardIsMaskedNotLeaked() {
        // A card copied from a spreadsheet (tab separators): storing the
        // normalized form means the single redaction pass catches it — rawText
        // must not retain the PAN and the flag must be set (no verbatim leak).
        let provider = FixtureProvider()
        let sink = RecordingSink()
        let engine = makeEngine(provider: provider, sink: sink)

        engine.handleClipboard("4111\t1111\t1111\t1111", context: safari, at: at(0))

        let event = sink.clipboardEvents[0]
        XCTAssertFalse(event.rawText.contains("4111"))
        XCTAssertTrue(event.redactionFlags.contains(.creditCard))
    }
}
