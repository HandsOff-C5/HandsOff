//
//  ListeningHUDView.swift
//  DirectorSidecar
//
//  G2a: the read-only Listening HUD — four zones filled live from the bridge (header + waveform +
//  StopControl, transcript, referent chips, intent+risk). Non-destructive intents auto-run and
//  show NO footer; the commit-to-execute + optional destructive Greenlight footer arrives in G2b.
//  Glass → opaque under Reduce Transparency; pulse/caret honor Reduce Motion.
//

import SwiftUI

struct ListeningHUDView: View {
    let model: HUDModel

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDHeader(model: model)

            if let transcript = model.transcript {
                TranscriptView(transcript: transcript)
            }

            if !model.referents.isEmpty {
                ReferentChipRow(surfaces: model.referents, selectedId: model.selectedReferent?.id)
            }

            if let intent = model.intent, intent.status == .ready {
                IntentRiskLine(intent: intent)
            } else if let intent = model.intent, let reason = intent.reason {
                Text(reason).font(theme.body).foregroundStyle(theme.textSecondary)
            }

            if model.phase == .complete {
                Label("Task complete", systemImage: "checkmark.circle.fill")
                    .font(theme.body).foregroundStyle(theme.success)
            }

            // Optional footer — shown ONLY for a ready destructive intent (revised Greenlight
            // policy). Everything else auto-runs on fn-end commit with no footer.
            if model.showFooter {
                FooterRow(onDismiss: { model.reject() }, onGreenlight: { model.greenlight() })
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusWindow, style: .continuous))
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            theme.opaqueSurface
        } else {
            VisualEffectBlur(.hudWindow, blending: .withinWindow)
        }
    }
}

/// LISTENING dot + label + waveform + StopControl (always visible while active).
private struct HUDHeader: View {
    let model: HUDModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            MicListeningDot()
            Text("LISTENING")
                .font(theme.sectionLabel).tracking(0.55)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Waveform()
            StopControl { model.cancel() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening")
        .accessibilityValue(model.transcript?.text ?? "")
    }
}

/// Gentle pulsing gold dot (Reduce Motion → static).
private struct MicListeningDot: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(theme.accent)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing && !reduceMotion ? 1.25 : 1)
            .opacity(pulsing && !reduceMotion ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// A small 5-bar waveform; animates with TimelineView, flat under Reduce Motion.
private struct Waveform: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            bars(amplitudes: [0.4, 0.4, 0.4, 0.4, 0.4])
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                bars(amplitudes: (0..<5).map { i in 0.3 + 0.7 * abs(sin(t * 3 + Double(i) * 0.7)) })
            }
        }
    }

    private func bars(amplitudes: [Double]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(amplitudes.enumerated()), id: \.offset) { _, a in
                Capsule().fill(theme.accent)
                    .frame(width: 2.5, height: 4 + 12 * a)
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

/// CANCEL/abort — sends stopListening (stop the mic, do NOT execute). Distinct from fn-end commit.
private struct StopControl: View {
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                KbdHint("esc")
            }
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(hovering ? theme.controlBg : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Stop listening")
        .accessibilityAddTraits(.isButton)
    }
}

private struct TranscriptView: View {
    let transcript: TranscriptEvent
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretOn = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(transcript.text)
                .font(.system(size: 13).italic())
                .foregroundStyle(transcript.isLowConfidence ? theme.textSecondary : theme.textPrimary)
            if transcript.isPartial {
                Rectangle().fill(theme.accent).frame(width: 2, height: 14)
                    .opacity(reduceMotion ? 1 : (caretOn ? 1 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(), value: caretOn)
                    .onAppear { caretOn.toggle() }
            }
        }
        .accessibilityLabel("Transcript")
        .accessibilityValue(transcript.text)
    }
}

private struct ReferentChipRow: View {
    let surfaces: [SurfaceSnapshot]
    let selectedId: String?
    @Environment(\.theme) private var theme

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(surfaces) { surface in
                ReferentChip(title: surface.title, app: surface.app, selected: surface.id == selectedId)
            }
        }
    }
}

/// Destructive-only approval footer: Dismiss (reject) + Greenlight (approve). Keyboard
/// equivalents ⌘⌫ / ⌘↩ are specified for the bundled app (the panel is non-key in dev).
private struct FooterRow: View {
    let onDismiss: () -> Void
    let onGreenlight: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(DirectorButtonStyle(kind: .secondary))
                .accessibilityHint("Rejects and dismisses")
            Button(action: onGreenlight) {
                Label("Greenlight", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(DirectorButtonStyle(kind: .primary))
            .accessibilityHint("Approves the proposed plan")
        }
    }
}

private struct IntentRiskLine: View {
    let intent: ResolvedIntentLite
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("Intent: \(intent.summary ?? intent.intentType ?? "ready")")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Spacer()
            if let risk = intent.riskLevel {
                RiskTag(level: risk)
            }
        }
    }
}

/// Minimal flow layout that wraps chips to the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight: CGFloat = y + rowHeight
        let resolvedWidth: CGFloat = proposal.width ?? x
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
