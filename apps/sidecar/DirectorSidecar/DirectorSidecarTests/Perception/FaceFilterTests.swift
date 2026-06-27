import Testing
import Foundation
import CoreGraphics
@testable import DirectorSidecar

// Adaptive EMA — the bespoke salvaged head-track smoothing, re-homed AS-IS (D3, FR-18-adjacent).
// NOT a 1€ filter. The smoothing factor is:
//   alpha = clamp(0.10 + |v|·0.55 + min(speed·0.025, 0.28), 0.10…0.52)
// where |v| is the current control-vector magnitude and `speed` is the per-second magnitude of
// the change since the previous vector ((raw − previous).magnitude / dt).
//
// A/B TUNING INTENT (TUNING_RUNBOOK §3): this bespoke speed-adaptive EMA is the SHIPPING start
// point; the 1€ filter (SL-3) is the A/B challenger. We re-home this AS-IS rather than swap to
// 1€ here so the face feel is preserved verbatim until measured side-by-side on hardware (I3).

@Test func testAdaptiveEMAReHomedAsIs() {
    let filter = FaceFilter()

    // Case 1: at rest. raw == previous (zero), |v| = 0, speed = 0.
    // alpha = clamp(0.10 + 0 + 0, 0.10…0.52) = 0.10 (the floor).
    let aRest = filter.alpha(
        rawVector: CGPoint(x: 0, y: 0),
        previousVector: CGPoint(x: 0, y: 0),
        dt: 1.0 / 60.0
    )
    #expect(abs(aRest - 0.10) < 1e-9)

    // Case 2: a moderate, steady offset with a small change.
    // raw = (0.2, 0) → |v| = 0.2 ; previous = (0.15, 0) → change = 0.05 over dt = 1/60
    //   speed = 0.05 / (1/60) = 3.0 ; speedTerm = min(3.0·0.025, 0.28) = min(0.075, 0.28) = 0.075
    // alpha = clamp(0.10 + 0.2·0.55 + 0.075, 0.10…0.52) = 0.10 + 0.11 + 0.075 = 0.285.
    let aMid = filter.alpha(
        rawVector: CGPoint(x: 0.2, y: 0),
        previousVector: CGPoint(x: 0.15, y: 0),
        dt: 1.0 / 60.0
    )
    #expect(abs(aMid - 0.285) < 1e-9)

    // Case 3: clamps to the 0.52 ceiling. raw = (1.0, 0) → |v| = 1.0 ;
    //   previous = (0, 0), change = 1.0 over dt = 1/60 → speed = 60 → speedTerm capped at 0.28.
    // raw: 0.10 + 1.0·0.55 + 0.28 = 0.93 → clamped to 0.52.
    let aHigh = filter.alpha(
        rawVector: CGPoint(x: 1.0, y: 0),
        previousVector: CGPoint(x: 0, y: 0),
        dt: 1.0 / 60.0
    )
    #expect(abs(aHigh - 0.52) < 1e-9)

    // Case 4: the EMA blend itself. prev filtered 0, raw 1.0, alpha 0.10 → 0.10.
    let blended = filter.blend(previous: 0.0, raw: 1.0, alpha: 0.10)
    #expect(abs(blended - 0.10) < 1e-12)
}
