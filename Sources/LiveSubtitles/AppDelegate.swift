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

        installStatusItem()
        controller.start()
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble.fill",
                                           accessibilityDescription: "Live Subtitles")
        statusItem.button?.toolTip = "Live Subtitles"

        let menu = NSMenu()
        menu.addItem(makeItem("Restart Engine", #selector(restartEngine), ""))
        menu.addItem(makeItem("Clear Captions", #selector(clearCaptions), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Export Transcript…", #selector(exportTranscript), "e"))
        menu.addItem(makeItem("Copy Transcript", #selector(copyTranscript), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Live Subtitles", #selector(NSApplication.terminate(_:)), "q"))

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func restartEngine() { controller?.restart() }
    @objc private func clearCaptions() { controller?.clearSession() }
    @objc private func exportTranscript() { controller?.exportTranscript() }
    @objc private func copyTranscript() { controller?.copyTranscript() }
    @objc private func openSettings() { controller?.openSettings() }
}
