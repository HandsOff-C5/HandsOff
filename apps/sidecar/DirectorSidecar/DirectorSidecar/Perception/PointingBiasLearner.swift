// PointingBiasLearner — per-user adaptation of the pointing-bias offset and the gesture
// integration window (FR-19). Ported near-verbatim from trackall/packages/perception
// (RESEARCH_CONVERGENCE §7; MIGRATION §8 — "EVALUATE/PORT").
//
// Two slowly-learned per-owner parameters refine the pointing path:
//   • offset (PixelPoint) — the systematic ray error. The 2D webcam ray lands with a consistent
//     bias; an EMA over CONFIRMED (predicted, actual) residuals converges to the compensating
//     offset, so `correct(predicted)` lands on the true target.
//   • integrationWindowMs — how long pointing is integrated before commit; an EMA over confirmed
//     gesture durations adapts it to the user's pace.
//
// CONFIRMED-ONLY (security-relevant — INV-5/INV-12 spirit, FR-19 "learns only from confirmed"):
// only a user-CONFIRMED commit may move the model. `observeUnconfirmed(…)` makes that boundary
// explicit — it rejects the sample and returns `false`, never touching offset or window. Raw /
// unconfirmed (attacker-influenceable) pointing therefore cannot poison the owner's calibration.
//
// Determinism (INV-14): pure value type, EMA arithmetic only. No clock, no RNG, no model (INV-1)
// — timestamps/durations are FED IN. Identical confirmed samples in identical order produce an
// identical offset and window.


/// Online learner for the per-user pointing-bias offset and gesture integration window. Updates
/// ONLY from confirmed selections.
struct PointingBiasLearner: Sendable {

    /// The learned compensating offset, in backing-store pixels. Added to a raw ray prediction by
    /// `correct(_:)`. Starts at zero (no correction).
    private(set) var offset: PixelPoint

    /// The learned gesture integration window, in milliseconds.
    private(set) var integrationWindowMs: Double

    /// EMA weight for the offset update (0…1). Higher ⇒ faster convergence, less noise rejection.
    private let offsetSmoothing: Double

    /// EMA weight for the integration-window update (0…1).
    private let windowSmoothing: Double

    /// - Parameters:
    ///   - offsetSmoothing: EMA weight for offset updates (default 0.3 — steady).
    ///   - initialWindowMs: starting integration window (default 250ms).
    ///   - windowSmoothing: EMA weight for window updates (default 0.3).
    init(
        offsetSmoothing: Double = 0.3,
        initialWindowMs: Double = 250,
        windowSmoothing: Double = 0.3
    ) {
        self.offset = PixelPoint(x: 0, y: 0)
        self.integrationWindowMs = initialWindowMs
        self.offsetSmoothing = offsetSmoothing
        self.windowSmoothing = windowSmoothing
    }

    /// Apply the learned offset to a raw ray prediction.
    func correct(_ predicted: PixelPoint) -> PixelPoint {
        PixelPoint(x: predicted.x + offset.x, y: predicted.y + offset.y)
    }

    /// Learn the pointing-bias offset from ONE confirmed selection: the ray's predicted screen
    /// point and the actually-confirmed target. The residual the offset must cancel is
    /// `(actual − predicted)`; an EMA folds it into `offset`.
    mutating func observeConfirmed(predicted: PixelPoint, actual: PixelPoint) {
        let residualX = actual.x - predicted.x
        let residualY = actual.y - predicted.y
        offset = PixelPoint(
            x: ema(offset.x, toward: residualX, weight: offsetSmoothing),
            y: ema(offset.y, toward: residualY, weight: offsetSmoothing)
        )
    }

    /// Learn from ONE confirmed selection including its gesture timing: updates the offset as
    /// above AND folds the confirmed gesture duration into the integration window via an EMA.
    mutating func observeConfirmed(
        predicted: PixelPoint,
        actual: PixelPoint,
        gestureDurationMs: Double
    ) {
        observeConfirmed(predicted: predicted, actual: actual)
        integrationWindowMs = ema(integrationWindowMs, toward: gestureDurationMs, weight: windowSmoothing)
    }

    /// An UNCONFIRMED selection. The confirmed-only guard made explicit: the sample is REJECTED —
    /// neither offset nor window moves — and `false` is returned. Unconfirmed/attacker-influenced
    /// pointing cannot poison the model (FR-19, INV-5/INV-12 spirit).
    @discardableResult
    mutating func observeUnconfirmed(
        predicted: PixelPoint,
        actual: PixelPoint,
        gestureDurationMs: Double
    ) -> Bool {
        false
    }

    /// One exponential-moving-average step: `(1−w)·current + w·sample`.
    private func ema(_ current: Double, toward sample: Double, weight w: Double) -> Double {
        (1 - w) * current + w * sample
    }
}
