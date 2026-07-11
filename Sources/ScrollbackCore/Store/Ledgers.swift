import Foundation

/// One row of `egress_ledger` — the user-visible record of a network request. The
/// courier writes this BEFORE it sends (append-before-send discipline), so the
/// ledger can never be behind the wire.
public struct EgressRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ts: Date
    public let process: String          // e.g. "scrollback-courier"
    public let destinationHost: String  // e.g. "api.anthropic.com"
    public let purpose: String          // e.g. "filing", "model_download", "sparkle"
    public let byteCount: Int?
    public let payloadSHA: String?
    public let trigger: String?         // what caused it (draft id, user action, …)

    public init(id: UUID = UUID(), ts: Date, process: String, destinationHost: String,
                purpose: String, byteCount: Int? = nil, payloadSHA: String? = nil, trigger: String? = nil) {
        self.id = id; self.ts = ts; self.process = process; self.destinationHost = destinationHost
        self.purpose = purpose; self.byteCount = byteCount; self.payloadSHA = payloadSHA; self.trigger = trigger
    }
}

public enum WriteAction: String, Codable, Sendable, CaseIterable {
    case create, append, archive
}

/// One row of `write_ledger` — every Notion mutation, which drives undo (archive).
public struct WriteRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let draftID: UUID?
    public let ts: Date
    public let action: WriteAction
    public let targetID: String?    // the Notion page/block id
    public let payloadSHA: String?
    public let diff: String?

    public init(id: UUID = UUID(), draftID: UUID? = nil, ts: Date, action: WriteAction,
                targetID: String? = nil, payloadSHA: String? = nil, diff: String? = nil) {
        self.id = id; self.draftID = draftID; self.ts = ts; self.action = action
        self.targetID = targetID; self.payloadSHA = payloadSHA; self.diff = diff
    }
}

/// One row of `consent_log` — a meeting-recording consent event. No `audio_segments`
/// row may exist without a corresponding consent record (enforced at the audio lane).
public struct ConsentRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: UUID?
    public let ts: Date
    public let method: String   // how consent was captured/observed
    public let note: String?

    public init(id: UUID = UUID(), meetingID: UUID? = nil, ts: Date, method: String, note: String? = nil) {
        self.id = id; self.meetingID = meetingID; self.ts = ts; self.method = method; self.note = note
    }
}

/// Append-only ledger DAOs. The three ledgers are the product's tamper-evident trust
/// surface, so — per the schema comments and CLAUDE.md — this API exposes ONLY append
/// + read. There is deliberately NO update or delete method: append-only is enforced
/// by the DAO's shape (and review), not by row triggers (which would fight the
/// tables' `ON DELETE CASCADE`/`SET NULL` referential actions). Deletion happens only
/// as whole-shard purge (dropping the file), never as a row DELETE.
extension SQLiteCatalogStore {

    // MARK: - Append (the only mutation)

    public func append(_ record: EgressRecord) throws {
        try db.run(
            "INSERT INTO egress_ledger (id, ts, process, destination_host, purpose, byte_count, payload_sha, trigger) VALUES (?,?,?,?,?,?,?,?)",
            [
                .text(record.id.uuidString), .double(record.ts.timeIntervalSince1970),
                .text(record.process), .text(record.destinationHost), .text(record.purpose),
                record.byteCount.map { SQLiteValue.int(Int64($0)) } ?? .null,
                record.payloadSHA.map(SQLiteValue.text) ?? .null,
                record.trigger.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    public func append(_ record: WriteRecord) throws {
        try db.run(
            "INSERT INTO write_ledger (id, draft_id, ts, action, target_id, payload_sha, diff) VALUES (?,?,?,?,?,?,?)",
            [
                .text(record.id.uuidString),
                record.draftID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .double(record.ts.timeIntervalSince1970), .text(record.action.rawValue),
                record.targetID.map(SQLiteValue.text) ?? .null,
                record.payloadSHA.map(SQLiteValue.text) ?? .null,
                record.diff.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    public func append(_ record: ConsentRecord) throws {
        try db.run(
            "INSERT INTO consent_log (id, meeting_id, ts, method, note) VALUES (?,?,?,?,?)",
            [
                .text(record.id.uuidString),
                record.meetingID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .double(record.ts.timeIntervalSince1970), .text(record.method),
                record.note.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    // MARK: - Read (ordered by ts, oldest first — a ledger is a timeline)

    public func egressLedger(since: Date? = nil) throws -> [EgressRecord] {
        let statement = try db.prepare(
            "SELECT id, ts, process, destination_host, purpose, byte_count, payload_sha, trigger FROM egress_ledger"
                + (since != nil ? " WHERE ts >= ?" : "") + " ORDER BY ts ASC"
        )
        defer { statement.finalize() }
        if let since { try statement.bindAll([.double(since.timeIntervalSince1970)]) }
        var out: [EgressRecord] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.text(0)) else { continue }
            out.append(EgressRecord(
                id: id, ts: Date(timeIntervalSince1970: statement.double(1)),
                process: statement.text(2), destinationHost: statement.text(3), purpose: statement.text(4),
                byteCount: statement.intOrNil(5).map(Int.init), payloadSHA: statement.textOrNil(6),
                trigger: statement.textOrNil(7)
            ))
        }
        return out
    }

    public func writeLedger(forDraft draftID: UUID? = nil) throws -> [WriteRecord] {
        let statement = try db.prepare(
            "SELECT id, draft_id, ts, action, target_id, payload_sha, diff FROM write_ledger"
                + (draftID != nil ? " WHERE draft_id = ?" : "") + " ORDER BY ts ASC"
        )
        defer { statement.finalize() }
        if let draftID { try statement.bindAll([.text(draftID.uuidString)]) }
        var out: [WriteRecord] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.text(0)),
                  let action = WriteAction(rawValue: statement.text(3)) else { continue }
            out.append(WriteRecord(
                id: id, draftID: statement.textOrNil(1).flatMap(UUID.init(uuidString:)),
                ts: Date(timeIntervalSince1970: statement.double(2)), action: action,
                targetID: statement.textOrNil(4), payloadSHA: statement.textOrNil(5), diff: statement.textOrNil(6)
            ))
        }
        return out
    }

    public func consentLog(forMeeting meetingID: UUID? = nil) throws -> [ConsentRecord] {
        let statement = try db.prepare(
            "SELECT id, meeting_id, ts, method, note FROM consent_log"
                + (meetingID != nil ? " WHERE meeting_id = ?" : "") + " ORDER BY ts ASC"
        )
        defer { statement.finalize() }
        if let meetingID { try statement.bindAll([.text(meetingID.uuidString)]) }
        var out: [ConsentRecord] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.text(0)) else { continue }
            out.append(ConsentRecord(
                id: id, meetingID: statement.textOrNil(1).flatMap(UUID.init(uuidString:)),
                ts: Date(timeIntervalSince1970: statement.double(2)), method: statement.text(3),
                note: statement.textOrNil(4)
            ))
        }
        return out
    }
}
