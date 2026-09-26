//
//  AppDelegate.swift
//  LiveSubtitles
//
//  The menu-bar item, its menu, and the app main menu.
//
//  The status menu is rebuilt each time it opens, so item titles, enablement and the
//  recorded shortcut all reflect the current state without any bookkeeping.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: CaptionController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = CaptionController()
        self.controller = controller

        installMainMenu()
        installStatusItem()

        controller.onStateChanged = { [weak self] state in
            self?.show(state)
        }
        controller.start()
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: ListeningState.stopped.symbolName,
                                           accessibilityDescription: "Live Subtitles")
        statusItem.button?.toolTip = "Live Subtitles"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        guard let controller else { return }
        menu.removeAllItems()

        // Current state, so the menu doubles as a status readout.
        let stateItem = NSMenuItem(title: controller.state.description, action: nil, keyEquivalent: "")
        stateItem.image = NSImage(systemSymbolName: controller.state.symbolName, accessibilityDescription: nil)
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        menu.addItem(action("Start Listening", #selector(startListening),
                            shortcut: controller.settings.startShortcut,
                            symbol: "play.fill",
                            enabled: controller.state != .listening))
        menu.addItem(action("Pause Listening", #selector(pauseListening),
                            shortcut: controller.settings.pauseShortcut,
                            symbol: "pause.fill",
                            enabled: controller.state == .listening))
        menu.addItem(action("Stop Listening", #selector(stopListening),
                            shortcut: controller.settings.stopShortcut,
                            symbol: "stop.fill",
                            enabled: controller.state != .stopped))
        menu.addItem(.separator())

        menu.addItem(action("Clear Captions", #selector(clearCaptions), symbol: "eraser"))
        menu.addItem(action("Export Transcript…", #selector(exportTranscript), key: "e",
                            symbol: "square.and.arrow.down"))
        menu.addItem(action("Copy Transcript", #selector(copyTranscript), symbol: "doc.on.doc"))
        menu.addItem(.separator())

        menu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(action("Restart Engine", #selector(restartEngine), symbol: "arrow.clockwise"))
        menu.addItem(.separator())
        menu.addItem(action("Quit Live Subtitles", #selector(NSApplication.terminate(_:)), key: "q",
                            symbol: "power"))
    }

    @discardableResult
    private func action(_ title: String,
                        _ selector: Selector,
                        key: String = "",
                        shortcut: KeyShortcut? = nil,
                        symbol: String,
                        enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let shortcut, let equivalent = KeyShortcut.menuKeyEquivalent(for: shortcut.keyCode) {
            // Display only: the Carbon hot key is what fires while another app is frontmost.
            item.keyEquivalent = equivalent
            item.keyEquivalentModifierMask = shortcut.flags
        }
        return item
    }

    // MARK: - State

    /// Menu-bar icon fills while capturing; the Dock tile (when shown) gets a LIVE badge.
    /// Full captions are deliberately *not* drawn into the Dock tile: at 64-128 px the
    /// text would be unreadable, and the Dock is as far from the video as the caption
    /// overlay is close to it.
    private func show(_ state: ListeningState) {
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            print("[state] \(state.description)")
        }
        statusItem?.button?.image = NSImage(systemSymbolName: state.symbolName,
                                            accessibilityDescription: "Live Subtitles")
        NSApp.dockTile.badgeLabel = state == .listening ? "LIVE" : nil
        NSApp.dockTile.display()
    }

    // MARK: - App main menu

    /// Needed once "Show Dock icon" makes the app activatable: without it, activating
    /// from the Dock leaves an empty menu bar. Every item carries an SF Symbol so the
    /// menus look consistent.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(action("About Live Subtitles",
                               #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               symbol: "info.circle"))
        appMenu.addItem(.separator())
        appMenu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        appMenu.addItem(.separator())
        appMenu.addItem(action("Hide Live Subtitles", #selector(NSApplication.hide(_:)), key: "h",
                               symbol: "eye.slash"))
        appMenu.addItem(action("Quit Live Subtitles", #selector(NSApplication.terminate(_:)), key: "q",
                               symbol: "power"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(action("Settings…", #selector(openSettings), symbol: "gearshape"))
        windowMenu.addItem(action("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m",
                                  symbol: "arrow.down.right.and.arrow.up.left"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func startListening() { controller?.startListening() }
    @objc private func pauseListening() { controller?.pauseListening() }
    @objc private func stopListening() { controller?.stopListening() }
    @objc private func restartEngine() { controller?.restartEngine() }
    @objc private func clearCaptions() { controller?.clearSession() }
    @objc private func exportTranscript() { controller?.exportTranscript() }
    @objc private func copyTranscript() { controller?.copyTranscript() }
    @objc private func openSettings() { controller?.openSettings() }
}
