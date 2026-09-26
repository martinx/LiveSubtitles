//
//  CaptionPanel.swift
//  LiveSubtitles
//
//  Overlay that floats above every Space, including full-screen video, without
//  ever stealing focus.
//
//  By default it is click-through, so it can never swallow a click meant for the
//  video. Turning on "Drag to reposition" makes it accept the mouse instead and
//  remembers where you put it.
//

import AppKit
import SwiftUI

/// Lets a mouse-down anywhere on the caption drag the window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class CaptionPanel: NSPanel {
    private let settings: Settings
    private var isApplyingLayout = false
    private var moveObserver: NSObjectProtocol?

    init(model: CaptionModel, settings: Settings) {
        self.settings = settings

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

        contentView = DraggableHostingView(rootView: CaptionView(model: model, settings: settings))

        applyInteraction(settings: settings)
        applyLayout(settings: settings)

        // Remember where the viewer dragged it.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isApplyingLayout, self.settings.draggable else { return }
            self.settings.panelX = Double(self.frame.origin.x)
            self.settings.panelY = Double(self.frame.origin.y)
            self.settings.hasCustomPosition = true
        }
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Click-through unless the viewer asked to be able to drag it.
    func applyInteraction(settings: Settings) {
        ignoresMouseEvents = !settings.draggable
        isMovableByWindowBackground = settings.draggable
    }

    func applyLayout(settings: Settings) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(visible.width - 60, visible.width * settings.widthFraction)
        let height = CGFloat(settings.lineLimit) * (settings.fontSize * 1.5) + 30

        isApplyingLayout = true
        defer { isApplyingLayout = false }

        let origin: NSPoint
        if settings.hasCustomPosition {
            origin = NSPoint(x: settings.panelX, y: settings.panelY)
        } else {
            origin = NSPoint(x: visible.midX - width / 2,
                             y: visible.minY + settings.bottomInset)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
