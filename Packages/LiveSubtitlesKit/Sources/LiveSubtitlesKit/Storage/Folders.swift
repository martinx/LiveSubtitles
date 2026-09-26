//
//  Folders.swift
//  LiveSubtitlesKit
//
//  Arbitrary-depth grouping for the history.
//
//  A folder tree rather than flat tags: the shape people already use for a season of a
//  show, a course, a language, a year. `parentID` refers to the same table, so depth is
//  unlimited, and a session belongs to exactly one folder — moving it is one column.
//
//  Deleting a folder keeps what is inside it: children are removed as folders and their
//  sessions fall back to the root, because losing a year of transcripts to a mis-click on
//  a folder is not a recoverable mistake.
//

import Foundation

public struct Folder: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var parentID: String?
    public var sessionCount: Int

    public init(id: String = UUID().uuidString,
                name: String,
                parentID: String? = nil,
                sessionCount: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sessionCount = sessionCount
    }
}

/// A folder with its children, for the outline.
public struct FolderNode: Identifiable, Hashable, Sendable {
    public let folder: Folder
    public var children: [FolderNode]

    public var id: String { folder.id }

    /// For `OutlineGroup`, which wants nil rather than an empty array at a leaf — and so
    /// leaves get no disclosure triangle.
    public var subfolders: [FolderNode]? { children.isEmpty ? nil : children }

    /// Sessions in this folder and everything beneath it.
    public var totalSessions: Int {
        folder.sessionCount + children.reduce(0) { $0 + $1.totalSessions }
    }
}

extension HistoryStore {
    // MARK: - Reading

    /// Every folder, flat. The tree is built from this so a deep hierarchy costs no queries.
    public func folders() throws -> [Folder] {
        try connection.query("""
            SELECT f.id, f.name, f.parentID,
                   (SELECT COUNT(*) FROM sessions s WHERE s.folderID = f.id)
            FROM folders f ORDER BY f.name COLLATE NOCASE;
            """) { row in
            Folder(id: row.string(0), name: row.string(1),
                   parentID: row.isNull(2) ? nil : row.string(2),
                   sessionCount: Int(row.int(3)))
        }
    }

    public func folderTree() throws -> [FolderNode] {
        let all = try folders()
        func children(of parent: String?) -> [FolderNode] {
            all.filter { $0.parentID == parent }
                .map { FolderNode(folder: $0, children: children(of: $0.id)) }
        }
        return children(of: nil)
    }

    /// Sessions in a folder and everything under it, so selecting a season shows its episodes.
    public func sessions(inFolder folderID: String?) throws -> [Session] {
        guard let folderID else { return try sessions() }
        let ids = try descendantFolderIDs(of: folderID)
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try connection.query("""
            SELECT s.id, s.title, s.startedAt, s.endedAt, s.source, s.modelID,
                   (SELECT COUNT(*) FROM cues c WHERE c.sessionID = s.id),
                   s.folderID
            FROM sessions s
            WHERE s.folderID IN (\(placeholders))
            ORDER BY s.startedAt DESC;
            """, ids.map { SQLValue.text($0) }) { row in
            Session(id: row.string(0), title: row.string(1),
                    startedAt: Date(timeIntervalSince1970: row.double(2)),
                    endedAt: row.isNull(3) ? nil : Date(timeIntervalSince1970: row.double(3)),
                    source: row.string(4), modelID: row.string(5),
                    cueCount: Int(row.int(6)),
                    folderID: row.isNull(7) ? nil : row.string(7))
        }
    }

    /// A folder's own id plus every folder beneath it, to any depth.
    private func descendantFolderIDs(of folderID: String) throws -> [String] {
        let all = try folders()
        var result: [String] = []
        var frontier = [folderID]
        while let current = frontier.popLast() {
            guard !result.contains(current) else { continue }   // a cycle cannot happen, but be safe
            result.append(current)
            frontier += all.filter { $0.parentID == current }.map(\.id)
        }
        return result
    }

    // MARK: - Writing

    @discardableResult
    public func createFolder(_ name: String, parentID: String? = nil) throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: trimmed.isEmpty ? "Untitled" : trimmed, parentID: parentID)
        try connection.run("""
            INSERT INTO folders (id, name, parentID, createdAt) VALUES (?, ?, ?, ?);
            """, [.text(folder.id), .text(folder.name),
                  parentID.map { SQLValue.text($0) } ?? .null,
                  .double(Date().timeIntervalSince1970)])
        return folder
    }

    public func renameFolder(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try connection.run("UPDATE folders SET name = ? WHERE id = ?;", [.text(trimmed), .text(id)])
    }

    /// Deletes the folder and its children. Sessions inside move back to the root rather
    /// than being deleted with it.
    public func deleteFolder(_ id: String) throws {
        for child in try descendantFolderIDs(of: id) where child != id {
            try connection.run("DELETE FROM folders WHERE id = ?;", [.text(child)])
        }
        try connection.run("DELETE FROM folders WHERE id = ?;", [.text(id)])
    }

    /// Reparents a folder. Refuses to put a folder inside its own descendant, which would
    /// detach that whole branch from the root.
    public func moveFolder(_ id: String, to parentID: String?) throws {
        if let parentID {
            let descendants = try descendantFolderIDs(of: id)
            guard !descendants.contains(parentID), parentID != id else { return }
        }
        try connection.run("UPDATE folders SET parentID = ? WHERE id = ?;",
                           [parentID.map { SQLValue.text($0) } ?? .null, .text(id)])
    }

    public func move(_ sessionID: String, to folderID: String?) throws {
        try connection.run("UPDATE sessions SET folderID = ? WHERE id = ?;",
                           [folderID.map { SQLValue.text($0) } ?? .null, .text(sessionID)])
    }

    public func folders(named name: String) throws -> [Folder] {
        try folders().filter { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    public func folder(of sessionID: String) throws -> Folder? {
        try connection.query("""
            SELECT f.id, f.name, f.parentID FROM folders f
            JOIN sessions s ON s.folderID = f.id WHERE s.id = ?;
            """, [.text(sessionID)]) { row in
            Folder(id: row.string(0), name: row.string(1),
                   parentID: row.isNull(2) ? nil : row.string(2))
        }.first
    }

    /// A guess at where a session belongs, from the titles already in the history.
    ///
    /// "Severance S02E05" beside "Severance S02E06" suggests "Severance": the longest common
    /// prefix, trimmed back to a whole word and rejected if it is too short to be a name.
    public func suggestedFolderName(for sessionID: String) throws -> String? {
        guard let title = try connection.query(
            "SELECT title FROM sessions WHERE id = ?;", [.text(sessionID)]) { $0.string(0) }.first,
              !title.isEmpty else { return nil }

        let others = try connection.query("""
            SELECT title FROM sessions WHERE id <> ? ORDER BY startedAt DESC LIMIT 200;
            """, [.text(sessionID)]) { $0.string(0) }

        var best = ""
        for other in others where !other.isEmpty {
            var shared = ""
            for (left, right) in zip(title, other) {
                guard left == right else { break }
                shared.append(left)
            }
            if shared.count > best.count { best = shared }
        }
        guard let cut = best.lastIndex(of: " ") else { return nil }
        let name = String(best[..<cut]).trimmingCharacters(in: .whitespaces)
        return name.count >= 3 ? name : nil
    }
}
