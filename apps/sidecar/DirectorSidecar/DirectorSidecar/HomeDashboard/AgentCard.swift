//
//  AgentCard.swift
//  DirectorSidecar
//
//  G4a: one supervised agent as a card — a large DirectorMark (the same status-tinted brand mark as
//  the rail, scaled up) beside its identity + title + status, with the listening waveform as the
//  "working" pulse. Tonal card fill + 1px border + ambient shadow; selected → accent border. Honors
//  Reduce Transparency. The mark + waveform are the shared Theme/DirectorMark components.
//

import SwiftUI

struct AgentCard: View {
    let session: SessionVM
    let selected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DirectorMark(status: session.status, size: 50)
                .padding(.top, 2)

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
                    if session.isRunning {
                        ListeningWaveform(maxHeight: 14, minHeight: 5)
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
        .accessibilityValue(session.status.spoken)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var agentChip: some View {
        Text(session.agent)
            .font(theme.mono).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(theme.controlBg))
    }
}
