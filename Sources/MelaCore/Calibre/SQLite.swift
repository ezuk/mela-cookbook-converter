import Foundation
import CSQLite

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// A minimal SQLite wrapper: enough to read Calibre's metadata.db (and build one in tests).
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    /// Opens read-only by default, so Calibre can keep the library open and nothing here can change it.
    public init(path: String, readOnly: Bool = true) throws {
        let flags = readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let name = readOnly ? "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro" : path
        guard sqlite3_open_v2(name, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError(description: "Couldn't open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "error"
            sqlite3_free(err)
            throw SQLiteError(description: message)
        }
    }

    /// Runs a query and returns rows as column-name → text (nil for NULL).
    public func query(_ sql: String) throws -> [[String: String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(description: String(cString: sqlite3_errmsg(handle))) }
            var row: [String: String?] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                if let text = sqlite3_column_text(stmt, c) { row[name] = String(cString: text) } else { row[name] = .some(nil) }
            }
            rows.append(row)
        }
        return rows
    }
}
