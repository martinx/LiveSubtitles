//
//  WelcomeWindow.swift
//  LiveSubtitles
//
//  First-run guidance: the permission, the one-time model download, and the two
//  controls worth knowing about. Also reachable later from About -> How to Use.
//

import AppKit
import CoreGraphics
import SwiftUI

@MainActor
struct WelcomeView: View {
    @ObservedObject var settings: Settings
    let onStart: () -> Void
    let onClose: () -> Void

    @State private var permissionGranted = CGPreflightScreenCaptureAccess()

    // The grant happens in System Settings, so poll rather than guess.
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    step(index: 1,
                         title: "Allow Screen Recording",
                         done: permissionGranted) {
                        Text("macOS only hands the system audio stream to apps you have allowed. "
                             + "The audio is transcribed on this Mac and never uploaded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if permissionGranted {
                            Label("Granted — quit and reopen the app if you just allowed it.",
                                  systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        } else {
                            Button("Open Screen Recording settings") {
                                // Prompts once, then adds the app to the list.
                                CGRequestScreenCaptureAccess()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }

                    step(index: 2, title: "The speech model downloads once", done: false) {
                        Text("The first time you start listening, the selected model is downloaded "
                             + "from Hugging Face and compiled for the Neural Engine:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 120M models — about 430 MB")
                            Text("• 0.6B models (the default) — about 600 MB")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        Text("That first run takes 40–90 seconds. Every launch after it takes about "
                             + "2 seconds. You can change the model in Settings → Engine.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    step(index: 3, title: "Then just watch something", done: false) {
                        Text("Subtitles appear in a bar near the bottom of the screen. It ignores "
                             + "clicks, so it never interrupts playback.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow(settings.startShortcut, "start listening")
                            shortcutRow(settings.pauseShortcut, "pause — keeps the model ready")
                            shortcutRow(settings.stopShortcut, "stop — releases the model")
                        }

                        Text("Turn on **Drag to reposition** in Settings to move the bar; turn it "
                             + "back off afterwards so clicks pass through again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Everything is under the captions bubble in the menu bar.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 600)
        .background(.background)
        .onReceive(ticker) { _ in
            let granted = CGPreflightScreenCaptureAccess()
            if granted != permissionGranted { permissionGranted = granted }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to \(AppInfo.name)")
                    .font(.system(size: 18, weight: .semibold))
                Text(AppInfo.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Text("English only, for now.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onClose)
            Button("Start Listening", action: onStart)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func step<Content: View>(index: Int,
                                     title: String,
                                     done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                content()
            }
        }
    }

    private func shortcutRow(_ shortcut: KeyShortcut?, _ meaning: String) -> some View {
        HStack(spacing: 8) {
            Text(shortcut?.display ?? "—")
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Text(meaning)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class WelcomeWindow {
    private var window: NSWindow?

    func show(settings: Settings, onStart: @escaping () -> Void) {
        let view = WelcomeView(settings: settings,
                               onStart: { [weak self] in
                                   self?.close()
                                   onStart()
                               },
                               onClose: { [weak self] in self?.close() })

        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let created = NSWindow(contentViewController: NSHostingController(rootView: view))
            created.title = "How to Use \(AppInfo.name)"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            WindowPlacement.center(created)
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
    }
}
