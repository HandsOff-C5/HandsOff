//
//  DisplayGeometry.swift
//  DirectorSidecar
//
//  Multi-display overlay geometry, folded in from the gesture-overlay sidecar
//  (src-tauri/sidecars/gesture-overlay/OverlayGeometry.swift). PURE + LLM-loop-independent:
//  it resolves a contract-space point (virtual-desktop px, top-left origin, y-DOWN — the same
//  space `cursorPosition`/`gazeFocus` publish) to the display that should draw it plus a
//  top-left-origin LOCAL offset inside that display's overlay window. This is what lets the
//  cursor render on a SECONDARY monitor instead of being clamped to the primary screen.
//
//  Why this is separate from ScreenGeometry (the contract→Cocoa y-flip): that flip turns a
//  point into AppKit window coordinates; THIS resolves which display owns the point and where
//  it lands inside that display, across gaps and negative offsets. Both are load-bearing and
//  both are pure (unit-tested without a live display, via synthetic `DisplayRect`s).
//

import CoreGraphics

/// A display rect in contract / CoreGraphics GLOBAL coordinates: origin at the top-left of the
/// primary display, x growing right, y growing DOWN. A monitor to the left/above the primary has a
/// negative x and/or y. This is the SAME space the published pointing coordinates live in, so a
/// point resolves to a display + a top-left-origin local offset with no per-axis flips.
struct DisplayRect: Equatable, Sendable {
    /// `CGDirectDisplayID` widened to `Int` — the join key to the per-display overlay window.
    /// (Kept `Int`, not `CGDirectDisplayID`/`UInt32`, so it round-trips through JSON/tests cleanly
    /// and matches the sidecar's wire shape.)
    let id: Int
    let isMain: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

extension DisplayRect {
    /// Half-open containment: a point on a shared edge belongs to exactly ONE display, so a cursor
    /// crossing a monitor boundary never lands ambiguously on two windows at once.
    func contains(_ gx: Double, _ gy: Double) -> Bool {
        gx >= x && gx < x + width && gy >= y && gy < y + height
    }

    /// Squared distance from a point to this rect (0 when inside). Used to pick the NEAREST display
    /// for a point that falls in the gap between monitors. Squared avoids a needless sqrt.
    func squaredDistance(_ gx: Double, _ gy: Double) -> Double {
        let cx = min(max(gx, x), x + width)
        let cy = min(max(gy, y), y + height)
        let dx = gx - cx
        let dy = gy - cy
        return dx * dx + dy * dy
    }
}

/// Where a global point lands: the display that should draw it, plus a top-left-origin LOCAL offset
/// ready to position inside that display's overlay window. `nil` only when there are no displays.
struct OverlayLocation: Equatable, Sendable {
    let displayID: Int
    let localX: Double
    let localY: Double
}

enum DisplayGeometry {
    /// Enumerate the active displays via CoreGraphics in contract (top-left origin) coordinates.
    /// Authoritative layout: the per-display overlay windows are derived from this, so the space a
    /// cursor point lives in is the same space the windows are built from. Main display first
    /// (CGMainDisplayID) so callers have a stable fallback.
    ///
    /// CoreGraphics-backed → not exercised by unit tests (no live display in CI). The geometry that
    /// IS tested — `locate`, `contains`, `squaredDistance` — operates on plain `[DisplayRect]`.
    static func activeDisplays() -> [DisplayRect] {
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

    /// Resolve a contract-space global point to the owning display + a top-left-origin local offset.
    /// A point inside a display maps straight through; a point in the GAP between displays resolves
    /// to the nearest display, clamped to its bounds (so a cursor in dead space still draws on the
    /// closest screen rather than vanishing). `nil` only when `displays` is empty.
    static func locate(_ gx: Double, _ gy: Double, in displays: [DisplayRect]) -> OverlayLocation? {
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
}
