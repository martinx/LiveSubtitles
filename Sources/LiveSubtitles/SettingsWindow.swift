//
//  SettingsWindow.swift
//  LiveSubtitles
//
//  A tabbed, native settings window. Engine options need a restart to take effect (they
//  are baked into the speech manager when it is constructed); everything else applies
//  immediately.
//

import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcript: TranscriptStore

    let onApplyEngine: () -> Void
    let onExport: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            engine
                .tabItem { Label("Engine", systemImage: "speedometer") }
            appearance
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            shortcuts
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 500)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Toggle("Start listening when the app launches", isOn: $settings.startAtLaunch)
                Toggle("Show Dock icon", isOn: $settings.showInDock)
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
            } header: {
                Label("Startup", systemImage: "power")
            } footer: {
                Text("The app is a menu-bar accessory, so it never takes activation away "
                     + "from the video unless the Dock icon is on. The update check is a "
                     + "once-a-day request to GitHub; nothing about you is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Start a new line after", selection: $settings.newLineAfterSilence) {
                    Text("Off — keep appending").tag(0.0)
                    Text("2 s of quiet").tag(2.0)
                    Text("3 s of quiet").tag(3.0)
                    Text("5 s of quiet").tag(5.0)
                    Text("8 s of quiet").tag(8.0)
                }
                Toggle("Keep captions on screen", isOn: $settings.alwaysVisible)
                Toggle("Drag to reposition", isOn: $settings.draggable)
                Button("Reset overlay position", action: settings.resetPosition)
            } header: {
                Label("Behaviour", systemImage: "text.bubble")
            } footer: {
                Text(settings.draggable
                     ? "Drag the caption bar to move the overlay; the position is remembered per display. Turn off to make it fully click-through."
                     : "Click-through: no part of the overlay takes a click, and it stays where it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Export…", action: onExport)
                    Button("Copy", action: onCopy)
                    Spacer()
                    Button("Clear", role: .destructive, action: onClear)
                        .disabled(transcript.isEmpty)
                }
            } header: {
                Label("Transcript", systemImage: "square.and.arrow.down")
            } footer: {
                Text(transcript.isEmpty
                     ? "Nothing captured yet."
                     : "\(transcript.count) line\(transcript.count == 1 ? "" : "s") captured this session. Stopping the engine keeps them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Engine

    private var engine: some View {
        Form {
            Section {
                Picker("Model", selection: $settings.modelID) {
                    ForEach(SpeechModel.allCases) { model in
                        Text(model.title).tag(model.rawValue)
                    }
                }
                LabeledContent("") {
                    HStack {
                        Spacer()
                        Text(selectedModelNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("End a sentence after", selection: $settings.eouDebounceMs) {
                    Text("0.4 s of silence").tag(400)
                    Text("0.6 s of silence").tag(600)
                    Text("1.0 s of silence").tag(1000)
                    Text("1.3 s of silence").tag(1300)
                }
                Button("Reload Engine", action: onApplyEngine)
            } header: {
                Label("Speech model", systemImage: "waveform")
            } footer: {
                Text("Changes take effect straight away — the engine reloads itself in about "
                     + "two seconds, and a newly selected model downloads on first use. Your "
                     + "transcript is kept. Reload Engine is only needed if the engine stops "
                     + "on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var selectedModelNote: String {
        (SpeechModel(rawValue: settings.modelID) ?? .default).note
    }

    // MARK: - Appearance

    private var appearance: some View {
        Form {
            Section {
                slider("Font size", value: $settings.fontSize, range: 16...48, suffix: "pt")
                slider("Width", value: $settings.widthFraction, range: 0.4...0.98, percent: true)
                slider("Background", value: $settings.backgroundOpacity, range: 0...0.95, percent: true)
                slider("Distance from bottom", value: $settings.bottomInset, range: 0...600, suffix: "pt")
                Picker("Max lines", selection: $settings.lineLimit) {
                    ForEach(1...5, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Overlay", systemImage: "rectangle.on.rectangle")
            } footer: {
                Text("1 = current sentence only · 2 = previous line above it · more keeps history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        Form {
            Section {
                LabeledContent("Start listening") {
                    ShortcutRecorder(shortcut: $settings.startShortcut)
                }
                LabeledContent("Pause listening") {
                    ShortcutRecorder(shortcut: $settings.pauseShortcut)
                }
                LabeledContent("Stop listening") {
                    ShortcutRecorder(shortcut: $settings.stopShortcut)
                }
            } header: {
                Label("Global shortcuts", systemImage: "keyboard")
            } footer: {
                Text("These work while any app is frontmost. Record expects at least one "
                     + "modifier (⌘ ⌥ ⌃ ⇧); Escape cancels, Delete clears. A combination "
                     + "another app already owns will silently not take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Pause keeps the model loaded so you can come straight back. Stop "
                     + "releases it — about 600 MB — and starting again reloads it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        suffix: String = "",
                        percent: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                Text(percent
                     ? "\(Int((value.wrappedValue * 100).rounded()))%"
                     : "\(Int(value.wrappedValue.rounded())) \(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
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

        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let hosting = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: hosting)
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
