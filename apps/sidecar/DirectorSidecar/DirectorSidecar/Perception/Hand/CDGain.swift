import Foundation

/// Control/Display gain curve for the hand pointer (`SL-3`, `I3`).
///
/// Reuses the SAME convex `pow(_, exponent)` shaping as the face `GainCurve` (exponent 1.35):
/// gentle near rest (fine control) and accelerating toward the edge, with the unit endpoints
/// fixed (`0 → 0`, `1 → 1`, so the active-region corners stay exactly reachable). It is a
/// START POINT only (`I3` — measured, not seed): the on-Mac SL-3 gate records the `.indexTip`
/// reach feel and tunes `Params.hand.cdGainExponent` from there (`TUNING_RUNBOOK §4`).
///
/// Kept a standalone, independently-tested primitive (as `GainCurve` is for the face): the
/// fingertip pointer ships an absolute active-region mapping; the C/D reach shaping is enabled
/// and tuned at the gate.
public struct CDGain {

    private let exponent: Double

    public init(exponent: Double = Params.hand.cdGainExponent) {
        self.exponent = exponent
    }

    /// Shape a normalized drive magnitude `0…1` by the gain exponent. `0 → 0`, `1 → 1`,
    /// monotonic increasing and convex — identical to the face `GainCurve.shape` at exponent
    /// 1.35 (the shared curve, `CDGainTests::testPow135GainMatchesFaceCurve`).
    public func shape(_ normalized: Double) -> Double {
        pow(normalized, exponent)
    }
}
