import Foundation
import OACSQLite

/// A thread-safe SQLite wrapper for GeoPackage operations.
///
/// All SQLite C API calls are serialised through a recursive lock so the
/// handle can be used from any task without synchronisation issues. The
/// recursive lock is required because ``withTransaction(_:)`` keeps the lock
/// while its body performs further ``SQLiteDB`` operations.
final class SQLiteDB: @unchecked Sendable {

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    /// The file path this database was opened from.
    let path: String

    /// Opens a SQLite database.
    ///
    /// - Parameters:
    ///   - path: The database file path.
    ///   - readOnly: When `true`, the file is opened with
    ///     `SQLITE_OPEN_READONLY`. Missing files then fail instead of being
    ///     created, which is important for read and validation entry points.
    init(path: String, readOnly: Bool = false) throws {
        self.path = path

        var handle: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(path, &handle, flags, nil)

        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unknown error"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw GeoPackageError.couldNotOpenDatabase(path: path, detail: message)
        }

        db = handle
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    /// Closes the database connection. Calling this more than once is safe.
    func close() {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = db else { return }
        sqlite3_close_v2(handle)
        db = nil
    }

    // MARK: - Execute (no results)

    /// Executes one or more SQL statements without bindings.
    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try _execute(sql)
    }

    /// Executes a single SQL statement with bindings.
    ///
    /// Use this for every statement that carries values; it avoids SQL
    /// injection and preserves SQLite storage classes.
    func execute(_ sql: String, values: [Any?]) throws {
        lock.lock()
        defer { lock.unlock() }

        let stmt = try _prepare(sql)
        defer { sqlite3_finalize(stmt) }

        for (index, value) in values.enumerated() {
            try SQLiteDB.bind(stmt, index: Int32(index + 1), value: value)
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw GeoPackageError.sqliteError(detail: lastError())
        }
    }

    // MARK: - Transactions

    /// Runs `body` inside a transaction, committing on success and rolling
    /// back on error.
    ///
    /// Nested calls join the outer transaction instead of issuing a nested
    /// `BEGIN`, which SQLite does not support.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        if transactionDepth > 0 {
            return try body()
        }

        try _execute("BEGIN IMMEDIATE;")
        transactionDepth = 1

        do {
            let result = try body()
            try _execute("COMMIT;")
            transactionDepth = 0
            return result
        }
        catch {
            // Roll back the whole transaction; ignore rollback errors so the
            // original error is not masked.
            _ = try? _execute("ROLLBACK;")
            transactionDepth = 0
            throw error
        }
    }

    // MARK: - Query (returns rows)

    /// Runs a query without bindings.
    func query(_ sql: String) throws -> [[String: Sendable]] {
        try query(sql, values: [])
    }

    /// Runs a query with bindings.
    func query(_ sql: String, values: [Any?]) throws -> [[String: Sendable]] {
        lock.lock()
        defer { lock.unlock() }
        return try _query(sql, values: values)
    }

    // MARK: - Query raw blob

    /// Runs a query with bindings and returns the first column of every row
    /// as blob data.
    func queryRawBlob(_ sql: String, values: [Any?]) throws -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return try _queryRawBlob(sql, values: values)
    }

    // MARK: - Last insert row ID

    func lastInsertRowId() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Private helpers (called with the lock held)

    private func lastError() -> String {
        guard let db else { return "Database is closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func _execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)

        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw GeoPackageError.sqliteError(detail: message)
        }
    }

    private func _prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)

        guard rc == SQLITE_OK, let stmt else {
            throw GeoPackageError.sqliteError(detail: lastError())
        }
        return stmt
    }

    private func _query(
        _ sql: String,
        values: [Any?]
    ) throws -> [[String: Sendable]] {
        let stmt = try _prepare(sql)
        defer { sqlite3_finalize(stmt) }

        for (index, value) in values.enumerated() {
            try SQLiteDB.bind(stmt, index: Int32(index + 1), value: value)
        }

        var results: [[String: Sendable]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw GeoPackageError.sqliteError(detail: lastError())
            }

            let columnCount = sqlite3_column_count(stmt)
            var row: [String: Sendable] = [:]
            row.reserveCapacity(Int(columnCount))

            for i in 0 ..< columnCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let declaredType = columnDeclaredType(stmt, i)
                row[name] = columnValue(stmt, i, declaredType: declaredType)
            }
            results.append(row)
        }
        return results
    }

    private func _queryRawBlob(
        _ sql: String,
        values: [Any?]
    ) throws -> [Data?] {
        let stmt = try _prepare(sql)
        defer { sqlite3_finalize(stmt) }

        for (index, value) in values.enumerated() {
            try SQLiteDB.bind(stmt, index: Int32(index + 1), value: value)
        }

        var results: [Data?] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw GeoPackageError.sqliteError(detail: lastError())
            }

            if sqlite3_column_type(stmt, 0) == SQLITE_BLOB {
                let length = Int(sqlite3_column_bytes(stmt, 0))
                if length == 0 {
                    results.append(Data())
                }
                else if let bytes = sqlite3_column_blob(stmt, 0) {
                    results.append(Data(bytes: bytes, count: length))
                }
                else {
                    results.append(nil)
                }
            }
            else {
                results.append(nil)
            }
        }
        return results
    }

    private func columnDeclaredType(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let ptr = sqlite3_column_decltype(stmt, i) else { return "" }
        return String(cString: ptr).lowercased()
    }

    private func columnValue(
        _ stmt: OpaquePointer,
        _ i: Int32,
        declaredType: String
    ) -> (any Sendable)? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL:
            return nil

        case SQLITE_INTEGER:
            let raw = sqlite3_column_int64(stmt, i)
            if declaredType == "boolean" || declaredType == "bool" {
                return raw != 0
            }
            if let int = Int(exactly: raw) {
                return int
            }
            return raw

        case SQLITE_FLOAT:
            return sqlite3_column_double(stmt, i)

        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: text)

        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(stmt, i))
            if length == 0 {
                return Data()
            }
            guard let bytes = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: bytes, count: length)

        default:
            return nil
        }
    }

    // MARK: - Bind helpers (static, can be called from anywhere)

    /// SQLite's `SQLITE_TRANSIENT` destructor: SQLite copies the bound value
    /// before returning, so Swift-owned buffers stay valid.
    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self)

    /// Bind a value to a prepared statement at the given 1-based index.
    ///
    /// - Important: `String` values are always bound as `TEXT`. They are never
    ///   auto-detected as Base64, which previously corrupted ordinary text
    ///   that happened to look like Base64 (for example `"Test"` or `"1234"`).
    ///   Pass `Data` to store a BLOB.
    static func bind(
        _ stmt: OpaquePointer,
        index: Int32,
        value: Any?
    ) throws {
        let rc: Int32

        switch value {
        case nil:
            rc = sqlite3_bind_null(stmt, index)
        case let v as Bool:
            rc = sqlite3_bind_int64(stmt, index, v ? 1 : 0)
        case let v as any BinaryInteger:
            if let int = Int64(exactly: v) {
                rc = sqlite3_bind_int64(stmt, index, int)
            }
            else {
                // Integers above Int64.max (for example UInt.max) cannot be
                // represented by SQLite INTEGER; store their exact decimal
                // representation as text instead of truncating.
                rc = sqlite3_bind_text(
                    stmt, index, String(describing: v), -1,
                    SQLiteDB.transientDestructor)
            }
        case let v as any BinaryFloatingPoint:
            rc = sqlite3_bind_double(stmt, index, Double(v))
        case let v as String:
            rc = sqlite3_bind_text(
                stmt, index, v, -1, SQLiteDB.transientDestructor)
        case let v as Data:
            if v.isEmpty {
                rc = sqlite3_bind_zeroblob(stmt, index, 0)
            }
            else {
                rc = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        stmt,
                        index,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        SQLiteDB.transientDestructor)
                }
            }
        default:
            throw GeoPackageError.invalidArgument(
                detail: """
                    Cannot bind a value of type \(type(of: value)); only Bool, \
                    integers, floating-point numbers, String and Data are \
                    supported
                    """)
        }

        guard rc == SQLITE_OK else {
            let handle = sqlite3_db_handle(stmt)
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Could not bind parameter \(index)"
            throw GeoPackageError.sqliteError(detail: message)
        }
    }

}
