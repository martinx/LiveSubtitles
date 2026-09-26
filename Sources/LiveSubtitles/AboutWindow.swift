//
//  AboutWindow.swift
//  LiveSubtitles
//
//  A custom About window rather than the stock panel, so the version, the author and
//  the privacy statement are all visible in one place.
//

import AppKit
import SwiftUI

@MainActor
struct AboutView: View {
    private let onShowWelcome: () -> Void

    init(onShowWelcome: @escaping () -> Void) {
        self.onShowWelcome = onShowWelcome
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                Text(AppInfo.name)
                    .font(.system(size: 22, weight: .semibold))

                Text(AppInfo.versionDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Text(AppInfo.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                row("person.crop.circle", "Made by \(AppInfo.author)")
                HStack(spacing: 6) {
                    Image(systemName: "envelope").frame(width: 16)
                    Link(AppInfo.authorEmail, destination: URL(string: "mailto:\(AppInfo.authorEmail)")!)
                }
                .font(.callout)

                HStack(spacing: 6) {
                    Image(systemName: "doc.text").frame(width: 16)
                    // Markdown links inside Text are tappable; Link cannot be concatenated.
                    Text("MIT licensed · speech recognition by [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)

            Divider()

            HStack(spacing: 10) {
                Button("How to Use", action: onShowWelcome)
                Spacer()
                Link("GitHub", destination: AppInfo.repositoryURL)
                Link("Release Notes", destination: AppInfo.releasesURL)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .background(.background)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 16)
            Text(text)
        }
        .font(.callout)
    }
}

@MainActor
final class AboutWindow {
    private var window: NSWindow?

    func show(onShowWelcome: @escaping () -> Void) {
        let view = AboutView(onShowWelcome: onShowWelcome)

        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let created = NSWindow(contentViewController: NSHostingController(rootView: view))
            created.title = "About \(AppInfo.name)"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            WindowPlacement.center(created)
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
