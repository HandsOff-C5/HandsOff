//
//  DisplayArbitration.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/display/arbitration.ts (A3) — which-display arbitration. Given
//  a calibrated screen-space point (global virtual-desktop px; x may be negative) and the
//  attached displays, decide which display the user is pointing at. Pure geometry: the OS
//  supplies the display rects keyed by the stable CGDisplay UUID.
//

import Foundation

struct Display: Equatable, Sendable, Identifiable {
    /// Stable identifier — CGDisplayCreateUUIDFromDisplayID, persistent across reconnects.
    let id: String
    /// Display rect in the same global virtual-desktop space as the calibration output.
    let bounds: Contracts.SurfaceBounds
}

enum DisplayArbitration {
    /// Is the point inside the rect grown by `margin` on every side?
    private static func insideExpanded(_ point: Vec2, _ b: Contracts.SurfaceBounds, _ margin: Double) -> Bool {
        point.x >= b.x - margin && point.x <= b.x + b.w + margin
            && point.y >= b.y - margin && point.y <= b.y + b.h + margin
    }

    /// Pick the display the point belongs to. With a `currentId` and a positive `marginPx`, the
    /// choice is sticky: the point must leave the current display's bounds by more than the
    /// margin before arbitration switches (no seam flicker). Otherwise the containing display,
    /// falling back to the nearest across a gap. Nil only if there are no displays.
    static func pickDisplay(
        _ point: Vec2,
        _ displays: [Display],
        currentId: String? = nil,
        marginPx: Double = 0
    ) -> String? {
        // Hysteresis: hold the current display until the point clears its bounds + margin.
        if let currentId, let current = displays.first(where: { $0.id == currentId }),
           insideExpanded(point, current.bounds, marginPx) {
            return current.id
        }
        // Otherwise the containing display, or the nearest one across a gap.
        var best: Display?
        var bestDist = Double.infinity
        for display in displays {
            let dist = display.bounds.distance(to: point)
            if dist < bestDist {
                best = display
                bestDist = dist
            }
        }
        return best?.id
    }
}
