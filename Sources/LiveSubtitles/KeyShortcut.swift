//
//  KeyShortcut.swift
//  LiveSubtitles
//
//  A global keyboard shortcut: one physical key plus modifiers, with the two
//  conversions that matter - a human-readable label, and Carbon's modifier mask.
//

import AppKit
import Carbon.HIToolbox

struct KeyShortcut: Equatable {
    let keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, device independent.
    let modifiers: UInt

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Persisted as "keyCode|modifiers".
    init?(storage: String) {
        let parts = storage.split(separator: "|")
        guard parts.count == 2,
              let keyCode = UInt16(parts[0]),
              let modifiers = UInt(parts[1]) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var storage: String { "\(keyCode)|\(modifiers)" }

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask)
    }

    /// e.g. "⌥⌘P".
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    // MARK: - Defaults

    static let defaultStart = KeyShortcut(keyCode: 37, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)  // ⌥⌘L
    static let defaultPause = KeyShortcut(keyCode: 35, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)  // ⌥⌘P
    static let defaultStop = KeyShortcut(keyCode: 47, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)   // ⌥⌘.

    // MARK: - Key naming

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The character a menu item needs in order to *display* this shortcut, or nil for
    /// keys with no printable equivalent (arrows, function keys). The global hot key is
    /// what actually triggers the action; this only makes the menu look right.
    static func menuKeyEquivalent(for keyCode: UInt16) -> String? {
        guard specialKeys[keyCode] == nil else { return nil }
        let name = keyName(for: keyCode)
        guard name.count == 1 else { return nil }
        return name.lowercased()
    }

    /// The key's name on the user's *current* layout, so the label matches the key cap.
    private static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "key \(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return "key \(keyCode)"
            }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout,
                                        keyCode,
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, length > 0 else { return "key \(keyCode)" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}
