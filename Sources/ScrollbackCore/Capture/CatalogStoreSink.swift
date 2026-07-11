import Foundation

/// The capture→store bridge: a `CaptureEventSink` that persists captured episodes
/// into the weekly-shard `ShardedCatalog` so they become searchable. This is what
/// turns the tested pieces into a runnable loop — `scrollbackd` captures through
/// this sink, `scrollbackd search` reads the same catalog.
///
/// The engine streams episodeOpened → event… → episodeClosed. Because the catalog
/// is episode-atomic (a whole episode + its events + chunks live in one shard file),
/// this BUFFERS the current episode's events, chunks them through a session-wide
/// `ChunkingStage` (so exact + near-duplicate re-reads collapse across episodes), and
/// flushes the whole episode on close. An optional `inner` sink (e.g. the JSONL spike
/// for human inspection) is forwarded to first.
///
/// Persistence failures are recorded, NOT thrown — capture resilience beats store
/// durability for a spike, and a transient DB error must not kill the capture loop.
/// Not thread-safe by contract (the engine drives it on the main run loop).
public final class CatalogStoreSink: CaptureEventSink {
    private let catalog: ShardedCatalog
    private let inner: CaptureEventSink?
    private let chunking: ChunkingStage

    private var episode: Episode?
    private var events: [CaptureEvent] = []
    private var chunks: [Chunk] = []

    public private(set) var episodesStored = 0
    public private(set) var lastPersistError: String?

    public init(catalog: ShardedCatalog, inner: CaptureEventSink? = nil, chunking: ChunkingStage = ChunkingStage()) {
        self.catalog = catalog
        self.inner = inner
        self.chunking = chunking
    }

    public func episodeOpened(_ episode: Episode) {
        inner?.episodeOpened(episode)
        flush() // defensive: flush any unclosed prior episode before starting a new one
        self.episode = episode
        events = []
        chunks = []
    }

    public func event(_ event: CaptureEvent) {
        inner?.event(event)
        events.append(event)
        chunks.append(contentsOf: chunking.ingest(event)) // dedup + near-dup collapse
    }

    public func episodeClosed(_ episode: Episode) {
        inner?.episodeClosed(episode)
        self.episode = episode // the closed episode carries the final ts_end
        flush()
    }

    /// Persist the buffered episode (skipping an empty one), then reset the buffer.
    private func flush() {
        defer { episode = nil; events = []; chunks = [] }
        guard let episode, !events.isEmpty else { return }
        do {
            try catalog.ingest(episode: episode, events: events, chunks: chunks)
            episodesStored += 1
        } catch {
            lastPersistError = "\(error)"
        }
    }

    /// A one-line volume/health summary for the shutdown log.
    public var summary: String {
        var line = "\(chunking.summary) episodes_stored=\(episodesStored)"
        if let lastPersistError { line += " persist_error=\(lastPersistError)" }
        return line
    }
}
