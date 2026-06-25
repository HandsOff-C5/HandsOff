//
//  Components.swift
//  DirectorSidecar
//
//  Shared reusable leaf components (built in G1, consumed by all gates). Every component reads
//  tokens from @Environment(\.theme); none hard-codes a hex. Each non-text affordance carries a
//  VoiceOver label/value/trait (brand pillar 3 — color is never the only signal).
//

import SwiftUI
import AppKit

/// Readiness dot — `ready`→success, `attention`→warning, `blocked`→danger. Spoken, not color-only.
struct ReadinessDot: View {
    let level: ReadinessLevel
    var diameter: CGFloat = 7
    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .fill(theme.color(for: level))
            .frame(width: diameter, height: diameter)
            .accessibilityElement()
            .accessibilityLabel("Readiness")
            .accessibilityValue(level.spoken)
    }
}

/// A status capsule for a session/run (used in the Home Dashboard cards too).
struct StatusPill: View {
    let status: ExecutionStatus
    var title: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(theme.color(for: status)).frame(width: 6, height: 6)
            Text(title ?? status.spoken).font(theme.kbd).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.controlBg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Status")
        .accessibilityValue(status.spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Risk tag — color from the risk level only (Greenlight is gesture-to-execute by default).
struct RiskTag: View {
    let level: RiskLevel
    @Environment(\.theme) private var theme

    var body: some View {
        Text(level.spoken.uppercased())
            .font(theme.kbd)
            .foregroundStyle(theme.color(for: level))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: theme.radiusChip, style: .continuous)
                .fill(theme.color(for: level).opacity(0.14)))
            .accessibilityLabel("Risk")
            .accessibilityValue(level.spoken)
    }
}

/// Uppercase section label — "AGENTS · N RUNNING", sidebar groups.
struct SectionLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(theme.sectionLabel)
            .tracking(0.55)
            .foregroundStyle(theme.textTertiary)
    }
}

/// Keyboard hint — "⇧⌘M", "hold fn".
struct KbdHint: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(theme.kbd).foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A live elapsed timer (mm:ss) that ticks without re-fetching, via TimelineView.
struct MonoTimer: View {
    let since: Date
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsed(from: since, to: context.date))
                .font(theme.mono)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
        }
        .accessibilityHidden(true)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The brand mark for the dropdown header (a simple geometric placeholder; the production glyph
/// is a design drop-in — see Assets `Template-Image`).
struct BrandGlyph: View {
    var size: CGFloat = 16
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(theme.accent)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(theme.goldInk)
            )
            .accessibilityHidden(true)
    }
}

/// A referent chip — the selected/resolved surface (HUD, G2). Defined in G1 as a shared leaf.
struct ReferentChip: View {
    let title: String
    let app: String
    var selected = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "app.dashed").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
            Text(title).font(theme.kbd).foregroundStyle(theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: theme.radiusChip, style: .continuous)
            .fill(selected ? theme.accentWash : theme.controlBg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Referent: \(app), \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The "not connected" banner pinned to the bottom of the menu / HUD chrome.
struct ConnectionBanner: View {
    let state: ConnectionState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(theme.warning)
            Text(BridgeStore.connectionLabel(state)).font(theme.kbd).foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.controlBg)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch state {
        case .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .engineDown: return "exclamationmark.triangle"
        case .connected: return "checkmark.circle"
        }
    }
}

/// Director button style — `.primary` (gold fill), `.secondary` (tonal), `.symbol` (icon-only).
struct DirectorButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, symbol }
    let kind: Kind
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(theme.body)
            .padding(.horizontal, kind == .symbol ? 6 : 12)
            .padding(.vertical, kind == .symbol ? 6 : 6)
            .foregroundStyle(foreground(pressed))
            .background(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(background(pressed)))
            .animation(theme.quickMotion, value: pressed)
    }

    private func foreground(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return theme.goldInk
        case .secondary, .symbol: return theme.textPrimary
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? theme.accentPressed : theme.accent
        case .secondary: return pressed ? theme.controlBg.opacity(0.8) : theme.controlBg
        case .symbol: return pressed ? theme.controlBg : .clear
        }
    }
}
