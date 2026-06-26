//
//  AttentionRanking.swift
//  DirectorSidecar
//
//  The head-pointing attention-region ranker — the deferred PRODUCER of the
//  `Contracts.AttentionRegionCandidate` the contract port already modeled (Contracts/AttentionRegion.swift
//  notes "the head-track attention ranking (PORTING note 6, deferred) is their producer"). Recreated
//  in Swift from @handsoff/intent src/attention/candidates.ts AND the Rust head-track host that
//  actually emitted candidates (apps/desktop/src-tauri/src/commands/head_track/candidates.rs).
//
//  Given a head point (CoreGraphics global top-left px — the SAME space cua-driver reports window
//  bounds in; HeadGeometry.appKitToGlobalTopLeft put it there for exactly this) and the live window
//  list, rank the windows the point falls in/near so the resolver can target the window the user is
//  LOOKING at. Behavior is identical to candidates.ts/.rs: a `radius`-bounded neighborhood, a
//  `1 - distance/radius` score, and the score↓ → distance↑ → zIndex↓ → id↑ tie-break.
//

import Foundation

enum AttentionRanking {
    /// The head-neighborhood radius in px (`DEFAULT_HEAD_NEIGHBORHOOD_RADIUS` / Rust `DEFAULT_RADIUS`):
    /// a window whose nearest edge is farther than this from the head point is not a candidate.
    static let defaultRadius: Double = 240

    /// Rank `windows` against `point`, strongest-first. Mirrors `rankAttentionCandidates`: keep only
    /// rankable windows with measured bounds, score each by `1 - distance/radius`, drop anything past
    /// `radius`, then sort score↓, distance↑, zIndex↓, id↑. A non-positive `radius` ranks nothing.
    static func rank(
        point: HeadPoint,
        windows: [CuaWindow],
        radius: Double = defaultRadius
    ) -> [Contracts.AttentionRegionCandidate] {
        guard radius > 0 else { return [] }
        let ranked: [(candidate: Contracts.AttentionRegionCandidate, zIndex: Int)] = windows.compactMap { window in
            guard let bounds = window.bounds, isRankable(window, bounds) else { return nil }
            let distance = round3(distanceToBounds(point, bounds))
            guard distance <= radius else { return nil }
            let candidate = Contracts.AttentionRegionCandidate(
                surface: window.surface,
                score: round3(1 - distance / radius),
                distance: distance)
            return (candidate, window.zIndex)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.candidate.score != rhs.candidate.score { return lhs.candidate.score > rhs.candidate.score }
                if lhs.candidate.distance != rhs.candidate.distance { return lhs.candidate.distance < rhs.candidate.distance }
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex > rhs.zIndex }
                return lhs.candidate.surface.id < rhs.candidate.surface.id
            }
            .map(\.candidate)
    }

    /// A window can host a candidate only when it is on-screen, AX-readable, not the cua-driver's own
    /// overlay, and has measured non-empty bounds — the exact `isRankable` gate (TS folds the
    /// cua-driver exclusion into `isRankable`; the Rust folds it into the driver→window mapping).
    private static func isRankable(_ window: CuaWindow, _ bounds: CuaWindowBounds) -> Bool {
        window.availability == .available
            && window.accessStatus == .accessible
            && !window.app.lowercased().contains("cua driver")
            && bounds.width > 0
            && bounds.height > 0
    }

    /// Euclidean distance from the point to the nearest point of the bounds rect — 0 when the point is
    /// inside. `distanceToBounds`: clamp the point into the rect, then hypot to the clamped point.
    private static func distanceToBounds(_ point: HeadPoint, _ bounds: CuaWindowBounds) -> Double {
        let nearestX = clamp(point.x, bounds.x, bounds.x + bounds.width)
        let nearestY = clamp(point.y, bounds.y, bounds.y + bounds.height)
        return hypot(point.x - nearestX, point.y - nearestY)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    /// Round to 3 decimals — the wire precision the TS/Rust rankers used, so a Swift candidate's
    /// score/distance match the originals on the same inputs.
    private static func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
