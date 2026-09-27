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
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: CaptionController?
    private var statusItem: NSStatusItem?

    private lazy var aboutWindow = AboutWindow()
    private lazy var libraryWindow = LibraryWindow()
    private lazy var libraryModel = LibraryModel()
    private lazy var welcomeWindow = WelcomeWindow()
    private var updateChecker: UpdateChecker?

    /// Clicking the Dock icon opens the library.
    ///
    /// The window is normally opened from the menu bar, so without this a Dock click on a
    /// running app with no windows open does nothing at all — the icon is there, it takes the
    /// click, and the window that should follow never appears.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openLibrary() }
        return true
    }

    /// Closing the library does not quit: this is a menu-bar app, and the captions keep
    /// running whether or not a window is open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The recording is only readable once its file has been closed.
        controller?.flushRecording()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = CaptionController()
        self.controller = controller

        let checker = UpdateChecker(defaults: .standard)
        self.updateChecker = checker
        // Rebuild the menu when a check finishes so "Update to …" appears.
        checker.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshMenuTitle() }
            }
            .store(in: &observers)

        installMainMenu()
        installStatusItem()

        // A downloaded copy offers to install itself: running from Downloads, or straight
        // out of the disk image, is what makes macOS treat every launch as a new app.
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            print("[install] path=\(Bundle.main.bundlePath) downloaded=\(SelfInstaller.isDownloadedCopy)")
        }

        if SelfInstaller.isDownloadedCopy {
            offerToInstall()
            return
        }

        controller.onStateChanged = { [weak self] state in
            self?.show(state)
        }
        controller.start()

        if !controller.settings.hasSeenWelcome {
            controller.settings.hasSeenWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showWelcome()
            }
        }
        checker.checkIfDue(enabled: controller.settings.checkForUpdates)

        openDebugWindowIfRequested()
    }

    /// LIVESUBTITLES_OPEN=settings|welcome|about|library opens a window straight away, so each
    /// of them can be inspected without clicking through the menu.
    /// LIVESUBTITLES_OPEN_SETTINGS=1 is the older spelling and still works.
    private func openDebugWindowIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        var request = environment["LIVESUBTITLES_OPEN"] ?? ""
        if environment["LIVESUBTITLES_OPEN_SETTINGS"] != nil { request = "settings" }
        guard !request.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            switch request {
            case "settings": self?.openSettings()
            case "welcome": self?.showWelcome()
            case "about": self?.showAbout()
            case "library": self?.openLibrary()
            default: break
            }
        }
    }

    private var observers = Set<AnyCancellable>()

    /// Move this copy into /Applications, then start it from there.
    ///
    /// This exists because a quarantined, non-notarised app run from Downloads or from the
    /// disk image is executed out of a fresh random directory every launch, so macOS never
    /// recognises it as the same app and the Screen Recording grant cannot be remembered.
    /// Installing it once removes the whole class of problem.
    private func offerToInstall() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install \(AppInfo.name) in Applications?"
        alert.informativeText = """
        This copy is running from a temporary location, which is why macOS asks for Screen \
        Recording permission over and over: each launch looks like a different app.

        Installing it into Applications fixes that and remembers the permission. You will \
        only be asked once.
        """
        alert.addButton(withTitle: "Install to Applications")
        alert.addButton(withTitle: "Quit")

        // LIVESUBTITLES_AUTOINSTALL=1 skips the prompt so this path can be exercised.
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_AUTOINSTALL"] != nil {
            performInstall()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        performInstall()
    }

    private func performInstall() {
        do {
            try SelfInstaller.install()
            SelfInstaller.relaunchInstalled()
            NSApp.terminate(nil)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Could not install automatically"
            failure.informativeText = """
            \(error.localizedDescription)

            Drag \(AppInfo.name) into Applications yourself, then open it from there.
            """
            failure.addButton(withTitle: "Show Applications Folder")
            failure.addButton(withTitle: "Quit")
            if failure.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: ListeningState.stopped.symbolName,
                                           accessibilityDescription: AppInfo.name)
        statusItem.button?.toolTip = AppInfo.name

        let menu = NSMenu()
        menu.delegate = self
        // AppKit re-enables items by validating the action against the target whenever
        // this is true (the default), which silently overrides `isEnabled` and greys out
        // anything whose target does not implement the selector.
        menu.autoenablesItems = false
        statusItem.menu = menu
        self.statusItem = statusItem

        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func refreshMenuTitle() {
        if let menu = statusItem?.menu {
            rebuild(menu)
        }
    }

    private func rebuild(_ menu: NSMenu) {
        guard let controller else { return }
        menu.removeAllItems()

        // Current state, so the menu doubles as a status readout.
        let stateItem = NSMenuItem(title: controller.state.description, action: nil, keyEquivalent: "")
        stateItem.image = NSImage(systemSymbolName: controller.state.symbolName, accessibilityDescription: nil)
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        // Section headers rather than bare separators: the current menu style groups
        // commands under a label, which also makes a long menu scannable.
        menu.addItem(.sectionHeader(title: "Listening"))
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
        menu.addItem(action("Reload Engine", #selector(restartEngine), symbol: "arrow.clockwise"))

        menu.addItem(.sectionHeader(title: "Study"))
        menu.addItem(action("Library…", #selector(openLibrary), key: "l", symbol: "books.vertical"))
        menu.addItem(action("How to Use", #selector(showWelcome), symbol: "questionmark.circle"))

        menu.addItem(.sectionHeader(title: "Transcript"))
        menu.addItem(action("Export Transcript…", #selector(exportTranscript), key: "e",
                            symbol: "square.and.arrow.down"))
        menu.addItem(action("Copy Transcript", #selector(copyTranscript), symbol: "doc.on.doc"))
        menu.addItem(action("Clear Captions", #selector(clearCaptions), symbol: "eraser"))

        addUpdateItems(to: menu)

        menu.addItem(.sectionHeader(title: "App"))
        menu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(action("About \(AppInfo.name)", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(appAction("Quit \(AppInfo.name)", #selector(NSApplication.terminate(_:)), key: "q",
                               symbol: "power"))

        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            for item in menu.items where !item.isSeparatorItem {
                print("[menu] \(item.isEnabled ? "on " : "off") \(item.title)")
            }
        }
    }

    private func addUpdateItems(to menu: NSMenu) {
        guard let checker = updateChecker else { return }

        menu.addItem(.sectionHeader(title: "Updates"))
        switch checker.status {
        case .available(let release):
            menu.addItem(action("Update to \(release.version)…", #selector(offerUpdate),
                                symbol: "arrow.down.circle"))
        case .installing(let release):
            menu.addItem(action("Installing \(release.version)…", #selector(checkForUpdates),
                                symbol: "arrow.down.circle", enabled: false))
        default:
            menu.addItem(action("Check for Updates…", #selector(checkForUpdates),
                                symbol: "arrow.triangle.2.circlepath"))
        }
    }

    /// An item whose action this delegate implements.
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

    /// An item whose action belongs to AppKit (Quit, Hide, About, Minimize).
    ///
    /// These must be nil-targeted so they travel the responder chain to `NSApplication`.
    /// Pointing them at this delegate is what made Quit grey out: the delegate does not
    /// implement `terminate:`.
    /// A menu item that shows whether something is on, and flips it.
    private func checkable(_ title: String, _ selector: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func appAction(_ title: String,
                           _ selector: Selector,
                           key: String = "",
                           symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = nil
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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
                                            accessibilityDescription: AppInfo.name)
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
        appMenu.autoenablesItems = false
        appMenu.addItem(action("About \(AppInfo.name)", #selector(showAbout), symbol: "info.circle"))
        appMenu.addItem(action("Check for Updates…", #selector(checkForUpdates),
                               symbol: "arrow.triangle.2.circlepath"))
        appMenu.addItem(.separator())
        appMenu.addItem(action("Library…", #selector(openLibrary), key: "l", symbol: "books.vertical"))
        appMenu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        appMenu.addItem(action("How to Use", #selector(showWelcome), symbol: "questionmark.circle"))
        appMenu.addItem(.separator())
        appMenu.addItem(appAction("Hide \(AppInfo.name)", #selector(NSApplication.hide(_:)), key: "h",
                                  symbol: "eye.slash"))
        appMenu.addItem(appAction("Quit \(AppInfo.name)", #selector(NSApplication.terminate(_:)), key: "q",
                                  symbol: "power"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // A Library menu of its own: these act on the window, and burying them in the app
        // menu is how a feature becomes invisible.
        let libraryItem = NSMenuItem()
        let libraryMenu = NSMenu(title: "Library")
        libraryMenu.autoenablesItems = false
        libraryMenu.addItem(action("Open Library…", #selector(openLibrary),
                                   shortcut: controller?.settings.libraryShortcut, symbol: "books.vertical"))
        libraryMenu.addItem(.separator())
        libraryMenu.addItem(action("New Note…", #selector(newNote),
                                   shortcut: controller?.settings.newNoteShortcut, symbol: "square.and.pencil"))
        libraryMenu.addItem(action("New Folder…", #selector(newFolder),
                                   shortcut: controller?.settings.newFolderShortcut, symbol: "folder.badge.plus"))
        libraryMenu.addItem(.separator())
        libraryMenu.addItem(action("Translate This Session", #selector(translateSession),
                                   shortcut: controller?.settings.translateShortcut, symbol: "translate"))
        libraryMenu.addItem(action("Search Everything…", #selector(searchLibrary),
                                   shortcut: controller?.settings.searchShortcut, symbol: "magnifyingglass"))
        libraryMenu.addItem(.separator())
        libraryMenu.addItem(action("Export as Subtitles…", #selector(exportLibrarySession), key: "e",
                                   symbol: "square.and.arrow.down"))
        libraryItem.submenu = libraryMenu
        mainMenu.addItem(libraryItem)

        // View holds the switches. A menu item with a checkmark is how macOS has always
        // shown "this is on or off", and it is where people look for it.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.autoenablesItems = false
        viewMenu.addItem(checkable("Show Dock Icon", #selector(toggleDockIcon),
                                   on: controller?.settings.showInDock ?? false))
        viewMenu.addItem(checkable("Keep Captions on Screen", #selector(toggleAlwaysVisible),
                                   on: controller?.settings.alwaysVisible ?? false))
        viewMenu.addItem(checkable("Drag to Reposition", #selector(toggleDraggable),
                                   on: controller?.settings.draggable ?? false))
        viewMenu.addItem(.separator())
        viewMenu.addItem(checkable("Follow the System Appearance", #selector(appearanceSystem),
                                   on: controller?.settings.appearance == "system"))
        viewMenu.addItem(checkable("Light", #selector(appearanceLight),
                                   on: controller?.settings.appearance == "light"))
        viewMenu.addItem(checkable("Dark", #selector(appearanceDark),
                                   on: controller?.settings.appearance == "dark"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(checkable("Check for Updates Automatically", #selector(toggleAutoUpdate),
                                   on: controller?.settings.checkForUpdates ?? false))
        viewMenu.addItem(.separator())
        viewMenu.addItem(action("Reset Overlay Position", #selector(resetOverlayPosition),
                                symbol: "arrow.uturn.backward"))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.autoenablesItems = false
        windowMenu.addItem(action("Settings…", #selector(openSettings), symbol: "gearshape"))
        windowMenu.addItem(appAction("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m",
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

    // MARK: - Library commands

    @objc private func newNote() {
        libraryModel.attach(controller?.historyStore())
        libraryWindow.show(model: libraryModel)
        libraryModel.beginNote(cue: libraryModel.selectedCue)
    }

    @objc private func newFolder() {
        libraryWindow.show(model: libraryModel)
        libraryModel.requestNewFolder()
    }

    @objc private func translateSession() {
        libraryWindow.show(model: libraryModel)
        libraryModel.toggleTranslation()
    }

    @objc private func searchLibrary() {
        libraryWindow.show(model: libraryModel)
        libraryModel.requestSearchFocus()
    }

    @objc private func exportLibrarySession() {
        guard let id = libraryModel.selectedSessionID else { return }
        libraryModel.export(.srt, sessionID: id)
    }

    // MARK: - View switches

    @objc private func toggleDockIcon() {
        controller?.settings.showInDock.toggle()
        controller?.applyActivationPolicy()
        installMainMenu()
    }

    @objc private func toggleAlwaysVisible() {
        controller?.settings.alwaysVisible.toggle()
        installMainMenu()
    }

    @objc private func toggleDraggable() {
        controller?.settings.draggable.toggle()
        installMainMenu()
    }

    @objc private func appearanceSystem() { setAppearance("system") }
    @objc private func appearanceLight() { setAppearance("light") }
    @objc private func appearanceDark() { setAppearance("dark") }

    private func setAppearance(_ value: String) {
        controller?.settings.appearance = value
        libraryModel.appearance = controller?.settings.preferredScheme
        installMainMenu()
    }

    @objc private func toggleAutoUpdate() {
        controller?.settings.checkForUpdates.toggle()
        installMainMenu()
    }

    @objc private func resetOverlayPosition() {
        controller?.settings.resetPosition()
    }

    @objc private func openLibrary() {
        libraryModel.appearance = controller?.settings.preferredScheme
        libraryModel.paletteShortcut = controller?.settings.paletteShortcut
        libraryModel.attach(controller?.historyStore())
        libraryWindow.show(model: libraryModel)
    }

    @objc private func showAbout() {
        aboutWindow.show { [weak self] in self?.showWelcome() }
    }

    @objc private func showWelcome() {
        guard let settings = controller?.settings else { return }
        welcomeWindow.show(settings: settings) { [weak self] in
            self?.controller?.startListening()
        }
    }

    @objc private func checkForUpdates() {
        guard let checker = updateChecker else { return }
        Task {
            await checker.check()
            presentUpdateOutcome(checker)
        }
    }

    @objc private func offerUpdate() {
        guard let checker = updateChecker, let release = checker.availableRelease else { return }

        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) \(release.version) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You have \(AppInfo.version). Download and install it now?"
            : String(release.notes.prefix(1200))
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await checker.install(release) }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    private func presentUpdateOutcome(_ checker: UpdateChecker) {
        let alert = NSAlert()
        switch checker.status {
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "\(AppInfo.name) \(AppInfo.version) is the latest release."
            alert.addButton(withTitle: "OK")
        case .available:
            offerUpdate()
            return
        case .failed(let message):
            alert.messageText = "Could not check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        case .installing:
            return
        default:
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
