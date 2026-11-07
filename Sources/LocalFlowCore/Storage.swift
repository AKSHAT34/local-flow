import Foundation
import SQLite3

public struct HistoryEntry: Sendable, Identifiable {
    public var id: Int64
    public var createdAt: Date
    public var appName: String
    public var bundleID: String
    public var rawText: String
    public var cleanText: String
    public var engine: String
    public var cleanupMode: String
    public var durationMilliseconds: Double

    public init(id: Int64 = 0, createdAt: Date = Date(), appName: String = "", bundleID: String = "", rawText: String = "", cleanText: String = "", engine: String = "", cleanupMode: String = "", durationMilliseconds: Double = 0) {
        self.id = id; self.createdAt = createdAt; self.appName = appName; self.bundleID = bundleID
        self.rawText = rawText; self.cleanText = cleanText; self.engine = engine; self.cleanupMode = cleanupMode
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct VocabularyItem: Sendable, Identifiable {
    public var term: String
    public var replacement: String
    public var enabled: Bool
    public var id: String { term }
    public init(term: String, replacement: String, enabled: Bool = true) { self.term = term; self.replacement = replacement; self.enabled = enabled }
}

public actor HistoryStore {
    private var db: OpaquePointer?
    private let databaseURL: URL

    public init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        databaseURL = base.appendingPathComponent("localflow.sqlite")
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func open() throws {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw LocalFlowError.insertionFailed("sqlite open failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS history(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at REAL NOT NULL,
          app_name TEXT NOT NULL DEFAULT '',
          bundle_id TEXT NOT NULL DEFAULT '',
          raw_text TEXT NOT NULL DEFAULT '',
          clean_text TEXT NOT NULL DEFAULT '',
          engine TEXT NOT NULL DEFAULT '',
          cleanup_mode TEXT NOT NULL DEFAULT '',
          duration_ms REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS dictionary(
          term TEXT PRIMARY KEY,
          replacement TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS snippets(
          trigger TEXT PRIMARY KEY,
          expansion TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1
        );
        """)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw LocalFlowError.insertionFailed(message)
        }
    }

    private func ensureOpen() throws {
        if db == nil { try open() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        try ensureOpen()
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw LocalFlowError.insertionFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let statement else { throw LocalFlowError.insertionFailed("sqlite prepare failed") }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    public func insertHistory(_ entry: HistoryEntry) throws -> Int64 {
        let statement = try prepare("""
        INSERT INTO history(created_at, app_name, bundle_id, raw_text, clean_text, engine, cleanup_mode, duration_ms)
        VALUES(?,?,?,?,?,?,?,?)
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, entry.createdAt.timeIntervalSince1970)
        bind(statement, 2, entry.appName); bind(statement, 3, entry.bundleID)
        bind(statement, 4, entry.rawText); bind(statement, 5, entry.cleanText)
        bind(statement, 6, entry.engine); bind(statement, 7, entry.cleanupMode)
        sqlite3_bind_double(statement, 8, entry.durationMilliseconds)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalFlowError.insertionFailed(String(cString: sqlite3_errmsg(db))) }
        return sqlite3_last_insert_rowid(db)
    }

    public func recentHistory(limit: Int = 200) throws -> [HistoryEntry] {
        let statement = try prepare("SELECT id, created_at, app_name, bundle_id, raw_text, clean_text, engine, cleanup_mode, duration_ms FROM history ORDER BY id DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: sqlite3_column_int64(statement, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                appName: columnText(statement, 2), bundleID: columnText(statement, 3),
                rawText: columnText(statement, 4), cleanText: columnText(statement, 5),
                engine: columnText(statement, 6), cleanupMode: columnText(statement, 7),
                durationMilliseconds: sqlite3_column_double(statement, 8)
            ))
        }
        return rows
    }

    public func deleteHistory(olderThanDays: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400).timeIntervalSince1970
        let statement = try prepare("DELETE FROM history WHERE created_at < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        _ = sqlite3_step(statement)
    }

    public func deleteAllHistory() throws {
        let statement = try prepare("DELETE FROM history")
        defer { sqlite3_finalize(statement) }
        _ = sqlite3_step(statement)
    }

    public func loadDictionary() throws -> [String: String] {
        var result: [String: String] = [:]
        let statement = try prepare("SELECT term, replacement FROM dictionary WHERE enabled = 1")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            result[columnText(statement, 0)] = columnText(statement, 1)
        }
        return result
    }

    public func upsertDictionary(_ item: VocabularyItem) throws {
        try upsert(table: "dictionary", keyColumn: "term", valueColumn: "replacement", item: item)
    }

    public func deleteDictionary(term: String) throws {
        try delete(table: "dictionary", keyColumn: "term", value: term)
    }

    public func loadSnippets() throws -> [String: String] {
        var result: [String: String] = [:]
        let statement = try prepare("SELECT trigger, expansion FROM snippets WHERE enabled = 1")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            result[columnText(statement, 0)] = columnText(statement, 1)
        }
        return result
    }

    public func upsertSnippet(_ item: VocabularyItem) throws {
        try upsert(table: "snippets", keyColumn: "trigger", valueColumn: "expansion", item: item)
    }

    public func deleteSnippet(trigger: String) throws {
        try delete(table: "snippets", keyColumn: "trigger", value: trigger)
    }

    private func upsert(table: String, keyColumn: String, valueColumn: String, item: VocabularyItem) throws {
        let sql = "INSERT INTO \(table)(\(keyColumn), \(valueColumn), enabled) VALUES(?,?,?) ON CONFLICT(\(keyColumn)) DO UPDATE SET \(valueColumn)=excluded.\(valueColumn), enabled=excluded.enabled"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, item.term); bind(statement, 2, item.replacement)
        sqlite3_bind_int(statement, 3, item.enabled ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalFlowError.insertionFailed(String(cString: sqlite3_errmsg(db))) }
    }

    private func delete(table: String, keyColumn: String, value: String) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE \(keyColumn) = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, value)
        _ = sqlite3_step(statement)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}
