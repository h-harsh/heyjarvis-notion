import Foundation

/// A ranked search hit with provenance, returned toward the MCP layer.
/// Results always carry source + provenance so Claude can cite the moment and
/// the untrusted-ambient origin can be spotlighted before it enters context.
public struct SearchResult: Sendable, Equatable {
    public let chunkID: Chunk.ID
    public let episodeID: Episode.ID
    public let text: String
    public let score: Double
    public let source: CaptureSource
    public let provenance: Provenance
    public let ts: Date

    public init(
        chunkID: Chunk.ID,
        episodeID: Episode.ID,
        text: String,
        score: Double,
        source: CaptureSource,
        provenance: Provenance,
        ts: Date
    ) {
        self.chunkID = chunkID
        self.episodeID = episodeID
        self.text = text
        self.score = score
        self.source = source
        self.provenance = provenance
        self.ts = ts
    }
}

/// Query parameters for hybrid retrieval. `timeRange`/`app`/`entities` are hard
/// pre-filters; the fused ranking (BM25 keyword + vector + recency via RRF) runs
/// over what survives the pre-filter.
public struct MemoryQuery: Sendable, Equatable {
    public var text: String
    public var timeRange: ClosedRange<Date>?
    public var app: String?
    public var entities: [String]
    public var limit: Int

    public init(
        text: String,
        timeRange: ClosedRange<Date>? = nil,
        app: String? = nil,
        entities: [String] = [],
        limit: Int = 8
    ) {
        self.text = text
        self.timeRange = timeRange
        self.app = app
        self.entities = entities
        self.limit = limit
    }
}

/// The single seam feature code depends on for storage + retrieval.
///
/// sqlite-vec is pre-v1 and single-maintainer, so the concrete store is
/// swappable behind this protocol (hedges: usearch, SQLite core Vec1). Feature
/// code MUST NOT call the vector engine directly. See docs/decisions.md (store).
///
/// `purge(before:)` is shard-drop by design: a cutoff maps to dropping whole
/// weekly shard files, which makes "delete everything before X" instant and
/// provable rather than a row-by-row DELETE.
public protocol RetrievalStore: Sendable {
    func upsert(_ chunks: [Chunk]) async throws
    func search(_ query: MemoryQuery) async throws -> [SearchResult]
    func purge(before: Date) async throws
}
