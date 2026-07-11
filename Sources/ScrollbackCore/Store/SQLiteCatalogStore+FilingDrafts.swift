import Foundation

/// The filing approval queue DAO. The `filing_drafts` lifecycle enforces the product's
/// central write-side trust invariant — **a draft can only become `committed` from
/// `approved`** — as a DB-level guarantee (guarded `UPDATE … WHERE status='approved'`),
/// so a Notion write can never bypass the user's approval (tech-spec §3d).
///
/// Insert is IDEMPOTENT on `external_key` (client-side dedup standing in for Notion's
/// missing idempotency keys): re-filing the same logical unit (recipe/day/destination)
/// writes nothing and reports it, instead of creating a duplicate draft.
extension SQLiteCatalogStore {

    /// Persist a composed draft. Returns `true` if a row was inserted, `false` if a
    /// draft with the same `external_key` already existed (the idempotent no-op).
    @discardableResult
    public func insertFilingDraft(_ draft: FilingDraft) throws -> Bool {
        try db.run(
            """
            INSERT INTO filing_drafts
              (id, recipe, created_at, payload, source_event_ids, content_hash, external_key,
               status, committed_at, external_system, external_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(external_key) DO NOTHING
            """,
            [
                .text(draft.id.uuidString), .text(draft.recipe),
                .double(draft.createdAt.timeIntervalSince1970), .text(draft.payloadJSON),
                .text(Self.encodeIDs(draft.sourceEventIDs)),
                draft.contentHash.map(SQLiteValue.text) ?? .null,
                .text(draft.externalKey), .text(draft.status.rawValue),
                draft.committedAt.map { SQLiteValue.double($0.timeIntervalSince1970) } ?? .null,
                draft.externalSystem.map(SQLiteValue.text) ?? .null,
                draft.externalID.map(SQLiteValue.text) ?? .null,
            ]
        )
        return db.changesCount == 1
    }

    /// The approval queue: drafts awaiting the user, oldest first.
    public func pendingFilingDrafts(limit: Int = 100) throws -> [FilingDraft] {
        try filingDrafts("WHERE status = 'draft' ORDER BY created_at ASC LIMIT ?", [.int(Int64(max(0, limit)))])
    }

    public func filingDraft(id: UUID) throws -> FilingDraft? {
        try filingDrafts("WHERE id = ?", [.text(id.uuidString)]).first
    }

    public func filingDrafts(status: FilingDraft.Status, limit: Int = 100) throws -> [FilingDraft] {
        try filingDrafts("WHERE status = ? ORDER BY created_at ASC LIMIT ?",
                         [.text(status.rawValue), .int(Int64(max(0, limit)))])
    }

    /// `draft → approved`. Only now may the courier commit it.
    public func approveFilingDraft(id: UUID) throws {
        try transition(id: id, to: .approved, allowedFrom: ["draft"])
    }

    /// `draft`/`approved → dismissed`. The user rejects; it can never commit.
    public func dismissFilingDraft(id: UUID) throws {
        try transition(id: id, to: .dismissed, allowedFrom: ["draft", "approved"])
    }

    /// `approved → committed`. Called by the courier AFTER a successful Notion write —
    /// REQUIRES `approved` (the "approval precedes commit" guarantee lives in this WHERE
    /// clause: a draft/dismissed/committed row cannot be committed).
    public func markFilingDraftCommitted(id: UUID, externalSystem: String, externalID: String, at now: Date) throws {
        try db.run(
            """
            UPDATE filing_drafts SET status='committed', committed_at=?, external_system=?, external_id=?
            WHERE id=? AND status='approved'
            """,
            [.double(now.timeIntervalSince1970), .text(externalSystem), .text(externalID), .text(id.uuidString)]
        )
        if db.changesCount == 0 { throw transitionError(id: id, to: .committed) }
    }

    /// `committed → undone`. The user reverses a committed write (the courier archives
    /// the Notion page and records it in the write ledger).
    public func markFilingDraftUndone(id: UUID) throws {
        try transition(id: id, to: .undone, allowedFrom: ["committed"])
    }

    // MARK: - Internals

    private func transition(id: UUID, to target: FilingDraft.Status, allowedFrom: [String]) throws {
        let inList = allowedFrom.map { "'\($0)'" }.joined(separator: ",")
        try db.run("UPDATE filing_drafts SET status=? WHERE id=? AND status IN (\(inList))",
                   [.text(target.rawValue), .text(id.uuidString)])
        if db.changesCount == 0 { throw transitionError(id: id, to: target) }
    }

    /// 0 rows changed → either the row is gone (`notFound`) or its current status
    /// forbade the transition (`illegalTransition`); a follow-up read distinguishes them.
    private func transitionError(id: UUID, to target: FilingDraft.Status) -> FilingDraftError {
        if let current = try? filingDraft(id: id) {
            return .illegalTransition(from: current.status, to: target)
        }
        return .notFound(id)
    }

    private func filingDrafts(_ clause: String, _ binds: [SQLiteValue]) throws -> [FilingDraft] {
        let statement = try db.prepare(
            "SELECT id, recipe, created_at, payload, source_event_ids, content_hash, external_key, "
                + "status, committed_at, external_system, external_id FROM filing_drafts " + clause
        )
        defer { statement.finalize() }
        try statement.bindAll(binds)
        var out: [FilingDraft] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.text(0)),
                  let externalKey = statement.textOrNil(6),
                  let status = FilingDraft.Status(rawValue: statement.text(7)) else { continue }
            out.append(FilingDraft(
                id: id, recipe: statement.text(1),
                createdAt: Date(timeIntervalSince1970: statement.double(2)),
                payloadJSON: statement.text(3),
                sourceEventIDs: Self.decodeIDs(statement.textOrNil(4)),
                contentHash: statement.textOrNil(5), externalKey: externalKey, status: status,
                committedAt: statement.doubleOrNil(8).map { Date(timeIntervalSince1970: $0) },
                externalSystem: statement.textOrNil(9), externalID: statement.textOrNil(10)
            ))
        }
        return out
    }

    private static func encodeIDs(_ ids: [UUID]) -> String {
        guard let data = try? JSONEncoder().encode(ids.map { $0.uuidString }),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func decodeIDs(_ text: String?) -> [UUID] {
        guard let text, let data = text.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr.compactMap(UUID.init(uuidString:))
    }
}
