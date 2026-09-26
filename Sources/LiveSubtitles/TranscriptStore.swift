//
//  TranscriptStore.swift
//  LiveSubtitles
//
//  Accumulates every committed utterance with its position in the captured
//  audio timeline, so a whole episode can be exported as .srt or plain text.
//

import Foundation

struct TranscriptCue {
    let startMs: Int
    let endMs: Int
    let text: String
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var cues: [TranscriptCue] = []

    var isEmpty: Bool { cues.isEmpty }
    var count: Int { cues.count }

    func append(_ cue: TranscriptCue) {
        cues.append(cue)
    }

    func clear() {
        cues.removeAll()
    }

    var plainText: String {
        cues.map(\.text).joined(separator: "\n")
    }

    /// SubRip output. Cues with no measured end time get a readable minimum duration.
    func srt() -> String {
        var output = ""
        for (index, cue) in cues.enumerated() {
            let end = max(cue.endMs, cue.startMs + 800)
            output += "\(index + 1)\n"
            output += "\(Self.timestamp(cue.startMs)) --> \(Self.timestamp(end))\n"
            output += cue.text
            output += "\n\n"
        }
        return output
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds)
        let hours = total / 3_600_000
        let minutes = (total % 3_600_000) / 60_000
        let seconds = (total % 60_000) / 1_000
        let millis = total % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
