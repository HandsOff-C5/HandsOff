//
//  MicroHUDView.swift
//  DirectorSidecar
//
//  G3: the ambient micro-HUD pill. Pulsing gold dot + LISTENING + waveform, an optional agent
//  row, and (in the idle edge-hover reveal) a clickable "Open Home" affordance. accentOnSurface
//  is the only gold used for the LISTENING text (WCAG). Honors Reduce Transparency / Reduce Motion.
//

import SwiftUI

struct MicroHUDView: View {
    let model: MicroHUDModel
    let onOpenHome: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.phase {
            case .edgeHoverReveal:
                openHomeRow
            case .agentWorking:
                agentWorkingRow
            default:
                listeningRow
            }
            if !model.runningSessions.isEmpty, model.phase != .edgeHoverReveal {
                AgentActivityRow(sessions: model.runningSessions)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 232, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusWindow, style: .continuous))
    }

    private var listeningRow: some View {
        HStack(spacing: 8) {
            MicroDot(active: true)
            Text("LISTENING")
                .font(theme.sectionLabel).tracking(0.55)
                .foregroundStyle(theme.accentOnSurface)
            Spacer()
            MicroWaveform(level: model.audioLevel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening")
    }

    private var agentWorkingRow: some View {
        HStack(spacing: 8) {
            MicroDot(active: true)
            Text("WORKING")
                .font(theme.sectionLabel).tracking(0.55)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            ProgressView().controlSize(.small).scaleEffect(0.7)
        }
        .accessibilityLabel("An agent is working")
    }

    private var openHomeRow: some View {
        Button(action: onOpenHome) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 11))
                Text("Open Home").font(theme.body)
                Spacer()
                KbdHint("⇧⌘M")
            }
            .foregroundStyle(theme.textPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Home")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            theme.opaqueSurface
        } else {
            VisualEffectBlur(.hudWindow, blending: .withinWindow)
        }
    }
}

private struct MicroDot: View {
    let active: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(theme.accent)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing && active && !reduceMotion ? 1.25 : 1)
            .opacity(pulsing && active && !reduceMotion ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

private struct MicroWaveform: View {
    let level: Double
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            bars { _ in 0.4 }
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                bars { i in (0.2 + 0.8 * abs(sin(t * 3 + Double(i) * 0.7))) * max(0.3, level) }
            }
        }
    }

    private func bars(_ amplitude: @escaping (Int) -> Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(theme.accent).frame(width: 2.5, height: 4 + 12 * amplitude(i))
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

private struct AgentActivityRow: View {
    let sessions: [MenuSession]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(primary).font(theme.mono).foregroundStyle(theme.textTertiary).lineLimit(1)
            if sessions.count > 1 {
                Text("+\(sessions.count - 1)").font(theme.mono).foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sessions.count) agents running")
    }

    private var primary: String {
        guard let first = sessions.first else { return "" }
        return "\(first.agentLabel) · \(first.title)"
    }
}
