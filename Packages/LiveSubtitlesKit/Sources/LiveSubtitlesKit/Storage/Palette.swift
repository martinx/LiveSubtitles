//
//  Palette.swift
//  LiveSubtitlesKit
//
//  One query, every kind of thing we keep. Backs the ⌘K palette, so the user does not have
//  to know whether what they remember is a session title, a line, a word or a note.
//

import Foundation

public struct PaletteResults: Sendable {
    public init() {}

    public var sessions: [Session] = []
    public var lines: [SearchHit] = []
    public var words: [VocabularyEntry] = []
    public var notes: [NoteWithSession] = []
    public var folders: [Folder] = []

    public var isEmpty: Bool {
        sessions.isEmpty && lines.isEmpty && words.isEmpty && notes.isEmpty && folders.isEmpty
    }

    public var total: Int {
        sessions.count + lines.count + words.count + notes.count + folders.count
    }
}

extension HistoryStore {
    /// Searches everything. Lines go through FTS for the prefix matching; the rest are small
    /// enough that a substring scan is honest and simpler.
    public func everything(matching query: String, limit: Int = 8) throws -> PaletteResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return PaletteResults() }

        var results = PaletteResults()
        let like = SQLValue.text("%\(trimmed)%")

        results.sessions = try connection.query("""
            SELECT s.id, s.title, s.startedAt, s.endedAt, s.source, s.modelID,
                   (SELECT COUNT(*) FROM cues c WHERE c.sessionID = s.id), s.folderID
            FROM sessions s
            WHERE s.title LIKE ? COLLATE NOCASE
            ORDER BY s.startedAt DESC LIMIT ?;
            """, [like, .int(Int64(limit))]) { row in
            Session(id: row.string(0), title: row.string(1),
                    startedAt: Date(timeIntervalSince1970: row.double(2)),
                    endedAt: row.isNull(3) ? nil : Date(timeIntervalSince1970: row.double(3)),
                    source: row.string(4), modelID: row.string(5),
                    cueCount: Int(row.int(6)),
                    folderID: row.isNull(7) ? nil : row.string(7))
        }

        results.folders = try connection.query("""
            SELECT id, name, parentID FROM folders
            WHERE name LIKE ? COLLATE NOCASE ORDER BY name LIMIT ?;
            """, [like, .int(Int64(limit))]) { row in
            Folder(id: row.string(0), name: row.string(1),
                   parentID: row.isNull(2) ? nil : row.string(2))
        }

        results.words = try connection.query("""
            SELECT text, COUNT(*), MIN(createdAt) FROM notes
            WHERE kind IN ('word', 'phrase') AND text LIKE ? COLLATE NOCASE
            GROUP BY LOWER(text) ORDER BY COUNT(*) DESC LIMIT ?;
            """, [like, .int(Int64(limit))]) { row in
            VocabularyEntry(term: row.string(0), count: Int(row.int(1)),
                            firstSaved: Date(timeIntervalSince1970: row.double(2)))
        }

        results.notes = try connection.query("""
            SELECT n.id, n.sessionID, n.cueID, n.kind, n.text, n.createdAt, s.title
            FROM notes n JOIN sessions s ON s.id = n.sessionID
            WHERE n.text LIKE ? COLLATE NOCASE
            ORDER BY n.createdAt DESC LIMIT ?;
            """, [like, .int(Int64(limit))]) { row in
            NoteWithSession(
                note: Note(id: row.int(0), sessionID: row.string(1),
                           cueID: row.isNull(2) ? nil : row.int(2),
                           kind: Note.Kind(rawValue: row.string(3)) ?? .note,
                           text: row.string(4),
                           createdAt: Date(timeIntervalSince1970: row.double(5))),
                sessionID: row.string(1), sessionTitle: row.string(6))
        }

        // FTS throws on some punctuation; a plain query should never break the palette.
        results.lines = (try? search(trimmed, limit: limit)) ?? []
        return results
    }
}
