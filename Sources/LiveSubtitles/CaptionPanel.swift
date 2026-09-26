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
    /// Height the SwiftUI bar reported; the panel matches it so the clickable area is
    /// exactly the visible bar.
    private var barHeight: CGFloat?
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

        contentView = NSHostingView(rootView: CaptionView(
            model: model,
            settings: settings,
            onBarHeightChange: { [weak self] height in
                self?.barHeightChanged(height)
            }
        ))

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

    /// The bar grew or shrank (different line count, font size, status text). Re-lay
    /// out so the window keeps hugging it.
    private func barHeightChanged(_ height: CGFloat) {
        guard height > 0 else { return }

        // A measurement taken mid-layout can be wildly wrong, and this value sizes the
        // window: a bogus one leaves an invisible panel swallowing clicks across the
        // screen. It is also bounded by what the settings can ever require - the bar holds
        // at most `lineLimit` lines - so the guard is exact rather than arbitrary.
        let lineHeight = CGFloat(settings.fontSize * 1.5)
        let ceiling = CGFloat(settings.lineLimit) * lineHeight + 60
        let clamped = min(height, ceiling)

        guard abs((barHeight ?? 0) - clamped) > 0.5 else { return }
        barHeight = clamped
        applyLayout(settings: settings)
    }

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
            setFrameOrigin(clamped(NSPoint(x: location.x - grabOffset.x,
                                           y: location.y - grabOffset.y),
                                   size: frame.size))
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

    /// The screen with the menu bar. `NSScreen.main` tracks the key window, and an
    /// accessory app with a non-activating panel has no reliable one, so it can flip
    /// between displays - which used to drop the overlay onto the wrong monitor.
    private var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    private func screenOverlappingMost(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens
            .map { ($0, $0.visibleFrame.intersection(rect)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
    }

    /// Keep the overlay reachable without fencing it to one display: a position that
    /// already fits on some screen is left alone (so it can be dragged to a second
    /// monitor), and only a position that would be lost gets snapped back.
    private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let rect = NSRect(origin: origin, size: size)
        if NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }) {
            return origin
        }
        guard let target = screenOverlappingMost(rect) ?? primaryScreen else { return origin }
        let bounds = target.visibleFrame
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        return NSPoint(x: min(max(origin.x, bounds.minX), maxX),
                       y: min(max(origin.y, bounds.minY), maxY))
    }

    // MARK: - Layout

    func applyLayout(settings: Settings) {
        // Lay out on the screen the saved position lives on, so an overlay parked on
        // a second monitor stays there.
        let savedRect = NSRect(x: settings.panelX, y: settings.panelY, width: 1, height: 1)
        let screen = (settings.hasCustomPosition ? screenOverlappingMost(savedRect) : nil)
            ?? primaryScreen
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = min(visible.width - 60, visible.width * settings.widthFraction)
        // Before the first measurement, reserve room for every allowed line; after it,
        // hug the bar so there is no dead zone above the captions.
        //
        // Both types are spelled out: mixing CGFloat and Double inside a `??` is
        // inferred differently by different Swift versions, and Swift 6.1 (Xcode 16,
        // what CI uses) resolves the whole expression to CGFloat? where 6.4 does not.
        let reservedForAllLines: CGFloat = CGFloat(settings.lineLimit) * CGFloat(settings.fontSize * 1.5) + 30
        let height: CGFloat = barHeight ?? reservedForAllLines

        let requested: NSPoint
        if settings.hasCustomPosition {
            requested = NSPoint(x: settings.panelX, y: settings.panelY)
        } else {
            requested = NSPoint(x: visible.midX - width / 2,
                                y: visible.minY + settings.bottomInset)
        }
        // A saved position may be off-screen (dragged past an edge, or the display
        // layout changed), so it is clamped on the way back in too.
        let size = NSSize(width: width, height: height)
        setFrame(NSRect(origin: clamped(requested, size: size), size: size), display: true)
    }
}
