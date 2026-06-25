//
//  ReticleOverlayView.swift
//  DirectorSidecar
//
//  G5 cursor visuals: per cursor, an expanding lock ring (locked only), the gold Director
//  arrowhead (always gold — never recolored per status; completion is the poof), and an agent
//  name pill. Honors Reduce Motion (instant, no ring/poof) + Reduce Transparency (opaque pill).
//

import SwiftUI

struct ReticleOverlayView: View {
    let model: OverlayModel
    let primaryHeight: CGFloat

    var body: some View {
        ZStack {
            ForEach(model.cursors) { cursor in
                ReticleFollower(cursor: cursor)
                    .position(OverlayModel.resolvedViewPoint(
                        for: cursor, systemCursorCocoa: model.systemCursor, primaryHeight: primaryHeight
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct ReticleFollower: View {
    let cursor: DirectorCursor
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringExpanded = false

    var body: some View {
        ZStack {
            if cursor.state == .locked {
                Circle()
                    .stroke(theme.accent, lineWidth: 2)
                    .frame(width: 26, height: 26)
                    .scaleEffect(reduceMotion ? 1 : (ringExpanded ? 1.6 : 1))
                    .opacity(reduceMotion ? 0.7 : (ringExpanded ? 0 : 0.9))
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.8).repeatForever(autoreverses: false), value: ringExpanded)
                    .onAppear { ringExpanded = true }
            }
            CursorArrow()
                .opacity(cursor.state == .poof ? 0 : 1)
                .blur(radius: cursor.state == .poof && !reduceMotion ? 8 : 0)
                .scaleEffect(cursor.state == .poof && !reduceMotion ? 1.5 : 1)
                .animation(reduceMotion ? nil : theme.standardMotion, value: cursor.state)
            if let label = cursor.label {
                AgentPill(label: label)
                    .offset(x: 22, y: 18)
            }
        }
        .accessibilityHidden(true) // overlay is decorative; announcements posted separately
    }
}

/// The gold Director arrowhead — gold fill + white keyline + soft shadow. Always gold.
private struct CursorArrow: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ArrowShape()
            .fill(theme.accent)
            .overlay(ArrowShape().stroke(.white, lineWidth: 1.33))
            .frame(width: 18, height: 24)
            .shadow(color: .black.opacity(0.4), radius: 0.84, y: 1.17)
    }
}

/// A classic pointer arrowhead, tip at the top-left.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                    // tip
        p.addLine(to: CGPoint(x: 0, y: h * 0.78))
        p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.60))
        p.addLine(to: CGPoint(x: w * 0.52, y: h))         // tail notch
        p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.92))
        p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.52))
        p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.50))
        p.closeSubpath()
        return p
    }
}

private struct AgentPill: View {
    let label: String
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.white)
                .frame(width: 5, height: 5)
                .opacity(pulse && !reduceMotion ? 0.5 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text(label).font(theme.mono).foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            Capsule().fill(reduceTransparency ? theme.opaqueSurface : theme.card)
                .overlay(Capsule().stroke(theme.border, lineWidth: 1))
        )
        .onAppear { pulse = true }
    }
}
