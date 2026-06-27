import Testing
import CoreGraphics
import Foundation
@testable import DirectorSidecar

// SL-3 shared 1€ filter (FR-18, §5.3) + the fingertip confidence-freeze (FR-16, I6). The 1€
// primitives are ported verbatim from the gesture TS oracle
// (Conformance/gesture/src/confidence/smoothing.ts); these worked values pin the same recurrence.

private let dtMs = 1000.0 / 60.0   // one 60-fps frame, in milliseconds.

@Test func testOneEuroBetaZeroIsFixedEMA() {
    // §5.3: fcmin=1.0, β=0, dt=1/60 → τ=1/(2π)=0.159155, α = 1/(1+τ/dt) ≈ 0.09479.
    let alpha = alphaFromCutoff(cutoffHz: 1.0, sampleSeconds: 1.0 / 60.0)
    #expect(abs(alpha - 0.09479) < 1e-4)   // the §5.3 worked α.

    let f = PerceptionOneEuroFilter(OneEuroParams(minCutoff: 1, beta: 0, dCutoff: 1))

    // First sample is returned unchanged (seeds the state).
    #expect(f.filter(0, tMs: 0) == 0)

    // Stepping toward 1 with β=0 is a fixed-α EMA: 0 → α → α(2−α).
    let s1 = f.filter(1, tMs: dtMs)
    #expect(abs(s1 - alpha) < 1e-9)              // 0.09479
    let s2 = f.filter(1, tMs: 2 * dtMs)
    #expect(abs(s2 - (alpha + (1 - alpha) * alpha)) < 1e-9)   // 0.18060 (α·(2−α))
}

@Test func testBetaZeroAlphaIndependentOfVelocity() {
    // "Doubling velocity doesn't change α": with β=0 the cutoff is fixed, so the EMA fraction
    // applied to the first step is α regardless of the step magnitude (velocity). A step to 1
    // and a step to 2 (double the velocity over the same dt) yield outputs in the same ratio.
    let slow = PerceptionOneEuroFilter(OneEuroParams(minCutoff: 1, beta: 0, dCutoff: 1))
    let fast = PerceptionOneEuroFilter(OneEuroParams(minCutoff: 1, beta: 0, dCutoff: 1))
    #expect(slow.filter(0, tMs: 0) == 0)
    #expect(fast.filter(0, tMs: 0) == 0)
    let a1 = slow.filter(1, tMs: dtMs)
    let a2 = fast.filter(2, tMs: dtMs)
    #expect(abs(a1 / 1.0 - a2 / 2.0) < 1e-12)   // identical α — velocity-independent.
}

@Test func testOneEuroMatchesOracleDefinitions() {
    // Parity with the oracle's own unit cases (smoothing.test.ts).
    #expect(ema(10, 3, alpha: 1) == 10)               // alpha=1 passthrough.
    #expect(ema(10, 3, alpha: 0) == 3)                // alpha=0 frozen.
    #expect(ema(10, 0, alpha: 0.5) == 5)              // midpoint.
    #expect(abs(alphaFromCutoff(cutoffHz: 1, sampleSeconds: 1) - 0.8627) < 1e-3)
    #expect(alphaFromCutoff(cutoffHz: 5, sampleSeconds: 1)
            > alphaFromCutoff(cutoffHz: 0.5, sampleSeconds: 1))
    // Converges to a constant input (stays put once settled).
    let f = PerceptionOneEuroFilter(OneEuroParams(minCutoff: 1, beta: 0))
    _ = f.filter(5, tMs: 0)
    var t = 50.0
    while t <= 500 { _ = f.filter(5, tMs: t); t += 50 }
    #expect(abs(f.filter(5, tMs: 550) - 5) < 1e-6)
}

@Test func testFreezesOnLowIndexTipConfidence() {
    // A good fingertip seeds the held point (742,318); a run of low-confidence frames must
    // FREEZE, holding it — never (0,0) (I6). The first 1€ sample returns the input unchanged,
    // so the held point is exactly (742,318).
    let filter = HandFilter()
    let held = CGPoint(x: 742, y: 318)
    let good = filter.update(point: held, confidence: 0.9, tMs: 0)
    #expect(good.state == .live)
    #expect(good.point == held)

    var last = good
    for i in 1...6 {   // exceed lostFrameLimit (3) → frozen.
        last = filter.update(
            point: CGPoint(x: 0, y: 0),     // a lost frame's point is irrelevant…
            confidence: 0.1,                // below hand.minConfidence (0.5).
            tMs: Double(i) * dtMs)
    }
    #expect(last.state == .frozen)
    #expect(last.point == held)     // held the last good point…
    #expect(last.point != .zero)    // …never the origin (I6).
}
