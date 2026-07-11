import Foundation
import ScrollbackCore

/// Wraps the event sink with the `ChunkingStage` so live capture surfaces volume
/// numbers — raw vs deduped chars, chunks (= future vector count), and per-hour
/// buckets — the week-1 M1 instrumentation the PRD gate calls for. Chunks are NOT
/// persisted yet (the encrypted store consumes them next); for now the stage runs
/// only for its counters, then this logs them on shutdown.
final class InstrumentedSink: CaptureEventSink {
    private let inner: JSONLSink
    private let chunking = ChunkingStage()

    var path: String { inner.path }

    init(inner: JSONLSink) {
        self.inner = inner
    }

    func episodeOpened(_ episode: Episode) { inner.episodeOpened(episode) }
    func episodeClosed(_ episode: Episode) { inner.episodeClosed(episode) }

    func event(_ event: CaptureEvent) {
        inner.event(event)
        chunking.ingest(event) // counters only until the store lands
    }

    func logVolume() {
        print("volume: \(chunking.summary)")
    }
}
