//
//  CaptionPanel.swift
//  LiveSubtitles
//
//  Non-activating, click-through overlay that floats above every Space,
//  including full-screen video, without ever stealing focus.
//

import AppKit
import SwiftUI

@MainActor
final class CaptionPanel: NSPanel {
    init(model: CaptionModel, settings: Settings) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // The overlay must never swallow clicks meant for the video underneath.
        ignoresMouseEvents = true

        contentView = NSHostingView(rootView: CaptionView(model: model, settings: settings))
        applyLayout(settings: settings)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyLayout(settings: Settings) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(visible.width - 60, visible.width * settings.widthFraction)
        let height = CGFloat(settings.lineLimit) * (settings.fontSize * 1.5) + 30
        let frame = NSRect(x: visible.midX - width / 2,
                           y: visible.minY + settings.bottomInset,
                           width: width,
                           height: height)
        setFrame(frame, display: true)
    }
}
