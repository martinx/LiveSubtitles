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

/// Everything the word card shows. Identifiable by the word *and* the line it came from,
/// so a popover can bind to exactly one token.
struct WordInspection: Identifiable, Equatable {
    let word: String
    let lemma: String
    let cueID: Int64?
    var definition: String?
    var translation: String?

    var id: String { "\(cueID ?? -1)-\(lemma)" }
}

/// A note being written, with its link back to the line it belongs to.
struct NoteDraft: Identifiable {
    let id = UUID()
    let sessionID: String
    let cueID: Int64?
    var kind: Note.Kind
    var text: String
}

/// What the translate button is doing, in a form the toolbar can show.
/// What the window is pointed at.
enum LibraryTarget: Hashable {
    case allSessions
    case folder(String)
    case section(LibrarySection)
}

enum TranslationPhase: Equatable {
    case off
    case waiting        // the task has been asked to run
    case downloading    // the language pack is not on this Mac yet
    case working        // translating
    case glossing       // only a looked-up word, paragraphs untouched
    case done
    case failed(String)

    var label: String {
        switch self {
        case .off:             return "Translate into Chinese"
        case .waiting:         return "Preparing…"
        case .downloading:     return "Downloading Chinese (one time, macOS will ask)"
        case .working:         return "Translating…"
        case .glossing:        return "Translated on demand"
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
    /// Where the window is pointed. A folder, or all of them, or one of the study sections.
    @Published var target: LibraryTarget = .allSessions

    @Published private(set) var folderTree: [FolderNode] = []
    /// Sessions in the current target. Kept apart from `sessions` (the whole archive) so the
    /// list column can be scoped to a folder without losing the global list.
    @Published private(set) var listedSessions: [Session] = []
    /// Multi-selection in the list, for moving or deleting in bulk.
    @Published var sessionSelection = Set<String>()

    // The other sections' contents.
    @Published private(set) var notebook: [NoteWithSession] = []
    @Published private(set) var favourites: [NoteWithSession] = []
    @Published private(set) var vocabulary: [VocabularyEntry] = []
    @Published private(set) var statistics = LibraryStatistics()

    // Translation: paragraph by paragraph, on demand, in Simplified Chinese.
    @Published private(set) var translationPhase: TranslationPhase = .off
    @Published private(set) var translations: [Int: String] = [:]
    /// Chinese glosses for words looked up on their own, keyed by lemma. They travel in the
    /// same batch as the paragraphs, so a looked-up word needs no second translation session.
    @Published private(set) var glosses: [String: String] = [:]
    /// Lemmas waiting to be glossed: translated even when paragraph translation is off.
    @Published private(set) var wantedWords: [String] = []
    /// Bumped to ask the view's `translationTask` to run; the session only exists inside it.
    @Published private(set) var translationRequestID = 0

    // Word inspection: drives the popover anchored on the word itself, so the transcript
    // stays the interface instead of sending every gesture down to a panel.
    @Published private(set) var inspection: WordInspection?
    @Published private(set) var occurrences: [SearchHit] = []

    // The note being written.
    @Published var noteDraft: NoteDraft?

    // ⌘K palette.
    @Published var isPaletteVisible = false
    @Published var paletteSelection = 0
    @Published private(set) var paletteResults = PaletteResults()
    @Published var paletteQuery = "" { didSet { schedulePaletteSearch() } }

    private var store: HistoryStore?
    private var paletteTask: Task<Void, Never>?

    /// The old section accessor, kept so the panes and toolbar do not all have to change.
    var section: LibrarySection {
        get { if case .section(let value) = target { return value }; return .sessions }
        set { target = .section(newValue) }
    }
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

    /// The same toggle, expressed as "turn it on" for menu items.
    func toggleTranslationOn() {
        guard !translationOn else { return }
        toggleTranslation()
    }

    func toggleTranslation() {
        if translationOn {
            translationPhase = .off
            translations = [:]
        } else {
            translationPhase = .waiting
            translationRequestID += 1
        }
    }

    // MARK: - Palette

    func showPalette() {
        isPaletteVisible = true
        paletteSelection = 0
        if paletteQuery.isEmpty { paletteResults = PaletteResults() }
    }

    func hidePalette() {
        isPaletteVisible = false
        paletteQuery = ""
        paletteResults = PaletteResults()
    }

    private func schedulePaletteSearch() {
        paletteTask?.cancel()
        paletteSelection = 0
        let query = paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let store else { paletteResults = PaletteResults(); return }
        paletteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let found = (try? await store.everything(matching: query)) ?? PaletteResults()
            guard !Task.isCancelled else { return }
            self.paletteResults = found
        }
    }

    /// Asks for one word's Chinese without turning on whole-paragraph translation.
    func requestGloss(for lemma: String) {
        guard glosses[lemma] == nil else { return }
        if !wantedWords.contains(lemma) { wantedWords.append(lemma) }
        if translationPhase == .off { translationPhase = .glossing }
        translationRequestID += 1
    }

    /// Runs inside the SwiftUI `translationTask`, which is the only place a usable session
    /// exists. Paragraphs are translated as blocks so the Chinese reads as prose rather than
    /// line fragments, and results are keyed by paragraph index.
    @available(macOS 15.0, *)
    func runTranslation(paragraphs: [[Cue]], using session: TranslationSession) async {
        let translatingParagraphs = translationOn && !paragraphs.isEmpty
        let words = wantedWords
        guard translatingParagraphs || !words.isEmpty else {
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

            // Paragraphs and words go in one batch; the tag says which is which on the way
            // back, where the order is all that is guaranteed.
            var requests: [TranslationSession.Request] = []
            if translatingParagraphs {
                requests += paragraphs.enumerated().map { index, paragraph in
                    TranslationSession.Request(
                        sourceText: paragraph.map(\.text).joined(separator: " "),
                        clientIdentifier: "p\(index)")
                }
            }
            requests += words.map {
                TranslationSession.Request(sourceText: $0, clientIdentifier: "w\($0)")
            }

            let responses = try await session.translations(from: requests)

            var translated: [Int: String] = translatingParagraphs ? [:] : translations
            var freshGlosses = glosses
            for response in responses {
                switch response.clientIdentifier {
                case .some(let tag) where tag.hasPrefix("p"):
                    if let index = Int(tag.dropFirst()), index < paragraphs.count {
                        translated[index] = response.targetText
                    }
                case .some(let tag) where tag.hasPrefix("w"):
                    freshGlosses[String(tag.dropFirst())] = response.targetText
                default:
                    break
                }
            }
            translations = translated
            glosses = freshGlosses
            wantedWords.removeAll { freshGlosses[$0] != nil }
            translationPhase = translatingParagraphs ? .done : .glossing
            if inspection != nil, let lemma = inspection?.lemma, let gloss = freshGlosses[lemma] {
                inspection?.translation = gloss
            }
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
            folderTree = try await store.folderTree()
            listedSessions = try await sessionsForTarget()
                listedSessions = try await sessionsForTarget()
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

    // MARK: - Folders

    private func sessionsForTarget() async throws -> [Session] {
        guard let store else { return [] }
        switch target {
        case .allSessions:            return try await store.sessions()
        case .folder(let id):         return try await store.sessions(inFolder: id)
        case .section:                return try await store.sessions()
        }
    }

    func selectTarget(_ newTarget: LibraryTarget) async {
        target = newTarget
        sessionSelection = []
        selectedSessionID = nil
        await refreshListed()
    }

    func refreshListed() async {
        guard let store else { return }
        folderTree = (try? await store.folderTree()) ?? folderTree
        listedSessions = (try? await sessionsForTarget()) ?? []
    }

    @discardableResult
    func createFolder(named name: String, in parentID: String? = nil) async -> Folder? {
        guard let store, let folder = try? await store.createFolder(name, parentID: parentID) else {
            return nil
        }
        await refreshListed()
        return folder
    }

    func renameFolder(_ id: String, to name: String) async {
        guard let store else { return }
        try? await store.renameFolder(id, to: name)
        await refreshListed()
    }

    func deleteFolder(_ id: String) async {
        guard let store else { return }
        try? await store.deleteFolder(id)
        if case .folder(let current) = target, current == id { target = .allSessions }
        await refresh()
    }

    func moveFolder(_ id: String, to parentID: String?) async {
        guard let store else { return }
        try? await store.moveFolder(id, to: parentID)
        await refreshListed()
    }

    /// Moves every selected session into a folder, or back to the root when nil.
    func moveSelectedSessions(to folderID: String?) async {
        guard let store, !sessionSelection.isEmpty else { return }
        for id in sessionSelection { try? await store.move(id, to: folderID) }
        await refresh()
        sessionSelection = []
    }

    func deleteSelectedSessions() async {
        guard let store else { return }
        for id in sessionSelection { try? await store.deleteSession(id) }
        sessionSelection = []
        await refresh()
    }

    /// Files a newly recorded session under its series, creating the folder the first time.
    ///
    /// This is the point of the tree: nobody stops watching to file an episode. The name
    /// comes from the titles already recorded, so it only fires when a series exists.
    func autoFile(_ sessionID: String) async {
        guard let store,
              let name = try? await store.suggestedFolderName(for: sessionID),
              !name.isEmpty else { return }
        let existing = (try? await store.folders())?.first {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        var folder = existing
        if folder == nil { folder = try? await store.createFolder(name) }
        guard let folder else { return }
        try? await store.move(sessionID, to: folder.id)
        await refresh()
    }

    /// Looks a word up and finds every other line it appears in.
    func inspect(_ word: String, in cue: Cue? = nil) async {
        let lemma = DictionaryLookup.lemma(of: word)
        guard let cue else {
            inspection = WordInspection(word: word, lemma: lemma, cueID: nil,
                                        definition: DictionaryLookup.entry(for: lemma)
                                            ?? DictionaryLookup.entry(for: word))
            occurrences = []
            return
        }
        selectedCueID = cue.id
        inspection = WordInspection(word: word, lemma: lemma, cueID: cue.id,
                                    definition: DictionaryLookup.entry(for: lemma)
                                        ?? DictionaryLookup.entry(for: word))
        inspection?.translation = nil
        if let existing = glosses[lemma] { inspection?.translation = existing }
        requestGloss(for: lemma)
        guard let store else { occurrences = []; return }
        occurrences = (try? await store.occurrences(of: lemma, excludingCue: cue.id)) ?? []
    }

    func clearInspection() {
        inspection = nil
        occurrences = []
    }

    // MARK: - Notes

    /// Starts a note against a line, pre-filled with a quote so the link back to the
    /// sentence is automatic rather than something the user has to type.
    func beginNote(cue: Cue?, kind: Note.Kind = .note, text: String? = nil) {
        guard let sessionID = selectedSessionID else { return }
        let quoted = cue.map { "> \($0.timestamp) \($0.text)\n\n" } ?? ""
        noteDraft = NoteDraft(sessionID: sessionID,
                              cueID: cue?.id,
                              kind: kind,
                              text: text ?? quoted)
    }

    func saveNoteDraft() async {
        guard let draft = noteDraft else { return }
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { noteDraft = nil; return }
        await addNote(cueID: draft.cueID, kind: draft.kind, text: trimmed)
        noteDraft = nil
    }

    /// Creates a folder for the selected session, named from its siblings when possible.
    func createSuggestedFolder() async {
        guard let store, let sessionID = selectedSessionID else { return }
        let name = (try? await store.suggestedFolderName(for: sessionID)) ?? "New Folder"
        guard let folder = try? await store.createFolder(name) else { return }
        try? await store.move(sessionID, to: folder.id)
        await refresh()
    }

    func cancelNoteDraft() {
        noteDraft = nil
    }

    /// The list binds straight to `selectedSessionID`; this is what reacting to it means.
    /// The list drives the reader: one selected session is the one being read.
    func syncSelectionToList() async {
        guard sessionSelection.count == 1, let id = sessionSelection.first else { return }
        selectedSessionID = id
    }

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
        guard let inspection else { return }
        await addNote(cueID: inspection.cueID, kind: .word, text: inspection.lemma)
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
