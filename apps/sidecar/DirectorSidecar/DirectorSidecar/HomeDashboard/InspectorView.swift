//
//  InspectorView.swift
//  DirectorSidecar
//
//  G4b Inspector — the trust anchor. A trailing panel bound to the selected session's intent:
//  status + risk, context anchors, the proposed plan (steps tagged READ/WRITE/EXEC), a mutation
//  preview, and a PINNED footer (Greenlight/Reject) that never scrolls away — shown ONLY for a
//  ready destructive plan (revised Greenlight policy). Non-destructive plans show no footer.
//

import SwiftUI

struct InspectorView: View {
    @Bindable var model: HomeDashboardModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(theme.windowPadding) }
            if model.showInspectorFooter { footer }
        }
        .frame(minWidth: 280)
        .background(theme.card)
    }

    @ViewBuilder private var content: some View {
        switch model.inspectorState {
        case .empty:
            ContentUnavailableView("No selection", systemImage: "sidebar.right",
                                   description: Text("Select an agent to inspect its plan."))
        case let .ready(intent):
            ReadyInspector(intent: intent)
        case let .blocked(reason):
            ContentUnavailableView("Blocked", systemImage: "exclamationmark.octagon", description: Text(reason))
        case let .clarification(reason):
            ContentUnavailableView("Needs clarification", systemImage: "questionmark.circle", description: Text(reason))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Dismiss") { model.reject() }
                .buttonStyle(DirectorButtonStyle(kind: .secondary))
                .keyboardShortcut(.delete, modifiers: .command)
                .accessibilityHint("Rejects and dismisses")
            Button { model.greenlight() } label: { Label("Greenlight", systemImage: "checkmark.circle.fill") }
                .buttonStyle(DirectorButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHint("Approves the proposed plan")
        }
        .padding(theme.windowPadding)
        .background(theme.card)
        .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .top)
        .accessibilitySortPriority(-1) // footer reads last
    }
}

private struct ReadyInspector: View {
    let intent: ResolvedIntentLite
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let summary = intent.summary {
                    Text(summary).font(theme.sectionTitle).foregroundStyle(theme.textPrimary)
                }
                Spacer()
                if let risk = intent.riskLevel { RiskTag(level: risk) }
            }

            if !intent.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Proposed Plan")
                    ForEach(Array(intent.steps.enumerated()), id: \.element.id) { index, step in
                        PlanStepRow(index: index + 1, step: step)
                    }
                }
            }

            let mutations = intent.steps.filter { $0.proposed != nil }
            if !mutations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Mutation Preview")
                    MutationPreview(steps: mutations)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlanStepRow: View {
    let index: Int
    let step: ActionStepLite
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)").font(theme.mono).foregroundStyle(theme.textTertiary).frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.label).font(theme.body).foregroundStyle(theme.textPrimary)
                if let target = step.targetTitle {
                    Text(target).font(theme.kbd).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            CapabilityTagBadge(tag: step.tag)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index): \(step.label), \(step.tag.rawValue)")
    }
}

private struct CapabilityTagBadge: View {
    let tag: CapabilityTag
    @Environment(\.theme) private var theme

    var body: some View {
        Text(tag.rawValue)
            .font(theme.kbd)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: theme.radiusChip, style: .continuous).fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch tag {
        case .read: return theme.textSecondary
        case .write: return theme.warning
        case .exec: return theme.danger
        }
    }
}

/// Proposed-only mutation preview (the contract has no prior value — see G4 #1 data-plane blocker).
private struct MutationPreview: View {
    let steps: [ActionStepLite]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps) { step in
                if let proposed = step.proposed {
                    Text("+ \(proposed)")
                        .font(theme.mono)
                        .foregroundStyle(theme.success)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.success.opacity(0.12))
                }
            }
            Text("previous value unavailable")
                .font(theme.kbd).foregroundStyle(theme.textTertiary)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusChip, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mutation preview, proposed changes")
    }
}
