import Foundation

// SL-2a — Calibration FIT math (pure; no I/O, no camera, no clock). Ported to match the live
// TS oracle (`Conformance/gesture/src/calibration/calibrate.ts`) within the A-3 tolerances
// (I4 Purity Gate). Deterministic solvers only (symmetric-3×3 cofactor inverse for affine;
// Gauss-Jordan with partial pivoting for the homography DLT and the polynomial normal
// equations) — no Accelerate dependency so the math is byte-for-byte reproducible.

public typealias CalibPoint = SIMD2<Double>

/// One calibration correspondence: a raw pointing signal observed while pointing at a known
/// `target` (screen px).
public struct PerceptionCalibrationPair {
    public let raw: CalibPoint
    public let target: CalibPoint
    public init(raw: CalibPoint, target: CalibPoint) {
        self.raw = raw
        self.target = target
    }
}

/// Errors a fit can raise (a degenerate/under-determined system is not a recoverable state).
public enum CalibrationError: Error {
    case tooFewCorrespondences(need: Int, got: Int)
    case singular
    case inconsistentFeatureLength(expected: Int, got: Int)
    case noSamples
}

// MARK: - Deterministic solvers

enum LinearSolver {

    /// Solve the symmetric 3×3 system S·p = v (S given by its distinct upper entries) via the
    /// cofactor inverse — the affine fit's normal equations. Throws on a singular system.
    static func solveSym3(
        _ s00: Double, _ s01: Double, _ s02: Double,
        _ s11: Double, _ s12: Double, _ s22: Double,
        _ v0: Double, _ v1: Double, _ v2: Double
    ) throws -> (Double, Double, Double) {
        let c00 = s11 * s22 - s12 * s12
        let c01 = s12 * s02 - s01 * s22
        let c02 = s01 * s12 - s11 * s02
        let det = s00 * c00 + s01 * c01 + s02 * c02
        if abs(det) < 1e-12 { throw CalibrationError.singular }
        let c11 = s00 * s22 - s02 * s02
        let c12 = s02 * s01 - s00 * s12
        let c22 = s00 * s11 - s01 * s01
        return (
            (c00 * v0 + c01 * v1 + c02 * v2) / det,
            (c01 * v0 + c11 * v1 + c12 * v2) / det,
            (c02 * v0 + c12 * v1 + c22 * v2) / det
        )
    }

    /// Solve the n×n system M·x = b by Gauss-Jordan elimination with partial pivoting. `m` is
    /// a flat row-major n×n matrix. Mirrors the oracle's `solveLinear` step-for-step so the
    /// rounding agrees. Throws on a singular system.
    static func solveLinear(_ m: [Double], _ b: [Double]) throws -> [Double] {
        let n = b.count
        let w = n + 1  // augmented row width [M | b]
        var aug = [Double]()
        aug.reserveCapacity(n * w)
        for r in 0..<n {
            for c in 0..<n { aug.append(m[r * n + c]) }
            aug.append(b[r])
        }
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where r < n {
                if abs(aug[r * w + col]) > abs(aug[pivot * w + col]) { pivot = r }
            }
            if abs(aug[pivot * w + col]) < 1e-12 { throw CalibrationError.singular }
            if pivot != col {
                for c in 0..<w {
                    aug.swapAt(col * w + c, pivot * w + c)
                }
            }
            let diag = aug[col * w + col]
            for r in 0..<n where r != col {
                let factor = aug[r * w + col] / diag
                for c in col..<w {
                    aug[r * w + c] -= factor * aug[col * w + c]
                }
            }
        }
        var x = [Double]()
        x.reserveCapacity(n)
        for i in 0..<n { x.append(aug[i * w + n] / aug[i * w + i]) }
        return x
    }
}

// MARK: - Affine

/// Affine map `[x,y] → [a·x + b·y + c, d·x + e·y + f]`. 6 DOF; needs ≥3 correspondences.
public struct Affine: Equatable {
    public let a, b, c, d, e, f: Double
    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public func apply(_ p: CalibPoint) -> CalibPoint {
        CalibPoint(a * p.x + b * p.y + c, d * p.x + e * p.y + f)
    }

    /// Least-squares affine fit via the normal equations (shared symmetric AᵀA, two RHS).
    public static func fit(_ pairs: [PerceptionCalibrationPair]) throws -> Affine {
        if pairs.count < 3 { throw CalibrationError.tooFewCorrespondences(need: 3, got: pairs.count) }
        var sxx = 0.0, sxy = 0.0, sx = 0.0, syy = 0.0, sy = 0.0
        let n = Double(pairs.count)
        var txx = 0.0, txy = 0.0, tx = 0.0  // Aᵀ·X'
        var tyx = 0.0, tyy = 0.0, ty = 0.0  // Aᵀ·Y'
        for p in pairs {
            let x = p.raw.x, y = p.raw.y, X = p.target.x, Y = p.target.y
            sxx += x * x; sxy += x * y; sx += x; syy += y * y; sy += y
            txx += x * X; txy += y * X; tx += X
            tyx += x * Y; tyy += y * Y; ty += Y
        }
        let (a, b, c) = try LinearSolver.solveSym3(sxx, sxy, sx, syy, sy, n, txx, txy, tx)
        let (d, e, f) = try LinearSolver.solveSym3(sxx, sxy, sx, syy, sy, n, tyx, tyy, ty)
        return Affine(a: a, b: b, c: c, d: d, e: e, f: f)
    }
}

// MARK: - PerceptionHomography (DLT)

/// 3×3 projective homography, row-major `[h0..h8]`, with `h8` pinned to 1.
public struct PerceptionHomography: Equatable {
    public let entries: [Double]  // length 9
    public init(entries: [Double]) {
        precondition(entries.count == 9, "PerceptionHomography needs 9 entries")
        self.entries = entries
    }

    public func apply(_ p: CalibPoint) -> CalibPoint {
        let h = entries
        let w = h[6] * p.x + h[7] * p.y + h[8]
        return CalibPoint((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }

    /// Least-squares homography fit via the Direct Linear Transform. Each correspondence gives
    /// two linear equations in h0..h7 (h8 = 1); accumulate the 8×8 normal equations and solve.
    public static func fit(_ pairs: [PerceptionCalibrationPair]) throws -> PerceptionHomography {
        if pairs.count < 4 { throw CalibrationError.tooFewCorrespondences(need: 4, got: pairs.count) }
        let dof = 8
        var m = [Double](repeating: 0, count: dof * dof)  // AᵀA
        var v = [Double](repeating: 0, count: dof)  // Aᵀt
        func accumulate(_ row: [Double], _ t: Double) {
            for i in 0..<dof {
                let ri = row[i]
                for j in 0..<dof { m[i * dof + j] += ri * row[j] }
                v[i] += ri * t
            }
        }
        for p in pairs {
            let x = p.raw.x, y = p.raw.y, X = p.target.x, Y = p.target.y
            accumulate([x, y, 1, 0, 0, 0, -x * X, -y * X], X)
            accumulate([0, 0, 0, x, y, 1, -x * Y, -y * Y], Y)
        }
        let h = try LinearSolver.solveLinear(m, v)
        return PerceptionHomography(entries: [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1])
    }
}

// MARK: - General polynomial (no-cross-term quadratic basis — matches the oracle)

/// A polynomial sample: a length-k feature vector and the screen-px `target` it maps to.
public struct PolynomialSample {
    public let features: [Double]
    public let target: CalibPoint
    public init(features: [Double], target: CalibPoint) {
        self.features = features
        self.target = target
    }
}

/// Polynomial transform over the quadratic basis `φ(f) = [1, f₀…f_{k-1}, f₀²…f_{k-1}²]`
/// (1 + 2k terms, no cross terms) — the per-monitor eye-gaze map. Matches the salvaged
/// oracle's basis so the eye-calibration flow ports exactly. The 2-feature standard-basis
/// keystone (incl. the cross term) lives in `RidgePoly`.
public struct PolynomialTransform {
    public let featureCount: Int
    public let cx: [Double]  // per-axis coeffs over φ, length 1 + 2·featureCount
    public let cy: [Double]

    static func basis(_ features: [Double]) -> [Double] {
        var b = [1.0]
        b.append(contentsOf: features)
        b.append(contentsOf: features.map { $0 * $0 })
        return b
    }

    public func apply(_ features: [Double]) -> CalibPoint {
        let phi = PolynomialTransform.basis(features)
        var x = 0.0, y = 0.0
        for i in 0..<phi.count {
            x += cx[i] * phi[i]
            y += cy[i] * phi[i]
        }
        return CalibPoint(x, y)
    }

    public static func fit(samples: [PolynomialSample]) throws -> PolynomialTransform {
        guard let first = samples.first else { throw CalibrationError.noSamples }
        let featureCount = first.features.count
        let basisSize = 1 + 2 * featureCount
        if samples.count < basisSize {
            throw CalibrationError.tooFewCorrespondences(need: basisSize, got: samples.count)
        }
        var m = [Double](repeating: 0, count: basisSize * basisSize)  // φᵀφ
        var vx = [Double](repeating: 0, count: basisSize)
        var vy = [Double](repeating: 0, count: basisSize)
        for s in samples {
            if s.features.count != featureCount {
                throw CalibrationError.inconsistentFeatureLength(
                    expected: featureCount, got: s.features.count)
            }
            let phi = basis(s.features)
            let X = s.target.x, Y = s.target.y
            for i in 0..<basisSize {
                let pi = phi[i]
                for j in 0..<basisSize { m[i * basisSize + j] += pi * phi[j] }
                vx[i] += pi * X
                vy[i] += pi * Y
            }
        }
        let cx = try LinearSolver.solveLinear(m, vx)
        let cy = try LinearSolver.solveLinear(m, vy)
        return PolynomialTransform(featureCount: featureCount, cx: cx, cy: cy)
    }

    /// RMS reprojection error (screen px) of a polynomial fit over its samples.
    public static func residual(_ t: PolynomialTransform, samples: [PolynomialSample]) -> Double {
        if samples.isEmpty { return 0 }
        var sumSq = 0.0
        for s in samples {
            let p = t.apply(s.features)
            sumSq += (p.x - s.target.x) * (p.x - s.target.x) + (p.y - s.target.y) * (p.y - s.target.y)
        }
        return (sumSq / Double(samples.count)).squareRoot()
    }
}

// MARK: - Ridge polynomial — §5.4 keystone, standard 6-coeff basis (incl. the xy cross-term)

/// Ridge-regularized polynomial fit over the **standard** 2D quadratic basis
/// `{1, xe, ye, xe·ye, xe², ye²}` (6 coeffs) for a single output axis. This is the
/// `CLAUDE.md §5.4` / `RESEARCH.md Q5` model: it INCLUDES the `xy` cross-term the salvaged
/// oracle omits. Objective `minimize ‖Aθ − b‖² + λ‖θ‖²` → `θ = (AᵀA + λI)⁻¹ Aᵀb`. λ=0 is the
/// exact least-squares fit; a small λ shrinks ‖θ‖ to damp overfit. Pure math.
public enum RidgePoly {

    public struct Fit {
        public let theta: [Double]  // 6 coeffs over {1, xe, ye, xe·ye, xe², ye²}
    }

    /// The standard 6-term basis row for one feature point.
    public static func basis(_ f: SIMD2<Double>) -> [Double] {
        let xe = f.x, ye = f.y
        return [1, xe, ye, xe * ye, xe * xe, ye * ye]
    }

    /// Fit one output axis. `θ = (AᵀA + λI)⁻¹ Aᵀb` solved via the deterministic Gaussian
    /// solver. The ridge term `λI` is added to the full 6×6 normal matrix (including the bias
    /// row — kept simple and matching the §5.4 keystone's `‖θ‖` shrink expectation).
    public static func fit(features: [SIMD2<Double>], targets: [Double], lambda: Double) -> Fit {
        let k = 6
        var m = [Double](repeating: 0, count: k * k)  // AᵀA
        var v = [Double](repeating: 0, count: k)  // Aᵀb
        for (idx, f) in features.enumerated() {
            let phi = basis(f)
            let b = targets[idx]
            for i in 0..<k {
                let pi = phi[i]
                for j in 0..<k { m[i * k + j] += pi * phi[j] }
                v[i] += pi * b
            }
        }
        for i in 0..<k { m[i * k + i] += lambda }  // + λI
        // λ ≥ 0 keeps AᵀA + λI positive-definite for any non-degenerate design, so the solve
        // cannot hit the singular guard for our calibration grids.
        let theta = (try? LinearSolver.solveLinear(m, v)) ?? [Double](repeating: 0, count: k)
        return Fit(theta: theta)
    }

    public static func apply(theta: [Double], _ f: SIMD2<Double>) -> Double {
        let phi = basis(f)
        var acc = 0.0
        for i in 0..<theta.count { acc += theta[i] * phi[i] }
        return acc
    }

    /// RMS residual of a single-axis ridge fit over its training points.
    public static func residual(theta: [Double], features: [SIMD2<Double>], targets: [Double])
        -> Double
    {
        if features.isEmpty { return 0 }
        var sumSq = 0.0
        for (idx, f) in features.enumerated() {
            let d = apply(theta: theta, f) - targets[idx]
            sumSq += d * d
        }
        return (sumSq / Double(features.count)).squareRoot()
    }
}

// MARK: - Fit model selection

/// Which calibration model the capture flow fits. Default is the ridge polynomial (`FR-21`).
public enum FitModel {
    case affine
    case homography
    case ridgePoly

    public static let `default`: FitModel = .ridgePoly
}

// MARK: - Unified CalibrationFit (the 2D→2D screen map the hand/face consumers share)

/// The unified, `FitModel`-selectable calibration map — `affine` / `homography` / `ridgePoly`
/// (default `ridgePoly`) — exposing ONE reusable `apply(SIMD2<Double>) -> SIMD2<Double>` plus an
/// RMS `residual`. This is the type the hand pointer (`ActiveRegion`) and the face map will
/// consume: a 2D raw signal in, a 2D screen-px point out (`FR-21`/`FR-22`, `CLAUDE.md §5.4`).
///
/// `ridgePoly` fits BOTH output axes over the STANDARD 6-coeff quadratic basis
/// `{1, xe, ye, xe·ye, xe², ye²}` (two `RidgePoly.fit` calls, incl. the `xy` cross-term the
/// salvaged eye-gaze basis omits) with ridge λ. The multi-feature eye-gaze map keeps its own
/// salvaged `PolynomialTransform` (oracle parity); this type is strictly the 2D model.
public enum CalibrationFit {
    case affine(Affine)
    case homography(PerceptionHomography)
    /// Per-axis ridge coeffs over `{1, xe, ye, xe·ye, xe², ye²}` plus the λ they were fit with.
    case ridgePoly(thetaX: [Double], thetaY: [Double], lambda: Double)

    /// Which `FitModel` this fit was produced by.
    public var model: FitModel {
        switch self {
        case .affine: return .affine
        case .homography: return .homography
        case .ridgePoly: return .ridgePoly
        }
    }

    /// Map a 2D raw signal to a 2D screen-px point. Reusable across the hand/face consumers.
    public func apply(_ f: SIMD2<Double>) -> SIMD2<Double> {
        switch self {
        case .affine(let a):
            return a.apply(f)
        case .homography(let h):
            return h.apply(f)
        case .ridgePoly(let tx, let ty, _):
            return SIMD2(RidgePoly.apply(theta: tx, f), RidgePoly.apply(theta: ty, f))
        }
    }

    /// RMS reprojection error (screen px) of this fit over the correspondences `pairs`.
    public func residual(over pairs: [PerceptionCalibrationPair]) -> Double {
        if pairs.isEmpty { return 0 }
        var sumSq = 0.0
        for p in pairs {
            let q = apply(p.raw)
            let dx = q.x - p.target.x, dy = q.y - p.target.y
            sumSq += dx * dx + dy * dy
        }
        return (sumSq / Double(pairs.count)).squareRoot()
    }

    // MARK: Builders

    /// Fit a ridge polynomial over BOTH axes (standard 6-coeff basis + λ). λ=0 is the exact
    /// least-squares fit (the §5.4 keystone recovers an affine target exactly); a small λ shrinks
    /// ‖θ‖ to damp overfit. Pure math — never throws (ridge keeps `AᵀA + λI` solvable).
    public static func ridgePoly(from pairs: [PerceptionCalibrationPair], lambda: Double) -> CalibrationFit {
        let features = pairs.map { $0.raw }
        let tx = RidgePoly.fit(features: features, targets: pairs.map { $0.target.x }, lambda: lambda)
        let ty = RidgePoly.fit(features: features, targets: pairs.map { $0.target.y }, lambda: lambda)
        return .ridgePoly(thetaX: tx.theta, thetaY: ty.theta, lambda: lambda)
    }

    /// Fit the selected model over `pairs`. `lambda` is only consumed by `.ridgePoly`. Throws on a
    /// degenerate/under-determined affine or homography system.
    public static func fit(model: FitModel, pairs: [PerceptionCalibrationPair], lambda: Double)
        throws -> CalibrationFit
    {
        switch model {
        case .affine:
            return .affine(try Affine.fit(pairs))
        case .homography:
            return .homography(try PerceptionHomography.fit(pairs))
        case .ridgePoly:
            return ridgePoly(from: pairs, lambda: lambda)
        }
    }
}
