import Foundation
import SQLite3

// SQLite passes these as the last arg to bind/column text; the "transient" form
// tells SQLite to copy the bytes (safe when the Swift String is temporary).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, Equatable {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)
}

/// A thin, synchronous wrapper over the SQLite C API. Deliberately minimal — it
/// isolates every `sqlite3_*` call so the rest of the store is plain Swift.
///
/// SQLCipher swap point: SQLCipher is API-identical to SQLite, so switching to an
/// encrypted DB is (1) linking SQLCipher instead of system libsqlite3 and (2)
/// issuing `PRAGMA key` as the FIRST statement after open — handled in `init` via
/// the `key` parameter. The rest of this file, and all DAOs, are unchanged by that
/// swap. Real key material comes from the Secure-Enclave custody layer (store b).
///
/// Not thread-safe by contract: confine one instance to a single actor/queue.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String, key: String? = nil) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open \(path)"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        self.handle = db

        // MUST be the first statement on an encrypted DB (SQLCipher). No-op path
        // on system SQLite (key is nil for the spike).
        if let key {
            try exec("PRAGMA key = '\(key.replacingOccurrences(of: "'", with: "''"))'")
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
        // So an FK-cascade delete of a chunk fires the chunks_fts cleanup trigger.
        try exec("PRAGMA recursive_triggers = ON")
        try exec("PRAGMA busy_timeout = 3000")
    }

    deinit { sqlite3_close(handle) }

    // MARK: - Execution

    /// Runs one or more statements with no result rows (DDL, pragmas, simple writes).
    public func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorPointer)
            throw SQLiteError.exec(message)
        }
    }

    /// Runs `body` inside an IMMEDIATE transaction, committing on success and
    /// rolling back on any thrown error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Prepared statements

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt: stmt, db: handle)
    }

    /// Prepare, bind, and step a write statement to completion.
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(params)
        try statement.stepDone()
    }

    // MARK: - PRAGMAs / metadata

    public var userVersion: Int {
        get {
            (try? prepare("PRAGMA user_version"))?.oneInt() ?? 0
        }
        set {
            try? exec("PRAGMA user_version = \(newValue)")
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

/// A bound value for a prepared statement.
public enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
    case null
}

/// A prepared statement. One-shot: bind, step, then `finalize()`.
public final class Statement {
    private let stmt: OpaquePointer
    private let db: OpaquePointer?

    init(stmt: OpaquePointer, db: OpaquePointer?) {
        self.stmt = stmt
        self.db = db
    }

    public func bindAll(_ params: [SQLiteValue]) throws {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1) // SQLite bind indices are 1-based
            let code: Int32
            switch value {
            case .int(let v): code = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): code = sqlite3_bind_double(stmt, index, v)
            case .text(let v): code = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let bytes):
                code = bytes.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
            case .null: code = sqlite3_bind_null(stmt, index)
            }
            guard code == SQLITE_OK else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
        }
    }

    /// Steps once; true if a row is available, false at completion.
    @discardableResult
    public func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Steps a non-select statement to completion.
    public func stepDone() throws {
        while try step() {}
    }

    // Column readers (0-based).
    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }
    public func text(_ column: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: c)
    }
    public func textOrNil(_ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : text(column)
    }
    public func blob(_ column: Int32) -> [UInt8] {
        guard let pointer = sqlite3_column_blob(stmt, column) else { return [] }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return Array(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    /// Convenience for a single-row single-int result (e.g. COUNT, PRAGMA).
    func oneInt() -> Int {
        defer { finalize() }
        return (try? step()) == true ? Int(int(0)) : 0
    }

    public func finalize() { sqlite3_finalize(stmt) }
}
