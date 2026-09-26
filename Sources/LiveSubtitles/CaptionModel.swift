//
//  CaptionModel.swift
//  LiveSubtitles
//
//  Holds caption text as two deliberately separate pieces:
//   - `committed`: sentences the engine has finished. Never rewritten, so text the
//     viewer has already read never moves.
//   - `live`: the sentence still being spoken. Replaced on every revision, which is
//     where the model's self-correction shows up.
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

    /// Rendering stays cheap because only a trailing window is ever drawn.
    private let committedLimit = 400
    private var hideTask: Task<Void, Never>?

    var hasText: Bool { !committed.isEmpty || !live.isEmpty }

    func setStatus(_ text: String) {
        if Self.debugLogging { print("[status] \(text)") }
        status = text
    }

    func applyPartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if Self.debugLogging { print("[partial] \(trimmed)") }
        live = trimmed
        reveal()
    }

    func applyUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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
    }

    var captionText: AttributedString {
        var result = AttributedString(committed)
        result.foregroundColor = .white

        guard !live.isEmpty else { return result }

        var provisional = AttributedString((committed.isEmpty ? "" : " ") + live)
        // Dimmer so the viewer can tell the tail is still being revised.
        provisional.foregroundColor = NSColor.white.withAlphaComponent(0.75)
        result.append(provisional)
        return result
    }

    private func reveal() {
        showsCaption = true

        // Linger briefly after speech stops, then fade out.
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.showsCaption = false
        }
    }
}
