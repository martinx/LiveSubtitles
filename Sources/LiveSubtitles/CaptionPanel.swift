//
//  CaptionPanel.swift
//  LiveSubtitles
//
//  Overlay that floats above every Space, including full-screen video, without
//  ever stealing focus.
//
//  By default it is click-through, so it can never swallow a click meant for the
//  video. Turning on "Drag to reposition" switches it into a repositioning mode
//  where the mouse is captured and the overlay can be dragged, and remembers where
//  it was put.
//
//  Dragging is handled here rather than with `isMovableByWindowBackground`: that
//  mechanism works by asking the *hit* view's `mouseDownCanMoveWindow`, and with a
//  SwiftUI `NSHostingView` the hit view is one of SwiftUI's internal subviews, so
//  overriding it on the content view has no effect and the drag silently does
//  nothing. Tracking the events directly does not depend on that at all.
//

import AppKit
import SwiftUI

@MainActor
final class CaptionPanel: NSPanel {
    private static let debugLogging = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil

    private let settings: Settings
    private var dragMonitor: Any?
    /// Where inside the panel the drag started, so it does not jump under the cursor.
    private var grabOffset: NSPoint?

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
        // Dragging is implemented below, so let AppKit stay out of it.
        isMovableByWindowBackground = false

        contentView = NSHostingView(rootView: CaptionView(model: model, settings: settings))

        applyInteraction(settings: settings)
        applyLayout(settings: settings)
    }

    deinit {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Interaction

    /// Click-through unless the viewer asked to be able to drag the overlay.
    func applyInteraction(settings: Settings) {
        ignoresMouseEvents = !settings.draggable
        grabOffset = nil

        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }

        guard settings.draggable else {
            if Self.debugLogging { print("[drag] repositioning off (click-through)") }
            return
        }

        if Self.debugLogging { print("[drag] repositioning on — mouse captured") }

        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleDrag(event)
        }
    }

    private func handleDrag(_ event: NSEvent) -> NSEvent? {
        // `mouseLocation` and `frame.origin` are both screen coordinates with the
        // origin at the bottom left, so no axis flipping is involved.
        let location = NSEvent.mouseLocation

        switch event.type {
        case .leftMouseDown:
            guard frame.contains(location) else { return event }
            grabOffset = NSPoint(x: location.x - frame.origin.x,
                                 y: location.y - frame.origin.y)
            if Self.debugLogging { print("[drag] grabbed at \(Int(location.x)),\(Int(location.y))") }
            // Deliberately not consumed: the event still goes through the normal
            // path so the window keeps receiving the drag stream.
            return event

        case .leftMouseDragged:
            guard let grabOffset else { return event }
            setFrameOrigin(NSPoint(x: location.x - grabOffset.x,
                                   y: location.y - grabOffset.y))
            return nil

        case .leftMouseUp:
            guard grabOffset != nil else { return event }
            grabOffset = nil
            settings.setPanelOrigin(frame.origin)
            if Self.debugLogging {
                print("[drag] dropped at \(Int(frame.origin.x)),\(Int(frame.origin.y)) — saved")
            }
            return nil

        default:
            return event
        }
    }

    // MARK: - Layout

    func applyLayout(settings: Settings) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(visible.width - 60, visible.width * settings.widthFraction)
        let height = CGFloat(settings.lineLimit) * (settings.fontSize * 1.5) + 30

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
