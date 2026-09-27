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
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ReadingTheme { ReadingTheme(scheme: colorScheme) }

    /// What the enhanced switch has to say for itself.
    ///
    /// It reads as broken when it does nothing, and on a session the analysis has not reached
    /// there is nothing for it to do — so it says so instead.
    private var enhancedHelp: String {
        guard model.hasEnhancedContent else {
            return "Nothing enhanced in this session yet — the speaker pass runs after a session ends"
        }
        return model.showsEnhanced
            ? "Showing the enhanced reading — speakers and translation"
            : "Showing the raw transcript"
    }

    /// The palette's key comes from the settings, like the menu's do.
    private var paletteKeyEquivalent: KeyEquivalent {
        guard let shortcut = model.paletteShortcut,
              let characters = KeyShortcut.menuKeyEquivalent(for: shortcut.keyCode),
              let first = characters.first else { return "k" }
        return KeyEquivalent(first)
    }

    private var paletteModifiers: EventModifiers {
        guard let flags = model.paletteShortcut?.flags else { return .command }
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers.isEmpty ? .command : modifiers
    }
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            listColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                detailPane
                Divider()
                statusBar
            }
        }
        // SwiftUI adds its own sidebar toggle, which slides to the trailing edge once the
        // sidebar is collapsed and reads as a stray button. The window has its own controls.
        .toolbar(removing: .sidebarToggle)
        .preferredColorScheme(model.appearance)
        .frame(minWidth: 1040, minHeight: 600)
        // ⌘K. A hidden button is the dependable way to claim a shortcut in SwiftUI; the
        // palette then owns the keyboard while it is open.
        .background {
            Button("") { model.showPalette() }
                .keyboardShortcut(paletteKeyEquivalent, modifiers: paletteModifiers)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            if model.isPaletteVisible {
                CommandPalette(model: model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveSubtitlesHistoryChanged)) { _ in
            Task { await model.refreshLive() }
        }
        .onChange(of: model.newFolderRequestID) { _, _ in
            folderPrompt = FolderPrompt(mode: .new(nil))
        }
        .onChange(of: model.searchFocusRequestID) { _, _ in
            searchFocused = true
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

    // MARK: - Sidebar

    /// Navigation: the whole archive, then a folder tree of any depth, then the study
    /// sections. Folders live here rather than in a flat list because a series with seasons
    /// is a tree, and flattening it is what made a long history unmanageable.
    private var sidebar: some View {
        List(selection: $model.target) {
            Section("Library") {
                sidebarRow("All Sessions", symbol: "rectangle.stack", tag: .allSessions)
                    .contextMenu {
                        Button("New Folder…") { folderPrompt = FolderPrompt(mode: .new(nil)) }
                    }
                    // Dropping here unfiles whatever was dragged.
                    .dropDestination(for: String.self) { tokens, _ in
                        Task { await model.handleDrop(tokens, onto: nil) }
                        return true
                    }

                ForEach(model.visibleFolderRows) { row in
                    HStack(spacing: 6) {
                        Label {
                            Text(row.folder.name).font(.system(size: 13))
                        } icon: {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tint)
                                .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        // The triangle goes on the trailing edge, next to the count, so the
                        // leading edge is free for the folder icon.
                        if row.hasChildren {
                            Button {
                                model.toggleFolderExpansion(row.folder.id)
                            } label: {
                                Image(systemName: model.expandedFolders.contains(row.folder.id)
                                      ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // The same row insets and padding every other sidebar row gets, so a
                    // top-level folder sits on exactly the same x as All Sessions; the depth
                    // indent is added on top of that, not instead of it.
                    .padding(.vertical, Metrics.sidebarRowVertical)
                    .padding(.leading, Metrics.sidebarRowHorizontal + CGFloat(row.depth) * 16)
                    .padding(.trailing, Metrics.sidebarRowHorizontal)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .tag(LibraryTarget.folder(row.folder.id))
                    .contextMenu { folderMenu(row.folder) }
                    .draggable(DragToken.folder(row.folder.id))
                    .dropDestination(for: String.self) { tokens, _ in
                        Task { await model.handleDrop(tokens, onto: row.folder.id) }
                        return true
                    }
                }

                // Always present, whether or not there are folders yet: a folder tree with no
                // visible way to start one is a dead end, and a bar pinned to the bottom is
                // the last place anyone looks.
                Button {
                    folderPrompt = FolderPrompt(mode: .new(nil))
                } label: {
                    Label {
                        Text("New Folder").font(.system(size: 13.5))
                    } icon: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .sidebarRow()
                .selectionDisabled()
            }

            Section("Study") {
                ForEach([LibrarySection.notebook, .favourites, .vocabulary, .writing, .statistics]) { item in
                    sidebarRow(item.title, symbol: item.symbol, tag: .section(item))
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.target) { _, _ in
            Task { await model.targetChanged() }
        }
        // Last on the column, and with nothing after it: a toolbar modifier placed here
        // stopped the width from being applied at all, and the sidebar sat at its default
        // 192pt however large the window was.
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
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

    /// One sidebar row, at the size the rest of the sidebar uses.
    private func sidebarRow(_ title: String, symbol: String, tag: LibraryTarget) -> some View {
        Label {
            Text(title).font(.system(size: 13))
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
        }
        .tag(tag)
        .sidebarRow()
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
                SessionRow(session: session, isLive: session.id == model.liveSessionID)
                    .tag(session.id)
                    .draggable(DragToken.session(session.id))
                    .contextMenu { sessionMenu(session) }
            }
            if model.listedSessions.isEmpty {
                Text("No sessions here yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // The middle column is the same surface as the sidebar and the detail, rather than
        // an opaque white sheet wedged between them.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .onDeleteCommand {
            // The Delete key, the way every list on this platform behaves.
            if !model.sessionSelection.isEmpty {
                Task { await model.deleteSelectedSessions() }
            } else if let id = model.selectedSessionID {
                model.sessionSelection = [id]
                Task { await model.deleteSelectedSessions() }
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
                    .focused($searchFocused)
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
                                  help: model.translationPhase.label) {
                    model.toggleTranslation()
                }
                ToolbarIconButton(symbol: model.showsEnhanced ? "wand.and.stars" : "doc.plaintext",
                                  help: enhancedHelp,
                                  enabled: model.hasEnhancedContent) {
                    model.showsEnhanced.toggle()
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
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Reading.paragraphGap) {
                        ForEach(Array(model.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                            if index > 0 { paragraphRule }
                            VStack(alignment: .leading, spacing: Reading.cueGap) {
                                ForEach(paragraph) { cue in
                                    TranscriptLine(cue: cue,
                                                   model: model,
                                                   notes: model.notesByCue[cue.id] ?? [])
                                        .id(cue.id)
                                }
                                // Part of the enhanced layer, so the switch hides it too:
                                // leaving it out meant turning the layer off left the Chinese
                                // sitting there, which reads as the switch not working.
                                if model.showsEnhanced,
                                   model.paragraphTranslationOn,
                                   let translation = model.translations[index] {
                                    TranslationLine(text: translation)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Reading.measurePadding)
                    .padding(.vertical, 26)
                    // A column, not a page: the text stops at a width the eye can follow and
                    // the remaining space is left empty rather than filled with characters.
                    .frame(maxWidth: Reading.measure + Reading.measurePadding * 2, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(theme.background)
                .onChange(of: model.readerCues.count) { _, _ in
                    guard model.selectedSessionID == model.liveSessionID,
                          let last = model.readerCues.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                }
            }
        }
    }

    private var paragraphRule: some View {
        Rectangle()
            .fill(theme.rule)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("\(model.hits.count) matches for “\(model.searchText)”")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.sessionTitle).font(.caption2).foregroundStyle(.tertiary)
                        TranscriptLine(cue: hit.cue, model: model, notes: [])
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
    @ViewBuilder
    private var statusBar: some View {
        if #available(macOS 15.0, *) {
            statusBarBody
                .modifier(OneShotTranslation(model: model))
                // Identity is applied last, and that order is the whole point: `.id` before
                // `.modifier` re-identifies only the inner view, the modifier and its @State
                // are reused, and onAppear never runs again — which is why the task never
                // started. Outermost, the whole subtree is rebuilt.
                .id(model.translationRequestID)
        } else {
            statusBarBody
        }
    }

    private var statusBarBody: some View {
        HStack(spacing: 10) {
            if model.showsEnhanced, !model.sessionSpeakers.isEmpty {
                Label("\(model.sessionSpeakers.count) speaker\(model.sessionSpeakers.count == 1 ? "" : "s")",
                      systemImage: "person.2.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Double-click a word for its meaning · right-click for more")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let filed = model.lastFiled {
                Label(filed, systemImage: "folder.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

/// One line of the transcript.
///
/// The words are still individually addressable — double-clicking any of them opens its card —
/// but the layout is a row of two fixed columns: a gutter for the time, and the sentence. The
/// previous version let the timestamp and a wrapping word flow share one line, so a cue that
/// wrapped ran into the cue below it.
private struct TranscriptLine: View {
    let cue: Cue
    @ObservedObject var model: LibraryModel
    let notes: [Note]

    @Environment(\.colorScheme) private var colorScheme
    private var theme: ReadingTheme { ReadingTheme(scheme: colorScheme) }

    private var isSelected: Bool { model.selectedCueID == cue.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(cue.timestamp)
                .font(.system(size: Reading.timestampSize, weight: .regular, design: .monospaced))
                .foregroundStyle(isSelected ? theme.secondary : theme.tertiary)
                .frame(width: Reading.gutter, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedCueID = cue.id }
                .contextMenu { lineMenu }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if model.showsEnhanced, let speaker = cue.speaker {
                        SpeakerChip(speaker: speaker,
                                    index: model.sessionSpeakers.firstIndex(of: speaker))
                    }
                    FlowLayout(spacing: model.wordSpacing, lineSpacing: Reading.bodyLeading) {
                        ForEach(Array(DictionaryLookup.words(in: cue.text).enumerated()),
                                id: \.offset) { _, word in
                            WordToken(word: word, cue: cue, model: model)
                        }
                    }
                }
                if !notes.isEmpty { noteBadges }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
        .background(isSelected ? theme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCueID = cue.id }
        .contextMenu { lineMenu }
    }

    private var noteBadges: some View {
        HStack(spacing: 4) {
            ForEach(notes) { note in
                Label(note.text, systemImage: "note.text")
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
        }
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

    @Environment(\.colorScheme) private var colorScheme
    private var theme: ReadingTheme { ReadingTheme(scheme: colorScheme) }

    private var isInspected: Bool {
        model.inspection?.word == word && model.inspection?.cueID == cue.id
    }

    var body: some View {
        Text(word)
            // Set at reading size with no padding of its own: the flow layout already puts a
            // word space between tokens, and adding to it made a sentence look like a row of
            // chips rather than prose.
            .font(model.readingFont.font(size: Reading.bodySize))
            .foregroundStyle(theme.text)
            .padding(.vertical, 0.5)
            .background(isInspected ? theme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
//
//  Read at a glance, in the order a person actually asks: what does it mean, how is it
//  said, what else does it mean, where else did I see it. Everything else is a button.

private struct WordCard: View {
    @ObservedObject var model: LibraryModel
    @State private var tab: WordCardTab = .dictionary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let inspection = model.inspection {
                heading(inspection)
                Divider().padding(.vertical, 10)
                Picker("", selection: $tab) {
                    ForEach(WordCardTab.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 10)
                sourceBody
                if !model.occurrences.isEmpty {
                    Divider().padding(.vertical, 10)
                    occurrences
                }
                Divider().padding(.vertical, 10)
                actions(inspection)
            }
        }
        .padding(16)
        .frame(width: 380)
        .task(id: tab) {
            // Fetched on demand: the local tab never waits on the network, and a lookup that
            // never leaves the Mac never touches it at all.
            if tab == .online { await model.loadOnlineEntry() }
        }
    }

    @ViewBuilder
    private var sourceBody: some View {
        switch tab {
        case .dictionary:
            if let entry = model.inspection?.entry {
                senses(entry)
            } else {
                note("This Mac has no entry for it.", detail: "The online tab may have one.")
            }
        case .online:
            switch model.onlineState {
            case .loading:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Looking it up…").font(.caption).foregroundStyle(.secondary)
                }
            case .ready:
                if let entry = model.onlineEntry { senses(entry, showsPartOfSpeech: true) }
            case .failed(let why):
                note(why, detail: nil)
            case .idle:
                note("Not looked up yet.", detail: nil)
            }
        case .translation:
            VStack(alignment: .leading, spacing: 5) {
                if let gloss = model.inspection?.translation ?? model.glosses[model.inspection?.lemma ?? ""] {
                    Text(gloss).font(.system(size: 15))
                } else {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Translating…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(_ inspection: WordInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(inspection.entry?.headword ?? inspection.lemma)
                    .font(.system(size: 22, weight: .semibold))
                if let phonetics = inspection.entry?.phonetics {
                    Text("/\(phonetics)/").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await model.saveInspectedWord() }
                } label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.borderless)
                .help("Add to vocabulary")
            }

            HStack(spacing: 8) {
                if let gloss = inspection.translation ?? model.glosses[inspection.lemma] {
                    Text(gloss).font(.system(size: 17))
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("translating…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let part = inspection.entry?.partOfSpeech {
                    Text(part)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private func senses(_ entry: DictionaryEntry, showsPartOfSpeech: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(entry.senses.prefix(3)) { sense in
                VStack(alignment: .leading, spacing: 2) {
                    if let label = sense.label {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(showsPartOfSpeech ? .secondary : .tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(sense.definition)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    if let example = sense.example {
                        Text("“\(example)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ message: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var occurrences: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass").font(.caption2)
                Text("Appears in \(model.occurrences.count) other line\(model.occurrences.count == 1 ? "" : "s")")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            ForEach(model.occurrences.prefix(3)) { hit in
                Button {
                    Task { await model.select(hit.sessionID) }
                    model.selectedCueID = hit.cue.id
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Text(hit.cue.timestamp)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(hit.cue.text)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ inspection: WordInspection) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.saveInspectedWord() }
            } label: {
                Label("Save", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                model.beginNote(cue: nil, text: "**\(inspection.lemma)** — ")
            } label: {
                Label("Note", systemImage: "square.and.pencil")
            }
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(inspection.lemma, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the word")
        }
    }
}

/// The card's sources, in the order they are worth reading.
enum WordCardTab: String, CaseIterable, Identifiable {
    case dictionary, online, translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictionary:  return "Dictionary"
        case .online:      return "Online"
        case .translation: return "Chinese"
        }
    }
}

// MARK: - Notes
//
//  No kind picker: the kind follows from where the note was started, and "is it a word or a
//  phrase" is something the app can see for itself. What the user gets instead is a toolbar
//  that does something, the sentence already quoted, and the words one tap away.

private struct NoteEditor: View {
    @ObservedObject var model: LibraryModel
    @State var draft: NoteDraft
    @State private var showingPreview = false
    @FocusState private var editing: Bool

    private var words: [String] {
        guard let cueID = draft.cueID,
              let cue = model.readerCues.first(where: { $0.id == cueID }) else { return [] }
        var seen = Set<String>()
        return DictionaryLookup.words(in: cue.text).filter { seen.insert($0.lowercased()).inserted }
    }

    private var linkedCue: Cue? {
        guard let cueID = draft.cueID else { return nil }
        return model.readerCues.first { $0.id == cueID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let cue = linkedCue { linkedLine(cue); Divider() }
            editor
            Divider()
            footer
        }
        .frame(width: 600)
        .onAppear { editing = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
            Text("New Note").font(.headline)
            Spacer()
            Button {
                draft.kind = draft.kind == .favourite ? .note : .favourite
            } label: {
                Label("Favourite", systemImage: draft.kind == .favourite ? "star.fill" : "star")
                    .foregroundStyle(draft.kind == .favourite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Also keep this line in Favourites")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func linkedLine(_ cue: Cue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
            Text(cue.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(cue.text).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.4))
    }

    /// A toolbar that actually edits the text, which is what makes this feel like an editor
    /// rather than a text box.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                formatButton("bold", help: "Bold") { wrap("**") }
                formatButton("italic", help: "Italic") { wrap("*") }
                formatButton("chevron.left.forwardslash.chevron.right", help: "Code") { wrap("`") }
                formatButton("text.quote", help: "Quote") { prefix("> ") }
                formatButton("list.bullet", help: "List") { prefix("- ") }
                Divider().frame(height: 14)
                formatButton("textformat.superscript", help: "Insert the whole sentence") {
                    if let cue = linkedCue {
                        draft.text += (draft.text.isEmpty ? "" : "\n") + "> \(cue.timestamp) \(cue.text)\n"
                    }
                }
                Spacer()
                Toggle("Preview", isOn: $showingPreview)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            if showingPreview {
                ScrollView {
                    MarkdownText(draft.text.isEmpty ? "_Nothing yet._" : draft.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 190)
            } else {
                TextEditor(text: $draft.text)
                    .font(.system(size: 13.5))
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 190)
            }

            if !words.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Text("Insert").font(.caption2).foregroundStyle(.tertiary)
                        ForEach(words, id: \.self) { word in
                            Button(word) { insert(word) }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Markdown · ⌘↩ to save")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel") { model.cancelNoteDraft() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Save") {
                model.noteDraft = draft
                Task { await model.saveNoteDraft() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func wrap(_ marker: String) {
        draft.text += "\(marker)text\(marker)"
    }

    private func prefix(_ marker: String) {
        if !draft.text.isEmpty && !draft.text.hasSuffix("\n") { draft.text += "\n" }
        draft.text += marker
    }

    private func insert(_ word: String) {
        let needsSpace = !draft.text.isEmpty && !draft.text.hasSuffix(" ") && !draft.text.hasSuffix("\n")
        draft.text += (needsSpace ? " " : "") + "**\(word)** "
    }
}

// MARK: - Pieces

private struct TranslationLine: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: 2)
            Text(text)
                .font(ReadingFont.system.font(size: Reading.translationSize))
                .lineSpacing(Reading.translationLeading)
                .foregroundStyle(ReadingTheme(scheme: colorScheme).translation)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, Reading.gutter + 12)
        .padding(.top, 2)
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
/// Runs one translation per request.
///
/// The parent hands this view a new identity whenever a request arrives, so SwiftUI tears the
/// old one down and builds a new one — and a view that has just appeared always runs its
/// `translationTask`. Two earlier designs failed here for the same reason: both tried to make
/// an *existing* task re-run, and `.translationTask` only restarts when its configuration
/// changes, while a configuration naming the same two languages compares equal to the last.
/// The trace of a three-press toggle showed the third press setting the configuration and
/// nothing starting; changing the view's identity removes the question.
@available(macOS 15.0, *)
private struct OneShotTranslation: ViewModifier {
    @ObservedObject var model: LibraryModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard model.hasPendingTranslation else { return }
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans"))
            }
            .translationTask(configuration) { session in
                await model.runPendingTranslation(using: session)
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

/// A speaker, as a colour and a number. Colour is what makes a page of dialogue scannable;
/// the number is what makes it referable.
private struct SpeakerChip: View {
    let speaker: String
    let index: Int?

    private static let palette: [Color] = [
        .blue, .orange, .purple, .green, .pink, .teal,
    ]

    private var color: Color {
        // FluidAudio numbers speakers from zero; people number things from one.
        Self.palette[(index ?? 0) % Self.palette.count]
    }

    private var label: String {
        guard let number = Int(speaker) else { return speaker }
        return "S\(number + 1)"
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 24, height: 16)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help("Speaker \(label.dropFirst())")
    }
}

private struct SessionRow: View {
    let session: Session
    var isLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if isLive {
                    Image(systemName: "record.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help("Recording now")
                }
                Text(session.title).lineLimit(1)
            }
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

    /// Shows the window, creating it the first time.
    ///
    /// It deliberately does *not* replace the content view controller on later calls.
    /// Assigning a new one makes AppKit resize the window to the new view's fitting size,
    /// and it throws away the SwiftUI view — including the `translationTask` wiring, which is
    /// why pressing a menu command that called this left the toolbar's Translate dead. The
    /// view observes the model, so it keeps itself up to date; nothing needs replacing.
    func show(model: LibraryModel) {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(model: model)))
            created.title = "Live Subtitles Library"
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.isReleasedWhenClosed = false
            // Wide enough for three columns at their own minimums; narrower and the sidebar
            // is squeezed until every label truncates.
            created.setContentSize(NSSize(width: 1360, height: 800))
            WindowPlacement.center(created)
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Settings {
    /// The appearance to hand `preferredColorScheme`, or nil to follow the system.
    var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}
