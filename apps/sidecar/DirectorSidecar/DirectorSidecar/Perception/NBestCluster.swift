// NBestCluster — coarse pointing region → ranked n-best window cluster (FR-4).
// Ported near-verbatim from trackall/packages/perception (RESEARCH_CONVERGENCE §7; MIGRATION §8 —
// "EVALUATE/PORT"). Adopted because our perception lacked the target-clustering step.
//
// ARCHITECTURE §5: the pointing n-best is a TARGET CLUSTER, not a pixel cursor. A screen-plane
// hit rarely lands on a single unambiguous window, so Pipeline B emits a ranked set of candidate
// windows (the cluster the user is "around"), which the aligner fuses with the deictic referent
// and the binder disambiguates.
//
// Ranking (deterministic — INV-14): a window that CONTAINS the hit, or whose frame is within
// `radius` of it, is a candidate. Confidence falls off with the distance from the hit to the
// window CENTER, normalized by the window's half-diagonal, so a hit dead-center scores ~1 and a
// hit at the far edge scores lower. Windows whose frame is farther than `radius` are excluded.
//
// Coordinates: the hit is a PixelPoint and window frames are CGGlobalRect; on the 2D path the
// calibration maps to backing-store pixels that coincide 1:1 with the CG-global point space used
// here (TECH_STACK §4) — no Y-flip is performed in this file (that one flip lives in Envelope).


/// Disambiguating re-export of the Envelope window reference. `Envelope.PerceptionWindowRef` collides with
/// the Carbon/HIToolbox `PerceptionWindowRef` that leaks in transitively wherever AppKit/XCTest is imported;
/// this module source imports only Envelope, so the alias resolves unambiguously and lets callers
/// (incl. the perception tests) name the type without fighting the collision.
typealias EnvelopePerceptionWindowRef = PerceptionWindowRef

/// Builds the ranked n-best window cluster for a pointing hit.
enum NBestCluster {

    /// Rank the windows in `screen` against a screen-plane `hit`.
    ///
    /// - Parameters:
    ///   - hit: the ray→screen-plane intersection in pixels.
    ///   - screen: the AX snapshot whose `windows` are the candidate set.
    ///   - radius: how far outside a window's frame the hit may fall and still count as "near"
    ///     (pixels). Defaults to a small reach.
    /// - Returns: candidates ranked by confidence descending; non-candidates dropped.
    static func rank(
        hit: PixelPoint,
        in screen: ScreenEvent,
        radius: Double = 24
    ) -> [WindowOrRegionRef] {
        let candidates: [WindowOrRegionRef] = screen.windows.compactMap { w in
            let frame = w.frame
            let edge = edgeDistance(hit: hit, frame: frame)
            guard edge <= radius else { return nil } // outside the reach → not in this cluster
            return WindowOrRegionRef(id: w.appBundleId, conf: confidence(hit: hit, frame: frame))
        }
        // Stable, deterministic ordering: confidence desc, then id for ties.
        return candidates.sorted { lhs, rhs in
            if lhs.conf != rhs.conf { return lhs.conf > rhs.conf }
            return lhs.id < rhs.id
        }
    }

    /// Distance from the hit to the nearest point of the frame (0 if inside).
    private static func edgeDistance(hit: PixelPoint, frame: CGGlobalRect) -> Double {
        let dx = max(frame.x - hit.x, 0, hit.x - (frame.x + frame.width))
        let dy = max(frame.y - hit.y, 0, hit.y - (frame.y + frame.height))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Calibrated confidence in (0,1]: 1 at the window center, decaying toward the edge by the
    /// center distance over the half-diagonal, floored just above 0 so a barely-overlapping
    /// window is still a (low-ranked) candidate.
    private static func confidence(hit: PixelPoint, frame: CGGlobalRect) -> Double {
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        let dx = hit.x - cx
        let dy = hit.y - cy
        let centerDist = (dx * dx + dy * dy).squareRoot()
        let halfDiag = (frame.width * frame.width + frame.height * frame.height).squareRoot() / 2
        guard halfDiag > 0 else { return 0.01 }
        let conf = 1 - centerDist / halfDiag
        return min(1, max(0.01, conf))
    }
}
