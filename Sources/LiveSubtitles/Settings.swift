//
//  Settings.swift
//  LiveSubtitles
//
//  UserDefaults-backed settings. Display settings apply live; the two engine
//  settings take effect on the next "Restart Engine".
//

import Foundation
import Combine

final class Settings: ObservableObject {
    private enum Key {
        static let chunkSizeMs = "chunkSizeMs"
        static let eouDebounceMs = "eouDebounceMs"
        static let fontSize = "fontSize"
        static let widthFraction = "widthFraction"
        static let backgroundOpacity = "backgroundOpacity"
        static let bottomInset = "bottomInset"
        static let lineLimit = "lineLimit"
    }

    private let defaults: UserDefaults

    /// Streaming chunk: 160 ms is the lowest latency, larger is more accurate.
    @Published var chunkSizeMs: Int { didSet { defaults.set(chunkSizeMs, forKey: Key.chunkSizeMs) } }
    /// Silence that ends a sentence. Lower feels snappier but splits fast dialogue.
    @Published var eouDebounceMs: Int { didSet { defaults.set(eouDebounceMs, forKey: Key.eouDebounceMs) } }

    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    @Published var widthFraction: Double { didSet { defaults.set(widthFraction, forKey: Key.widthFraction) } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity) } }
    @Published var bottomInset: Double { didSet { defaults.set(bottomInset, forKey: Key.bottomInset) } }
    @Published var lineLimit: Int { didSet { defaults.set(lineLimit, forKey: Key.lineLimit) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.chunkSizeMs: 160,
            Key.eouDebounceMs: 600,
            Key.fontSize: 28.0,
            Key.widthFraction: 0.72,
            Key.backgroundOpacity: 0.55,
            Key.bottomInset: 110.0,
            Key.lineLimit: 2,
        ])
        chunkSizeMs = defaults.integer(forKey: Key.chunkSizeMs)
        eouDebounceMs = defaults.integer(forKey: Key.eouDebounceMs)
        fontSize = defaults.double(forKey: Key.fontSize)
        widthFraction = defaults.double(forKey: Key.widthFraction)
        backgroundOpacity = defaults.double(forKey: Key.backgroundOpacity)
        bottomInset = defaults.double(forKey: Key.bottomInset)
        lineLimit = defaults.integer(forKey: Key.lineLimit)
    }
}
