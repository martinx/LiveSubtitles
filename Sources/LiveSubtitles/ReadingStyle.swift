//
//  ReadingStyle.swift
//  LiveSubtitles
//
//  How the transcript is set. Separated from the view so the numbers are in one place and
//  can be argued about without touching layout code.
//
//  The transcript is the one thing in this app that gets read for minutes at a time, so it
//  is set like prose rather than like a table: a column narrow enough to follow with the eye,
//  leading that gives the lines room, and hierarchy carried by colour and weight rather than
//  by boxes and rules.
//

import SwiftUI

/// The typeface the transcript is set in.
///
/// Apple's own faces first, which is why the default is not a font name at all: SF is reached
/// through `design: .default` rather than by name, and so are New York and SF Mono. The named
/// ones below all ship with macOS.
enum ReadingFont: String, CaseIterable, Identifiable {
    case system, serif, mono, rounded, charter, georgia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:  return "System (SF)"
        case .serif:   return "New York"
        case .mono:    return "SF Mono"
        case .rounded: return "Rounded"
        case .charter: return "Charter"
        case .georgia: return "Georgia"
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system:  return .system(size: size, weight: weight, design: .default)
        case .serif:   return .system(size: size, weight: weight, design: .serif)
        case .mono:    return .system(size: size, weight: weight, design: .monospaced)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .charter: return .custom("Charter", size: size)
        case .georgia: return .custom("Georgia", size: size)
        }
    }

    /// The width of a single space in this face, which is what the reader must put between
    /// words. The flow layout renders each word as its own view, so the gap is a number rather
    /// than a glyph — and a number guessed wrong makes prose read as a row of tokens.
    func spaceWidth(atSize size: CGFloat) -> CGFloat {
        let font: NSFont
        switch self {
        case .system:  font = NSFont.systemFont(ofSize: size)
        case .serif:   font = NSFont(descriptor: NSFont.systemFont(ofSize: size)
                                        .fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor,
                                     size: size) ?? NSFont.systemFont(ofSize: size)
        case .mono:    font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .rounded: font = NSFont.systemFont(ofSize: size)
        case .charter: font = NSFont(name: "Charter", size: size) ?? NSFont.systemFont(ofSize: size)
        case .georgia: font = NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        }
        return (" " as NSString).size(withAttributes: [.font: font]).width
    }
}

enum Reading {
    // MARK: - Measure
    //
    // The width of the column the text is set in. Beyond roughly 75 characters the eye loses
    // the start of the next line; the old reader used the whole window, which at this window
    // size was about 130.
    static let measure: CGFloat = 660
    static let measurePadding: CGFloat = 28

    // MARK: - Vertical rhythm
    //
    // Two numbers, not eight. A cue sits a little under its neighbour; a paragraph break is
    // the same gap plus air, so the reader can see the difference without counting.
    static let cueGap: CGFloat = 7
    static let paragraphGap: CGFloat = 22

    // MARK: - Type
    static let bodySize: CGFloat = 15.5
    static let bodyLeading: CGFloat = 5          // extra leading inside a wrapped cue
    static let timestampSize: CGFloat = 11
    static let translationSize: CGFloat = 14
    static let translationLeading: CGFloat = 4

    /// The gutter the timestamps live in, and so the left edge of the text.
    static let gutter: CGFloat = 74
}

/// Colours that follow the system appearance.
///
/// Values rather than assets: a light theme is not a dark theme with the brightness turned
/// up, and the transcript needs different contrast in each — near-black on white for reading,
/// off-white on near-black to stop it glaring.
struct ReadingTheme {
    let scheme: ColorScheme

    var background: Color {
        scheme == .dark ? Color(white: 0.11) : Color(white: 0.985)
    }
    var text: Color {
        scheme == .dark ? Color(white: 0.92) : Color(white: 0.13)
    }
    var secondary: Color {
        scheme == .dark ? Color(white: 0.62) : Color(white: 0.45)
    }
    var tertiary: Color {
        scheme == .dark ? Color(white: 0.44) : Color(white: 0.62)
    }
    var rule: Color {
        scheme == .dark ? Color(white: 1).opacity(0.07) : Color(white: 0).opacity(0.07)
    }
    var selection: Color {
        scheme == .dark ? Color.accentColor.opacity(0.30) : Color.accentColor.opacity(0.16)
    }
    var translation: Color {
        scheme == .dark ? Color(white: 0.70) : Color(white: 0.38)
    }
}
