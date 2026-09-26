//
//  Exporter.swift
//  LiveSubtitlesKit
//
//  Turns stored cues into the formats someone might actually want: SubRip for players,
//  plain text for notes, Markdown for a study log.
//

import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case srt
    case text
    case markdown

    public var fileExtension: String { self == .text ? "txt" : rawValue }
    public var displayName: String {
        switch self {
        case .srt:      return "SubRip (.srt)"
        case .text:     return "Plain text (.txt)"
        case .markdown: return "Markdown (.md)"
        }
    }
}

public enum Exporter {
    public static func render(cues: [Cue],
                              session: Session?,
                              notes: [Note] = [],
                              format: ExportFormat) -> String {
        switch format {
        case .srt:      return subrip(cues)
        case .text:     return cues.map(\.text).joined(separator: "\n") + "\n"
        case .markdown: return markdown(cues: cues, session: session, notes: notes)
        }
    }

    private static func subrip(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(stamp(cue.startMs)) --> \(stamp(cue.endMs))
            \(cue.text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private static func markdown(cues: [Cue], session: Session?, notes: [Note]) -> String {
        var out = "# \(session?.title ?? "Transcript")\n\n"
        if let session {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            out += "- \(formatter.string(from: session.startedAt))\n"
            out += "- \(cues.count) lines\n\n"
        }
        for cue in cues {
            out += "**\(cue.timestamp)**  \(cue.text)\n\n"
        }
        let kept = notes.filter { $0.kind != .note }
        if !kept.isEmpty {
            out += "## Saved\n\n"
            for note in kept {
                out += "- *\(note.kind.rawValue)*: \(note.text)\n"
            }
        }
        return out
    }

    /// `00:00:01,760` as SubRip wants it.
    private static func stamp(_ milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        return String(format: "%02d:%02d:%02d,%03d",
                      ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
