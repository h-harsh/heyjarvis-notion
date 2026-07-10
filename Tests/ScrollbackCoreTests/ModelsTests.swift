import XCTest
@testable import ScrollbackCore

final class ModelsTests: XCTestCase {

    /// The security invariant: anything captured is untrusted by default.
    func testCaptureEventDefaultsToUntrustedAmbient() {
        let event = CaptureEvent(
            episodeID: UUID(),
            ts: Date(),
            type: .screenText,
            source: .ax,
            rawText: "hello"
        )
        XCTAssertEqual(event.provenance, .untrustedAmbient)
    }

    /// A freshly created chunk is not yet embedded (no model recorded).
    func testChunkStartsUnembedded() {
        let chunk = Chunk(
            episodeID: UUID(),
            eventID: UUID(),
            text: "some text",
            tokenCount: 2,
            tsCapture: Date(),
            source: .ax
        )
        XCTAssertFalse(chunk.isEmbedded)

        var embedded = chunk
        embedded.modelID = "embeddinggemma-300m-q4_0"
        embedded.dim = 512
        XCTAssertTrue(embedded.isEmbedded)
    }

    /// Codable round-trip preserves fields (the store persists these as JSON/columns).
    func testEpisodeCodableRoundTrip() throws {
        let original = Episode(
            tsStart: Date(timeIntervalSince1970: 1_000),
            tsEnd: Date(timeIntervalSince1970: 2_000),
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#general",
            url: nil,
            summary: nil,
            entityKeys: ["rahul", "friday"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Episode.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
