//
//  HomeFeedView.swift
//  DirectorSidecar
//
//  The Home tab — the Intention Log (pillar 4, Accountable by design): a reverse-chronological feed
//  of executed intentions. Each row is what the user said (transcript) with the apps/services it
//  touched as reference chips. Wispr-Flow-style history; native List treatment, no custom chrome.
//

import SwiftUI

struct HomeFeedView: View {
    let entries: [IntentionEntry]
    @Environment(\.theme) private var theme

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("Nothing yet today", systemImage: "waveform",
                                   description: Text("Activate Director and speak — your intentions land here."))
        } else {
            List {
                Section {
                    ForEach(entries) { IntentionRow(entry: $0) }
                } header: {
                    Text("Today")
                        .font(theme.sectionLabel).textCase(.uppercase).tracking(0.6)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Home")
        }
    }
}

/// One executed intention: a mono timestamp, the spoken transcript, and reference chips.
private struct IntentionRow: View {
    let entry: IntentionEntry
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(entry.at, format: .dateTime.hour().minute())
                .font(theme.mono).foregroundStyle(theme.textTertiary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
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
        .padding(.vertical, 8)
        .listRowSeparator(.visible)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.transcript)
        .accessibilityValue(entry.references.isEmpty ? "" : "References \(entry.references.joined(separator: ", "))")
    }
}

/// A reference chip — the app/service an intention touched. Word, not logo (e.g. "Slack", "Cursor").
private struct ReferenceChip: View {
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
