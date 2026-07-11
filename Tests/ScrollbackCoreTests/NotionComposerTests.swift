import XCTest
@testable import ScrollbackCore

/// Guards the privileged composer: it turns a VALIDATED FilingExtract into
/// well-formed Notion blocks, structurally cannot emit a URL/image, and never
/// touches raw captured text (its input type is the validated extract).
final class NotionComposerTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func json(_ draft: NotionPageDraft) throws -> [String: Any] {
        let data = try JSONEncoder().encode(draft)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func jsonString(_ draft: NotionPageDraft) throws -> String {
        String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
    }
    private func children(_ obj: [String: Any]) -> [[String: Any]] {
        (obj["children"] as? [[String: Any]]) ?? []
    }
    private func richText(_ block: [String: Any], _ type: String) -> String? {
        ((block[type] as? [String: Any])?["rich_text"] as? [[String: Any]])?
            .first.flatMap { ($0["text"] as? [String: Any])?["content"] as? String }
    }

    func testBlockShapeIsValidNotion() throws {
        let extract = FilingExtract(logEntries: [.init(text: "debugged the ingest worker")])
        let obj = try json(NotionComposer.compose(extract, title: "2027-01-15", timeZone: utc))
        XCTAssertEqual(obj["title"] as? String, "2027-01-15")
        let blocks = children(obj)
        XCTAssertEqual(blocks[0]["object"] as? String, "block")
        XCTAssertEqual(blocks[0]["type"] as? String, "heading_2")
        XCTAssertEqual(richText(blocks[0], "heading_2"), "Log")
        XCTAssertEqual(blocks[1]["type"] as? String, "bulleted_list_item")
        XCTAssertEqual(richText(blocks[1], "bulleted_list_item"), "debugged the ingest worker")
    }

    func testCommitmentsBecomeCheckboxesWithDueDate() throws {
        let due = Date(timeIntervalSince1970: 1_800_086_400) // 2027-01-16 08:00 UTC
        let extract = FilingExtract(commitments: [.init(text: "send the deck", due: due)])
        let blocks = children(try json(NotionComposer.compose(extract, title: "t", timeZone: utc)))
        XCTAssertEqual(blocks[0]["type"] as? String, "heading_2")
        XCTAssertEqual(richText(blocks[0], "heading_2"), "Commitments")
        XCTAssertEqual(blocks[1]["type"] as? String, "to_do")
        XCTAssertEqual(richText(blocks[1], "to_do"), "send the deck (due 2027-01-16)")
        XCTAssertEqual((blocks[1]["to_do"] as? [String: Any])?["checked"] as? Bool, false)
    }

    func testAllThreeSectionsInOrder() throws {
        let extract = FilingExtract(
            commitments: [.init(text: "ship it")],
            logEntries: [.init(text: "reviewed PRs")],
            reading: [.init(title: "a paper on fusion")]
        )
        let types = children(try json(NotionComposer.compose(extract, title: "t", timeZone: utc)))
            .compactMap { block -> String? in
                let type = block["type"] as? String
                if type == "heading_2" { return "H:" + (richText(block, "heading_2") ?? "") }
                return type
            }
        XCTAssertEqual(types, ["H:Commitments", "to_do", "H:Log", "bulleted_list_item", "H:Reading", "bulleted_list_item"])
    }

    func testEmptyExtractStillProducesAPlaceholder() throws {
        let blocks = children(try json(NotionComposer.compose(FilingExtract(), title: "t", timeZone: utc)))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "paragraph")
    }

    // MARK: Security — the composer cannot introduce an exfil channel

    func testComposedPayloadNeverContainsLinkOrURL() throws {
        // Even if a field mentioned a domain, the composer sets no `link` and adds no
        // markup — the output has no link property (URLs are already rejected upstream
        // by the validator; this is defense-in-depth on the composer side).
        let extract = FilingExtract(
            logEntries: [.init(text: "looked at the acme dashboard")],
            reading: [.init(title: "notes on retrieval")]
        )
        let payload = try jsonString(NotionComposer.compose(extract, title: "t", timeZone: utc))
        XCTAssertFalse(payload.contains("\"link\""))
        XCTAssertFalse(payload.lowercased().contains("http"))
        XCTAssertFalse(payload.contains("]("))
    }

    func testEncodedRichTextHasNoLinkField() throws {
        // A rich-text run is plain {type:"text", text:{content}} — no link key.
        let data = try JSONEncoder().encode(NotionRichText("hello"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "text")
        XCTAssertNotNil(obj["text"])
        XCTAssertNil((obj["text"] as? [String: Any])?["link"] ?? obj["link"])
    }
}
