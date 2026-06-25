//
//  MenuComponents.swift
//  DirectorSidecar
//
//  Menu-bar dropdown rows + the status-item label (G1 §SwiftUI component spec). Rows are plain
//  buttons with custom hover; timers tick via TimelineView. Honors Reduce Motion.
//

import SwiftUI
import AppKit

/// The status-bar item: the brand template glyph + a readiness dot overlay (dot only when not
/// ready — a calm bar). Readiness is the dot, never a recolor of the template glyph.
struct MenuBarLabel: View {
    let readiness: ReadinessLevel
    @Environment(\.theme) private var theme

    var body: some View {
        // The Template-Image asset, explicitly sized so the status item is visible (a MenuBarExtra
        // label needs a concrete frame). Template-rendered → auto-tints to the menu-bar appearance.
        Image("Template-Image")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                if readiness != .ready {
                    Circle()
                        .fill(theme.color(for: readiness))
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -3)
                }
            }
            .accessibilityLabel("Director")
            .accessibilityValue(readiness.spoken)
    }
}

/// A tappable action row: title, optional keyboard hint, enabled/active state. Icon-less by default
/// (cleaner, more native — Wispr-style); pass `icon` only where a glyph genuinely earns its place.
struct MenuActionRow: View {
    var icon: String? = nil
    let title: String
    var trailing: String?
    var enabled = true
    var active = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: theme.iconBox, height: theme.iconBox)
                        .foregroundStyle(tint)
                }
                Text(title).font(theme.body).foregroundStyle(tint)
                Spacer()
                if let trailing { KbdHint(trailing) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(hovering && enabled ? theme.menuHighlight : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : theme.quickMotion, value: hovering)
        .accessibilityAddTraits(.isButton)
    }

    private var tint: Color {
        if !enabled { return theme.textTertiary }
        return active ? theme.accent : theme.textPrimary
    }
}

/// A running-session row: status dot + title/agent + live mono timer. Tapping opens Home.
struct SessionRow: View {
    let session: MenuSession
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(theme.color(for: session.status)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(theme.body).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Text(session.agentLabel).font(theme.kbd).foregroundStyle(theme.textTertiary)
                }
                Spacer()
                MonoTimer(since: session.startedAt)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(hovering ? theme.menuHighlight : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : theme.quickMotion, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.title)
        .accessibilityValue(session.status.spoken)
        .accessibilityAddTraits([.isButton, .updatesFrequently])
    }
}

/// The "no agents running" placeholder row.
struct EmptyAgentsRow: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("No agents running")
            .font(theme.body)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 18).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
