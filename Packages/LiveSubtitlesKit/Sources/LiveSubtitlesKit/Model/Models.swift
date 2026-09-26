//
//  Models.swift
//  LiveSubtitlesKit
//
//  The stored shapes. Kept plain: no persistence concerns, no UI concerns.
//

import Foundation

/// One listening run — normally one episode.
public struct Session: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var source: String
    public var modelID: String
    public var cueCount: Int

    public init(id: String = UUID().uuidString,
                title: String,
                startedAt: Date = Date(),
                endedAt: Date? = nil,
                source: String = "",
                modelID: String = "",
                cueCount: Int = 0) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.modelID = modelID
        self.cueCount = cueCount
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// One finished caption line, with the audio-clock bounds the pipeline produced.
public struct Cue: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let sessionID: String
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(id: Int64 = 0, sessionID: String, startMs: Int, endMs: Int, text: String) {
        self.id = id
        self.sessionID = sessionID
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }

    /// `00:12:34` for the reader's gutter.
    public var timestamp: String {
        let total = max(0, startMs) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// A note or a saved selection. `cueID` is optional so a whole-session note is possible.
public struct Note: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case note          // free-form note
        case word          // a word worth remembering
        case phrase        // a phrase worth remembering
        case favourite     // a line worth keeping
    }

    public let id: Int64
    public let sessionID: String
    public let cueID: Int64?
    public var kind: Kind
    public var text: String
    public var createdAt: Date

    public init(id: Int64 = 0,
                sessionID: String,
                cueID: Int64? = nil,
                kind: Kind = .note,
                text: String,
                createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.cueID = cueID
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}

/// A full-text search result: the matching cue plus which session it came from.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public let cue: Cue
    public let sessionID: String
    public let sessionTitle: String

    public var id: Int64 { cue.id }

    public init(cue: Cue, sessionID: String, sessionTitle: String) {
        self.cue = cue
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
    }
}

/// Where history lives, and a default title for a new session.
public enum History {
    /// `~/Library/Application Support/Live Subtitles/history.sqlite`
    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Live Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    /// "Netflix · 26 Sep 21:14" — a starting point the user can rename.
    public static func suggestedTitle(source: String, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let stamp = formatter.string(from: date)
        return source.isEmpty ? stamp : "\(source) · \(stamp)"
    }
}
