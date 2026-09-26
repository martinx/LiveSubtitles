//
//  CaptionView.swift
//  LiveSubtitles
//
//  The finished sentences and the sentence still being spoken are rendered as
//  *separate* lines. That is what makes the caption behave like YouTube's: the
//  in-progress sentence can never run on from the end of the previous one, it
//  always starts on a fresh line and pushes the older lines up.
//
//  Older lines scroll off because `truncationMode(.head)` drops from the top once
//  the line budget is used up.
//

import SwiftUI

@MainActor
struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings

    private var hasContent: Bool {
        model.hasText || !model.status.isEmpty
    }

    /// While a sentence is in progress it gets a line of its own, so the finished
    /// sentences are limited to the remaining lines.
    private var committedLineLimit: Int {
        model.live.isEmpty ? settings.lineLimit : max(1, settings.lineLimit - 1)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hasContent ? Color.black.opacity(settings.backgroundOpacity) : Color.clear)
            )
            .opacity(model.showsCaption ? 1 : 0)
            .animation(.easeOut(duration: 0.28), value: model.showsCaption)
    }

    @ViewBuilder
    private var content: some View {
        if model.hasText {
            VStack(spacing: 3) {
                if !model.committed.isEmpty {
                    Text(model.committed)
                        .foregroundStyle(.white)
                        .lineLimit(committedLineLimit)
                        .truncationMode(.head)
                }

                if !model.live.isEmpty {
                    Text(model.live)
                        // Dimmer, so the viewer can tell the tail is still being revised.
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .font(.system(size: settings.fontSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
            .animation(.easeOut(duration: 0.12), value: model.live)
        } else if !model.status.isEmpty {
            Text(model.status)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
