//
//  SettingsWindow.swift
//  LiveSubtitles
//
//  A tabbed settings window in the current design language: a glass capsule for the
//  sections, a glass card per group. Engine options need a reload to take effect (they are
//  baked into the speech manager when it is constructed); everything else applies at once.
//

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, engine, appearance, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "General"
        case .engine:     return "Engine"
        case .appearance: return "Appearance"
        case .shortcuts:  return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .engine:     return "speedometer"
        case .appearance: return "textformat.size"
        case .shortcuts:  return "keyboard"
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcript: TranscriptStore

    let onApplyEngine: () -> Void
    let onExport: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void

    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            sectionBar
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.paragraphSpacing) {
                    switch tab {
                    case .general:    general
                    case .engine:     engine
                    case .appearance: appearance
                    case .shortcuts:  shortcuts
                    }
                }
                .padding(Metrics.panePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(settings.preferredScheme)
        .frame(width: 620, height: 620)
    }

    private var sectionBar: some View {
        GlassControlGroup {
            ForEach(SettingsTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 12))
                        Text(item.title).font(.system(size: 12.5,
                                                      weight: tab == item ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tab == item ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                            : AnyShapeStyle(.clear),
                                in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - General

    @ViewBuilder
    private var general: some View {
        SettingsCard("Startup", symbol: "power",
                     footer: "The app is a menu-bar accessory, so it never takes activation away "
                           + "from the video unless the Dock icon is on. The update check is a "
                           + "once-a-day request to GitHub; nothing about you is sent.") {
            ToggleRow("Start listening when the app launches", isOn: $settings.startAtLaunch)
            Divider()
            ToggleRow("Show Dock icon", isOn: $settings.showInDock)
            Divider()
            ToggleRow("Check for updates automatically", isOn: $settings.checkForUpdates)
        }

        SettingsCard("Behaviour", symbol: "text.bubble",
                     footer: settings.draggable
                        ? "Drag the caption bar to move the overlay; the position is remembered per "
                        + "display. Turn off to make it fully click-through."
                        : "Click-through: no part of the overlay takes a click, and it stays where it is.") {
            Row("Start a new line after") {
                Picker("", selection: $settings.newLineAfterSilence) {
                    Text("Off — keep appending").tag(0.0)
                    Text("2 s of quiet").tag(2.0)
                    Text("3 s of quiet").tag(3.0)
                    Text("5 s of quiet").tag(5.0)
                    Text("8 s of quiet").tag(8.0)
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Divider()
            ToggleRow("Keep captions on screen", isOn: $settings.alwaysVisible)
            Divider()
            ToggleRow("Drag to reposition", isOn: $settings.draggable)
            Divider()
            Row("") {
                Button("Reset overlay position", action: settings.resetPosition)
            }
        }

        SettingsCard("Transcript", symbol: "square.and.arrow.down",
                     footer: transcript.isEmpty
                        ? "Nothing captured yet."
                        : "\(transcript.count) line\(transcript.count == 1 ? "" : "s") captured this "
                        + "session. Stopping the engine keeps them.") {
            HStack(spacing: 8) {
                Button("Export…", action: onExport)
                Button("Copy", action: onCopy)
                Spacer()
                Button("Clear", role: .destructive, action: onClear)
                    .disabled(transcript.isEmpty)
            }
        }
    }

    // MARK: - Engine

    @ViewBuilder
    private var engine: some View {
        SettingsCard("Speech model", symbol: "waveform",
                     footer: "Changes take effect straight away — the engine reloads itself in about "
                           + "two seconds, and a newly selected model downloads on first use. Your "
                           + "transcript is kept. Reload Engine is only needed if the engine stops "
                           + "on its own.") {
            Row("Model") {
                Picker("", selection: $settings.modelID) {
                    ForEach(SpeechModel.allCases) { model in
                        Text(model.title).tag(model.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            Text((SpeechModel(rawValue: settings.modelID) ?? .default).note)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Row("End a sentence after") {
                Picker("", selection: $settings.eouDebounceMs) {
                    Text("0.4 s of silence").tag(400)
                    Text("0.6 s of silence").tag(600)
                    Text("1.0 s of silence").tag(1000)
                    Text("1.3 s of silence").tag(1300)
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Divider()
            Row("") {
                Button("Reload Engine", action: onApplyEngine)
            }
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearance: some View {
        SettingsCard("Application", symbol: "circle.lefthalf.filled",
                     footer: "Applies to the library and to these settings together. The caption "
                           + "overlay is drawn over the video and is styled separately below.") {
            Row("Theme") {
                Picker("", selection: $settings.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            Divider()
            Row("Transcript font") {
                Picker("", selection: $settings.readingFont) {
                    ForEach(ReadingFont.allCases) { face in
                        Text(face.title).tag(face.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }

        SettingsCard("Overlay", symbol: "rectangle.on.rectangle",
                     footer: "1 = current sentence only · 2 = previous line above it · more keeps history.") {
            slider("Font size", value: $settings.fontSize, range: 16...48, suffix: "pt")
            Divider()
            slider("Width", value: $settings.widthFraction, range: 0.4...0.98, percent: true)
            Divider()
            slider("Background", value: $settings.backgroundOpacity, range: 0...0.95, percent: true)
            Divider()
            slider("Distance from bottom", value: $settings.bottomInset, range: 0...600, suffix: "pt")
            Divider()
            Row("Max lines") {
                Picker("", selection: $settings.lineLimit) {
                    ForEach(1...5, id: \.self) { count in Text("\(count)").tag(count) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var shortcuts: some View {
        SettingsCard("Global shortcuts", symbol: "keyboard",
                     footer: "These work while any app is frontmost. Record expects at least one "
                           + "modifier (⌘ ⌥ ⌃ ⇧); Escape cancels, Delete clears. A combination "
                           + "another app already owns will silently not take effect.") {
            Row("Start listening") { ShortcutRecorder(shortcut: $settings.startShortcut) }
            Divider()
            Row("Pause listening") { ShortcutRecorder(shortcut: $settings.pauseShortcut) }
            Divider()
            Row("Stop listening") { ShortcutRecorder(shortcut: $settings.stopShortcut) }
        }

        SettingsCard("Library shortcuts", symbol: "macwindow",
                     footer: "These act on the library window and work while the app is "
                           + "frontmost, unlike the three above. Escape cancels a recording; "
                           + "Delete clears it and leaves that command with no key.") {
            Row("Open Library") { ShortcutRecorder(shortcut: $settings.libraryShortcut) }
            Divider()
            Row("New Note") { ShortcutRecorder(shortcut: $settings.newNoteShortcut) }
            Divider()
            Row("New Folder") { ShortcutRecorder(shortcut: $settings.newFolderShortcut) }
            Divider()
            Row("Translate Session") { ShortcutRecorder(shortcut: $settings.translateShortcut) }
            Divider()
            Row("Search") { ShortcutRecorder(shortcut: $settings.searchShortcut) }
            Divider()
            Row("Command Palette") { ShortcutRecorder(shortcut: $settings.paletteShortcut) }
        }

        SettingsCard("What the states cost", symbol: "info.circle") {
            Text("Pause keeps the model loaded so you can come straight back. Stop releases it — "
                 + "about 600 MB — and starting again reloads it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pieces

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        suffix: String = "",
                        percent: Bool = false) -> some View {
        Row(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range).frame(width: 220)
                Text(percent
                     ? "\(Int((value.wrappedValue * 100).rounded()))%"
                     : "\(Int(value.wrappedValue.rounded())) \(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
    }
}

/// A labelled group of settings on one glass card.
private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String,
         symbol: String,
         footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: Metrics.cardRadius)

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One settings row: a label on the left, its control on the right.
private struct Row<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !title.isEmpty {
                Text(title)
                Spacer(minLength: 12)
            }
            content
        }
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        // `.switch` is not the default outside a Form on macOS: without it these render as
        // checkboxes on the left, which is not what a settings window looks like.
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(settings: Settings,
              transcript: TranscriptStore,
              onApplyEngine: @escaping () -> Void,
              onExport: @escaping () -> Void,
              onCopy: @escaping () -> Void,
              onClear: @escaping () -> Void) {
        let view = SettingsView(settings: settings,
                                transcript: transcript,
                                onApplyEngine: onApplyEngine,
                                onExport: onExport,
                                onCopy: onCopy,
                                onClear: onClear)

        // Created once and never replaced: assigning a content view controller makes AppKit
        // resize the window to the view's fitting size, and discards the SwiftUI view with
        // it. `Settings` is observed, so the pane keeps itself current.
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: view))
            created.title = "Live Subtitles Settings"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            WindowPlacement.center(created)
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
