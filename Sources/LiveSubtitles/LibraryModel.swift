//
//  LibraryModel.swift
//  LiveSubtitles
//
//  The study window's state. Talks to LiveSubtitlesKit and publishes what the views need;
//  it holds no storage logic of its own, so the archive can be tested without a UI.
//

import AppKit
import Combine
import LiveSubtitlesKit
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedSessionID: String?
    @Published private(set) var cues: [Cue] = []
    @Published private(set) var notes: [Note] = []

    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published private(set) var hits: [SearchHit] = []

    @Published private(set) var totalCues = 0
    @Published var errorMessage: String?
    @Published var selectedCueID: Int64?

    private var store: HistoryStore?
    private var searchTask: Task<Void, Never>?

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Cues the reader shows: the selected session's, or the cross-session search results.
    var readerCues: [Cue] {
        isSearching ? hits.map(\.cue) : cues
    }

    var notesByCue: [Int64: [Note]] {
        Dictionary(grouping: notes.compactMap { note in note.cueID.map { ($0, note) } },
                   by: { $0.0 }).mapValues { $0.map(\.1) }
    }

    func attach(_ store: HistoryStore?) {
        self.store = store
        guard store != nil else {
            errorMessage = "History is unavailable, so there is nothing to show yet."
            return
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let store else { return }
        do {
            sessions = try await store.sessions()
            totalCues = try await store.cueCount()
            // Prefer a session that actually has something in it, so the window does not
            // open on the empty one a just-started run leaves behind.
            if selectedSessionID == nil {
                selectedSessionID = sessions.first(where: { $0.cueCount > 0 })?.id ?? sessions.first?.id
            }
            if let id = selectedSessionID { try await load(id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ id: String?) async {
        selectedSessionID = id
        selectedCueID = nil
        guard let id else { cues = []; notes = []; return }
        try? await load(id)
    }

    private func load(_ id: String) async throws {
        guard let store else { return }
        cues = try await store.cues(in: id)
        notes = try await store.notes(in: id)
    }

    func rename(_ id: String, to title: String) async {
        guard let store else { return }
        try? await store.rename(id, to: title)
        await refresh()
    }

    func delete(_ id: String) async {
        guard let store else { return }
        try? await store.deleteSession(id)
        if selectedSessionID == id { selectedSessionID = nil }
        await refresh()
    }

    func addNote(cueID: Int64?, kind: Note.Kind, text: String) async {
        guard let store, let sessionID = selectedSessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await store.addNote(sessionID: sessionID, cueID: cueID, kind: kind, text: trimmed)
        try? await load(sessionID)
    }

    func deleteNote(_ id: Int64) async {
        guard let store, let sessionID = selectedSessionID else { return }
        try? await store.deleteNote(id)
        try? await load(sessionID)
    }

    func export(_ format: ExportFormat, sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        Task {
            guard let store else { return }
            let cues = (try? await store.cues(in: sessionID)) ?? []
            let notes = (try? await store.notes(in: sessionID)) ?? []
            let body = Exporter.render(cues: cues, session: session, notes: notes, format: format)

            let panel = NSSavePanel()
            panel.title = "Export Transcript"
            panel.nameFieldStringValue = "\(Self.safeName(session.title)).\(format.fileExtension)"
            panel.allowedContentTypes = format == .markdown
                ? [.init(filenameExtension: "md") ?? .plainText]
                : (format == .srt ? [.init(filenameExtension: "srt") ?? .plainText] : [.plainText])

            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                try? body.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { hits = []; return }

        searchTask = Task { [weak self] in
            // Debounce: the field is queried as it is typed, and FTS is fast but pointless
            // to run on every keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let results = (try? await store.search(query)) ?? []
            guard !Task.isCancelled else { return }
            self.hits = results
        }
    }

    private static func safeName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
        let cleaned = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}
