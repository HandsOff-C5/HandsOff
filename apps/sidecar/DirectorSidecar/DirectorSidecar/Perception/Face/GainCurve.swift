import Foundation

/// Gain / acceleration curve for the edge-mode velocity drive (`FR-10`).
///
/// The normalized drive magnitude (`0…1`, how far past the dead-zone the head is pushed) is
/// shaped by `pow(_, gainExponent)` — a convex curve that is gentle near rest (fine control)
/// and accelerates as the push grows. The resulting velocity is scaled by a per-second pixel
/// ceiling that grows with the user's chosen reach `speed`:
///
///   `maxPixelsPerSecond = gainBase + speed · gainSpeedScale`  (`180 + speed·90`)
///
/// Ported verbatim from the salvaged head-track motion. The shared `pow(_, 1.35)` exponent is
/// reused by the SL-3 hand C/D gain (`CDGainTests::testPow135GainMatchesFaceCurve`).
public struct GainCurve {

    private let exponent: Double
    private let base: Double
    private let speedScale: Double

    public init(
        exponent: Double = Params.face.gainExponent,
        base: Double = Params.face.gainBase,
        speedScale: Double = Params.face.gainSpeedScale
    ) {
        self.exponent = exponent
        self.base = base
        self.speedScale = speedScale
    }

    /// Shape a normalized drive magnitude `0…1` by the gain exponent. `0 → 0`, `1 → 1`,
    /// monotonic increasing and convex (values in `(0,1)` sit below the linear line).
    public func shape(_ normalized: Double) -> Double {
        pow(normalized, exponent)
    }

    /// Per-second pixel velocity ceiling for a given reach `speed`.
    public func maxPixelsPerSecond(speed: Double) -> Double {
        base + speed * speedScale
    }
}
