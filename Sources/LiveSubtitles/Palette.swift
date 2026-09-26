//
//  Palette.swift
//  LiveSubtitles
//
//  ⌘K: one field over everything the app keeps. The point is that the user does not have to
//  remember whether what they are after is a session, a line, a word, a note or a command.
//

import AppKit
import LiveSubtitlesKit
import SwiftUI

/// One row in the palette, flattened so the arrow keys can walk it without knowing groups.
enum PaletteItem: Identifiable, Hashable {
    case session(Session)
    case line(SearchHit)
    case word(VocabularyEntry)
    case note(NoteWithSession)
    case folder(Folder)
    case command(PaletteCommand)

    var id: String {
        switch self {
        case .session(let s):  return "s-\(s.id)"
        case .line(let hit):   return "l-\(hit.cue.id)"
        case .word(let w):     return "w-\(w.term.lowercased())"
        case .note(let n):     return "n-\(n.note.id)"
        case .folder(let f):   return "f-\(f.id)"
        case .command(let c):  return "c-\(c.rawValue)"
        }
    }

    var group: String {
        switch self {
        case .session: return "Sessions"
        case .line:    return "Lines"
        case .word:    return "Vocabulary"
        case .note:    return "Notes"
        case .folder:  return "Folders"
        case .command: return "Commands"
        }
    }

    var title: String {
        switch self {
        case .session(let s): return s.title
        case .line(let hit):  return hit.cue.text
        case .word(let w):    return w.term
        case .note(let n):    return n.note.text.replacingOccurrences(of: "\n", with: " ")
        case .folder(let f):  return f.name
        case .command(let c): return c.title
        }
    }

    var subtitle: String {
        switch self {
        case .session(let s): return "\(s.cueCount) lines"
        case .line(let hit):  return "\(hit.sessionTitle) · \(hit.cue.timestamp)"
        case .word(let w):    return w.count > 1 ? "saved \(w.count) times" : "saved word"
        case .note(let n):    return n.sessionTitle
        case .folder:         return "folder"
        case .command(let c): return c.subtitle
        }
    }

    var symbol: String {
        switch self {
        case .session: return "rectangle.stack"
        case .line:    return "text.alignleft"
        case .word:    return "textformat.abc"
        case .note:    return "note.text"
        case .folder:  return "folder"
        case .command: return "command"
        }
    }
}

enum PaletteCommand: String, CaseIterable {
    case translate, stopTranslation, newFolder, exportMarkdown, exportSRT, copyTranscript, settings

    var title: String {
        switch self {
        case .translate:       return "Translate This Session into Chinese"
        case .stopTranslation: return "Hide the Chinese"
        case .newFolder:       return "New Folder"
        case .exportMarkdown:  return "Export Transcript as Markdown"
        case .exportSRT:       return "Export Transcript as Subtitles"
        case .copyTranscript:  return "Copy the Whole Transcript"
        case .settings:        return "Open Settings"
        }
    }

    var subtitle: String { "command" }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return title.lowercased().contains(query.lowercased())
    }
}

extension LibraryModel {
    var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = []
        items += paletteResults.lines.map(PaletteItem.line)
        items += paletteResults.sessions.map(PaletteItem.session)
        items += paletteResults.words.map(PaletteItem.word)
        items += paletteResults.notes.map(PaletteItem.note)
        items += paletteResults.folders.map(PaletteItem.folder)
        items += PaletteCommand.allCases
            .filter { $0.matches(paletteQuery) }
            .map(PaletteItem.command)
        return items
    }

    var highlightedItem: PaletteItem? {
        paletteItems.indices.contains(paletteSelection) ? paletteItems[paletteSelection] : nil
    }

    func movePaletteSelection(by delta: Int) {
        let count = paletteItems.count
        guard count > 0 else { return }
        paletteSelection = max(0, min(count - 1, paletteSelection + delta))
    }

    func activateHighlighted() async {
        guard let item = highlightedItem else { return }
        await activate(item)
    }

    func activate(_ item: PaletteItem) async {
        hidePalette()
        switch item {
        case .session(let session):
            await select(session.id)

        case .line(let hit):
            await select(hit.sessionID)
            selectedCueID = hit.cue.id

        case .word(let entry):
            if let cue = readerCues.first(where: {
                $0.text.range(of: entry.term, options: .caseInsensitive) != nil
            }) {
                await inspect(entry.term, in: cue)
            } else {
                await inspect(entry.term)
            }

        case .note:
            section = .notebook

        case .folder:
            section = .sessions

        case .command(let command):
            await run(command)
        }
    }

    private func run(_ command: PaletteCommand) async {
        switch command {
        case .translate:
            toggleTranslationOn()
        case .stopTranslation:
            if translationOn { toggleTranslation() }
        case .newFolder:
            section = .sessions
            Task { await createSuggestedFolder() }
        case .exportMarkdown:
            if let id = selectedSessionID { export(.markdown, sessionID: id) }
        case .exportSRT:
            if let id = selectedSessionID { export(.srt, sessionID: id) }
        case .copyTranscript:
            let text = readerCues.map { "\($0.timestamp)  \($0.text)" }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .settings:
            NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
        }
    }
}

// MARK: - The overlay

struct CommandPalette: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sessions, lines, words, notes, commands…", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                Text("esc").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if model.paletteItems.isEmpty {
                            Text(model.paletteQuery.isEmpty
                                 ? "Type to search everything."
                                 : "Nothing matched.")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(16)
                        }
                        ForEach(Array(model.paletteItems.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, isSelected: index == model.paletteSelection)
                                .id(item.id)
                                .onTapGesture {
                                    model.paletteSelection = index
                                    Task { await model.activate(item) }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 380)
                .onChange(of: model.paletteSelection) { _, _ in
                    if let item = model.highlightedItem { proxy.scrollTo(item.id, anchor: .center) }
                }
            }
        }
        .frame(width: 620)
        .glassPanel(cornerRadius: 20)
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .padding(.top, 90)
        .onAppear {
            focused = true
            // Arrow keys and Return need to work while the text field has focus; a local
            // monitor is the reliable way to see them before the field consumes them.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: model.movePaletteSelection(by: 1);  return nil
                case 126: model.movePaletteSelection(by: -1); return nil
                case 36, 76: Task { await model.activateHighlighted() }; return nil
                case 53: model.hidePalette(); return nil
                default: return event
                }
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Text("\(item.group) · \(item.subtitle)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
    }
}
