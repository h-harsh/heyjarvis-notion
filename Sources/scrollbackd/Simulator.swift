import Foundation
import ScrollbackCore

/// `scrollbackd simulate` — replays a fixed workday fixture through the real
/// CaptureEngine and self-asserts the resulting counters. This is verify
/// check #4: a deterministic, TCC-free, observed-behavior drive of the
/// capture logic (episodes, debounce, dedup, clipboard, idle suppression,
/// resume-after-idle).
private final class ScriptedProvider: TextSnapshotProvider {
    var textByContextKey: [String: String] = [:]
    func snapshot(for context: FrontmostContext) -> CapturedText? {
        guard let text = textByContextKey[context.key] else { return nil }
        return CapturedText(text: text, source: .ax, confidence: 1.0)
    }
}

private final class NullSink: CaptureEventSink {
    func episodeOpened(_ episode: Episode) {}
    func episodeClosed(_ episode: Episode) {}
    func event(_ event: CaptureEvent) {}
}

func runSimulation() -> Int32 {
    // Fixed base time — determinism is the point.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let at = { (offset: TimeInterval) in t0.addingTimeInterval(offset) }

    let safari = FrontmostContext(pid: 100, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "ANE docs")
    let slack = FrontmostContext(pid: 200, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#general")

    let provider = ScriptedProvider()
    let engine = CaptureEngine(provider: provider, sink: NullSink(), config: CaptureConfig())

    // Episode 1: reading in Safari.
    provider.textByContextKey[safari.key] = "Apple Neural Engine performance guide"
    engine.handleAppOrWindowChange(safari, at: at(0)) // capture #1

    // Typing → debounced capture of changed content.
    engine.handleTextChangeSignal(safari, at: at(5)) // deadline t+7
    provider.textByContextKey[safari.key] = "Apple Neural Engine performance guide — now with Metal notes"
    engine.tick(at: at(7)) // capture #2

    // Another signal, content unchanged → dedup skip (provider called, nothing stored).
    engine.handleTextChangeSignal(safari, at: at(9)) // deadline t+11
    engine.tick(at: at(11)) // provider call #3, dedup skip

    // Clipboard copy (concealed-type filtering is the runtime's job).
    engine.handleClipboard("sqlite-vec: 68ms full scan @ 100K vectors", context: safari, at: at(12))

    // Episode 2: switch to Slack.
    provider.textByContextKey[slack.key] = "#general — standup thread"
    engine.handleAppOrWindowChange(slack, at: at(20)) // capture #4

    // Long silence → idle: episode closes at last activity, capture suppressed.
    engine.tick(at: at(340)) // 320s since last activity ≥ 300 → idle
    engine.tick(at: at(350)) // still idle: zero provider calls

    // User returns and reads (scroll → runtime feeds noteUserActivity): episode 3
    // reopens for the last-known window and captures again (dedup cleared on open).
    engine.noteUserActivity(at: at(360)) // reopen + capture #5

    engine.finish(at: at(365))

    let expected = CaptureStats(
        episodesOpened: 3,
        episodesClosed: 3,
        screenEvents: 4,
        clipboardEvents: 1,
        dedupSkips: 1,
        providerCalls: 5,
        idleProviderCalls: 0
    )

    if engine.stats == expected {
        print("simulate OK: \(engine.stats.summary)")
        return 0
    } else {
        print("simulate FAILED")
        print("  expected: \(expected.summary)")
        print("  actual:   \(engine.stats.summary)")
        return 1
    }
}
