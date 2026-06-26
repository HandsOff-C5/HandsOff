//
//  IntentionLogView.swift
//  DirectorSidecar
//
//  H4 — the Intention Log made visible. The "Agent Logs" sidebar view renders the live `audit`
//  topic: one row per recorded supervision event, with the per-call `tool_call` rows surfacing the
//  derived risk, approval gate, and result as first-class colored chips (color is never the only
//  signal — the summary line carries the same facts in text). This is the audit UI that reflects
//  execution: every tool call, its risk, whether it auto-ran / was approved / rejected, and how it
//  resolved. Replaces the deferred "Coming soon" placeholder.
//

import SwiftUI

struct IntentionLogView: View {
    let entries: [AuditLogEntry]
    @Environment(\.theme) private var theme

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No activity yet", systemImage: "list.bullet.rectangle",
                description: Text("Tool calls appear here as the agent acts."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.elementGap) {
                    SectionLabel("Intention Log · \(entries.count)")
                    ForEach(entries) { entry in
                        AuditRow(entry: entry)
                    }
                }
                .padding(theme.windowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One Intention Log row: a kind-colored rail + timestamp, the summary line, and (for `tool_call`)
/// the risk / approval / result chips the audit surface exists to show.
private struct AuditRow: View {
    let entry: AuditLogEntry
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.clock(entry.recordedAt))
                .font(theme.mono).monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.summary)
                    .font(theme.body).foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.kind == .toolCall {
                    HStack(spacing: 6) {
                        if let risk = entry.risk { RiskTag(level: risk) }
                        if let approval = entry.approval { ApprovalBadge(approval: approval) }
                        if let result = entry.result { ResultBadge(result: result) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous).fill(theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .stroke(theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.summary)
    }

    /// Local time-of-day from the ISO-8601 `recordedAt`; falls back to the raw string if unparseable.
    static func clock(_ iso: String) -> String {
        guard let date = BridgeStore.parseISO(iso) else { return iso }
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// How the call was gated — `approved`→success, `rejected`→danger, `auto`→muted.
private struct ApprovalBadge: View {
    let approval: AuditLogEntry.Approval
    @Environment(\.theme) private var theme

    var body: some View {
        Text(approval.rawValue.uppercased())
            .font(theme.kbd)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: theme.radiusChip, style: .continuous)
                .fill(color.opacity(0.14)))
            .accessibilityLabel("Approval")
            .accessibilityValue(approval.rawValue)
    }

    private var color: Color {
        switch approval {
        case .auto: return theme.textSecondary
        case .approved: return theme.success
        case .rejected: return theme.danger
        }
    }
}

/// How the call resolved — `succeeded`→success, `failed`→danger, `blocked`→warning.
private struct ResultBadge: View {
    let result: AuditLogEntry.ResultStatus
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(theme.kbd).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(theme.controlBg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Result")
        .accessibilityValue(label)
    }

    private var label: String {
        switch result {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .blocked: return "blocked"
        }
    }

    private var color: Color {
        switch result {
        case .succeeded: return theme.success
        case .failed: return theme.danger
        case .blocked: return theme.warning
        }
    }
}
