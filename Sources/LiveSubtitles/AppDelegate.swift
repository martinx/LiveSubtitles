//
//  AppDelegate.swift
//  LiveSubtitles
//
//  Owns the menu-bar item and wires the menu to the caption controller.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CaptionController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = CaptionController()
        self.controller = controller

        installMainMenu()
        installStatusItem()

        controller.onListeningChanged = { [weak self] listening in
            self?.showListeningState(listening)
        }
        controller.start()
    }

    /// A real menu bar for the app. Needed once "Show Dock icon" makes the app
    /// activatable: without it, activating from the Dock leaves an empty menu bar.
    /// Every item carries an SF Symbol so the menus look consistent.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("About Live Subtitles",
                                 #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                 "", symbol: "info.circle"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Settings…", #selector(openSettings), ",", symbol: "gearshape"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Hide Live Subtitles",
                                 #selector(NSApplication.hide(_:)), "h", symbol: "eye.slash"))
        appMenu.addItem(menuItem("Quit Live Subtitles",
                                 #selector(NSApplication.terminate(_:)), "q", symbol: "power"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Window menu, so the caption overlay and settings can be reached from the bar.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Settings…", #selector(openSettings), "", symbol: "gearshape"))
        windowMenu.addItem(menuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m",
                                    symbol: "arrow.down.right.and.arrow.up.left"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble.fill",
                                           accessibilityDescription: "Live Subtitles")
        statusItem.button?.toolTip = "Live Subtitles"

        let menu = NSMenu()
        menu.addItem(menuItem("Restart Engine", #selector(restartEngine), "", symbol: "arrow.clockwise"))
        menu.addItem(menuItem("Clear Captions", #selector(clearCaptions), "", symbol: "eraser"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Export Transcript…", #selector(exportTranscript), "e",
                              symbol: "square.and.arrow.down"))
        menu.addItem(menuItem("Copy Transcript", #selector(copyTranscript), "", symbol: "doc.on.doc"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings), ",", symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Live Subtitles", #selector(NSApplication.terminate(_:)), "q",
                              symbol: "power"))

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    /// Menu-bar icon fills in while capturing, and the Dock tile (when shown) gets a
    /// LIVE badge - a legible state cue. Full captions are deliberately *not* drawn
    /// into the Dock tile: at 64-128 px the text would be unreadable, and the Dock is
    /// as far from the video as the caption overlay is close to it.
    private func showListeningState(_ listening: Bool) {
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            print("[state] listening=\(listening) dockBadge=\(listening ? "LIVE" : "none")")
        }
        let symbol = listening ? "captions.bubble.fill" : "captions.bubble"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol,
                                            accessibilityDescription: "Live Subtitles")
        NSApp.dockTile.badgeLabel = listening ? "LIVE" : nil
        NSApp.dockTile.display()
    }

    private func menuItem(_ title: String,
                          _ action: Selector,
                          _ key: String,
                          symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func restartEngine() { controller?.restart() }
    @objc private func clearCaptions() { controller?.clearSession() }
    @objc private func exportTranscript() { controller?.exportTranscript() }
    @objc private func copyTranscript() { controller?.copyTranscript() }
    @objc private func openSettings() { controller?.openSettings() }
}
