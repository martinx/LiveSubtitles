//
//  Settings.swift
//  LiveSubtitles
//
//  UserDefaults-backed settings. Appearance and behaviour apply live; the two
//  engine settings take effect on the next "Restart Engine".
//

import Foundation
import AppKit
import Combine
import CoreGraphics

final class Settings: ObservableObject {
    private enum Key {
        static let modelID = "modelID"
        static let chunkSizeMs = "chunkSizeMs"   // legacy, read once for migration
        static let eouDebounceMs = "eouDebounceMs"
        static let fontSize = "fontSize"
        static let widthFraction = "widthFraction"
        static let backgroundOpacity = "backgroundOpacity"
        static let bottomInset = "bottomInset"
        static let lineLimit = "lineLimit"
        static let newLineAfterSilence = "newLineAfterSilence"
        static let alwaysVisible = "alwaysVisible"
        static let draggable = "draggable"
        static let showInDock = "showInDock"
        static let appearance = "appearance"
        static let readingFont = "readingFont"
        static let startAtLaunch = "startAtLaunch"
        static let startShortcut = "startShortcut"
        static let pauseShortcut = "pauseShortcut"
        static let stopShortcut = "stopShortcut"
        static let libraryShortcut = "libraryShortcut"
        static let newNoteShortcut = "newNoteShortcut"
        static let newFolderShortcut = "newFolderShortcut"
        static let translateShortcut = "translateShortcut"
        static let searchShortcut = "searchShortcut"
        static let paletteShortcut = "paletteShortcut"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let checkForUpdates = "checkForUpdates"
        static let hasCustomPosition = "hasCustomPosition"
        static let panelX = "panelX"
        static let panelY = "panelY"
    }

    private let defaults: UserDefaults

    /// Which streaming model to run. Larger models are more accurate; each one
    /// downloads on first use.
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: Key.modelID) } }
    /// Silence that ends a sentence. Lower feels snappier but splits fast dialogue.
    @Published var eouDebounceMs: Int { didSet { defaults.set(eouDebounceMs, forKey: Key.eouDebounceMs) } }

    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    @Published var widthFraction: Double { didSet { defaults.set(widthFraction, forKey: Key.widthFraction) } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity) } }
    @Published var bottomInset: Double { didSet { defaults.set(bottomInset, forKey: Key.bottomInset) } }
    @Published var lineLimit: Int { didSet { defaults.set(lineLimit, forKey: Key.lineLimit) } }

    // MARK: - Behaviour

    /// After this much silence the next sentence starts on a **fresh line** instead
    /// of being appended to the previous one. 0 disables the break.
    @Published var newLineAfterSilence: Double { didSet { defaults.set(newLineAfterSilence, forKey: Key.newLineAfterSilence) } }
    /// Keep the caption on screen through quiet stretches instead of fading it out.
    @Published var alwaysVisible: Bool { didSet { defaults.set(alwaysVisible, forKey: Key.alwaysVisible) } }
    /// Make the overlay draggable. Off means it is click-through and fixed in place.
    @Published var draggable: Bool { didSet { defaults.set(draggable, forKey: Key.draggable) } }
    /// Show a Dock icon as well as the menu-bar item. Off by default: an accessory
    /// app can never activate itself over the video.
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Key.showInDock) } }

    /// "system", "light" or "dark". Applied with `preferredColorScheme`, so every window —
    /// the library, the settings, the overlay — follows it together.
    /// The transcript's typeface. "system" is SF, Apple's own.
    @Published var readingFont: String {
        didSet { defaults.set(readingFont, forKey: Key.readingFont) }
    }

    @Published var appearance: String {
        didSet { defaults.set(appearance, forKey: Key.appearance) }
    }
    /// Begin listening as soon as the app launches.
    @Published var startAtLaunch: Bool { didSet { defaults.set(startAtLaunch, forKey: Key.startAtLaunch) } }

    /// Global shortcuts. `nil` means "not bound".
    @Published var startShortcut: KeyShortcut? {
        didSet { defaults.set(startShortcut?.storage ?? "", forKey: Key.startShortcut) }
    }
    @Published var pauseShortcut: KeyShortcut? {
        didSet { defaults.set(pauseShortcut?.storage ?? "", forKey: Key.pauseShortcut) }
    }
    // The window's own commands. Unlike the three above these only work while the app is
    // frontmost, which is what a menu key equivalent means.
    @Published var libraryShortcut: KeyShortcut? {
        didSet { defaults.set(libraryShortcut?.storage ?? "", forKey: Key.libraryShortcut) }
    }
    @Published var newNoteShortcut: KeyShortcut? {
        didSet { defaults.set(newNoteShortcut?.storage ?? "", forKey: Key.newNoteShortcut) }
    }
    @Published var newFolderShortcut: KeyShortcut? {
        didSet { defaults.set(newFolderShortcut?.storage ?? "", forKey: Key.newFolderShortcut) }
    }
    @Published var translateShortcut: KeyShortcut? {
        didSet { defaults.set(translateShortcut?.storage ?? "", forKey: Key.translateShortcut) }
    }
    @Published var searchShortcut: KeyShortcut? {
        didSet { defaults.set(searchShortcut?.storage ?? "", forKey: Key.searchShortcut) }
    }
    @Published var paletteShortcut: KeyShortcut? {
        didSet { defaults.set(paletteShortcut?.storage ?? "", forKey: Key.paletteShortcut) }
    }

    @Published var stopShortcut: KeyShortcut? {
        didSet { defaults.set(stopShortcut?.storage ?? "", forKey: Key.stopShortcut) }
    }

    /// The welcome window is shown once, automatically, then only on request.
    @Published var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }
    /// A daily GET of the public GitHub releases API - the app's only network use
    /// besides the one-time model download.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }

    // MARK: - Overlay position

    /// True once the overlay has been dragged somewhere. Published, because it
    /// changes the layout; the coordinates themselves are not, so recording a drop
    /// does not trigger three separate re-layouts.
    @Published var hasCustomPosition: Bool { didSet { defaults.set(hasCustomPosition, forKey: Key.hasCustomPosition) } }
    private(set) var panelX: Double
    private(set) var panelY: Double

    /// Record where the viewer dropped the overlay.
    func setPanelOrigin(_ origin: CGPoint) {
        panelX = Double(origin.x)
        panelY = Double(origin.y)
        defaults.set(panelX, forKey: Key.panelX)
        defaults.set(panelY, forKey: Key.panelY)
        hasCustomPosition = true
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.modelID: SpeechModel.default.rawValue,
            Key.eouDebounceMs: 600,
            Key.fontSize: 28.0,
            Key.widthFraction: 0.72,
            Key.backgroundOpacity: 0.55,
            Key.bottomInset: 110.0,
            Key.lineLimit: 2,
            Key.newLineAfterSilence: 3.0,
            Key.alwaysVisible: false,
            Key.draggable: true,
            Key.showInDock: false,
            Key.appearance: "system",
            Key.readingFont: "system",
            Key.startAtLaunch: true,
            Key.startShortcut: KeyShortcut.defaultStart.storage,
            Key.pauseShortcut: KeyShortcut.defaultPause.storage,
            Key.stopShortcut: KeyShortcut.defaultStop.storage,
            Key.hasSeenWelcome: false,
            Key.checkForUpdates: true,
            Key.hasCustomPosition: false,
            Key.panelX: 0.0,
            Key.panelY: 0.0,
        ])
        // Migrate the old chunk-size setting the first time this version runs.
        if let stored = defaults.string(forKey: Key.modelID), !stored.isEmpty {
            modelID = stored
        } else {
            switch defaults.integer(forKey: Key.chunkSizeMs) {
            case 320: modelID = SpeechModel.eou320.rawValue
            default: modelID = SpeechModel.default.rawValue
            }
        }
        eouDebounceMs = defaults.integer(forKey: Key.eouDebounceMs)
        fontSize = defaults.double(forKey: Key.fontSize)
        widthFraction = defaults.double(forKey: Key.widthFraction)
        backgroundOpacity = defaults.double(forKey: Key.backgroundOpacity)
        bottomInset = defaults.double(forKey: Key.bottomInset)
        lineLimit = defaults.integer(forKey: Key.lineLimit)
        newLineAfterSilence = defaults.double(forKey: Key.newLineAfterSilence)
        alwaysVisible = defaults.bool(forKey: Key.alwaysVisible)
        draggable = defaults.bool(forKey: Key.draggable)
        showInDock = defaults.bool(forKey: Key.showInDock)
        appearance = defaults.string(forKey: Key.appearance) ?? "system"
        readingFont = defaults.string(forKey: Key.readingFont) ?? "system"
        startAtLaunch = defaults.bool(forKey: Key.startAtLaunch)
        startShortcut = Self.loadShortcut(defaults, Key.startShortcut)
        pauseShortcut = Self.loadShortcut(defaults, Key.pauseShortcut)
        stopShortcut = Self.loadShortcut(defaults, Key.stopShortcut)
        // Defaults are the keys these commands have always had, so an existing install keeps
        // working and a fresh one starts with sensible bindings.
        let command = NSEvent.ModifierFlags.command.rawValue
        let commandShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        libraryShortcut = Self.loadShortcut(defaults, Key.libraryShortcut)
            ?? KeyShortcut(keyCode: 37, modifiers: command)          // ⌘L
        newNoteShortcut = Self.loadShortcut(defaults, Key.newNoteShortcut)
            ?? KeyShortcut(keyCode: 45, modifiers: command)          // ⌘N
        newFolderShortcut = Self.loadShortcut(defaults, Key.newFolderShortcut)
            ?? KeyShortcut(keyCode: 45, modifiers: commandShift)     // ⇧⌘N
        translateShortcut = Self.loadShortcut(defaults, Key.translateShortcut)
            ?? KeyShortcut(keyCode: 17, modifiers: command)          // ⌘T
        searchShortcut = Self.loadShortcut(defaults, Key.searchShortcut)
            ?? KeyShortcut(keyCode: 3, modifiers: command)           // ⌘F
        paletteShortcut = Self.loadShortcut(defaults, Key.paletteShortcut)
            ?? KeyShortcut(keyCode: 40, modifiers: command)          // ⌘K
        hasSeenWelcome = defaults.bool(forKey: Key.hasSeenWelcome)
        checkForUpdates = defaults.bool(forKey: Key.checkForUpdates)
        hasCustomPosition = defaults.bool(forKey: Key.hasCustomPosition)
        panelX = defaults.double(forKey: Key.panelX)
        panelY = defaults.double(forKey: Key.panelY)
    }

    /// Empty string is how a cleared shortcut is stored, which is different from the
     /// key being absent (that yields the registered default).
    private static func loadShortcut(_ defaults: UserDefaults, _ key: String) -> KeyShortcut? {
        guard let raw = defaults.string(forKey: key), !raw.isEmpty else { return nil }
        return KeyShortcut(storage: raw)
    }

    /// Forget the dragged position and go back to the configured bottom-centre spot.
    func resetPosition() {
        hasCustomPosition = false
        defaults.removeObject(forKey: Key.panelX)
        defaults.removeObject(forKey: Key.panelY)
    }
}
