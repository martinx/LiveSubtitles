//
//  WindowPlacement.swift
//  LiveSubtitles
//
//  Where the app's windows open.
//
//  `NSScreen.main` follows the *key* window, and an accessory app frequently has none,
//  so it can resolve to a display that is not the one the user is looking at - which is
//  how windows ended up opening on the external monitor, or above the top of the
//  desktop at a negative Y. The screen with the menu bar is the reliable anchor: it is
//  the one whose frame origin is (0, 0).
//

import AppKit

enum WindowPlacement {
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    /// Centre a window on the menu-bar screen, clamped so it cannot open off-screen.
    static func center(_ window: NSWindow) {
        guard let screen = menuBarScreen else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        var origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        window.setFrameOrigin(origin)
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            print("[placement] \(window.title) size=\(size) screen=\(screen.frame) visible=\(visible) -> \(origin) now=\(window.frame.origin)")
        }
    }
}
