//
//  SettingsWindow.swift
//  LiveSubtitles
//
//  A small settings window. Display and behaviour options apply immediately; the
//  two engine options need "Apply & Restart Engine".
//

import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings
    let onApplyEngine: () -> Void
    let onExport: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Performance")
                .font(.headline)

            Picker("Streaming chunk", selection: $settings.chunkSizeMs) {
                Text("160 ms — lowest latency").tag(160)
                Text("320 ms — more accurate").tag(320)
                Text("1280 ms — most accurate").tag(1280)
            }

            Picker("End of sentence after", selection: $settings.eouDebounceMs) {
                Text("0.4 s silence").tag(400)
                Text("0.6 s silence").tag(600)
                Text("1.0 s silence").tag(1000)
                Text("1.3 s silence").tag(1300)
            }

            Button("Apply & Restart Engine", action: onApplyEngine)

            Divider()

            Text("Behaviour")
                .font(.headline)

            Picker("New line after silence", selection: $settings.newLineAfterSilence) {
                Text("Off — keep appending").tag(0.0)
                Text("2 s").tag(2.0)
                Text("3 s").tag(3.0)
                Text("5 s").tag(5.0)
                Text("8 s").tag(8.0)
            }

            Toggle("Keep captions on screen (never fade out)", isOn: $settings.alwaysVisible)
            Toggle("Drag to reposition the overlay", isOn: $settings.draggable)

            HStack {
                Button("Reset overlay position", action: settings.resetPosition)
                Text(settings.draggable
                     ? "Drag the caption where you want it — the spot is remembered."
                     : "Turn on dragging to move the caption, then reset here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Appearance")
                .font(.headline)

            slider("Font size", value: $settings.fontSize, range: 16...48, format: "%.0f pt")
            slider("Width", value: $settings.widthFraction, range: 0.4...0.98, format: "%.0f%%", scale: 100)
            slider("Background", value: $settings.backgroundOpacity, range: 0.0...0.95, format: "%.0f%%", scale: 100)
            slider("Distance from bottom", value: $settings.bottomInset, range: 0...600, format: "%.0f pt")

            Picker("Max lines", selection: $settings.lineLimit) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }
            .pickerStyle(.segmented)

            Divider()

            HStack {
                Button("Export Transcript…", action: onExport)
                Button("Clear Transcript", action: onClear)
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: String,
                        scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(settings: Settings,
              onApplyEngine: @escaping () -> Void,
              onExport: @escaping () -> Void,
              onClear: @escaping () -> Void) {
        let view = SettingsView(settings: settings,
                                onApplyEngine: onApplyEngine,
                                onExport: onExport,
                                onClear: onClear)

        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let hosting = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: hosting)
            created.title = "Live Subtitles Settings"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
