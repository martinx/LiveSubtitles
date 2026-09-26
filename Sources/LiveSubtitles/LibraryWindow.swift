//
//  LibraryWindow.swift
//  LiveSubtitles
//
//  The study window, laid out the way the design describes it:
//
//    sidebar   the seven sections
//    toolbar   session, search, replay, speed, summarise, export
//    reader    the session's paragraphs
//    inspector the selected line: its words, their definitions, every other line the word
//              appears in, and its notes
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
    @State private var noteText = ""
    @State private var noteKind: Note.Kind = .word
    @State private var confirmDelete: Session?

    var body: some View {
        translationHost(
            NavigationSplitView {
            List(selection: $model.section) {
                ForEach(LibrarySection.allCases) { section in
                    Label {
                        Text(section.title).font(.system(size: 13.5))
                    } icon: {
                        Image(systemName: section.symbol)
                            .font(.system(size: 13))
                            .frame(width: Metrics.sidebarIconWidth, alignment: .leading)
                    }
                    .tag(section)
                    .sidebarRow()
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
            } detail: {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    pane
                    Divider()
                    inspector
                }
            }
        )
        .frame(minWidth: 900, minHeight: 560)
        .alert("Rename session", isPresented: Binding(get: { renaming != nil },
                                                      set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let session = renaming { Task { await model.rename(session.id, to: renameText) } }
                renaming = nil
            }
        } message: {
            Text("For example “Severance S02E05”, or anything else you will recognise.")
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

    /// `.translationTask` only exists from macOS 15, so the window carries it only there.
    @ViewBuilder
    private func translationHost<V: View>(_ content: V) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(ParagraphTranslationHost(model: model))
        } else {
            content
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
                    Text(model.selectedSession?.title ?? "No session")
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(model.sessions.isEmpty)

            searchField

            Spacer(minLength: 12)

            // Replay, speech, speed and summarising are shown rather than hidden so the
            // intent stays visible; each says what it is waiting for.
            GlassControlGroup {
                ToolbarIconButton(symbol: "translate",
                                  help: model.translationPhase.label,
                                  enabled: !model.isSearching) {
                    model.toggleTranslation()
                }
                ToolbarIconButton(symbol: "play.circle", help: playHelp, enabled: false)
                ToolbarIconButton(symbol: "waveform", help: "Speak this line — needs the voice model (phase 4)", enabled: false)
                ToolbarIconButton(symbol: "gauge.with.needle", help: "Playback speed — needs audio retention (phase 1)", enabled: false)
                ToolbarIconButton(symbol: "text.bubble", help: "Summarise — needs the local model (phase 7)", enabled: false)
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

    private var playHelp: String {
        "Replay the original — needs audio retention (phase 1 of the design)"
    }

    private var searchField: some View {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    // MARK: - Panes

    @ViewBuilder
    private var pane: some View {
        switch model.section {
        case .sessions:     reader
        case .notebook:     notesPane(model.notebook, empty: "Nothing saved yet.")
        case .favourites:   notesPane(model.favourites, empty: "No favourite lines yet.")
        case .vocabulary:   vocabularyPane
        case .statistics:   statisticsPane
        case .collections:  placeholder("Collections",
                                        "Group sessions by series or topic. Coming with the next pass.")
        case .writing:      placeholder("Writing",
                                        "Summaries and graded conversation practice, once the local model is wired in.")
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
                                    CueRow(cue: cue,
                                           notes: model.notesByCue[cue.id] ?? [],
                                           isSelected: model.selectedCueID == cue.id)
                                        .onTapGesture { model.selectedCueID = cue.id }
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
            LazyVStack(alignment: .leading, spacing: 4) {
                Text("\(model.hits.count) matches for “\(model.searchText)”")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(model.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.sessionTitle).font(.caption2).foregroundStyle(.tertiary)
                        CueRow(cue: hit.cue, notes: [], isSelected: model.selectedCueID == hit.cue.id)
                            .onTapGesture {
                                model.selectedCueID = hit.cue.id
                                Task { await model.select(hit.sessionID) }
                            }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notesPane(_ notes: [NoteWithSession], empty: String) -> some View {
        Group {
            if notes.isEmpty {
                placeholder("Nothing here yet", empty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: symbol(for: entry.note.kind))
                                    .foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.note.text).font(.body)
                                    Text(entry.sessionTitle).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    Task { await model.deleteNote(entry.note.id) }
                                } label: {
                                    Image(systemName: "trash").font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var vocabularyPane: some View {
        Group {
            if model.vocabulary.isEmpty {
                placeholder("No vocabulary yet",
                            "Select a line, then click a word in the inspector to look it up and save it.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.vocabulary) { entry in
                            HStack {
                                Text(entry.term).font(.body)
                                Spacer()
                                if entry.count > 1 {
                                    Text("×\(entry.count)").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Look up") { Task { await model.inspect(entry.term) } }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.body)
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cue = model.selectedCue {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cue.timestamp)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(cue.text).font(.callout).lineLimit(2)
                }

                // 划词: every word in the line is a target.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(model.selectedWords.enumerated()), id: \.offset) { _, word in
                            Button(word) { Task { await model.inspect(word) } }
                                .buttonStyle(.plain)
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(model.inspectedWord == word
                                            ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                            : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                        }
                    }
                }

                if let definition = model.definition {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(definition)
                                .font(.caption)
                                .lineLimit(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Add “\(model.inspectedWord ?? "")” to vocabulary") {
                                Task { await model.saveInspectedWord() }
                            }
                            .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Other lines (\(model.occurrences.count))")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(model.occurrences.prefix(4)) { hit in
                                Text("• \(hit.cue.text)")
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            if model.occurrences.isEmpty {
                                Text("No other lines contain it.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if model.inspectedWord != nil {
                    Text("No dictionary entry for “\(model.inspectedWord ?? "")”.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Picker("", selection: $noteKind) {
                        Text("Word").tag(Note.Kind.word)
                        Text("Phrase").tag(Note.Kind.phrase)
                        Text("Favourite").tag(Note.Kind.favourite)
                        Text("Note").tag(Note.Kind.note)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)

                    TextField("What do you want to remember?", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveNote)
                    Button("Save", action: saveNote)
                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text("Select a line to look up its words, see every other line they appear in, and save a note.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if !model.notes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.notes) { note in
                            NoteChip(note: note) { Task { await model.deleteNote(note.id) } }
                        }
                    }
                }
            }
        }
        .padding(Metrics.panePadding)
        .frame(minHeight: 108)
        .glassPanel(cornerRadius: Metrics.cardRadius)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 8)
    }

    private func saveNote() {
        let text = noteText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        noteText = ""
        Task { await model.addNote(cueID: model.selectedCueID, kind: noteKind, text: text) }
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

/// A paragraph's Chinese, set apart from the transcript so the eye can tell them apart
/// without a second column.
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
        .padding(.vertical, 2)
        .padding(.leading, 72)
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
                await model.runTranslation(paragraphs: model.paragraphs, using: session)
            }
    }
}

private struct CueRow: View {
    let cue: Cue
    let notes: [Note]
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(cue.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(cue.text)
                    .font(.system(size: 14))
                    .lineSpacing(Metrics.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !notes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(notes) { note in
                            Text(note.text)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct NoteChip: View {
    let note: Note
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(note.text).font(.caption).lineLimit(1)
            Button(action: onDelete) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
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
