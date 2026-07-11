import XCTest
@testable import ScrollbackCore

/// The filing approval queue: idempotent insert (external_key dedup) and the status
/// lifecycle that ENFORCES "approval precedes commit" — the write-side trust guarantee
/// (tech-spec §3d). A commit is only reachable from `approved`; everything else throws.
final class FilingDraftQueueTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let payload = #"{"title":"Daily Summary","children":[]}"#
    private func draft(_ key: String, createdAt: Date, recipe: String = "daily_summary",
                       ids: [UUID] = []) -> FilingDraft {
        FilingDraft(recipe: recipe, createdAt: createdAt, payloadJSON: payload,
                    sourceEventIDs: ids, contentHash: "h", externalKey: key)
    }

    // MARK: - The trust invariant

    func testCommitRequiresApproval() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let d = draft("daily_summary:2026-07-11:notion", createdAt: at(0))
        try store.insertFilingDraft(d)

        // A NON-approved draft cannot be committed — the DB-enforced guarantee.
        XCTAssertThrowsError(try store.markFilingDraftCommitted(
            id: d.id, externalSystem: "notion", externalID: "pg1", at: at(1))) { err in
            XCTAssertEqual(err as? FilingDraftError, .illegalTransition(from: .draft, to: .committed))
        }
        XCTAssertEqual(try store.filingDraft(id: d.id)?.status, .draft) // unchanged

        // Approve → commit succeeds and records the external ids + timestamp.
        try store.approveFilingDraft(id: d.id)
        try store.markFilingDraftCommitted(id: d.id, externalSystem: "notion", externalID: "pg1", at: at(2))
        let committed = try XCTUnwrap(try store.filingDraft(id: d.id))
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(committed.externalID, "pg1")
        XCTAssertEqual(committed.externalSystem, "notion")
        XCTAssertEqual(committed.committedAt, at(2))
    }

    func testCannotCommitADismissedDraft() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let d = draft("k", createdAt: at(0))
        try store.insertFilingDraft(d)
        try store.dismissFilingDraft(id: d.id)
        XCTAssertThrowsError(try store.markFilingDraftCommitted(
            id: d.id, externalSystem: "notion", externalID: "x", at: at(1)))
        XCTAssertThrowsError(try store.approveFilingDraft(id: d.id)) // and can't be revived
        XCTAssertEqual(try store.filingDraft(id: d.id)?.status, .dismissed)
    }

    // MARK: - Idempotency

    func testInsertIsIdempotentOnExternalKey() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let key = "daily_summary:2026-07-11:notion"
        XCTAssertTrue(try store.insertFilingDraft(draft(key, createdAt: at(0))))
        XCTAssertFalse(try store.insertFilingDraft(draft(key, createdAt: at(5)))) // same key → no-op
        XCTAssertEqual(try store.pendingFilingDrafts().count, 1) // no duplicate
    }

    // MARK: - Queue

    func testPendingQueueOldestFirstAndApproveDequeues() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let a = draft("k-a", createdAt: at(10))
        let b = draft("k-b", createdAt: at(5))
        try store.insertFilingDraft(a)
        try store.insertFilingDraft(b)
        XCTAssertEqual(try store.pendingFilingDrafts().map { $0.externalKey }, ["k-b", "k-a"]) // created_at ASC

        try store.approveFilingDraft(id: a.id)
        XCTAssertEqual(try store.pendingFilingDrafts().map { $0.externalKey }, ["k-b"])
        XCTAssertEqual(try store.filingDrafts(status: .approved).map { $0.externalKey }, ["k-a"])
    }

    // MARK: - Not found

    func testTransitionsOnMissingDraftThrowNotFound() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let ghost = UUID()
        XCTAssertEqual(try? errorOf { try store.approveFilingDraft(id: ghost) }, .notFound(ghost))
    }

    // MARK: - Undo

    func testUndoOnlyFromCommitted() throws {
        let store = try SQLiteCatalogStore.inMemory()
        let d = draft("k", createdAt: at(0))
        try store.insertFilingDraft(d)
        XCTAssertThrowsError(try store.markFilingDraftUndone(id: d.id)) // a draft can't be undone

        try store.approveFilingDraft(id: d.id)
        try store.markFilingDraftCommitted(id: d.id, externalSystem: "notion", externalID: "pg", at: at(1))
        try store.markFilingDraftUndone(id: d.id)
        XCTAssertEqual(try store.filingDraft(id: d.id)?.status, .undone)
    }

    // MARK: - Persistence

    func testFieldsRoundTripAcrossReopen() throws {
        let path = NSTemporaryDirectory() + "sb-drafts-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ids = [UUID(), UUID()]
        let d = draft("k", createdAt: at(0), ids: ids)
        do {
            let store = try SQLiteCatalogStore(path: path)
            try store.insertFilingDraft(d)
            try store.approveFilingDraft(id: d.id)
        }
        let reopened = try SQLiteCatalogStore(path: path)
        let back = try XCTUnwrap(try reopened.filingDraft(id: d.id))
        XCTAssertEqual(back.status, .approved)
        XCTAssertEqual(back.sourceEventIDs, ids)   // json-array provenance survives
        XCTAssertEqual(back.contentHash, "h")
        XCTAssertEqual(back.payloadJSON, payload)  // the composed body is preserved verbatim
        XCTAssertEqual(back.recipe, "daily_summary")
    }

    // MARK: - helper

    private func errorOf(_ body: () throws -> Void) throws -> FilingDraftError? {
        do { try body(); return nil } catch let e as FilingDraftError { return e }
    }
}
