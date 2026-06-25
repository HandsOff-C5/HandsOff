import AppKit
import CoreGraphics
import Foundation

// A display rect in CoreGraphics global coordinates: origin at the top-left of the
// primary display, x growing right, y growing DOWN. A monitor to the left/above the
// primary therefore has a negative x and/or y. This is the same space the calibrated
// pointing coordinates live in, so a cursor point can be resolved to a display + a
// top-left-origin local offset without any per-axis flips.
struct DisplayRect {
    let id: Int        // CGDirectDisplayID — the join key to the per-display window.
    let isMain: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// Enumerate the active displays via CoreGraphics in global (top-left origin) coordinates.
// The authoritative layout: both the per-display windows and the host's calibration grid are
// derived from this, so the space a cursor point lives in is the same space the targets are
// generated in. Returns the main display first (CGMainDisplayID) so callers have a stable
// fallback when no target display is specified.
func enumerateDisplays() -> [DisplayRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let main = CGMainDisplayID()
    return ids.map { id in
        let bounds = CGDisplayBounds(id)
        return DisplayRect(
            id: Int(id),
            isMain: id == main,
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.size.width,
            height: bounds.size.height
        )
    }
}

// Half-open containment: a point on a shared edge belongs to exactly one display, so a
// cursor crossing a monitor boundary never lands ambiguously on two windows at once.
extension DisplayRect {
    func contains(_ gx: Double, _ gy: Double) -> Bool {
        gx >= x && gx < x + width && gy >= y && gy < y + height
    }

    func squaredDistance(_ gx: Double, _ gy: Double) -> Double {
        let cx = min(max(gx, x), x + width)
        let cy = min(max(gy, y), y + height)
        let dx = gx - cx
        let dy = gy - cy
        return dx * dx + dy * dy
    }
}

// Where a global point lands: the display that contains it, or — for a point in the gap
// between displays — the nearest display, clamped to its bounds. Returns the display id
// plus a top-left-origin local offset ready to draw in a flipped per-display view. Nil
// only when there are no displays.
struct OverlayLocation {
    let displayID: Int
    let localX: Double
    let localY: Double
}

func locate(_ gx: Double, _ gy: Double, displays: [DisplayRect]) -> OverlayLocation? {
    if let owned = displays.first(where: { $0.contains(gx, gy) }) {
        return OverlayLocation(displayID: owned.id, localX: gx - owned.x, localY: gy - owned.y)
    }
    guard let nearest = displays.min(by: { $0.squaredDistance(gx, gy) < $1.squaredDistance(gx, gy) }) else {
        return nil
    }
    let cx = min(max(gx, nearest.x), nearest.x + nearest.width)
    let cy = min(max(gy, nearest.y), nearest.y + nearest.height)
    return OverlayLocation(displayID: nearest.id, localX: cx - nearest.x, localY: cy - nearest.y)
}
