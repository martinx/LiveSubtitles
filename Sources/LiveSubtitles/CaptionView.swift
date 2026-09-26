//
//  CaptionView.swift
//  LiveSubtitles
//
//  The finished sentences and the sentence still being spoken are rendered as
//  *separate* lines, so the in-progress sentence can never run on from the end of
//  the previous one - it always starts on a fresh line and pushes older text up.
//
//  The line budget is split between them:
//
//    Max lines = 1 -> the current sentence only
//    Max lines = 2 -> previous sentence + current sentence (classic subtitles)
//    Max lines = 3+ -> up to two lines for the sentence being spoken, the rest
//                      for what came before
//
//  Older lines scroll off because `truncationMode(.head)` drops from the top.
//

import SwiftUI

@MainActor
struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings
    /// Reports the height the caption bar actually occupies. The panel shrinks to it,
    /// so the window only swallows clicks where the bar is drawn rather than over a
    /// tall empty rectangle above it.
    var onBarHeightChange: (CGFloat) -> Void = { _ in }

    private var hasContent: Bool {
        model.hasText || !model.status.isEmpty
    }

    /// The sentence being spoken gets the extra room: two lines once there is space
    /// for it, so a long sentence wraps instead of being cut off after one line.
    private var liveLineLimit: Int {
        settings.lineLimit >= 3 ? 2 : 1
    }

    /// Everything left over goes to the finished sentences. Zero means single-line
    /// mode, where only the current sentence is shown.
    private var committedLineLimit: Int {
        guard !model.live.isEmpty else { return settings.lineLimit }
        return max(0, settings.lineLimit - liveLineLimit)
    }

    var body: some View {
        content
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            // Full-width bar...
            .frame(maxWidth: .infinity)
            // Never let the panel's *current* height clamp the bar. The panel is sized from
            // this measurement, so a clamped measurement deadlocks the two: the overlay
            // would stop growing and Max lines would silently show fewer lines than asked.
            .fixedSize(horizontal: false, vertical: true)
            // ...whose *height* hugs the text, so a large Max lines setting does not
            // leave a permanent black block around one line of captions.
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hasContent ? Color.black.opacity(settings.backgroundOpacity) : Color.clear)
            )
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { onBarHeightChange(proxy.size.height) }
                        .onChange(of: proxy.size.height) { _, height in
                            onBarHeightChange(height)
                        }
                }
            )
            // Anchored to the bottom of the panel's reserved area.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .opacity(model.showsCaption ? 1 : 0)
            .animation(.easeOut(duration: 0.28), value: model.showsCaption)
    }

    @ViewBuilder
    private var content: some View {
        if model.hasText {
            VStack(spacing: 3) {
                if committedLineLimit > 0, !model.committed.isEmpty {
                    Text(model.committed)
                        .foregroundStyle(.white)
                        .lineLimit(committedLineLimit)
                        .truncationMode(.head)
                }

                if !model.live.isEmpty {
                    Text(model.live)
                        // Dimmer, so the viewer can tell the tail is still being revised.
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(liveLineLimit)
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
