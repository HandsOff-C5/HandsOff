//
//  CalibrationCapture.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/calibration/capture.ts (#26) — collects the target→raw
//  correspondences the pure `fitAffine` needs. The user is shown known screen targets one at a
//  time; for each, the runtime captures the raw pointing signal, then the session fits the
//  affine. Pure: the caller supplies the captured raw points (no camera here). Stateful → class.
//

import Foundation

struct GridSpec: Equatable, Sendable {
    let cols: Int
    let rows: Int
    /// Fraction of the bounds to inset the outer points by (0 = corner-to-corner). Default 0.1.
    let margin: Double

    init(cols: Int, rows: Int, margin: Double = 0.1) {
        self.cols = cols
        self.rows = rows
        self.margin = margin
    }
}

struct CalibrationProgress: Equatable, Sendable {
    let index: Int
    let total: Int
    let done: Bool
    /// The target to display now, or nil when the session is complete.
    let target: Vec2?
}

struct CalibrationResult: Equatable, Sendable {
    let transform: CalibrationAffine
    let residual: Double
    let quality: Contracts.CalibrationQuality
}

enum CalibrationCapture {
    /// A cols×rows grid of screen-space target points across `bounds`, row-major (top-left
    /// first). 3×3 is the default calibration layout.
    static func gridTargets(_ bounds: Contracts.SurfaceBounds, _ spec: GridSpec) -> [Vec2] {
        let insetX = bounds.w * spec.margin
        let insetY = bounds.h * spec.margin
        let spanX = bounds.w - 2 * insetX
        let spanY = bounds.h - 2 * insetY
        var targets: [Vec2] = []
        for r in 0..<spec.rows {
            for c in 0..<spec.cols {
                let x = bounds.x + insetX + (spec.cols == 1 ? 0 : (spanX * Double(c)) / Double(spec.cols - 1))
                let y = bounds.y + insetY + (spec.rows == 1 ? 0 : (spanY * Double(r)) / Double(spec.rows - 1))
                targets.append(Vec2(x, y))
            }
        }
        return targets
    }
}

/// Drives the one-target-at-a-time capture flow and fits the affine once every target is in.
final class CalibrationSession {
    private let targets: [Vec2]
    private var pairs: [CalibrationPair] = []

    init(targets: [Vec2]) {
        self.targets = targets
    }

    private func progress() -> CalibrationProgress {
        CalibrationProgress(
            index: pairs.count,
            total: targets.count,
            done: pairs.count >= targets.count,
            target: targets.indices.contains(pairs.count) ? targets[pairs.count] : nil
        )
    }

    func current() -> CalibrationProgress { progress() }

    /// Record the raw pointing signal for the current target and advance.
    @discardableResult
    func capture(_ raw: Vec2) throws -> CalibrationProgress {
        guard targets.indices.contains(pairs.count) else {
            throw GestureContractError.outOfRange("calibration: all targets already captured")
        }
        pairs.append(CalibrationPair(raw: raw, target: targets[pairs.count]))
        return progress()
    }

    /// The fitted result once every target is captured; nil until then.
    func result() throws -> CalibrationResult? {
        guard pairs.count >= targets.count else { return nil }
        let transform = try GestureCalibration.fitAffine(pairs)
        let residual = GestureCalibration.calibrationResidual(transform, pairs)
        return CalibrationResult(
            transform: transform,
            residual: residual,
            quality: GestureCalibration.calibrationQualityFromResidual(residual)
        )
    }
}
