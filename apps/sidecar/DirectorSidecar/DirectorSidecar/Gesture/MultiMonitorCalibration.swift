//
//  MultiMonitorCalibration.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/calibration/multi-monitor.ts. A single affine across the whole
//  virtual desktop degrades at monitor seams and on off-axis secondaries, so we fit ONE affine
//  PER display and route a new reading to the right display by nearest raw-signal centroid
//  (two-stage: classify display, then regress within it). With one display this collapses to
//  the single-affine fit.
//

import Foundation

/// One calibration target: a global-px point (display origin baked in) on a known display.
struct CalibrationTarget: Equatable, Sendable {
    let displayId: String
    let target: Vec2
}

/// A captured correspondence: the raw pointing signal observed while aiming at `target`.
struct MultiCalibrationPair: Equatable, Sendable {
    let raw: Vec2
    let displayId: String
    let target: Vec2
}

/// A per-display fit: the affine raw→global-px plus the centroid of the captured raw signals
/// (the nearest-neighbour key used to classify which display a new reading targets).
struct PerDisplayFit: Equatable, Sendable {
    let transform: CalibrationAffine
    let centroid: Vec2
}

struct MultiMonitorCalibration: Equatable, Sendable {
    let byDisplay: [String: PerDisplayFit]
    /// RMS reprojection error (global px) across every correspondence.
    let residual: Double
    let quality: Contracts.CalibrationQuality
}

enum MultiMonitor {
    /// Lay a cols×rows grid across EACH display (global-px targets), concatenated in display
    /// order. A 3×3 grid across 2 monitors yields 18 targets.
    static func multiMonitorTargets(_ displays: [Display], _ spec: GridSpec) -> [CalibrationTarget] {
        displays.flatMap { display in
            CalibrationCapture.gridTargets(display.bounds, spec).map {
                CalibrationTarget(displayId: display.id, target: $0)
            }
        }
    }

    private static func meanPoint(_ points: [Vec2]) -> Vec2 {
        var sx = 0.0, sy = 0.0
        for p in points { sx += p.x; sy += p.y }
        let n = Double(points.count)
        return Vec2(sx / n, sy / n)
    }

    /// Group pairs by display, preserving first-seen order so the residual fold is deterministic
    /// (the TS `Object.entries` over an insertion-ordered record).
    private static func groupByDisplay(_ pairs: [MultiCalibrationPair]) -> [(String, [MultiCalibrationPair])] {
        var order: [String] = []
        var groups: [String: [MultiCalibrationPair]] = [:]
        for pair in pairs {
            if groups[pair.displayId] == nil { order.append(pair.displayId) }
            groups[pair.displayId, default: []].append(pair)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Fit one affine per display from the captured correspondences. Each display needs ≥3 points.
    static func fitMultiMonitor(_ pairs: [MultiCalibrationPair]) throws -> MultiMonitorCalibration {
        guard !pairs.isEmpty else {
            throw GestureContractError.outOfRange("fitMultiMonitor: no correspondences")
        }
        var byDisplay: [String: PerDisplayFit] = [:]
        var sumSq = 0.0
        var count = 0
        for (displayId, group) in groupByDisplay(pairs) {
            guard group.count >= 3 else {
                throw GestureContractError.outOfRange("fitMultiMonitor: display \(displayId) has \(group.count) target(s); need ≥3")
            }
            let calibrationPairs = group.map { CalibrationPair(raw: $0.raw, target: $0.target) }
            let transform = try GestureCalibration.fitAffine(calibrationPairs)
            byDisplay[displayId] = PerDisplayFit(transform: transform, centroid: meanPoint(group.map(\.raw)))
            for pair in group {
                let p = GestureCalibration.applyTransform(transform, pair.raw)
                sumSq += (p.x - pair.target.x) * (p.x - pair.target.x) + (p.y - pair.target.y) * (p.y - pair.target.y)
                count += 1
            }
        }
        let residual = count > 0 ? (sumSq / Double(count)).squareRoot() : 0
        return MultiMonitorCalibration(
            byDisplay: byDisplay,
            residual: residual,
            quality: GestureCalibration.calibrationQualityFromResidual(residual)
        )
    }

    private static func nearestDisplay(_ cal: MultiMonitorCalibration, _ raw: Vec2) -> PerDisplayFit? {
        var best: PerDisplayFit?
        var bestDist = Double.infinity
        // Object.values order = insertion order of the dictionary the fit built. Swift dictionary
        // order is unspecified, but nearest-centroid selection is order-independent for distinct
        // centroids, which is the regime this classifier is designed for.
        for fit in cal.byDisplay.values {
            let dx = raw.x - fit.centroid.x
            let dy = raw.y - fit.centroid.y
            let dist = dx * dx + dy * dy
            if best == nil || dist < bestDist {
                bestDist = dist
                best = fit
            }
        }
        return best
    }

    /// Map a raw pointing signal to a global-px point: classify the display by nearest centroid,
    /// then apply that display's affine. Returns the raw point unchanged when there is no
    /// calibration (graceful degrade before the first fit). NOT clamped to a display here.
    static func predictMultiMonitor(_ cal: MultiMonitorCalibration?, _ raw: Vec2) -> Vec2 {
        guard let cal else { return raw }
        guard let fit = nearestDisplay(cal, raw) else { return raw }
        return GestureCalibration.applyTransform(fit.transform, raw)
    }
}
