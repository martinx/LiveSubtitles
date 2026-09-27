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
