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
import Translation

/// The sidebar's destinations, in the order the design put them.
enum LibrarySection: String, CaseIterable, Identifiable {
    case sessions, collections, notebook, favourites, vocabulary, writing, statistics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:    return "Sessions"
        case .collections: return "Collections"
        case .notebook:    return "Notebook"
        case .favourites:  return "Favourites"
        case .vocabulary:  return "Vocabulary"
        case .writing:     return "Writing"
        case .statistics:  return "Statistics"
        }
    }

    var symbol: String {
        switch self {
        case .sessions:    return "rectangle.stack"
        case .collections: return "folder"
        case .notebook:    return "note.text"
        case .favourites:  return "star"
        case .vocabulary:  return "textformat.abc"
        case .writing:     return "square.and.pencil"
        case .statistics:  return "chart.bar"
        }
    }
}

/// What the translate button is doing, in a form the toolbar can show.
enum TranslationPhase: Equatable {
    case off
    case waiting        // the task has been asked to run
    case downloading    // the language pack is not on this Mac yet
    case working        // translating
    case done
    case failed(String)

    var label: String {
        switch self {
        case .off:             return "Translate into Chinese"
        case .waiting:         return "Preparing…"
        case .downloading:     return "Downloading Chinese (one time, macOS will ask)"
        case .working:         return "Translating…"
        case .done:            return "Translated"
        case .failed(let why): return "Translation failed: \(why)"
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedSessionID: String? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            Task { await self.loadSelected() }
        }
    }
    @Published private(set) var cues: [Cue] = []
    @Published private(set) var notes: [Note] = []

    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published private(set) var hits: [SearchHit] = []

    @Published private(set) var totalCues = 0
    @Published var errorMessage: String?
    @Published var selectedCueID: Int64?
    @Published var section: LibrarySection = .sessions

    // The other sections' contents.
    @Published private(set) var notebook: [NoteWithSession] = []
    @Published private(set) var favourites: [NoteWithSession] = []
    @Published private(set) var vocabulary: [VocabularyEntry] = []
    @Published private(set) var statistics = LibraryStatistics()

    // Translation: paragraph by paragraph, on demand, in Simplified Chinese.
    @Published private(set) var translationPhase: TranslationPhase = .off
    @Published private(set) var translations: [Int: String] = [:]
    /// Bumped to ask the view's `translationTask` to run; the session only exists inside it.
    @Published private(set) var translationRequestID = 0

    // Inspector.
    @Published private(set) var inspectedWord: String?
    @Published private(set) var definition: String?
    @Published private(set) var occurrences: [SearchHit] = []

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

    /// The reader's paragraphs; a gap in the audio starts a new block.
    var paragraphs: [[Cue]] { Paragraphs.group(readerCues) }

    var selectedCue: Cue? {
        guard let id = selectedCueID else { return nil }
        return readerCues.first { $0.id == id }
    }

    /// Words in the selected line, for the inspector's chips.
    var selectedWords: [String] {
        guard let cue = selectedCue else { return [] }
        return DictionaryLookup.words(in: cue.text)
    }

    var translationOn: Bool { translationPhase != .off }

    func toggleTranslation() {
        if translationOn {
            translationPhase = .off
            translations = [:]
        } else {
            translationPhase = .waiting
            translationRequestID += 1
        }
    }

    /// Runs inside the SwiftUI `translationTask`, which is the only place a usable session
    /// exists. Paragraphs are translated as blocks so the Chinese reads as prose rather than
    /// line fragments, and results are keyed by paragraph index.
    @available(macOS 15.0, *)
    func runTranslation(paragraphs: [[Cue]], using session: TranslationSession) async {
        guard !paragraphs.isEmpty else {
            translationPhase = .done
            return
        }
        translationPhase = .working
        do {
            // Say plainly when the first run has to fetch the language pairs, because the
            // system's own sheet is what the user will see and it does not explain itself.
            let availability = LanguageAvailability()
            let status = await availability.status(
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: "zh-Hans"))
            if status == .supported { translationPhase = .downloading }

            try await session.prepareTranslation()
            translationPhase = .working

            let requests = paragraphs.enumerated().map { index, paragraph in
                TranslationSession.Request(
                    sourceText: paragraph.map(\.text).joined(separator: " "),
                    clientIdentifier: String(index))
            }
            let responses = try await session.translations(from: requests)

            // Responses come back in request order, so index them rather than trusting a
            // client identifier to survive the round trip.
            var translated: [Int: String] = [:]
            for (index, response) in responses.enumerated() where index < paragraphs.count {
                translated[index] = response.targetText
            }
            translations = translated
            translationPhase = .done
        } catch {
            translationPhase = .failed(error.localizedDescription)
        }
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
            notebook = try await store.notes()
            favourites = try await store.notes(kind: .favourite)
            vocabulary = try await store.vocabulary()
            statistics = try await store.statistics()
            // Prefer a session that actually has something in it, so the window does not
            // open on the empty one a just-started run leaves behind.
            let target = selectedSessionID
                ?? sessions.first(where: { $0.cueCount > 0 })?.id
                ?? sessions.first?.id
            if selectedSessionID != target {
                selectedSessionID = target      // didSet loads it
            } else if let id = target {
                try await load(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Looks a word up and finds every other line it appears in.
    func inspect(_ word: String) async {
        let lemma = DictionaryLookup.lemma(of: word)
        inspectedWord = lemma
        definition = DictionaryLookup.entry(for: lemma) ?? DictionaryLookup.entry(for: word)
        guard let store else { occurrences = []; return }
        occurrences = (try? await store.occurrences(of: lemma, excludingCue: selectedCueID)) ?? []
    }

    func clearInspection() {
        inspectedWord = nil
        definition = nil
        occurrences = []
    }

    /// The list binds straight to `selectedSessionID`; this is what reacting to it means.
    func loadSelected() async {
        selectedCueID = nil
        clearInspection()
        translations = [:]
        if translationOn { translationPhase = .waiting; translationRequestID += 1 }
        guard let id = selectedSessionID else { cues = []; notes = []; return }
        try? await load(id)
    }

    func select(_ id: String?) async {
        selectedSessionID = id
        await loadSelected()
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
        await refreshDerived()
    }

    /// Saves the inspected word straight into the vocabulary.
    func saveInspectedWord() async {
        guard let word = inspectedWord else { return }
        await addNote(cueID: selectedCueID, kind: .word, text: word)
    }

    func deleteNote(_ id: Int64) async {
        guard let store, let sessionID = selectedSessionID else { return }
        try? await store.deleteNote(id)
        try? await load(sessionID)
        await refreshDerived()
    }

    private func refreshDerived() async {
        guard let store else { return }
        notebook = (try? await store.notes()) ?? []
        favourites = (try? await store.notes(kind: .favourite)) ?? []
        vocabulary = (try? await store.vocabulary()) ?? []
        statistics = (try? await store.statistics()) ?? LibraryStatistics()
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
