//
//  HeadGeometry.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/Geometry.swift (ADR 0005 step 5). The standalone
//  sidecar declared these as top-level free functions (`clamp`, `center`, `distance`, …); inside the
//  app module those generic names would pollute — and risk colliding with — the global namespace, so
//  they are namespaced here as static members, matching the app's `ScreenGeometry` / `CuaWire`
//  convention. Pure, queue-agnostic math: callable from the camera's video queue or a unit test.
//
//  Coordinate spaces in play (see `appKitToGlobalTopLeft`):
//   - AppKit / NSScreen: bottom-left origin, y grows UP. The golden overlay panel lives here.
//   - CoreGraphics global / contract `cursorPosition`: top-left origin, y grows DOWN. The emitted
//     head point lives here, sharing cua-driver's window-bounds space (see ScreenGeometry.swift —
//     the SAME primary-height flip the bridge cursorPosition path uses).
//

import CoreGraphics

enum HeadGeometry {
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    static func squaredDistance(_ point: CGPoint, to rect: CGRect) -> Double {
        let x = clamp(point.x, rect.minX...rect.maxX)
        let y = clamp(point.y, rect.minY...rect.maxY)
        let dx = point.x - x
        let dy = point.y - y
        return dx * dx + dy * dy
    }

    static func clampIntoRealScreen(_ point: CGPoint, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return point }
        if screens.contains(where: { containsInclusive($0, point) }) {
            return point
        }
        let nearest = screens.min { squaredDistance(point, to: $0) < squaredDistance(point, to: $1) }!
        return CGPoint(
            x: clamp(point.x, nearest.minX...nearest.maxX),
            y: clamp(point.y, nearest.minY...nearest.maxY)
        )
    }

    static func unionRect(_ screens: [CGRect]) -> CGRect? {
        screens.reduce(nil as CGRect?) { partial, rect in
            guard let partial else { return rect }
            return partial.union(rect)
        }
    }

    static func defaultPointerPoint(screens: [CGRect]) -> CGPoint? {
        guard let union = unionRect(screens), union.width > 0, union.height > 0 else {
            return nil
        }
        return clampIntoRealScreen(CGPoint(x: union.midX, y: union.midY), screens: screens)
    }

    static func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    static func blend(_ a: CGPoint, _ b: CGPoint, alpha: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
    }

    static func blendOptional(_ previous: Double?, _ raw: Double?, alpha: Double) -> Double? {
        guard let raw else { return previous }
        guard let previous else { return raw }
        return previous + (raw - previous) * alpha
    }

    static func centroid(_ points: [CGPoint]?) -> CGPoint? {
        guard let points, !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
    }

    static func area(_ rect: CGRect) -> Double {
        max(0, rect.width) * max(0, rect.height)
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        let union = area(a) + area(b) - area(intersection)
        guard union > 0 else { return 0 }
        return area(intersection) / union
    }

    // The head point is computed in AppKit global coordinates (bottom-left origin,
    // y increasing upward) so the golden overlay — an NSPanel positioned with
    // `setFrame` — lands where the user is looking. But cua-driver reports window
    // bounds in CoreGraphics global display coordinates (top-left origin, y
    // increasing downward). Attention-region ranking compares the emitted point
    // against those window bounds, so the point must be flipped into the same
    // top-left space first. Without this, a point near the visual top of the screen
    // (large AppKit y) is compared against top-edge windows (small CG y), landing a
    // full screen-height away and falling outside the neighborhood radius — every
    // window is rejected and the intent engine sees zero candidates.
    //
    // The flip is about the PRIMARY display's height: both systems share the x axis
    // and the origin column, and differ only by `cg.y = primaryHeight - appKit.y`.
    // That formula holds for points on secondary displays too (a display above the
    // primary yields a negative CG y, matching CoreGraphics global coordinates).
    //
    // This is the SAME flip as ScreenGeometry.cocoaPoint (in reverse): the emitted
    // head point is therefore already in the bridge `cursorPosition` contract space.
    static func appKitToGlobalTopLeft(_ point: CGPoint, screens: [CGRect]) -> CGPoint {
        let primaryHeight =
            screens.first(where: { $0.origin == .zero })?.height ?? screens.first?.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
