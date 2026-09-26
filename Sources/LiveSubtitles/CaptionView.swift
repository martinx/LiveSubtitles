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
            // Deliberately no `maxHeight: .infinity`: a view that asks for unbounded
            // height lets AppKit size the window to fit, which showed up as an invisible
            // full-height panel swallowing clicks. The window hugs the bar instead, so
            // bottom alignment is all that is left to say.
            .frame(maxWidth: .infinity, alignment: .bottom)
            .opacity(model.showsCaption ? 1 : 0)
            .animation(.easeOut(duration: 0.28), value: model.showsCaption)
    }

    @ViewBuilder
    private var content: some View {
        if model.hasText {
            VStack(spacing: paragraphGap) {
                if committedLineLimit > 0, !model.committed.isEmpty {
                    Text(model.committed)
                        .foregroundStyle(.white)
                        .lineLimit(committedLineLimit)
                        .truncationMode(.head)
                }

                if !model.live.isEmpty {
                    Text(model.live)
                        // A shade dimmer, so the tail reads as still being revised. Only a
                        // shade: the old 0.75 cost more in legibility than the hint was worth.
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(liveLineLimit)
                        .truncationMode(.head)
                }
            }
            .font(captionFont)
            .tracking(captionTracking)
            .lineSpacing(captionLeading)
            .multilineTextAlignment(.center)
            // A wide, soft shadow rather than a hard one. Apple's own captions sit on a
            // gentle shadow that stays readable over bright video without looking drawn on.
            .shadow(color: .black.opacity(0.55),
                    radius: max(2, settings.fontSize * 0.14),
                    x: 0, y: settings.fontSize * 0.04)
            .animation(.easeOut(duration: 0.12), value: model.live)
        } else if !model.status.isEmpty {
            Text(model.status)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Typography
    //
    // Set the way the system sets captions: SF Pro, semibold, slightly tightened tracking,
    // and leading that scales with the size instead of being a fixed number of points.

    private var captionFont: Font {
        .system(size: settings.fontSize, weight: .semibold, design: .default)
    }

    /// Large type needs a touch of negative tracking or it reads loose.
    private var captionTracking: CGFloat {
        -settings.fontSize * 0.012
    }

    /// ~1.18× the size, which is where subtitles stop looking cramped without drifting apart.
    private var captionLeading: CGFloat {
        settings.fontSize * 0.18
    }

    /// The gap between the settled line and the one still being revised.
    private var paragraphGap: CGFloat {
        settings.fontSize * 0.16
    }
}
