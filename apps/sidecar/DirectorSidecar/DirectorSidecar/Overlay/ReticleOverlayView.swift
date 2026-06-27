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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The active display layout in contract space + which display THIS window covers. Empty/`nil`
    /// is the single primary-only overlay (every cursor drawn at its raw contract point — the
    /// original G5 behavior). In the multi-display fold-in each window passes its own `displayID`
    /// so a cursor renders on exactly the display that owns it, in that display's LOCAL coords.
    var displays: [DisplayRect] = []
    var displayID: Int? = nil

    /// A friendly, critically-damped follow (heyClicky-style ease in/out): the rendered cursor
    /// trails the 60 Hz target instead of snapping, so movement glides and settles.
    private static let followEase = Animation.smooth(duration: 0.32)

    var body: some View {
        ZStack {
            ForEach(model.cursors) { cursor in
                let cp = OverlayModel.resolvedViewPoint(
                    for: cursor, systemCursorCocoa: model.systemCursor, primaryHeight: primaryHeight
                )
                if let pt = localPoint(cp) {
                    ReticleFollower(cursor: cursor)
                        .position(pt)
                        .animation(reduceMotion ? nil : Self.followEase, value: pt)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// Resolve a contract-space point to THIS window's local coords, or `nil` when the point belongs
    /// to a different display (so each cursor draws once). A point in the gap between monitors is
    /// clamped to the nearest display by `DisplayGeometry.locate` and draws there. Empty `displays`
    /// (or `nil` id) → primary-only fallback: pass the contract point straight through.
    private func localPoint(_ cp: CGPoint) -> CGPoint? {
        guard let displayID, !displays.isEmpty else { return cp }
        guard let loc = DisplayGeometry.locate(cp.x, cp.y, in: displays), loc.displayID == displayID else { return nil }
        return CGPoint(x: loc.localX, y: loc.localY)
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

/// The following cursor draws the shared `DirectorCursorGlyph` — the ONE brand cursor (gold
/// arrowhead, white keyline, soft shadow) the rail pips, dashboard cards, and app icon all use.
/// Always gold, never a tinted system pointer.
private struct CursorArrow: View {
    var body: some View {
        DirectorCursorGlyph(height: 23)
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
