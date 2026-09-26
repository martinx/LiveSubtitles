//
//  LibraryWindow.swift
//  LiveSubtitles
//
//  The study window. The transcript is the interface: words are targets, so looking one up
//  opens a card on the word itself rather than sending every gesture down to a panel.
//
//    double-click a word   its card: definition, Chinese, every other line it appears in
//    right-click a word    translate, save to the vocabulary, copy
//    right-click a line    write a note, mark it, copy it, translate the paragraph
//

import AppKit
import LiveSubtitlesKit
import SwiftUI
import Translation

@MainActor
struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var confirmDelete: Session?
    @State private var folderPrompt: FolderPrompt?

    var body: some View {
        translationHost(NavigationSplitView {
            sidebar
        } content: {
            listColumn
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                detailPane
                Divider()
                statusBar
            }
        })
        .frame(minWidth: 900, minHeight: 560)
        // ⌘K. A hidden button is the dependable way to claim a shortcut in SwiftUI; the
        // palette then owns the keyboard while it is open.
        .background {
            Button("") { model.showPalette() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            if model.isPaletteVisible {
                CommandPalette(model: model)
            }
        }
        .sheet(item: $model.noteDraft) { draft in
            NoteEditor(model: model, draft: draft)
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil },
                                                      set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let session = renaming { Task { await model.rename(session.id, to: renameText) } }
                renaming = nil
            }
        }
        .alert("Delete this session?", isPresented: Binding(get: { confirmDelete != nil },
                                                            set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let session = confirmDelete { Task { await model.delete(session.id) } }
                confirmDelete = nil
            }
        } message: {
            Text("Its transcript and notes are removed. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func translationHost<V: View>(_ content: V) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(ParagraphTranslationHost(model: model))
        } else {
            content
        }
    }

    // MARK: - Sidebar

    /// Navigation: the whole archive, then a folder tree of any depth, then the study
    /// sections. Folders live here rather than in a flat list because a series with seasons
    /// is a tree, and flattening it is what made a long history unmanageable.
    private var sidebar: some View {
        List(selection: $model.target) {
            Label {
                Text("All Sessions").font(.system(size: 13.5))
            } icon: {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 13))
                    .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
            }
            .tag(LibraryTarget.allSessions)
            .sidebarRow()

            if !model.folderTree.isEmpty {
                Section("Folders") {
                    OutlineGroup(model.folderTree, children: \.subfolders) { node in
                        Label {
                            Text(node.folder.name).font(.system(size: 13.5))
                        } icon: {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                                .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
                        }
                        .badge(node.totalSessions)
                        .tag(LibraryTarget.folder(node.folder.id))
                        .contextMenu { folderMenu(node.folder) }
                    }
                }
            }

            Section("Study") {
                ForEach([LibrarySection.notebook, .favourites, .vocabulary, .writing, .statistics]) { item in
                    Label {
                        Text(item.title).font(.system(size: 13.5))
                    } icon: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
                    }
                    .tag(LibraryTarget.section(item))
                    .sidebarRow()
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    folderPrompt = FolderPrompt(mode: .new(nil))
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus").font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .sheet(item: $folderPrompt) { prompt in
            FolderPromptSheet(prompt: prompt) { name in
                switch prompt.mode {
                case .new(let parent):
                    Task { await model.createFolder(named: name, in: parent) }
                case .rename(let folder):
                    Task { await model.renameFolder(folder.id, to: name) }
                }
                folderPrompt = nil
            } onCancel: {
                folderPrompt = nil
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("New Subfolder…") { folderPrompt = FolderPrompt(mode: .new(folder.id)) }
        Button("Rename…") { folderPrompt = FolderPrompt(mode: .rename(folder)) }
        Divider()
        Menu("Move to") {
            folderDestinations { id in Task { await model.moveFolder(folder.id, to: id) } }
        }
        Divider()
        Button("Delete Folder", role: .destructive) { Task { await model.deleteFolder(folder.id) } }
    }

    /// The folder tree, expanded as nested submenus — the same shape the sidebar shows.
    @ViewBuilder
    private func folderDestinations(_ action: @escaping (String?) -> Void) -> some View {
        Button("All Sessions (no folder)") { action(nil) }
        Divider()
        ForEach(model.folderTree) { node in
            FolderDestination(node: node, action: action)
        }
    }

    // MARK: - List column

    @ViewBuilder
    private var listColumn: some View {
        switch model.target {
        case .allSessions, .folder:
            sessionList
        case .section(.notebook):
            notesList(model.notebook, empty: "Nothing saved yet.")
        case .section(.favourites):
            notesList(model.favourites, empty: "No favourite lines yet.")
        case .section(.vocabulary):
            vocabularyList
        default:
            List { Text("Nothing to list here.").foregroundStyle(.secondary) }
        }
    }

    private var sessionList: some View {
        List(selection: $model.sessionSelection) {
            ForEach(model.listedSessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
                    .contextMenu { sessionMenu(session) }
            }
            if model.listedSessions.isEmpty {
                Text("No sessions here yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.sessionSelection) { _, _ in
            Task { await model.syncSelectionToList() }
        }
        .safeAreaInset(edge: .bottom) {
            if model.sessionSelection.count > 1 {
                HStack(spacing: 10) {
                    Text("\(model.sessionSelection.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteSelectedSessions() }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: Session) -> some View {
        Button("Rename…") {
            renameText = session.title
            renaming = session
        }
        Menu("Move to") {
            folderDestinations { id in Task { await model.moveSelectedSessions(to: id) } }
        }
        Divider()
        Menu("Export") {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) { model.export(format, sessionID: session.id) }
            }
        }
        if model.sessionSelection.count > 1 {
            Divider()
            Button("Delete \(model.sessionSelection.count) Sessions", role: .destructive) {
                Task { await model.deleteSelectedSessions() }
            }
        } else {
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = session }
        }
    }

    private func notesList(_ notes: [NoteWithSession], empty: String) -> some View {
        List {
            ForEach(notes) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    MarkdownText(entry.note.text)
                    Text(entry.sessionTitle).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }
            if notes.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var vocabularyList: some View {
        List {
            ForEach(model.vocabulary) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.term)
                        if let gloss = model.glosses[entry.term] {
                            Text(gloss).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if entry.count > 1 {
                        Text("×\(entry.count)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if model.vocabulary.isEmpty {
                Text("No vocabulary yet. Double-click a word in the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(model.sessions) { session in
                    Button {
                        Task { await model.select(session.id) }
                    } label: {
                        Text("\(session.title)  (\(session.cueCount))")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                    Text(model.selectedSession?.title ?? "No session").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(model.sessions.isEmpty)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search every session", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                if model.isSearching {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())

            Spacer(minLength: 12)

            GlassControlGroup {
                ToolbarIconButton(symbol: "translate",
                                  help: model.translationPhase.label,
                                  enabled: !model.isSearching) {
                    model.toggleTranslation()
                }
                ToolbarIconButton(symbol: "note.text", help: "Write a note about this session") {
                    model.beginNote(cue: model.selectedCue)
                }
                .disabled(model.selectedSession == nil)
                ToolbarIconButton(symbol: "play.circle",
                                  help: "Replay the original — needs audio retention (phase 1)",
                                  enabled: false)
                ToolbarIconButton(symbol: "gauge.with.needle",
                                  help: "Playback speed — needs audio retention (phase 1)",
                                  enabled: false)
                ToolbarIconButton(symbol: "text.bubble",
                                  help: "Summarise — needs the local model (phase 7)",
                                  enabled: false)
            }

            if let session = model.selectedSession, model.section == .sessions {
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(format.displayName) { model.export(format, sessionID: session.id) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.panePadding)
        .padding(.vertical, 12)
    }

    // MARK: - Panes

    @ViewBuilder
    private var detailPane: some View {
        switch model.target {
        case .allSessions, .folder:
            reader
        case .section(.statistics):
            statisticsPane
        case .section(.writing):
            placeholder("Writing",
                        "Summaries and graded practice, once the local model is in.")
        case .section(let other):
            placeholder(other.title, detailHint(for: other))
        }
    }

    private func detailHint(for section: LibrarySection) -> String {
        switch section {
        case .notebook:    return "Pick a note on the left. Notes are Markdown and keep a link to the line they came from."
        case .favourites:  return "Lines you marked while reading."
        case .vocabulary:  return "Words you saved. Look one up again from the transcript."
        default:           return ""
        }
    }

    private var reader: some View {
        Group {
            if model.isSearching {
                searchResults
            } else if model.readerCues.isEmpty {
                placeholder("Nothing here yet",
                            "Start listening and every finished line lands in this session.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.paragraphSpacing) {
                        ForEach(Array(model.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(paragraph) { cue in
                                    TokenizedLine(cue: cue,
                                                  model: model,
                                                  notes: model.notesByCue[cue.id] ?? [])
                                }
                                if let translation = model.translations[index] {
                                    TranslationBlock(text: translation)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.panePadding)
                    .padding(.vertical, Metrics.panePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("\(model.hits.count) matches for “\(model.searchText)”")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.sessionTitle).font(.caption2).foregroundStyle(.tertiary)
                        TokenizedLine(cue: hit.cue, model: model, notes: [])
                    }
                }
            }
            .padding(.horizontal, Metrics.panePadding)
            .padding(.vertical, Metrics.panePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func unusedNotesPane(_ notes: [NoteWithSession], empty: String) -> some View {
        Group {
            if notes.isEmpty {
                placeholder("Nothing here yet", empty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(notes) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: symbol(for: entry.note.kind))
                                    .foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 4) {
                                    MarkdownText(entry.note.text)
                                    Text(entry.sessionTitle)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    Task { await model.deleteNote(entry.note.id) }
                                } label: {
                                    Image(systemName: "trash").font(.caption)
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(.horizontal, Metrics.panePadding)
                    .padding(.vertical, Metrics.panePadding)
                }
            }
        }
    }

    private var unusedVocabularyPane: some View {
        Group {
            if model.vocabulary.isEmpty {
                placeholder("No vocabulary yet",
                            "Double-click any word in the transcript, then save it from its card.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.vocabulary) { entry in
                            HStack {
                                Text(entry.term).font(.body)
                                if let gloss = model.glosses[entry.term] {
                                    Text(gloss).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.count > 1 {
                                    Text("×\(entry.count)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                    .padding(.horizontal, Metrics.panePadding)
                    .padding(.vertical, Metrics.panePadding)
                }
            }
        }
    }

    private var statisticsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                statistic("Sessions", "\(model.statistics.sessions)")
                statistic("Lines", "\(model.statistics.cues)")
                statistic("Notes", "\(model.statistics.notes)")
                statistic("Favourites", "\(model.statistics.favourites)")
                statistic("Words saved", "\(model.statistics.vocabulary)")
                statistic("Listening time", formatted(model.statistics.listeningTime))
                Divider().padding(.vertical, 6)
                Text("Word frequency, coverage and sentence statistics arrive with the analysis pass.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Metrics.panePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(detail).font(.callout).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// One quiet line of help, where the old inspector's bulk used to be.
    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("Double-click a word for its meaning · right-click for more")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if case .failed(let why) = model.translationPhase {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if model.translationPhase != .off {
                Text(model.translationPhase.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Metrics.panePadding)
        .padding(.vertical, 7)
    }

    private func symbol(for kind: Note.Kind) -> String {
        switch kind {
        case .word:      return "textformat.abc"
        case .phrase:    return "text.quote"
        case .favourite: return "star"
        case .note:      return "note.text"
        }
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - One line, as words

/// A cue rendered as individually addressable words, so a lookup happens on the word itself.
private struct TokenizedLine: View {
    let cue: Cue
    @ObservedObject var model: LibraryModel
    let notes: [Note]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                model.selectedCueID = cue.id
            } label: {
                Text(cue.timestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.selectedCueID == cue.id ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 62, alignment: .leading)
            .contextMenu { lineMenu }

            VStack(alignment: .leading, spacing: 4) {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(Array(DictionaryLookup.words(in: cue.text).enumerated()), id: \.offset) { _, word in
                        WordToken(word: word, cue: cue, model: model)
                    }
                }
                if !notes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(notes) { note in
                            Label(note.text, systemImage: "note.text")
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(model.selectedCueID == cue.id ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCueID = cue.id }
        .contextMenu { lineMenu }
    }

    @ViewBuilder
    private var lineMenu: some View {
        Button("Write a Note…") { model.beginNote(cue: cue) }
        Button("Mark as Favourite") { model.beginNote(cue: cue, kind: .favourite) }
        Button("Translate This Line") { model.toggleTranslationOn() }
        Divider()
        Button("Copy Line") { copy(cue.text) }
        Button("Copy with Timestamp") { copy("\(cue.timestamp)  \(cue.text)") }
        Divider()
        Button("Search for This Line") { model.searchText = cue.text }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One word. Double-click is the whole interaction; the card appears on the word itself.
private struct WordToken: View {
    let word: String
    let cue: Cue
    @ObservedObject var model: LibraryModel

    private var isInspected: Bool {
        model.inspection?.word == word && model.inspection?.cueID == cue.id
    }

    var body: some View {
        Text(word)
            .font(.system(size: 14))
            .lineSpacing(Metrics.lineSpacing)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(isInspected ? Color.accentColor.opacity(0.20) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.selectedCueID = cue.id
                Task { await model.inspect(word, in: cue) }
            }
            .onTapGesture {
                model.selectedCueID = cue.id
                if isInspected { model.clearInspection() }
            }
            .popover(isPresented: inspectionBinding, arrowEdge: .bottom) {
                WordCard(model: model)
            }
            .contextMenu {
                Button("Translate “\(word)”") {
                    Task { await model.inspect(word, in: cue) }
                }
                Button("Add to Vocabulary") {
                    Task {
                        await model.inspect(word, in: cue)
                        await model.saveInspectedWord()
                    }
                }
                Divider()
                Button("Copy Word") { copy(word) }
                Button("Copy Line") { copy(cue.text) }
                Divider()
                Button("Write a Note…") { model.beginNote(cue: cue) }
            }
            .help("Double-click for the meaning of “\(word)”")
    }

    private var inspectionBinding: Binding<Bool> {
        Binding(get: { isInspected },
                set: { if !$0 { model.clearInspection() } })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Folders in menus

/// A folder as a nested submenu, so "Move to" shows the same tree the sidebar does.
struct FolderDestination: View {
    let node: FolderNode
    let action: (String?) -> Void

    var body: some View {
        if node.children.isEmpty {
            Button(node.folder.name) { action(node.folder.id) }
        } else {
            Menu(node.folder.name) {
                Button("Move Here") { action(node.folder.id) }
                Divider()
                ForEach(node.children) { child in
                    FolderDestination(node: child, action: action)
                }
            }
        }
    }
}

/// New folder or rename, in one small sheet.
struct FolderPrompt: Identifiable {
    enum Mode {
        case new(String?)      // parent folder id, nil for the root
        case rename(Folder)
    }

    let id = UUID()
    let mode: Mode
    var text: String = ""
}

struct FolderPromptSheet: View {
    @State var prompt: FolderPrompt
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $prompt.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if case .rename(let folder) = prompt.mode { prompt.text = folder.name }
        }
    }

    private var title: String {
        switch prompt.mode {
        case .new(let parent): return parent == nil ? "New Folder" : "New Subfolder"
        case .rename:          return "Rename Folder"
        }
    }

    private func commit() {
        let name = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onCommit(name)
    }
}

// MARK: - The word card

private struct WordCard: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inspection = model.inspection {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(inspection.lemma)
                        .font(.system(size: 16, weight: .semibold))
                    if let gloss = inspection.translation ?? model.glosses[inspection.lemma] {
                        Text(gloss).font(.system(size: 15)).foregroundStyle(.secondary)
                    } else if model.translationPhase == .glossing || model.translationPhase == .working {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }

                if let definition = inspection.definition {
                    Text(definition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No dictionary entry on this Mac.")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                if !model.occurrences.isEmpty {
                    Divider()
                    Text("Other lines (\(model.occurrences.count))")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.occurrences.prefix(3)) { hit in
                        Button {
                            Task { await model.select(hit.sessionID) }
                            model.selectedCueID = hit.cue.id
                        } label: {
                            Text("• \(hit.cue.text)")
                                .font(.caption2)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Button("Add to Vocabulary") { Task { await model.saveInspectedWord() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Note…") { model.beginNote(cue: nil) }
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Notes

/// Markdown, with the link back to the sentence already in place.
private struct NoteEditor: View {
    @ObservedObject var model: LibraryModel
    @State var draft: NoteDraft

    private var words: [String] {
        guard let cueID = draft.cueID,
              let cue = model.readerCues.first(where: { $0.id == cueID }) else { return [] }
        var seen = Set<String>()
        return DictionaryLookup.words(in: cue.text).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $draft.kind) {
                    Text("Note").tag(Note.Kind.note)
                    Text("Word").tag(Note.Kind.word)
                    Text("Phrase").tag(Note.Kind.phrase)
                    Text("Favourite").tag(Note.Kind.favourite)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
                if let cueID = draft.cueID,
                   let cue = model.readerCues.first(where: { $0.id == cueID }) {
                    Text("Linked to \(cue.timestamp)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $draft.text)
                .font(.system(size: 13.5))
                .frame(minHeight: 170)
                .padding(8)
                .glassPanel(cornerRadius: Metrics.controlRadius)

            if !words.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Insert a word").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(words, id: \.self) { word in
                            Button(word) { insert(word) }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            HStack {
                Text("Markdown: **bold** *italic* `code` — the quote above links this to its line.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.cancelNoteDraft() }
                Button("Save") {
                    model.noteDraft = draft
                    Task { await model.saveNoteDraft() }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func insert(_ word: String) {
        let needsSpace = !draft.text.isEmpty && !draft.text.hasSuffix(" ") && !draft.text.hasSuffix("\n")
        draft.text += (needsSpace ? " " : "") + "**\(word)** "
    }
}

// MARK: - Pieces

private struct TranslationBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 3)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(Metrics.lineSpacing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 72)
    }
}

/// Notes are written in Markdown; this is what they look like when read back.
private struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}

@available(macOS 15.0, *)
private struct ParagraphTranslationHost: ViewModifier {
    @ObservedObject var model: LibraryModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.translationRequestID) { _, _ in
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans"))
            }
            .translationTask(configuration) { session in
                // Paragraphs when the toggle is on, plus any word looked up on its own.
                await model.runTranslation(paragraphs: model.translationOn ? model.paragraphs : [],
                                           using: session)
            }
    }
}

/// A wrapping row layout: words flow and break like text, but stay separate views.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title).lineLimit(1)
            Text("\(session.cueCount) lines · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Window

@MainActor
final class LibraryWindow {
    private var window: NSWindow?

    func show(model: LibraryModel) {
        let view = LibraryView(model: model)

        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let created = NSWindow(contentViewController: NSHostingController(rootView: view))
            created.title = "Live Subtitles Library"
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 1120, height: 700))
            WindowPlacement.center(created)
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
