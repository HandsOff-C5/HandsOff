//
//  GazeBracketLayer.swift
//  DirectorSidecar
//
//  G7: four gold corner brackets that morph (position + size) to the predicted referent region.
//  Drawn in G5's passthrough overlay window (top-left/y-down SwiftUI space == contract space, so
//  the region maps straight through). The .frame animates origin AND size toward the latest region
//  — the smoothing IS the wow factor (never snap, never jitter). Honors Reduce Motion/Transparency.
//

import SwiftUI

struct GazeBracketLayer: View {
    let model: GazeBracketModel
    /// The active display layout + which display THIS window covers (see ReticleOverlayView).
    /// Empty/`nil` → primary-only overlay (region positioned at its raw contract center). Multi-
    /// display: the region draws on the display containing its CENTER, in that display's local coords.
    var displays: [DisplayRect] = []
    var displayID: Int? = nil

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { _ in
            if let region = model.region, model.isVisible, let center = localCenter(region) {
                BracketFrame(dim: model.isDim)
                    .frame(width: region.w, height: region.h)
                    .position(center)
                    .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.3), value: region)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The region's center in THIS window's local coords, or `nil` when its center belongs to another
    /// display. A region is an indivisible unit (element-sized) — it draws on one display, not split.
    private func localCenter(_ region: GazeRegion) -> CGPoint? {
        let cx = region.x + region.w / 2
        let cy = region.y + region.h / 2
        guard let displayID, !displays.isEmpty else { return CGPoint(x: cx, y: cy) }
        guard let loc = DisplayGeometry.locate(cx, cy, in: displays), loc.displayID == displayID else { return nil }
        return CGPoint(x: loc.localX, y: loc.localY)
    }
}

/// Four corner brackets (no full border) — the only gold on screen at that moment.
private struct BracketFrame: View {
    let dim: Bool
    @Environment(\.theme) private var theme

    private let cornerLength: CGFloat = 16
    private let stroke: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                // top-left
                p.move(to: CGPoint(x: 0, y: cornerLength)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: cornerLength, y: 0))
                // top-right
                p.move(to: CGPoint(x: w - cornerLength, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: cornerLength))
                // bottom-right
                p.move(to: CGPoint(x: w, y: h - cornerLength)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - cornerLength, y: h))
                // bottom-left
                p.move(to: CGPoint(x: cornerLength, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - cornerLength))
            }
            .stroke(theme.accent.opacity(dim ? 0.5 : 1), style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        }
    }
}
