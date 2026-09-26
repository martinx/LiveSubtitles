//
//  LibraryWindow.swift
//  LiveSubtitles
//
//  The study window: everything that survived from previous sessions.
//
//  Two panes and a composer. The sidebar is the archive; the detail is a session's
//  transcript, or cross-session search results. Selecting a line is what every later
//  feature hangs off — notes now, replay and analysis later.
//

import AppKit
import LiveSubtitlesKit
import SwiftUI

@MainActor
struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    @State private var selection: String?
    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var noteText = ""
    @State private var noteKind: Note.Kind = .word
    @State private var confirmDelete: Session?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 520)
        .onChange(of: selection) { _, newValue in
            Task { await model.select(newValue) }
        }
        .onAppear {
            selection = model.selectedSessionID
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil },
                                                      set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let session = renaming {
                    Task { await model.rename(session.id, to: renameText) }
                }
                renaming = nil
            }
        } message: {
            Text("For example “Severance S02E05”, or anything else you will recognise.")
        }
        .alert("Delete this session?", isPresented: Binding(get: { confirmDelete != nil },
                                                            set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let session = confirmDelete {
                    Task { await model.delete(session.id) }
                }
                confirmDelete = nil
            }
        } message: {
            Text("Its transcript and notes are removed. This cannot be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                Section("Sessions") {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Rename…") { beginRename(session) }
                                Menu("Export") {
                                    ForEach(ExportFormat.allCases, id: \.self) { format in
                                        Button(format.displayName) {
                                            model.export(format, sessionID: session.id)
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete…", role: .destructive) { confirmDelete = session }
                            }
                    }
                    if model.sessions.isEmpty {
                        Text("Nothing recorded yet. Start listening and lines will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Text("\(model.sessions.count) sessions · \(model.totalCues) lines")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search every session", text: $model.searchText)
                .textFieldStyle(.plain)
            if model.isSearching {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()
            reader
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if model.isSearching {
                Text("\(model.hits.count) matches for “\(model.searchText)”")
                    .font(.headline)
            } else if let session = model.selectedSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline)
                    Text(subtitle(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    beginRename(session)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this session")
            } else {
                Text("No session selected").font(.headline).foregroundStyle(.secondary)
            }

            Spacer()

            if let session = model.selectedSession, !model.isSearching {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.readerCues) { cue in
                        CueRow(cue: cue,
                               notes: model.notesByCue[cue.id] ?? [],
                               showsSession: model.isSearching,
                               sessionTitle: model.hits.first { $0.cue.id == cue.id }?.sessionTitle ?? "",
                               isSelected: model.selectedCueID == cue.id)
                            .id(cue.id)
                            .onTapGesture { model.selectedCueID = cue.id }
                    }
                    if model.readerCues.isEmpty {
                        Text(model.isSearching ? "No lines matched." : "This session has no lines yet.")
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.hits.count) { _, _ in
                if let first = model.hits.first { proxy.scrollTo(first.cue.id, anchor: .top) }
            }
        }
    }

    // MARK: - Note composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = model.selectedCueID,
               let cue = model.readerCues.first(where: { $0.id == id }) {
                Text(cue.text)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a line to save a word, a phrase or the whole line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                .frame(maxWidth: 320)

                TextField("What do you want to remember?", text: $noteText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveNote)

                Button("Save", action: saveNote)
                    .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func saveNote() {
        let text = noteText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        noteText = ""
        Task { await model.addNote(cueID: model.selectedCueID, kind: noteKind, text: text) }
    }

    private func beginRename(_ session: Session) {
        renameText = session.title
        renaming = session
    }

    private func subtitle(for session: Session) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var parts = [formatter.string(from: session.startedAt), "\(session.cueCount) lines"]
        if !session.source.isEmpty { parts.insert(session.source, at: 0) }
        return parts.joined(separator: " · ")
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
    }
}

private struct CueRow: View {
    let cue: Cue
    let notes: [Note]
    let showsSession: Bool
    let sessionTitle: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(cue.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if showsSession, !sessionTitle.isEmpty {
                    Text(sessionTitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(cue.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !notes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(notes) { note in
                            Text(note.text)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

private struct NoteChip: View {
    let note: Note
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2)
            Text(note.text).font(.caption).lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private var symbol: String {
        switch note.kind {
        case .word:      return "textformat.abc"
        case .phrase:    return "text.quote"
        case .favourite: return "star"
        case .note:      return "note.text"
        }
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
            created.setContentSize(NSSize(width: 1040, height: 660))
            WindowPlacement.center(created)
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
