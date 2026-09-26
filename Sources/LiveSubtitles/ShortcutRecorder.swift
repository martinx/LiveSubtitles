//
//  ShortcutRecorder.swift
//  LiveSubtitles
//
//  A click-to-record shortcut field. While recording it swallows key presses with a
//  local event monitor, so the combination being recorded does not also trigger a menu
//  command or a system beep.
//

import AppKit
import SwiftUI

@MainActor
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(isRecording ? "Press keys…" : (shortcut?.display ?? "None"))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isRecording ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(minWidth: 84, alignment: .leading)

            Button(isRecording ? "Cancel" : "Record") { isRecording ? stop() : start() }
                .disabled(false)

            Button("Clear") { shortcut = nil }
                .disabled(shortcut == nil)
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let required: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

            switch event.keyCode {
            case 53:                                    // Escape cancels
                stop()
                return nil
            case 51, 117:                               // Delete clears
                shortcut = nil
                stop()
                return nil
            default:
                break
            }

            // A bare key would shadow ordinary typing everywhere, so require a modifier.
            guard !flags.intersection(required).isEmpty else {
                NSSound.beep()
                return nil
            }
            shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: flags.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
