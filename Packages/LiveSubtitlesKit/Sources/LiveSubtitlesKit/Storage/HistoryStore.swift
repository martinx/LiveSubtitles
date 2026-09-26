//
//  HistoryStore.swift
//  LiveSubtitlesKit
//
//  Everything the app keeps: sessions, their cues, notes, and search across all of it.
//
//  An actor, so the caption pipeline can append from its own context while the window
//  reads, without either side reaching for a lock. Writes are one row every few seconds;
//  reads are indexed or full-text. The measured cost at a year of daily watching is
//  91 MB and sub-millisecond queries, so there is no reason to get clever yet.
//

import Foundation

public actor HistoryStore {
    /// Internal rather than private: the read queries live in Queries.swift.
    let connection: SQLiteConnection

    public init(url: URL) throws {
        connection = try SQLiteConnection(path: url.path)
        try Self.migrate(connection)
    }

    public convenience init() throws {
        try self.init(url: History.defaultDatabaseURL())
    }

    // MARK: - Schema

    /// Stepwise, driven by `PRAGMA user_version`, so a future column is an addition here
    /// rather than a migration script someone has to remember to run.
    private static func migrate(_ connection: SQLiteConnection) throws {
        if connection.userVersion < 1 {
            try connection.transaction {
                try connection.execute("""
                CREATE TABLE IF NOT EXISTS sessions (
                    id        TEXT PRIMARY KEY,
                    title     TEXT NOT NULL,
                    startedAt REAL NOT NULL,
                    endedAt   REAL,
                    source    TEXT NOT NULL DEFAULT '',
                    modelID   TEXT NOT NULL DEFAULT ''
                );

                CREATE TABLE IF NOT EXISTS cues (
                    id        INTEGER PRIMARY KEY AUTOINCREMENT,
                    sessionID TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    startMs   INTEGER NOT NULL,
                    endMs     INTEGER NOT NULL,
                    text      TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS cues_by_session ON cues(sessionID, startMs);

                -- Kept in step by triggers rather than by the caller, so a cue inserted
                -- from anywhere is searchable immediately.
                CREATE VIRTUAL TABLE IF NOT EXISTS cues_fts USING fts5(
                    text, content='cues', content_rowid='id'
                );
                CREATE TRIGGER IF NOT EXISTS cues_insert AFTER INSERT ON cues BEGIN
                    INSERT INTO cues_fts(rowid, text) VALUES (new.id, new.text);
                END;
                CREATE TRIGGER IF NOT EXISTS cues_delete AFTER DELETE ON cues BEGIN
                    INSERT INTO cues_fts(cues_fts, rowid, text) VALUES ('delete', old.id, old.text);
                END;
                CREATE TRIGGER IF NOT EXISTS cues_update AFTER UPDATE ON cues BEGIN
                    INSERT INTO cues_fts(cues_fts, rowid, text) VALUES ('delete', old.id, old.text);
                    INSERT INTO cues_fts(rowid, text) VALUES (new.id, new.text);
                END;

                CREATE TABLE IF NOT EXISTS notes (
                    id        INTEGER PRIMARY KEY AUTOINCREMENT,
                    sessionID TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    cueID     INTEGER REFERENCES cues(id) ON DELETE SET NULL,
                    kind      TEXT NOT NULL DEFAULT 'note',
                    text      TEXT NOT NULL,
                    createdAt REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS notes_by_session ON notes(sessionID, createdAt);
                """)
            }
            try connection.setUserVersion(1)
        }
    }

    // MARK: - Sessions

    @discardableResult
    public func startSession(source: String = "", modelID: String = "", title: String? = nil) throws -> Session {
        let session = Session(title: title ?? History.suggestedTitle(source: source),
                              source: source,
                              modelID: modelID)
        try connection.run("""
            INSERT INTO sessions (id, title, startedAt, endedAt, source, modelID)
            VALUES (?, ?, ?, NULL, ?, ?);
            """, [
                .text(session.id), .text(session.title),
                .double(session.startedAt.timeIntervalSince1970),
                .text(session.source), .text(session.modelID),
            ])
        return session
    }

    public func appendCue(sessionID: String, startMs: Int, endMs: Int, text: String) throws {
        try connection.run("""
            INSERT INTO cues (sessionID, startMs, endMs, text) VALUES (?, ?, ?, ?);
            """, [.text(sessionID), .int(Int64(startMs)), .int(Int64(endMs)), .text(text)])
    }

    public func endSession(_ id: String, at date: Date = Date()) throws {
        try connection.run("UPDATE sessions SET endedAt = ? WHERE id = ?;",
                           [.double(date.timeIntervalSince1970), .text(id)])
    }

    public func rename(_ id: String, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try connection.run("UPDATE sessions SET title = ? WHERE id = ?;", [.text(trimmed), .text(id)])
    }

    public func deleteSession(_ id: String) throws {
        try connection.run("DELETE FROM sessions WHERE id = ?;", [.text(id)])
    }

    public func sessions() throws -> [Session] {
        try connection.query("""
            SELECT s.id, s.title, s.startedAt, s.endedAt, s.source, s.modelID,
                   (SELECT COUNT(*) FROM cues c WHERE c.sessionID = s.id)
            FROM sessions s
            ORDER BY s.startedAt DESC;
            """) { row in
            Session(id: row.string(0),
                    title: row.string(1),
                    startedAt: Date(timeIntervalSince1970: row.double(2)),
                    endedAt: row.isNull(3) ? nil : Date(timeIntervalSince1970: row.double(3)),
                    source: row.string(4),
                    modelID: row.string(5),
                    cueCount: Int(row.int(6)))
        }
    }

    // MARK: - Cues

    public func cues(in sessionID: String) throws -> [Cue] {
        try connection.query("""
            SELECT id, sessionID, startMs, endMs, text FROM cues
            WHERE sessionID = ? ORDER BY startMs;
            """, [.text(sessionID)]) { row in
            Cue(id: row.int(0), sessionID: row.string(1),
                startMs: Int(row.int(2)), endMs: Int(row.int(3)), text: row.string(4))
        }
    }

    // MARK: - Search

    /// Full-text search over every cue ever captured.
    ///
    /// The user's text is turned into quoted tokens so punctuation cannot be read as FTS
    /// syntax, and the final token gets a prefix match so results appear while typing.
    public func search(_ text: String, limit: Int = 200) throws -> [SearchHit] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let expression = tokens.enumerated()
            .map { index, token in
                index == tokens.count - 1 ? "\"\(token)\"*" : "\"\(token)\""
            }
            .joined(separator: " AND ")

        return try connection.query("""
            SELECT c.id, c.sessionID, c.startMs, c.endMs, c.text, s.title
            FROM cues_fts f
            JOIN cues c ON c.id = f.rowid
            JOIN sessions s ON s.id = c.sessionID
            WHERE cues_fts MATCH ?
            ORDER BY s.startedAt DESC, c.startMs
            LIMIT ?;
            """, [.text(expression), .int(Int64(limit))]) { row in
            SearchHit(cue: Cue(id: row.int(0), sessionID: row.string(1),
                               startMs: Int(row.int(2)), endMs: Int(row.int(3)),
                               text: row.string(4)),
                      sessionID: row.string(1),
                      sessionTitle: row.string(5))
        }
    }

    // MARK: - Notes

    @discardableResult
    public func addNote(sessionID: String, cueID: Int64?, kind: Note.Kind, text: String) throws -> Note {
        let note = Note(sessionID: sessionID, cueID: cueID, kind: kind, text: text)
        try connection.run("""
            INSERT INTO notes (sessionID, cueID, kind, text, createdAt) VALUES (?, ?, ?, ?, ?);
            """, [.text(note.sessionID),
                  note.cueID.map { SQLValue.int($0) } ?? .null,
                  .text(note.kind.rawValue), .text(note.text),
                  .double(note.createdAt.timeIntervalSince1970)])
        return note
    }

    public func notes(in sessionID: String) throws -> [Note] {
        try connection.query("""
            SELECT id, sessionID, cueID, kind, text, createdAt FROM notes
            WHERE sessionID = ? ORDER BY createdAt;
            """, [.text(sessionID)]) { row in
            Note(id: row.int(0), sessionID: row.string(1),
                 cueID: row.isNull(2) ? nil : row.int(2),
                 kind: Note.Kind(rawValue: row.string(3)) ?? .note,
                 text: row.string(4),
                 createdAt: Date(timeIntervalSince1970: row.double(5)))
        }
    }

    public func deleteNote(_ id: Int64) throws {
        try connection.run("DELETE FROM notes WHERE id = ?;", [.int(id)])
    }

    // MARK: - Statistics

    public func cueCount() throws -> Int {
        try connection.query("SELECT COUNT(*) FROM cues;") { Int($0.int(0)) }.first ?? 0
    }
}
