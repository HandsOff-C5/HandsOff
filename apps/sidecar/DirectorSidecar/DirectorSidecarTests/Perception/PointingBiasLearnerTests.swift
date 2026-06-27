import XCTest
@testable import DirectorSidecar

/// S2·T4 — per-user pointing-bias + integration-window learner (FR-19). Adopted from trackall
/// perception. Two slowly-EMA-learned parameters refine the pointing path, and BOTH learn ONLY
/// from CONFIRMED selections: this confirmed-only rule is the security-relevant invariant
/// (INV-5/INV-12 spirit) — an unconfirmed / attacker-influenced sample must NEVER move the model,
/// so raw pointing cannot poison the owner's calibration. Pure + deterministic (INV-14): no clock,
/// no RNG; samples are fed in. (RESEARCH_CONVERGENCE §7.)
final class PointingBiasLearnerTests: XCTestCase {

    func test_offsetConvergesFromConfirmedSelections() {
        let bias = PixelPoint(x: -12, y: 20) // predicted = actual + bias (systematic error)
        let actuals: [PixelPoint] = [
            PixelPoint(x: 200, y: 150), PixelPoint(x: 1700, y: 300), PixelPoint(x: 960, y: 540),
            PixelPoint(x: 480, y: 880), PixelPoint(x: 1450, y: 700), PixelPoint(x: 100, y: 1000),
            PixelPoint(x: 1820, y: 90), PixelPoint(x: 760, y: 420),
        ]
        func predicted(_ a: PixelPoint) -> PixelPoint { PixelPoint(x: a.x + bias.x, y: a.y + bias.y) }

        var learner = PointingBiasLearner(offsetSmoothing: 0.5)
        func residual(_ a: PixelPoint) -> Double {
            let c = learner.correct(predicted(a))
            let dx: Double = c.x - a.x
            let dy: Double = c.y - a.y
            return (dx * dx + dy * dy).squareRoot()
        }

        let start = residual(actuals[0])
        let expectedStart = (12.0 * 12.0 + 20.0 * 20.0).squareRoot()
        XCTAssertEqual(start, expectedStart, accuracy: 1e-9)

        for a in actuals { learner.observeConfirmed(predicted: predicted(a), actual: a) }

        XCTAssertEqual(learner.offset.x, -bias.x, accuracy: 1.0)
        XCTAssertEqual(learner.offset.y, -bias.y, accuracy: 1.0)
        XCTAssertLessThan(residual(actuals[0]), start * 0.1, "confirmed updates drive residual down ≥10×")
    }

    func test_defaultOffsetSmoothing_isPoint3() {
        // The steady default EMA weight is 0.3.
        var learner = PointingBiasLearner()
        learner.observeConfirmed(predicted: PixelPoint(x: 0, y: 0), actual: PixelPoint(x: 100, y: 0))
        // After one step: offset.x = 0.3 * 100 = 30.
        XCTAssertEqual(learner.offset.x, 30, accuracy: 1e-9, "default offsetSmoothing == 0.3")
    }

    func test_integrationWindow_learnsFromConfirmed_rejectsUnconfirmed() {
        var learner = PointingBiasLearner(offsetSmoothing: 0.5, initialWindowMs: 600, windowSmoothing: 0.5)
        XCTAssertEqual(learner.integrationWindowMs, 600, accuracy: 1e-9)
        for ms in [150.0, 160, 140, 155, 145, 150, 158, 142] {
            learner.observeConfirmed(predicted: PixelPoint(x: 500, y: 500),
                                     actual: PixelPoint(x: 500, y: 500), gestureDurationMs: ms)
        }
        XCTAssertLessThan(learner.integrationWindowMs, 300, "quick confirmer ⇒ shorter window")

        // confirmed-only: an unconfirmed sample must move NOTHING and return false.
        let offsetBefore = learner.offset
        let windowBefore = learner.integrationWindowMs
        let moved = learner.observeUnconfirmed(
            predicted: PixelPoint(x: 9999, y: -9999), actual: PixelPoint(x: 0, y: 0), gestureDurationMs: 10)
        XCTAssertFalse(moved, "observeUnconfirmed rejects the sample")
        XCTAssertEqual(learner.offset.x, offsetBefore.x, accuracy: 1e-12)
        XCTAssertEqual(learner.offset.y, offsetBefore.y, accuracy: 1e-12)
        XCTAssertEqual(learner.integrationWindowMs, windowBefore, accuracy: 1e-12)
    }
}
