import XCTest
@testable import ScrollbackCore

/// Guards the three append-only audit ledgers — the tamper-evident trust surface.
/// The DAO exposes only append + read (no update/delete); these prove appends
/// accumulate immutably, read back in ts order, and survive reopen.
final class LedgersTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: egress_ledger

    func testEgressAppendAndReadInOrder() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try store.append(EgressRecord(ts: at(20), process: "scrollback-courier",
                                      destinationHost: "api.anthropic.com", purpose: "filing", byteCount: 512))
        try store.append(EgressRecord(ts: at(10), process: "scrollback-courier",
                                      destinationHost: "api.notion.com", purpose: "notion_write"))

        let rows = try store.egressLedger()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0.destinationHost }, ["api.notion.com", "api.anthropic.com"]) // ts ASC
        XCTAssertEqual(rows[1].byteCount, 512)
        XCTAssertNil(rows[0].byteCount) // nullable INTEGER round-trips as nil, not 0
    }

    func testEgressSinceFilter() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try store.append(EgressRecord(ts: at(10), process: "p", destinationHost: "a", purpose: "x"))
        try store.append(EgressRecord(ts: at(100), process: "p", destinationHost: "b", purpose: "x"))
        XCTAssertEqual(try store.egressLedger(since: at(50)).map { $0.destinationHost }, ["b"])
    }

    func testEgressIsAppendOnlyAcrossReopen() throws {
        let dir = NSTemporaryDirectory() + "sb-ledger-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let record = EgressRecord(ts: at(5), process: "p", destinationHost: "h", purpose: "filing")
        do {
            let store = try SQLiteCatalogStore(path: dir)
            try store.append(record)
        }
        // The ledger persists immutably; reopening sees the same row.
        let reopened = try SQLiteCatalogStore(path: dir)
        let rows = try reopened.egressLedger()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first, record)
    }

    // MARK: write_ledger

    /// Minimal filing_drafts row so a write_ledger FK (draft_id) resolves.
    private func seedDraft(_ store: SQLiteCatalogStore, id: UUID) throws {
        try store.db.run(
            "INSERT INTO filing_drafts (id, recipe, created_at, payload) VALUES (?,?,?,?)",
            [.text(id.uuidString), .text("daily_summary"), .double(t0.timeIntervalSince1970), .text("{}")]
        )
    }

    func testWriteLedgerRecordsEveryMutation() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let draft = UUID()
        try seedDraft(store, id: draft)
        // A create then an append then an archive (undo) for the same draft.
        try store.append(WriteRecord(draftID: draft, ts: at(1), action: .create, targetID: "page-1"))
        try store.append(WriteRecord(draftID: draft, ts: at(2), action: .append, targetID: "page-1"))
        try store.append(WriteRecord(draftID: draft, ts: at(3), action: .archive, targetID: "page-1"))

        let rows = try store.writeLedger(forDraft: draft)
        XCTAssertEqual(rows.map { $0.action }, [.create, .append, .archive]) // full trail, drives undo
        // A different draft is isolated by the filter.
        XCTAssertTrue(try store.writeLedger(forDraft: UUID()).isEmpty)
    }

    func testWriteLedgerNullDraftAllowed() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try store.append(WriteRecord(draftID: nil, ts: at(1), action: .create, targetID: "page-x"))
        XCTAssertEqual(try store.writeLedger().count, 1)
        XCTAssertNil(try store.writeLedger().first?.draftID)
    }

    // MARK: consent_log

    func testConsentAppendAndRead() throws {
        let store = try SQLiteCatalogStore.inMemory()
        try store.append(ConsentRecord(ts: at(1), method: "in_app_prompt", note: "granted for 1:1"))
        let rows = try store.consentLog()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.method, "in_app_prompt")
        XCTAssertEqual(rows.first?.note, "granted for 1:1")
    }

    // MARK: append-only accumulation

    func testRepeatedAppendsAccumulateNeverOverwrite() throws {
        let store = try SQLiteCatalogStore.inMemory()
        for index in 0..<5 {
            try store.append(EgressRecord(ts: at(TimeInterval(index)), process: "p",
                                          destinationHost: "h", purpose: "filing"))
        }
        // Five distinct appends → five rows. A ledger never coalesces or overwrites.
        XCTAssertEqual(try store.egressLedger().count, 5)
        XCTAssertEqual(try store.count("egress_ledger"), 5)
    }
}
