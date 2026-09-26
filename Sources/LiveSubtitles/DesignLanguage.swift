//
//  DesignLanguage.swift
//  LiveSubtitles
//
//  The macOS 26/27 look: Liquid Glass where the system provides it, materials where it
//  does not. One place for spacing too, so panes do not each invent their own.
//
//  Everything here is availability-gated rather than requiring macOS 26 outright, so the
//  app still builds and runs on 14 — it simply looks like the older system there.
//

import AppKit
import SwiftUI

enum Metrics {
    /// Sidebar rows were cramped at the system default; these are the roomier figures.
    static let sidebarRowVertical: CGFloat = 7
    static let sidebarRowHorizontal: CGFloat = 10
    static let sidebarIconWidth: CGFloat = 22

    static let panePadding: CGFloat = 22
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
    static let paragraphSpacing: CGFloat = 16
    static let lineSpacing: CGFloat = 3.5
}

extension View {
    /// A panel that floats: real Liquid Glass on macOS 26+, a thin material before that.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Roomier sidebar rows without giving up the system's own sidebar behaviour.
    func sidebarRow() -> some View {
        self
            .padding(.vertical, Metrics.sidebarRowVertical)
            .padding(.horizontal, Metrics.sidebarRowHorizontal)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
    }
}

/// Glass capsules for grouped toolbar controls, so they read as one instrument cluster
/// rather than a row of loose buttons.
struct GlassControlGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) { content }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
        } else {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Toolbar icon buttons in the current system style.
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var enabled: Bool = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .modifier(GlassButtonModifier())
        .disabled(!enabled)
        .help(help)
    }
}

private struct GlassButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderless)
        }
    }
}
