//
//  App.swift
//  LiveSubtitles
//
//  Menu-bar-only entry point: `.accessory` means no Dock icon and no focus
//  stealing from whatever is playing.
//

import AppKit

@main
struct LiveSubtitlesApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
