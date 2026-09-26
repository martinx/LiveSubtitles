//
//  SQLite.swift
//  LiveSubtitlesKit
//
//  A very small wrapper over the system SQLite. Deliberately thin: the store below is the
//  only caller, and swapping in a richer library later would touch this file alone.
//
//  SQLite rather than a document format because the history is a relational archive:
//  search across everything, aggregate word frequencies, join cues to notes. It is also
//  already on the machine, with FTS5 compiled in, so this adds no dependency.
//

import Foundation
import SQLite3

/// Tell SQLite to copy bound text, rather than borrow a pointer into Swift-owned memory.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .open(let message):            return "Could not open the history database: \(message)"
        case .prepare(let message, let sql): return "SQL error (\(message)) preparing: \(sql)"
        case .step(let message, let sql):    return "SQL error (\(message)) running: \(sql)"
        }
    }
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        self.handle = handle
        // WAL keeps the UI reading while the caption pipeline appends.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    var userVersion: Int {
        (try? query("PRAGMA user_version;") { Int($0.int(0)) }.first) ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ binds: [SQLValue] = []) throws {
        let statement = try Statement(handle, sql)
        defer { statement.finalize() }
        try statement.bind(binds)
        _ = try statement.step()
    }

    /// Runs a statement and maps each row.
    func query<T>(_ sql: String,
                  _ binds: [SQLValue] = [],
                  _ map: (Statement) -> T) throws -> [T] {
        let statement = try Statement(handle, sql)
        defer { statement.finalize() }
        try statement.bind(binds)
        var rows: [T] = []
        while try statement.step() {
            rows.append(map(statement))
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

final class Statement {
    private let handle: OpaquePointer

    init(_ database: OpaquePointer?, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.prepare(message, sql: sql)
        }
        self.handle = handle
    }

    func finalize() {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number):     sqlite3_bind_int64(handle, index, number)
            case .double(let number):  sqlite3_bind_double(handle, index, number)
            case .text(let string):    sqlite3_bind_text(handle, index, string, -1, sqliteTransient)
            case .null:                sqlite3_bind_null(handle, index)
            }
        }
    }

    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default:          throw SQLiteError.step(String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))), sql: "")
        }
    }

    func int(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(handle, index) }
    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(handle, index) == SQLITE_NULL }

    func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: pointer)
    }
}
