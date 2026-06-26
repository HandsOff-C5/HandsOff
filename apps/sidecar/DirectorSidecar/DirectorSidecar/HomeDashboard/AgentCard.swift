//
//  AgentCard.swift
//  DirectorSidecar
//
//  G4a: one supervised agent as a card — a large DirectorMark (same brand mark as the rail) that
//  doubles as a Pause/Play control on hover, beside its identity + title + status. No per-agent
//  waveform: listening is system-level, so the waveform lives by the toolbar's Activate control.
//  Tonal card fill + 1px border; selected → accent border. The mark + status are shared components.
//

import SwiftUI

struct AgentCard: View {
    let session: SessionVM
    let selected: Bool
    var paused: Bool = false
    var onTogglePause: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var iconHover = false

    /// Active agents (running or paused) can be paused/resumed from the mark; done agents can't.
    private var canControl: Bool { session.isRunning || paused }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            mark
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
                HStack(spacing: 10) {
                    if paused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(theme.kbd).foregroundStyle(theme.textTertiary)
                    }
                    Spacer()
                    if session.isRunning {
                        MonoTimer(since: session.startedAt)
                    }
                }
                .frame(minHeight: 14)
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
        .accessibilityValue(paused ? "paused" : session.status.spoken)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// The mark is a Pause/Play button for active agents (hover swaps the arrowhead for the control);
    /// done agents keep a plain mark so a card tap just selects.
    @ViewBuilder private var mark: some View {
        if canControl {
            Button(action: onTogglePause) { markVisual }
                .buttonStyle(.plain)
                .onHover { iconHover = $0 }
                .help(paused ? "Resume agent" : "Pause agent")
                .padding(.top, 2)
        } else {
            markVisual.padding(.top, 2)
        }
    }

    private var markVisual: some View {
        ZStack {
            DirectorMark(status: session.status, paused: paused, size: 50)
                .opacity(iconHover && canControl ? 0 : 1)
            if canControl {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.goldInk)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(theme.accent))
                    .opacity(iconHover ? 1 : 0)
            }
        }
        .frame(width: 50, height: 50)
        .contentShape(Circle())
    }

    private var agentChip: some View {
        Text(session.agent)
            .font(theme.mono).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(theme.controlBg))
    }
}
