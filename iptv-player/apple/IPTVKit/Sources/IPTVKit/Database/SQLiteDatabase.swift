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

/// One SQLite connection: handle, recursive lock, statement cache.
final class SQLiteConnection: @unchecked Sendable {
    fileprivate var handle: OpaquePointer?
    let lock = NSRecursiveLock()
    private var statementCache: [String: OpaquePointer] = [:]

    init(path: String, flags: Int32) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
    }

    deinit {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    func execute(_ sql: String) throws {
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

    /// Finalizes cached statements whose SQL mentions `fragment` (a dropped per-source table).
    func evictStatements(containing fragment: String) {
        lock.lock(); defer { lock.unlock() }
        for (sql, stmt) in statementCache where sql.contains(fragment) {
            sqlite3_finalize(stmt)
            statementCache[sql] = nil
        }
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

    func run(_ sql: String, _ args: [SQLiteValue]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ args: [SQLiteValue], busyTimeoutMs: Int32? = nil, map: (SQLiteRow) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        if let busyTimeoutMs { sqlite3_busy_timeout(handle, busyTimeoutMs) }
        // Stale searches: a cancelled task interrupts its statement (SQLITE_INTERRUPT) instead of running on.
        let interruptible = SQLiteDatabase.interruptsOnCancel
        if interruptible { sqlite3_progress_handler(handle, 1000, sqliteCancelCheck, nil) }
        defer { if interruptible { sqlite3_progress_handler(handle, 0, nil, nil) } }
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
}

/// Progress handler: non-zero interrupts the running statement when the current task is cancelled.
private func sqliteCancelCheck(_: UnsafeMutableRawPointer?) -> Int32 {
    withUnsafeCurrentTask { $0?.isCancelled == true } ? 1 : 0
}

/// Thread-safe wrapper over the system SQLite3 library: one **writer** connection (all writes, and every
/// read made inside a transaction on the thread that holds it) and – for an on-disk database – one
/// **read-only** connection for all other reads. In WAL mode the reader sees the last committed state and is
/// never blocked by a writer, so a catalog refresh or a background re-index never freezes main-actor reads
/// (ARCHITECTURE §3.1). Each connection is serialized by a recursive lock (`transaction` bodies may call
/// `run`/`query`).
public final class SQLiteDatabase: @unchecked Sendable {
    private let writer: SQLiteConnection
    private let reader: SQLiteConnection?
    /// Thread currently inside `transaction` on the writer (its reads must see its own uncommitted writes).
    private var transactionOwner: pthread_t?
    private var transactionDepth = 0
    /// Guards `transactionOwner` only (never the writer lock: a read must not wait for a running transaction).
    private let ownerLock = NSLock()
    public let path: String
    /// Whether the linked SQLite has FTS5 (system SQLite on iOS/tvOS/macOS does).
    public private(set) var hasFTS5 = false
    /// Whether FTS5's `trigram` tokenizer exists (SQLite ≥ 3.34; iOS/tvOS 17 ship 3.39) – typo-tolerant search.
    public private(set) var hasTrigram = false
    /// True when reads use their own connection (on-disk database).
    public var hasReadConnection: Bool { reader != nil }

    /// Reads in a task with this set are interrupted when the task is cancelled (stale searches).
    @TaskLocal public static var interruptsOnCancel = false
    /// Busy wait of the writer connection (all writes go through it; within the app they are serialized by its
    /// lock, so BUSY only comes from outside: another connection still closing, WAL recovery).
    public static let writerBusyTimeoutMs: Int32 = 5000

    /// True for SQLITE_BUSY / SQLITE_LOCKED (extended codes included): a lock held elsewhere, not a damaged file.
    public static func isBusy(_ error: Error) -> Bool {
        guard let error = error as? SQLiteError else { return false }
        return [5, 6].contains(error.code & 0xFF)
    }

    /// Opens (creating) a database. `path == nil` → private in-memory database (tests; no read connection).
    public init(path: String?) throws {
        self.path = path ?? ":memory:"
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS) || os(tvOS)
        if path != nil { flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION }
        #endif
        writer = try SQLiteConnection(path: self.path, flags: flags)
        // Another connection (a second process, a database still closing, WAL recovery) may hold a lock for a
        // moment: wait for it instead of failing with SQLITE_BUSY ("database is locked").
        sqlite3_busy_timeout(writer.handle, Self.writerBusyTimeoutMs)
        try writer.execute("PRAGMA foreign_keys = OFF; PRAGMA temp_store = MEMORY; PRAGMA cache_size = -32000;")
        if path != nil { try writer.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;") }
        if path != nil {
            var readFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            #if os(iOS) || os(tvOS)
            readFlags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
            #endif
            reader = try? SQLiteConnection(path: self.path, flags: readFlags)
            try? reader?.execute("PRAGMA temp_store = MEMORY; PRAGMA cache_size = -32000;")
        } else {
            reader = nil
        }
        hasFTS5 = (try? writer.execute("CREATE VIRTUAL TABLE IF NOT EXISTS temp.__fts5_probe USING fts5(x); DROP TABLE temp.__fts5_probe;")) != nil
        hasTrigram = hasFTS5 && (try? writer.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS temp.__tri_probe USING fts5(x, tokenize = 'trigram'); DROP TABLE temp.__tri_probe;")) != nil
    }

    /// Connection for a read: the writer inside this thread's transaction, else the reader.
    private var readConnection: SQLiteConnection {
        guard let reader else { return writer }
        ownerLock.lock(); defer { ownerLock.unlock() }
        if let owner = transactionOwner, pthread_equal(owner, pthread_self()) != 0 { return writer }
        return reader
    }

    /// Executes one or more statements without parameters (writer).
    public func execute(_ sql: String) throws {
        try writer.execute(sql)
    }

    /// Runs a write statement; returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ args: [SQLiteValue] = []) throws -> Int {
        try writer.run(sql, args)
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ args: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        let connection = readConnection
        // Reader busy wait (WAL recovery/checkpoint edge cases): short on the main thread, 1.5 s in the background.
        let timeout: Int32? = connection === reader ? (Thread.isMainThread ? 100 : 1500) : nil
        return try connection.query(sql, args, busyTimeoutMs: timeout, map: map)
    }

    /// First row of a query, if any.
    public func queryFirst<T>(_ sql: String, _ args: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> T? {
        try query(sql, args, map: map).first
    }

    /// Scalar integer (COUNT(*) etc.).
    public func scalar(_ sql: String, _ args: [SQLiteValue] = []) throws -> Int {
        try queryFirst(sql, args) { $0.int(0) } ?? 0
    }

    /// Forgets cached statements that mention `fragment` on both connections (a dropped table).
    public func evictStatements(containing fragment: String) {
        writer.evictStatements(containing: fragment)
        reader?.evictStatements(containing: fragment)
    }

    /// Runs `body` in a transaction on the writer (nested calls join the outer one via savepoints). Reads of the
    /// calling thread inside `body` go to the writer and see the uncommitted changes; other threads keep
    /// reading the last committed state from the reader without waiting.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        writer.lock.lock(); defer { writer.lock.unlock() }
        ownerLock.lock()
        if transactionDepth == 0 { transactionOwner = pthread_self() }
        transactionDepth += 1
        ownerLock.unlock()
        defer {
            ownerLock.lock()
            transactionDepth -= 1
            if transactionDepth == 0 { transactionOwner = nil }
            ownerLock.unlock()
        }
        let name = "sp\(UInt32.random(in: 0...UInt32.max))"
        try writer.execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try writer.execute("RELEASE \(name)")
            return result
        } catch {
            try? writer.execute("ROLLBACK TO \(name); RELEASE \(name)")
            throw error
        }
    }

    /// Runs `body` with the writer lock if it is free right now (or already held by this thread); nil when
    /// another thread is writing (a refresh commit) – the caller can defer the write instead of blocking.
    public func ifWriterFree<T>(_ body: () throws -> T) rethrows -> T? {
        guard writer.lock.try() else { return nil }
        defer { writer.lock.unlock() }
        return try body()
    }

    /// `PRAGMA user_version` (writer: the migration's own view).
    public var userVersion: Int {
        get { (try? writer.query("PRAGMA user_version", []) { $0.int(0) }.first) ?? 0 }
        set { try? writer.execute("PRAGMA user_version = \(newValue)") }
    }
}
