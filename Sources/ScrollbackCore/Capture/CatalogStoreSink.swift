import Foundation

/// The capture→store bridge: a `CaptureEventSink` that persists captured episodes
/// into the weekly-shard `ShardedCatalog` so they become searchable. This is what
/// turns the tested pieces into a runnable loop — `scrollbackd` captures through
/// this sink, `scrollbackd search` reads the same catalog.
///
/// The engine streams episodeOpened → event… → episodeClosed. Because the catalog
/// is episode-atomic (a whole episode + its events + chunks live in one shard file),
/// this BUFFERS each episode's events, chunks them through a session-wide
/// `ChunkingStage` (so exact + near-duplicate re-reads collapse across episodes), and
/// flushes the whole episode on close. An optional `inner` sink (e.g. the JSONL spike
/// for human inspection) is forwarded to first.
///
/// Buffers are keyed by episode id because episodes can be IN FLIGHT concurrently:
/// the focused stream holds ONE episode open for a while, and the all-windows sweep
/// opens/closes short-lived ambient episodes INTERLEAVED inside it. A single shared
/// buffer would let an ambient episode flush a partial focused episode, then flush it
/// again on close under the same id → duplicate/PK-conflicting ingest and misattributed
/// chunks. Keyed buffers keep every episode's events + chunks separate.
///
/// Persistence failures are recorded, NOT thrown — capture resilience beats store
/// durability for a spike, and a transient DB error must not kill the capture loop.
/// Not thread-safe by contract (the engine drives it on the main run loop).
public final class CatalogStoreSink: CaptureEventSink {
    private let catalog: ShardedCatalog
    private let inner: CaptureEventSink?
    private let chunking: ChunkingStage

    private struct Buffer {
        var episode: Episode
        var events: [CaptureEvent] = []
        var chunks: [Chunk] = []
    }
    private var buffers: [Episode.ID: Buffer] = [:]

    public private(set) var episodesStored = 0
    public private(set) var lastPersistError: String?

    public init(catalog: ShardedCatalog, inner: CaptureEventSink? = nil, chunking: ChunkingStage = ChunkingStage()) {
        self.catalog = catalog
        self.inner = inner
        self.chunking = chunking
    }

    public func episodeOpened(_ episode: Episode) {
        inner?.episodeOpened(episode)
        buffers[episode.id] = Buffer(episode: episode)
    }

    public func event(_ event: CaptureEvent) {
        inner?.event(event)
        // Chunk in global arrival order (session-wide dedup memory is unchanged),
        // but bucket the resulting chunks into THIS event's episode. Ignore an event
        // with no open episode (shouldn't happen — the engine opens before emitting).
        guard buffers[event.episodeID] != nil else { return }
        let newChunks = chunking.ingest(event) // dedup + near-dup collapse
        buffers[event.episodeID]?.events.append(event)
        buffers[event.episodeID]?.chunks.append(contentsOf: newChunks)
    }

    public func episodeClosed(_ episode: Episode) {
        inner?.episodeClosed(episode)
        // The closed episode carries the final ts_end.
        if buffers[episode.id] != nil {
            buffers[episode.id]?.episode = episode
        } else {
            buffers[episode.id] = Buffer(episode: episode)
        }
        flush(episode.id)
    }

    /// Persist the buffered episode (skipping an empty one), then drop the buffer.
    private func flush(_ id: Episode.ID) {
        guard let buffer = buffers.removeValue(forKey: id), !buffer.events.isEmpty else { return }
        do {
            try catalog.ingest(episode: buffer.episode, events: buffer.events, chunks: buffer.chunks)
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
