//
//  Smoothing.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/confidence/smoothing.ts — confidence/pointer smoothing
//  primitives. The pure functions stay pure (time passed in as ms timestamps, never read from
//  a clock) so they're deterministic and fixture-testable; the 1€ filter is a small stateful
//  class (the TS closure's captured state).
//

import Foundation

enum GestureSmoothing {
    /// Exponential moving average — one smoothing step. alpha=1 passthrough (no smoothing),
    /// alpha→0 frozen (holds previous). The inner recurrence of 1€.
    static func ema(_ x: Double, _ prev: Double, _ alpha: Double) -> Double {
        alpha * x + (1 - alpha) * prev
    }

    /// Smoothing factor for a low-pass cutoff: alpha = 1/(1 + tau/Te), tau = 1/(2π·fc).
    /// Higher cutoff → larger alpha → tracks faster. fc in Hz, sample period in seconds.
    static func alphaFromCutoff(_ cutoffHz: Double, _ sampleSeconds: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoffHz)
        return 1 / (1 + tau / sampleSeconds)
    }
}

/// 1€ filter: adaptive low-pass — low cutoff when still (kills jitter), high cutoff when moving
/// fast (kills lag). State lives in the instance; deterministic in (x, t).
final class OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double

    private var xHat: Double = 0
    private var dxHat: Double = 0
    private var tPrevMs: Double?
    private var initialized = false

    init(minCutoff: Double = 1, beta: Double = 0, dCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// Filter sample `x` captured at `tMs` (ms). Returns the smoothed value.
    func filter(_ x: Double, _ tMs: Double) -> Double {
        guard initialized, let prev = tPrevMs else {
            initialized = true
            tPrevMs = tMs
            xHat = x
            dxHat = 0
            return x
        }

        let te = (tMs - prev) / 1000
        tPrevMs = tMs
        // A non-advancing (or backwards) timestamp can't smooth meaningfully — hold.
        if te <= 0 { return xHat }

        // Low-pass the derivative, then set the adaptive cutoff from its magnitude.
        let dx = (x - xHat) / te
        dxHat = GestureSmoothing.ema(dx, dxHat, GestureSmoothing.alphaFromCutoff(dCutoff, te))
        let cutoff = minCutoff + beta * abs(dxHat)

        xHat = GestureSmoothing.ema(x, xHat, GestureSmoothing.alphaFromCutoff(cutoff, te))
        return xHat
    }
}
