//
//  CaptionView.swift
//  LiveSubtitles
//
//  Two-line rolling caption. `truncationMode(.head)` keeps the newest words on
//  screen and lets old text slide off the top, which is what makes it read like
//  YouTube's captions instead of a string that snaps to a new value.
//

import SwiftUI

@MainActor
struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings

    private var hasContent: Bool {
        model.hasText || !model.status.isEmpty
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
            Text(model.captionText)
                .font(.system(size: settings.fontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(settings.lineLimit)
                .truncationMode(.head)
                .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                .animation(.easeOut(duration: 0.12), value: model.live)
        } else if !model.status.isEmpty {
            Text(model.status)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
