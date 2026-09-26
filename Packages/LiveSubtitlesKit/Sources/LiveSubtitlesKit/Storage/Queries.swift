//
//  Queries.swift
//  LiveSubtitlesKit
//
//  The reads the library's sections need. Kept out of HistoryStore only to keep that
//  file about writing; both are the same actor's API.
//

import Foundation

/// A note with enough context to show it outside its session.
public struct NoteWithSession: Identifiable, Hashable, Sendable {
    public let note: Note
    public let sessionID: String
    public let sessionTitle: String
    public var id: Int64 { note.id }

    public init(note: Note, sessionID: String, sessionTitle: String) {
        self.note = note
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
    }
}

/// One entry in the vocabulary list: a term saved more than once is one row with a count.
public struct VocabularyEntry: Identifiable, Hashable, Sendable {
    public let term: String
    public let count: Int
    public let firstSaved: Date
    public var id: String { term.lowercased() }

    public init(term: String, count: Int, firstSaved: Date) {
        self.term = term
        self.count = count
        self.firstSaved = firstSaved
    }
}

public struct LibraryStatistics: Sendable, Hashable {
    public var sessions: Int = 0
    public var cues: Int = 0
    public var notes: Int = 0
    public var favourites: Int = 0
    public var vocabulary: Int = 0
    public var listeningTime: TimeInterval = 0

    public init() {}
}

extension HistoryStore {
    /// Notes across every session — the Notebook section.
    public func notes(kind: Note.Kind? = nil) throws -> [NoteWithSession] {
        let filter = kind.map { _ in "WHERE n.kind = ?" } ?? ""
        let binds: [SQLValue] = kind.map { [.text($0.rawValue)] } ?? []
        return try connection.query("""
            SELECT n.id, n.sessionID, n.cueID, n.kind, n.text, n.createdAt, s.title
            FROM notes n JOIN sessions s ON s.id = n.sessionID
            \(filter)
            ORDER BY n.createdAt DESC;
            """, binds) { row in
            NoteWithSession(
                note: Note(id: row.int(0), sessionID: row.string(1),
                           cueID: row.isNull(2) ? nil : row.int(2),
                           kind: Note.Kind(rawValue: row.string(3)) ?? .note,
                           text: row.string(4),
                           createdAt: Date(timeIntervalSince1970: row.double(5))),
                sessionID: row.string(1),
                sessionTitle: row.string(6))
        }
    }

    /// Saved words and phrases, deduplicated by spelling.
    public func vocabulary() throws -> [VocabularyEntry] {
        struct Row { let term: String; let count: Int; let first: Date }
        let rows = try connection.query("""
            SELECT text, COUNT(*), MIN(createdAt) FROM notes
            WHERE kind IN ('word', 'phrase')
            GROUP BY LOWER(text)
            ORDER BY COUNT(*) DESC, text;
            """) { row in
            Row(term: row.string(0), count: Int(row.int(1)),
                first: Date(timeIntervalSince1970: row.double(2)))
        }
        return rows.map { VocabularyEntry(term: $0.term, count: $0.count, firstSaved: $0.first) }
    }

    public func statistics() throws -> LibraryStatistics {
        var stats = LibraryStatistics()
        stats.sessions = try connection.query("SELECT COUNT(*) FROM sessions;") { Int($0.int(0)) }.first ?? 0
        stats.cues = try connection.query("SELECT COUNT(*) FROM cues;") { Int($0.int(0)) }.first ?? 0
        stats.notes = try connection.query("SELECT COUNT(*) FROM notes;") { Int($0.int(0)) }.first ?? 0
        stats.favourites = try connection.query(
            "SELECT COUNT(*) FROM notes WHERE kind = 'favourite';") { Int($0.int(0)) }.first ?? 0
        stats.vocabulary = try connection.query(
            "SELECT COUNT(DISTINCT LOWER(text)) FROM notes WHERE kind IN ('word','phrase');") { Int($0.int(0)) }.first ?? 0
        stats.listeningTime = try connection.query("""
            SELECT COALESCE(SUM(COALESCE(endedAt, startedAt) - startedAt), 0) FROM sessions;
            """) { $0.double(0) }.first ?? 0
        return stats
    }

    /// Every other cue containing a term — the concordance behind the inspector.
    /// Distinct from `search`, which is for the search field: this one is literal.
    public func occurrences(of term: String, excludingCue cueID: Int64?, limit: Int = 50) throws -> [SearchHit] {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return try connection.query("""
            SELECT c.id, c.sessionID, c.startMs, c.endMs, c.text, s.title
            FROM cues_fts f
            JOIN cues c ON c.id = f.rowid
            JOIN sessions s ON s.id = c.sessionID
            WHERE cues_fts MATCH ?
              AND (? IS NULL OR c.id <> ?)
            ORDER BY s.startedAt DESC
            LIMIT ?;
            """, [.text("\"\(cleaned.replacingOccurrences(of: "\"", with: ""))\""),
                  cueID.map { SQLValue.int($0) } ?? .null,
                  cueID.map { SQLValue.int($0) } ?? .null,
                  .int(Int64(limit))]) { row in
            SearchHit(cue: Cue(id: row.int(0), sessionID: row.string(1),
                               startMs: Int(row.int(2)), endMs: Int(row.int(3)),
                               text: row.string(4)),
                      sessionID: row.string(1), sessionTitle: row.string(5))
        }
    }
}

/// Groups cues into paragraphs so the reader can show blocks rather than a flat list.
public enum Paragraphs {
    /// A gap this long ends the paragraph. Matches the "new line after silence" idea, but
    /// applied to the archive where we can afford to look at the whole session at once.
    public static func group(_ cues: [Cue], gapMs: Int = 2_000) -> [[Cue]] {
        var groups: [[Cue]] = []
        var current: [Cue] = []
        for cue in cues {
            if let last = current.last, cue.startMs - last.endMs > gapMs {
                groups.append(current)
                current = []
            }
            current.append(cue)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
