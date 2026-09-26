//
//  SettingsWindow.swift
//  LiveSubtitles
//
//  A native grouped-form settings window. Engine options need a restart to take
//  effect (they are baked into the speech manager at construction); everything else
//  applies immediately.
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
                Button("Apply & Restart Engine", action: onApplyEngine)
            } header: {
                Label("Performance", systemImage: "speedometer")
            } footer: {
                Text("Reloads the model on restart; your transcript is kept. Larger "
                     + "models download on first use.")
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

                HStack {
                    Button("Reset overlay position", action: settings.resetPosition)
                    Spacer()
                }
            } header: {
                Label("Behaviour", systemImage: "text.bubble")
            } footer: {
                Text(settings.draggable
                     ? "On: the overlay captures clicks in its area — turn off once positioned."
                     : "Click-through. Turn on dragging to move it; the position is remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Label("Appearance", systemImage: "textformat.size")
            } footer: {
                Text("1 = current sentence only · 2 = previous line above it · more keeps history.")
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
                     : "\(transcript.count) line\(transcript.count == 1 ? "" : "s") captured this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 840)
    }

    private var selectedModelNote: String {
        (SpeechModel(rawValue: settings.modelID) ?? .default).note
    }

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
            // Centre on the menu-bar screen: `NSScreen.main` follows the key window,
            // which an accessory app does not reliably have, and it would otherwise
            // open the window on whichever display it happened to pick.
            if let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                created.setFrameOrigin(NSPoint(x: visible.midX - created.frame.width / 2,
                                               y: visible.midY - created.frame.height / 2))
            }
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
