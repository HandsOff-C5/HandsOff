import Foundation

// Shared smoothing home (`Models/Filtering/`, `D3`, `FR-18`). The 1€ filter and its EMA /
// cutoff primitives are ported VERBATIM from the gesture TS oracle
// (`Conformance/gesture/src/confidence/smoothing.ts`) so the Swift pointer smoothing is
// byte-faithful to the conformance ground truth (same recurrence, same `alpha = 1/(1+tau/Te)`
// definition). SL-3 hand pointing consumes it now; it is ALSO the A/B challenger to SL-1's
// bespoke speed-adaptive EMA (`FaceFilter`) — both shipped, measured side-by-side at the
// on-Mac Filtering gate (`TUNING_RUNBOOK §3`). Pure: time is passed in as millisecond
// timestamps, never read from a clock, so it is deterministic and fixture-testable.

/// One EMA step — the inner recurrence of 1€. `alpha = 1` is passthrough (no smoothing);
/// `alpha → 0` is frozen (holds `prev`).
@inlinable
public func ema(_ x: Double, _ prev: Double, alpha: Double) -> Double {
    alpha * x + (1 - alpha) * prev
}

/// Smoothing factor for a low-pass cutoff: `alpha = 1/(1 + tau/Te)`, `tau = 1/(2π·fc)`.
/// Higher cutoff → larger alpha → tracks faster. `fc` in Hz, `sampleSeconds` the frame period.
@inlinable
public func alphaFromCutoff(cutoffHz: Double, sampleSeconds: Double) -> Double {
    let tau = 1 / (2 * Double.pi * cutoffHz)
    return 1 / (1 + tau / sampleSeconds)
}

/// 1€-filter parameters. Defaults come from the shared knob surface (`Params.hand.filter*`).
public struct OneEuroParams {
    /// Baseline cutoff at low speed (Hz); lower → less jitter, more lag.
    public let minCutoff: Double
    /// Speed coefficient; higher → less lag on fast motion, more jitter. `0` → fixed-α EMA.
    public let beta: Double
    /// Cutoff for the derivative's own low-pass (Hz).
    public let dCutoff: Double

    public init(
        minCutoff: Double = Params.filter.minCutoffHz,
        beta: Double = Params.filter.beta,
        dCutoff: Double = Params.filter.dCutoffHz
    ) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }
}

/// Adaptive low-pass 1€ filter on ONE scalar channel: low cutoff when still (kills jitter),
/// high cutoff when moving fast (kills lag). Internal state; deterministic in `(x, tMs)`.
/// Mirrors the oracle's `createPerceptionOneEuroFilter` step-for-step — the first sample is returned
/// unchanged (seeds the state), and a non-advancing/backwards timestamp holds the last output.
public final class PerceptionOneEuroFilter {

    private let params: OneEuroParams
    private var xHat = 0.0
    private var dxHat = 0.0
    private var tPrevMs: Double?

    public init(_ params: OneEuroParams = OneEuroParams()) {
        self.params = params
    }

    /// Filter sample `x` captured at `tMs` (milliseconds). Returns the smoothed value.
    public func filter(_ x: Double, tMs: Double) -> Double {
        guard let prev = tPrevMs else {
            tPrevMs = tMs
            xHat = x
            dxHat = 0
            return x
        }
        let te = (tMs - prev) / 1000
        // A non-advancing (or backwards) timestamp can't smooth meaningfully — hold, and do NOT
        // shift the baseline, so the next valid frame still measures `te` from `prev`.
        if te <= 0 { return xHat }
        tPrevMs = tMs

        // Low-pass the derivative, then set the adaptive cutoff from its magnitude.
        let dx = (x - xHat) / te
        dxHat = ema(dx, dxHat, alpha: alphaFromCutoff(cutoffHz: params.dCutoff, sampleSeconds: te))
        let cutoff = params.minCutoff + params.beta * abs(dxHat)

        xHat = ema(x, xHat, alpha: alphaFromCutoff(cutoffHz: cutoff, sampleSeconds: te))
        return xHat
    }
}
