import CoreGraphics
import Foundation

/// Adaptive EMA smoothing for the face control vector (`D3`, `FR-18`-adjacent), re-homed
/// **AS-IS** from the salvaged head-track motion — deliberately NOT a 1€ filter.
///
/// The smoothing factor adapts to both the offset magnitude and the change rate:
///
///   `alpha = clamp(emaBase + |v|·emaVelocityGain + min(speed·emaSpeedGain, emaSpeedCap),
///                  emaMin … emaMax)`
///
/// where `|v|` is the current control-vector magnitude and `speed` is the per-second magnitude
/// of the change since the previous vector. A larger / faster move pulls `alpha` up (less lag,
/// more responsive); at rest it floors at `emaMin` (heavy smoothing, no jitter).
///
/// **A/B tuning intent (`TUNING_RUNBOOK §3`):** this bespoke speed-adaptive EMA is the SHIPPING
/// start point. The 1€ filter introduced in SL-3 is the A/B challenger. We re-home this filter
/// verbatim rather than swap to 1€ here so the face pointer's feel is preserved exactly until
/// the two are measured side-by-side on hardware (`I3` — measurement beats seed).
public struct FaceFilter {

    private let base: Double
    private let velocityGain: Double
    private let speedGain: Double
    private let speedCap: Double
    private let lo: Double
    private let hi: Double

    public init(
        base: Double = Params.face.emaBase,
        velocityGain: Double = Params.face.emaVelocityGain,
        speedGain: Double = Params.face.emaSpeedGain,
        speedCap: Double = Params.face.emaSpeedCap,
        lo: Double = Params.face.emaMin,
        hi: Double = Params.face.emaMax
    ) {
        self.base = base
        self.velocityGain = velocityGain
        self.speedGain = speedGain
        self.speedCap = speedCap
        self.lo = lo
        self.hi = hi
    }

    /// Compute the adaptive smoothing factor for the current frame. `dt` is the frame delta in
    /// seconds (guarded against zero). Salvaged formula, verbatim.
    public func alpha(rawVector: CGPoint, previousVector: CGPoint, dt: Double) -> Double {
        let mag = magnitude(rawVector)
        let change = magnitude(CGPoint(x: rawVector.x - previousVector.x,
                                       y: rawVector.y - previousVector.y))
        let speed = change / max(dt, 0.001)
        let raw = base + mag * velocityGain + min(speed * speedGain, speedCap)
        return max(lo, min(hi, raw))
    }

    /// One EMA step on a scalar component: `previous + (raw − previous)·alpha`.
    public func blend(previous: Double, raw: Double, alpha: Double) -> Double {
        previous + (raw - previous) * alpha
    }

    private func magnitude(_ p: CGPoint) -> Double {
        Double(hypot(p.x, p.y))
    }
}
