import Foundation
import SQLite3

/// SQLite failure (message from `sqlite3_errmsg`).
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// A bindable value.
public enum SQLiteValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func from(_ v: String?) -> SQLiteValue { v.map(SQLiteValue.text) ?? .null }
    public static func from(_ v: Int?) -> SQLiteValue { v.map { .int(Int64($0)) } ?? .null }
    public static func from(_ v: Int64?) -> SQLiteValue { v.map(SQLiteValue.int) ?? .null }
    public static func from(_ v: Double?) -> SQLiteValue { v.map(SQLiteValue.double) ?? .null }
    public static func from(_ v: Bool) -> SQLiteValue { .int(v ? 1 : 0) }
    public static func from(_ v: Date?) -> SQLiteValue { v.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null }
}

extension SQLiteValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// Read access to the current result row.
public struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    public func optInt64(_ i: Int32) -> Int64? { isNull(i) ? nil : int64(i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    public func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func optString(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    public func optDate(_ i: Int32) -> Date? { isNull(i) ? nil : Date(timeIntervalSince1970: Double(int64(i)) / 1000) }
    public func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: Double(int64(i)) / 1000) }
    public func data(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe wrapper over the system SQLite3 library. All calls are serialized by a
/// recursive lock (so `transaction` bodies may call `run`/`query`); callers keep work off the
/// main thread for large writes (refresh), small paged reads are cheap.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var statementCache: [String: OpaquePointer] = [:]
    public let path: String
    /// Whether the linked SQLite has FTS5 (system SQLite on iOS/tvOS/macOS does).
    public private(set) var hasFTS5 = false

    /// Opens (creating) a database. `path == nil` → private in-memory database (tests).
    public init(path: String?) throws {
        self.path = path ?? ":memory:"
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS) || os(tvOS)
        if path != nil { flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION }
        #endif
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(self.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        try execute("PRAGMA foreign_keys = OFF; PRAGMA temp_store = MEMORY;")
        if path != nil { try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;") }
        hasFTS5 = (try? execute("CREATE VIRTUAL TABLE IF NOT EXISTS temp.__fts5_probe USING fts5(x); DROP TABLE temp.__fts5_probe;")) != nil
    }

    deinit {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    /// Executes one or more statements without parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: message)
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        statementCache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLiteValue]) throws {
        for (i, value) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
            if rc != SQLITE_OK { throw error(rc) }
        }
    }

    /// Runs a write statement; returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ args: [SQLiteValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ args: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, args)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try map(SQLiteRow(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw error(rc)
            }
        }
        return out
    }

    /// First row of a query, if any.
    public func queryFirst<T>(_ sql: String, _ args: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> T? {
        try query(sql, args, map: map).first
    }

    /// Scalar integer (COUNT(*) etc.).
    public func scalar(_ sql: String, _ args: [SQLiteValue] = []) throws -> Int {
        try queryFirst(sql, args) { $0.int(0) } ?? 0
    }

    /// Runs `body` in a transaction (nested calls join the outer one via savepoints).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let name = "sp\(UInt32.random(in: 0...UInt32.max))"
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name); RELEASE \(name)")
            throw error
        }
    }

    /// `PRAGMA user_version`.
    public var userVersion: Int {
        get { (try? scalar("PRAGMA user_version")) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }
}
