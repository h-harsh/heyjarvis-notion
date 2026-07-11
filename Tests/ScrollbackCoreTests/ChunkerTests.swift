import XCTest
@testable import ScrollbackCore

final class ChunkerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // 1 token per word — exact arithmetic for deterministic assertions.
    private let wordCount: @Sendable (String) -> Int = { $0.split(separator: " ").count }

    private func event(
        _ text: String,
        source: CaptureSource = .ax,
        ts: Date? = nil,
        episode: UUID = UUID()
    ) -> CaptureEvent {
        CaptureEvent(episodeID: episode, ts: ts ?? t0, type: .screenText, source: source, rawText: text)
    }

    // MARK: Splitting

    func testEmptyAndWhitespaceProduceNoChunks() {
        let chunker = Chunker(estimateTokens: wordCount)
        XCTAssertEqual(chunker.split(""), [])
        XCTAssertEqual(chunker.split("   \n  "), [])
    }

    func testShortTextIsOneChunk() {
        let chunker = Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount)
        XCTAssertEqual(chunker.split("a b c."), ["a b c."])
    }

    func testSentencePackingRespectsBudget() {
        let chunker = Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount)
        let pieces = chunker.split("a b c. d e f. g h i. j k l.")
        XCTAssertEqual(pieces.count, 2) // packs two 3-word sentences per ~5-token chunk
        for piece in pieces {
            XCTAssertLessThanOrEqual(wordCount(piece), 8) // never exceeds maxTokens
        }
    }

    func testOversizedSentenceIsHardSplitByWords() {
        let chunker = Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount)
        let twenty = (1...20).map { "w\($0)" }.joined(separator: " ") // one 20-word "sentence", no period
        let pieces = chunker.split(twenty)
        XCTAssertEqual(pieces.count, 3) // 8 + 8 + 4
        for piece in pieces {
            XCTAssertLessThanOrEqual(wordCount(piece), 8)
        }
        // No content lost.
        XCTAssertEqual(pieces.joined(separator: " "), twenty)
    }

    func testChunkCarriesEventForeignKeysAndSource() {
        let chunker = Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount)
        let e = event("a b c.", source: .ocr)
        let chunks = chunker.chunk(e)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].episodeID, e.episodeID)
        XCTAssertEqual(chunks[0].eventID, e.id)
        XCTAssertEqual(chunks[0].source, .ocr)
        XCTAssertEqual(chunks[0].tsCapture, e.ts)
        XCTAssertEqual(chunks[0].tokenCount, 3)
        XCTAssertNil(chunks[0].tsEvent) // filled later by dual-timestamp extraction
    }

    func testDefaultEstimateIsNonZeroAndScales() {
        XCTAssertEqual(Chunker.defaultEstimate(""), 0)
        XCTAssertGreaterThanOrEqual(Chunker.defaultEstimate("one"), 1)
        XCTAssertGreaterThan(
            Chunker.defaultEstimate(String(repeating: "word ", count: 100)),
            Chunker.defaultEstimate("word")
        )
    }

    // MARK: ChunkingStage — dedup + volume

    func testIdenticalRereadStoredOnce() {
        let stage = ChunkingStage(chunker: Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount))
        let text = "a b c. d e f. g h i. j k l."

        let first = stage.ingest(event(text))
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(stage.stats.chunksStored, 2)

        let second = stage.ingest(event(text)) // same content, later re-read
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(stage.stats.chunksStored, 2)       // unchanged
        XCTAssertEqual(stage.stats.chunksProduced, 4)     // both events produced chunks
        XCTAssertEqual(stage.stats.dedupSkips, 2)
        XCTAssertGreaterThan(stage.stats.rawChars, stage.stats.storedChars) // dedup shrank stored volume
    }

    func testVectorCountEqualsStoredChunks() {
        let stage = ChunkingStage(chunker: Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount))
        stage.ingest(event("a b c. d e f."))
        stage.ingest(event("x y z. p q r."))
        // Each unique chunk becomes exactly one vector once embedded.
        XCTAssertEqual(stage.stats.chunksStored, 2)
    }

    func testHourlyVolumeBuckets() {
        let stage = ChunkingStage(chunker: Chunker(targetTokens: 5, maxTokens: 8, estimateTokens: wordCount))
        stage.ingest(event("a b c.", ts: t0))
        stage.ingest(event("d e f.", ts: t0.addingTimeInterval(3600))) // next hour
        XCTAssertEqual(stage.hourly.count, 2)
        for (_, volume) in stage.hourly {
            XCTAssertEqual(volume.chunksStored, 1)
            XCTAssertGreaterThan(volume.storedChars, 0)
        }
    }

    // MARK: ChunkingStage — near-dup collapse

    private func longDoc(_ namespace: String, words: Int = 60) -> String {
        (0..<words).map { "\(namespace)\($0)" }.joined(separator: " ")
    }

    func testNearDuplicateRereadIsCollapsedNotStored() {
        // A scrolled re-read (same doc + a couple appended words) is NOT byte-equal,
        // so exact-hash dedup misses it; MinHash collapse must catch it.
        let stage = ChunkingStage(chunker: Chunker(targetTokens: 4000, maxTokens: 8000))
        let base = longDoc("a")

        let first = stage.ingest(event(base))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(stage.stats.chunksStored, 1)

        let second = stage.ingest(event(base + " a60 a61")) // scrolled re-read
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(stage.stats.chunksStored, 1)   // not re-stored
        XCTAssertEqual(stage.stats.nearDupSkips, 1)
        XCTAssertEqual(stage.stats.dedupSkips, 0)     // it wasn't an EXACT match
    }

    func testDisablingNearDupKeepsNearDuplicates() {
        // With near-dup off, only exact-hash dedup applies — the scrolled re-read
        // is a distinct chunk and IS stored.
        let stage = ChunkingStage(
            chunker: Chunker(targetTokens: 4000, maxTokens: 8000),
            nearDup: nil
        )
        let base = longDoc("a")
        stage.ingest(event(base))
        stage.ingest(event(base + " a60 a61"))
        XCTAssertEqual(stage.stats.chunksStored, 2)
        XCTAssertEqual(stage.stats.nearDupSkips, 0)
    }

    func testDistinctDocsSurviveNearDup() {
        // Default (near-dup on): genuinely different documents are all retained.
        let stage = ChunkingStage(chunker: Chunker(targetTokens: 4000, maxTokens: 8000))
        stage.ingest(event(longDoc("a")))
        stage.ingest(event(longDoc("b")))
        stage.ingest(event(longDoc("c")))
        XCTAssertEqual(stage.stats.chunksStored, 3)
        XCTAssertEqual(stage.stats.nearDupSkips, 0)
    }
}
