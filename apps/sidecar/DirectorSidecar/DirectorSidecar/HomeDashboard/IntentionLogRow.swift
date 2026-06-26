//
//  IntentionLogRow.swift
//  DirectorSidecar
//
//  The "done" rows of the unified Home — the Intention Log (pillar 4, Accountable by design): one
//  past intention each = mono timestamp + what was said (transcript) + reference chips (the apps it
//  touched, words not logos). Compact rows that sit beneath the live agent cards.
//

import SwiftUI

struct IntentionLogRow: View {
    let entry: IntentionEntry
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.at, format: .dateTime.hour().minute())
                .font(theme.mono).foregroundStyle(theme.textTertiary)
                .frame(width: 58, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                Text(entry.transcript)
                    .font(theme.body).foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.references.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(entry.references, id: \.self) { ReferenceChip(label: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.transcript)
        .accessibilityValue(entry.references.isEmpty ? "" : "Referenced \(entry.references.joined(separator: ", "))")
    }
}

/// A reference chip — the app/service an intention touched. Word, not logo (e.g. "Slack", "Cursor").
struct ReferenceChip: View {
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .font(theme.kbd)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(theme.cardInset))
            .overlay(Capsule(style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
