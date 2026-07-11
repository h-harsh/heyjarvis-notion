import Foundation

/// Splits a `CaptureEvent`'s text into embeddable `Chunk`s in a target token
/// range. Pure + deterministic. Captured text arrives whitespace-normalized (the
/// engine collapses newlines to spaces), so there's no paragraph structure to
/// lean on — we pack SENTENCES up to the token budget and hard-split (by word) any
/// single sentence that overflows.
///
/// Token counting is an ESTIMATE (`estimateTokens`) — the real EmbeddingGemma
/// tokenizer isn't bundled until the embedding task, at which point the estimator
/// is swapped for the true tokenizer and `chunks.token_count` becomes exact.
public struct Chunker: Sendable {
    public let targetTokens: Int
    public let maxTokens: Int
    private let estimateTokens: @Sendable (String) -> Int
    private let eventTime: EventTimeExtractor?

    public init(
        targetTokens: Int = 768,
        maxTokens: Int = 1024,
        estimateTokens: @escaping @Sendable (String) -> Int = Chunker.defaultEstimate,
        eventTime: EventTimeExtractor? = EventTimeExtractor()
    ) {
        self.targetTokens = max(1, min(targetTokens, maxTokens))
        self.maxTokens = max(1, maxTokens)
        self.estimateTokens = estimateTokens
        self.eventTime = eventTime
    }

    public func chunk(_ event: CaptureEvent) -> [Chunk] {
        split(event.rawText).map { text in
            Chunk(
                episodeID: event.episodeID,
                eventID: event.id,
                text: text,
                tokenCount: estimateTokens(text),
                tsCapture: event.ts,
                // Dual timestamp: the event time the chunk REFERS to (if any),
                // resolved relative to when it was captured. Distinct from tsCapture.
                tsEvent: eventTime?.eventTime(in: text, capturedAt: event.ts),
                source: event.source
            )
        }
    }

    // MARK: - Splitting

    func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""
        var currentTokens = 0

        func flush() {
            if !current.isEmpty { chunks.append(current); current = ""; currentTokens = 0 }
        }

        for sentence in sentences(trimmed) {
            let tokens = estimateTokens(sentence)
            if tokens > maxTokens {
                flush() // a single sentence over budget → hard word-split it
                chunks.append(contentsOf: hardSplit(sentence))
                continue
            }
            if currentTokens + tokens > maxTokens { flush() }
            current = current.isEmpty ? sentence : current + " " + sentence
            currentTokens += tokens
            if currentTokens >= targetTokens { flush() }
        }
        flush()
        return chunks
    }

    /// Sentence-ish segmentation: break after `.`/`!`/`?` when followed by a space.
    /// Cheap and deterministic; good enough to keep chunk boundaries readable.
    func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            current.append(char)
            if (char == "." || char == "!" || char == "?"),
               index + 1 < chars.count, chars[index + 1] == " " {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
                index += 1 // consume the boundary space
            }
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Word-packs an oversized segment so no chunk exceeds `maxTokens`. A single
    /// word longer than the budget becomes its own (over-budget) chunk.
    func hardSplit(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var tokens = 0
        for word in text.split(separator: " ").map(String.init) {
            let wordTokens = estimateTokens(word)
            if tokens + wordTokens > maxTokens, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []; tokens = 0
            }
            current.append(word)
            tokens += wordTokens
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }

    /// Heuristic token estimate (~1.3 tokens/word for English) used until the real
    /// tokenizer is bundled. Deliberately conservative-ish; never returns 0 for
    /// non-empty text.
    public static func defaultEstimate(_ text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(words == 0 ? 0 : 1, Int((Double(words) * 1.3).rounded(.up)))
    }
}

/// Per-hour capture volume (keyed by the hour bucket of `ts_capture`). Feeds the
/// week-1 "deduped text volume/hour" instrumentation the PRD gate calls for.
public struct HourlyVolume: Sendable, Equatable {
    public var rawChars = 0
    public var storedChars = 0
    public var chunksStored = 0
    public init() {}
}

/// Running counters for the chunking stage — the observable surface the volume
/// instrumentation logs and the sqlite-vec ~1M re-eval trigger reads.
public struct ChunkVolumeStats: Sendable, Equatable {
    public var rawChars = 0        // chars across all chunks produced (pre-dedup)
    public var storedChars = 0     // chars kept after dedup + near-dup collapse
    public var chunksProduced = 0
    public var chunksStored = 0    // == the vector count once embedded
    public var dedupSkips = 0      // dropped by exact normalized-hash match
    public var nearDupSkips = 0    // dropped by MinHash near-dup collapse (~0.85 Jaccard)
    public init() {}
}

/// The chunk pipeline stage: chunk each event, then drop chunks that are either an
/// exact re-read (normalized-hash match — "identical text stored once") or a NEAR
/// duplicate of already-retained text (MinHash/LSH collapse — a scrolled or lightly
/// edited re-read that isn't byte-equal but would waste the embedding budget), and
/// maintain volume counters (total + per hour). Not thread-safe by contract; the
/// daemon drives it on the main run loop like the rest of capture.
///
/// The seen-hash set + MinHash index are in-memory for the spike; once the encrypted
/// store lands, exact dedup becomes a DB existence check against a chunk-hash index
/// (bounded memory).
public final class ChunkingStage {
    private let chunker: Chunker
    private let nearDup: NearDupCollapser?
    private var seenHashes: Set<String> = []
    public private(set) var stats = ChunkVolumeStats()
    public private(set) var hourly: [Int64: HourlyVolume] = [:]

    /// - Parameter nearDup: MinHash near-dup collapser (default on). Pass `nil` to
    ///   run exact-hash dedup only.
    public init(chunker: Chunker = Chunker(), nearDup: NearDupCollapser? = NearDupCollapser()) {
        self.chunker = chunker
        self.nearDup = nearDup
    }

    /// Chunks `event` and returns the NEW (non-duplicate) chunks to persist.
    @discardableResult
    public func ingest(_ event: CaptureEvent) -> [Chunk] {
        var stored: [Chunk] = []
        for chunk in chunker.chunk(event) {
            let hash = TextNormalizer.hash(TextNormalizer.normalize(chunk.text))
            let hourBucket = Int64(chunk.tsCapture.timeIntervalSince1970 / 3600)

            stats.rawChars += chunk.text.count
            stats.chunksProduced += 1
            bump(hourBucket) { $0.rawChars += chunk.text.count }

            if seenHashes.contains(hash) {
                stats.dedupSkips += 1
                continue
            }
            // Near-dup collapse runs only after the cheap exact-hash miss. A
            // collapsed chunk is intentionally NOT added to `seenHashes` — a later
            // exact re-read of it still resolves via the MinHash index.
            if let nearDup, case .duplicate = nearDup.add(chunk.text) {
                stats.nearDupSkips += 1
                continue
            }
            seenHashes.insert(hash)
            stats.storedChars += chunk.text.count
            stats.chunksStored += 1
            bump(hourBucket) { $0.storedChars += chunk.text.count; $0.chunksStored += 1 }
            stored.append(chunk)
        }
        return stored
    }

    private func bump(_ bucket: Int64, _ mutate: (inout HourlyVolume) -> Void) {
        var volume = hourly[bucket] ?? HourlyVolume()
        mutate(&volume)
        hourly[bucket] = volume
    }

    public var summary: String {
        "chunks_stored=\(stats.chunksStored) exact_dupes=\(stats.dedupSkips) "
            + "near_dupes=\(stats.nearDupSkips) "
            + "raw_chars=\(stats.rawChars) stored_chars=\(stats.storedChars) "
            + "hours=\(hourly.count)"
    }
}
