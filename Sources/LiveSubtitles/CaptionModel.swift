//
//  CaptionModel.swift
//  LiveSubtitles
//
//  Holds caption text as two deliberately separate pieces:
//   - `committed`: sentences already finished. Never rewritten, so text the viewer
//     has already read never moves.
//   - `live`: the sentence still being spoken. Replaced on every revision, which is
//     where the model's self-correction shows up.
//
//  Two timers run off the last speech:
//   - a long pause drops the accumulated text so the next sentence starts a fresh
//     line instead of continuing the previous one;
//   - unless "always visible" is on, the caption then fades out.
//

import Foundation
import SwiftUI

@MainActor
final class CaptionModel: ObservableObject {
    @Published private(set) var committed = ""
    @Published private(set) var live = ""
    @Published private(set) var showsCaption = false
    @Published private(set) var status = "Starting…"

    /// Set LIVESUBTITLES_DEBUG=1 to trace recognition timing on stdout.
    private static let debugLogging = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil
    /// How long the caption lingers before fading when "always visible" is off.
    private static let fadeAfterSilence: Double = 6

    /// Rendering stays cheap because only a trailing window is ever drawn.
    private let committedLimit = 400
    private let settings: Settings
    private var silenceTask: Task<Void, Never>?
    /// Set once a pause has been long enough that the *next* sentence should begin a
    /// fresh line. Applied when speech resumes rather than immediately, so the last
    /// line stays readable during the silence.
    private var lineBreakPending = false

    init(settings: Settings) {
        self.settings = settings
    }

    var hasText: Bool { !committed.isEmpty || !live.isEmpty }

    func setStatus(_ text: String) {
        if Self.debugLogging { print("[status] \(text)") }
        status = text
    }

    func applyPartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        beginLineIfNeeded()
        if Self.debugLogging { print("[partial] \(trimmed)") }
        live = trimmed
        reveal()
    }

    func applyUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        beginLineIfNeeded()
        if Self.debugLogging { print("[utterance] \(trimmed)") }

        committed += committed.isEmpty ? trimmed : " " + trimmed
        if committed.count > committedLimit {
            committed = String(committed.suffix(committedLimit))
        }
        live = ""
        reveal()
    }

    func clear() {
        committed = ""
        live = ""
        showsCaption = false
        lineBreakPending = false
        silenceTask?.cancel()
    }

    /// The audio itself has been quiet long enough. The line on screen stays put -
    /// the break is applied when the next words arrive, so the last line does not
    /// blank out during the pause. Driven by audio level rather than by the model
    /// going silent, because the model keeps emitting hallucinated words through
    /// silence and would reset a text-based timer forever.
    func markPause() {
        lineBreakPending = true
        if Self.debugLogging { print("[newline] armed (quiet audio)") }
    }

    /// A long pause marks the end of the current line: whatever is on screen stays
    /// put, but the next words start a fresh line instead of being appended to it.
    private func beginLineIfNeeded() {
        guard lineBreakPending else { return }
        lineBreakPending = false
        if Self.debugLogging { print("[newline] previous line dropped") }
        committed = ""
        live = ""
    }

    private func reveal() {
        showsCaption = true

        silenceTask?.cancel()
        let breakAfter = settings.newLineAfterSilence
        let alwaysVisible = settings.alwaysVisible

        silenceTask = Task { [weak self] in
            // 1. Long pause -> flag a line break for when speech resumes.
            if breakAfter > 0 {
                try? await Task.sleep(for: .seconds(breakAfter))
                guard !Task.isCancelled, let self else { return }
                self.lineBreakPending = true
                if Self.debugLogging {
                    print("[break] silence \(breakAfter)s -> next sentence starts a new line")
                }
            }

            // 2. Then fade, unless the overlay is pinned on screen.
            guard !alwaysVisible else { return }
            try? await Task.sleep(for: .seconds(Self.fadeAfterSilence))
            guard !Task.isCancelled else { return }
            self?.showsCaption = false
        }
    }
}
