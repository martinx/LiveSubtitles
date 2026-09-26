//
//  Settings.swift
//  LiveSubtitles
//
//  UserDefaults-backed settings. Appearance and behaviour apply live; the two
//  engine settings take effect on the next "Restart Engine".
//

import Foundation
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
            Key.draggable: false,
            Key.showInDock: false,
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
        hasCustomPosition = defaults.bool(forKey: Key.hasCustomPosition)
        panelX = defaults.double(forKey: Key.panelX)
        panelY = defaults.double(forKey: Key.panelY)
    }

    /// Forget the dragged position and go back to the configured bottom-centre spot.
    func resetPosition() {
        hasCustomPosition = false
        defaults.removeObject(forKey: Key.panelX)
        defaults.removeObject(forKey: Key.panelY)
    }
}
