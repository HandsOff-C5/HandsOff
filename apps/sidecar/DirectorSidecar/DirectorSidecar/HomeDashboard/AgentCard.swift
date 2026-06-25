//
//  AgentCard.swift
//  DirectorSidecar
//
//  G4a: one supervised agent as a card — identity chip + status pill + (running) progress track +
//  live elapsed timer. Tonal card fill + 1px border + ambient shadow (no Material lift); selected
//  → accent border + focus ring. Honors Reduce Transparency.
//

import SwiftUI

struct AgentCard: View {
    let session: SessionVM
    let selected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                agentChip
                Spacer()
                StatusPill(status: session.status)
            }
            Text(session.title)
                .font(theme.sectionTitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            HStack {
                if session.isRunning {
                    ProgressTrack()
                }
                Spacer()
                if session.isRunning {
                    MonoTimer(since: session.startedAt)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .stroke(selected ? theme.accent : theme.border, lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 10, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.agent): \(session.title)")
        .accessibilityValue(session.status.spoken)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var agentChip: some View {
        HStack(spacing: 5) {
            Circle().fill(theme.color(for: session.status)).frame(width: 7, height: 7)
            Text(session.agent).font(theme.mono).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.controlBg))
    }
}

/// A 3px indeterminate accent progress track (engine-side progress is deferred; this signals "running").
private struct ProgressTrack: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift = false

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(theme.accent.opacity(0.25))
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.accent)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: reduceMotion ? 0 : (shift ? geo.size.width * 0.6 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: shift)
                }
        }
        .frame(width: 120, height: 3)
        .onAppear { shift = true }
        .accessibilityHidden(true)
    }
}
