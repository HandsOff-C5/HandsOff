//
//  Calibration.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/calibration/calibrate.ts (#26) — raw pointing signal → screen
//  px → surface candidate. Pure math; no camera, no clock. Affine is the starting model
//  (scale/rotation/shear/translation, ≥3 correspondences); homography (≥4) is the documented
//  perspective upgrade for off-axis displays.
//

import Foundation

/// Affine map [x,y] → [a·x + b·y + c, d·x + e·y + f]. 6 DOF; needs ≥3 correspondences.
struct CalibrationAffine: Equatable, Sendable {
    let a, b, c, d, e, f: Double
}

/// One calibration correspondence: a raw signal observed while pointing at a known target.
struct CalibrationPair: Equatable, Sendable {
    let raw: Vec2
    let target: Vec2
}

/// 3×3 projective homography, row-major [h0..h8]. h8 is pinned to 1 (defined up to scale).
struct Homography: Equatable, Sendable {
    let values: [Double]
    subscript(_ i: Int) -> Double { values[i] }
}

enum GestureCalibration {
    static func applyTransform(_ t: CalibrationAffine, _ p: Vec2) -> Vec2 {
        Vec2(t.a * p.x + t.b * p.y + t.c, t.d * p.x + t.e * p.y + t.f)
    }

    /// Solve the symmetric 3×3 system S·p = v (S by its distinct entries) via the cofactor
    /// inverse. Throws on a singular system (collinear/degenerate points).
    private static func solveSym3(
        _ s00: Double, _ s01: Double, _ s02: Double,
        _ s11: Double, _ s12: Double, _ s22: Double,
        _ v0: Double, _ v1: Double, _ v2: Double
    ) throws -> (Double, Double, Double) {
        let c00 = s11 * s22 - s12 * s12
        let c01 = s12 * s02 - s01 * s22
        let c02 = s01 * s12 - s11 * s02
        let det = s00 * c00 + s01 * c01 + s02 * c02
        if abs(det) < 1e-12 {
            throw GestureContractError.outOfRange("calibration: singular system (collinear or degenerate points)")
        }
        let c11 = s00 * s22 - s02 * s02
        let c12 = s02 * s01 - s00 * s12
        let c22 = s00 * s11 - s01 * s01
        return (
            (c00 * v0 + c01 * v1 + c02 * v2) / det,
            (c01 * v0 + c11 * v1 + c12 * v2) / det,
            (c02 * v0 + c12 * v1 + c22 * v2) / det
        )
    }

    /// Least-squares affine fit via the normal equations. x' and y' share the design matrix A
    /// (rows [x, y, 1]); build the symmetric AᵀA once and solve against the two RHS.
    static func fitAffine(_ pairs: [CalibrationPair]) throws -> CalibrationAffine {
        guard pairs.count >= 3 else {
            throw GestureContractError.outOfRange("fitAffine: need ≥3 correspondences for an affine fit, got \(pairs.count)")
        }
        var sxx = 0.0, sxy = 0.0, sx = 0.0, syy = 0.0, sy = 0.0
        let n = Double(pairs.count)
        var txx = 0.0, txy = 0.0, tx = 0.0 // Aᵀ·X'
        var tyx = 0.0, tyy = 0.0, ty = 0.0 // Aᵀ·Y'
        for pair in pairs {
            let x = pair.raw.x, y = pair.raw.y
            let X = pair.target.x, Y = pair.target.y
            sxx += x * x; sxy += x * y; sx += x; syy += y * y; sy += y
            txx += x * X; txy += y * X; tx += X
            tyx += x * Y; tyy += y * Y; ty += Y
        }
        let (a, b, c) = try solveSym3(sxx, sxy, sx, syy, sy, n, txx, txy, tx)
        let (d, e, f) = try solveSym3(sxx, sxy, sx, syy, sy, n, tyx, tyy, ty)
        return CalibrationAffine(a: a, b: b, c: c, d: d, e: e, f: f)
    }

    static func applyHomography(_ h: Homography, _ p: Vec2) -> Vec2 {
        let w = h[6] * p.x + h[7] * p.y + h[8]
        return Vec2((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }

    /// Solve the n×n linear system M·x = b by Gauss-Jordan elimination with partial pivoting.
    /// `m` is a flat row-major n×n matrix; throws on a singular system.
    private static func solveLinear(_ m: [Double], _ b: [Double]) throws -> [Double] {
        let n = b.count
        let w = n + 1 // augmented row width: [M | b]
        var aug: [Double] = []
        aug.reserveCapacity(n * w)
        for r in 0..<n {
            for c in 0..<n { aug.append(m[r * n + c]) }
            aug.append(b[r])
        }
        for col in 0..<n {
            // Partial pivot: swap in the row with the largest magnitude in this column.
            var pivot = col
            for r in (col + 1)..<n where abs(aug[r * w + col]) > abs(aug[pivot * w + col]) {
                pivot = r
            }
            if abs(aug[pivot * w + col]) < 1e-12 {
                throw GestureContractError.outOfRange("calibration: singular system (collinear or degenerate points)")
            }
            for c in 0..<w {
                aug.swapAt(col * w + c, pivot * w + c)
            }
            let diag = aug[col * w + col]
            for r in 0..<n where r != col {
                let factor = aug[r * w + col] / diag
                for c in col..<w {
                    aug[r * w + c] -= factor * aug[col * w + c]
                }
            }
        }
        var x: [Double] = []
        for i in 0..<n { x.append(aug[i * w + n] / aug[i * w + i]) }
        return x
    }

    /// Least-squares homography fit via the Direct Linear Transform. Each correspondence gives
    /// two linear equations in h0..h7 (h8 pinned to 1); accumulate the 8×8 normal equations.
    /// Needs ≥4 non-collinear correspondences.
    static func fitHomography(_ pairs: [CalibrationPair]) throws -> Homography {
        guard pairs.count >= 4 else {
            throw GestureContractError.outOfRange("fitHomography: need ≥4 correspondences for a homography fit, got \(pairs.count)")
        }
        let dof = 8
        var m = [Double](repeating: 0, count: dof * dof) // flat row-major AᵀA
        var v = [Double](repeating: 0, count: dof)        // Aᵀt
        func accumulate(_ row: [Double], _ t: Double) {
            for i in 0..<dof {
                let ri = row[i]
                for j in 0..<dof {
                    m[i * dof + j] += ri * row[j]
                }
                v[i] += ri * t
            }
        }
        for pair in pairs {
            let x = pair.raw.x, y = pair.raw.y
            let X = pair.target.x, Y = pair.target.y
            accumulate([x, y, 1, 0, 0, 0, -x * X, -y * X], X)
            accumulate([0, 0, 0, x, y, 1, -x * Y, -y * Y], Y)
        }
        let h = try solveLinear(m, v)
        return Homography(values: [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1])
    }

    /// RMS reprojection error (screen-px) of a homography over its correspondences.
    static func homographyResidual(_ h: Homography, _ pairs: [CalibrationPair]) -> Double {
        if pairs.isEmpty { return 0 }
        var sumSq = 0.0
        for pair in pairs {
            let p = applyHomography(h, pair.raw)
            sumSq += (p.x - pair.target.x) * (p.x - pair.target.x) + (p.y - pair.target.y) * (p.y - pair.target.y)
        }
        return (sumSq / Double(pairs.count)).squareRoot()
    }

    /// RMS reprojection error (target/screen-px space) of an affine over its correspondences.
    static func calibrationResidual(_ t: CalibrationAffine, _ pairs: [CalibrationPair]) -> Double {
        if pairs.isEmpty { return 0 }
        var sumSq = 0.0
        for pair in pairs {
            let p = applyTransform(t, pair.raw)
            sumSq += (p.x - pair.target.x) * (p.x - pair.target.x) + (p.y - pair.target.y) * (p.y - pair.target.y)
        }
        return (sumSq / Double(pairs.count)).squareRoot()
    }

    // Residual thresholds (global px). Pointing is coarse — dwell + voice seal it — so these
    // tolerate tens of px rather than aiming for a pixel-perfect cursor.
    private static let goodMaxPx = 20.0
    private static let fairMaxPx = 60.0

    static func calibrationQualityFromResidual(_ rmsPx: Double) -> Contracts.CalibrationQuality {
        if rmsPx <= goodMaxPx { return .good }
        if rmsPx <= fairMaxPx { return .fair }
        return .poor
    }

    // Distance scale (px) over which confidence decays once the point is outside a surface.
    private static let confidenceFalloffPx = 200.0

    /// Resolve a calibrated screen-px point to the nearest surface candidate. Returns nil when
    /// there are no surfaces. Confidence is 1 inside a surface and decays with distance outside;
    /// `calibrationQuality` is threaded through from the fit.
    static func toCandidate(
        _ screenXY: Vec2,
        _ surfaces: [Contracts.Surface],
        _ calibrationQuality: Contracts.CalibrationQuality
    ) -> Contracts.PointingCandidate? {
        var nearest: Contracts.Surface?
        var nearestDist = Double.infinity
        for surface in surfaces {
            let dist = surface.bounds.distance(to: screenXY)
            if dist < nearestDist {
                nearest = surface
                nearestDist = dist
            }
        }
        guard let nearest else { return nil }
        let confidence = 1 / (1 + nearestDist / confidenceFalloffPx)
        return Contracts.PointingCandidate(
            targetId: nearest.id,
            confidence: confidence,
            calibrationQuality: calibrationQuality
        )
    }
}

extension Contracts.SurfaceBounds {
    /// Euclidean distance from a point to this rect; 0 when the point is inside. Shared by the
    /// calibration hit-test (`toCandidate`) and display arbitration (`pickDisplay`).
    func distance(to point: Vec2) -> Double {
        let dx = max(x - point.x, 0, point.x - (x + w))
        let dy = max(y - point.y, 0, point.y - (y + h))
        return hypot(dx, dy)
    }
}
