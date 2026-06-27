import CoreGraphics

/// Identity homography — the no-correction default (maps the active region straight to the
/// screen rect). Additive convenience on the SL-2 `PerceptionHomography` so `ActiveRegion` has a sane
/// default for its (currently unused) in-region correction hook. The live per-display
/// calibration is a `CalibrationFit` applied upstream in `HandModelPlugin` (`RB-3`), NOT a
/// fitted `PerceptionHomography` installed here.
extension PerceptionHomography {
    public static var identity: PerceptionHomography {
        PerceptionHomography(entries: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }
}

/// Edge-padded pointing region → screen mapping (`FR-17`, `I7`, `SL-3`).
///
/// This is the **UNCALIBRATED FALLBACK** mapping (used when no per-display calibration is
/// installed). A comfortable hand-pointing region does not span the whole camera frame —
/// splaying the arm to the frame edges is tiring and imprecise. `ActiveRegion` takes the
/// fingertip's normalized `[inset, 1−inset]²` sub-rectangle and stretches it to fill the screen,
/// so every screen corner is reachable from a relaxed range of motion. The stretched,
/// region-normalized point is passed through the optional in-region `homography` hook (which
/// **defaults to identity = no correction** and is currently unused by the live mapping), and
/// finally placed into the screen rect.
///
/// The real per-display **SL-2 calibration** does NOT live here: it is applied UPSTREAM in
/// `HandModelPlugin` via a `CalibrationFit` (`RB-3`), which drives the whole raw-fingertip →
/// screen mapping itself and BYPASSES `ActiveRegion` entirely. The `homography` field below is a
/// vestigial in-region correction seam, not the calibration path.
///
/// Output is canonical CG **top-left** (`I7`): the region-normalized `v` already grows downward
/// (the `HandModel` lift flipped Vision's bottom-left origin), so no further flip happens here.
///
/// Worked (inset 0.2, screen 1000×800, identity homography): the active-region corners map to
/// the screen corners — `(0.2,0.2)→(0,0)`, `(0.8,0.2)→(1000,0)`, `(0.2,0.8)→(0,800)`,
/// `(0.8,0.8)→(1000,800)`, center `(0.5,0.5)→(500,400)`.
public struct ActiveRegion {

    /// Edge padding (each side) of the active sub-rectangle. `0` is full-frame (no padding).
    public let inset: Double
    /// Optional in-region correction hook in region-normalized space. **Defaults to identity
    /// (no correction)** and is currently unused by the live mapping — the real per-display SL-2
    /// calibration is applied upstream in `HandModelPlugin` via `CalibrationFit` (`RB-3`), which
    /// bypasses `ActiveRegion`. Kept as a seam; not the calibration path.
    public let homography: PerceptionHomography
    /// Control/Display sensitivity curve (`FR-18`). Applied to the region-normalized point as a
    /// **center-relative** shaping with the unit endpoints fixed (`0→0`, `0.5→0.5`, `1→1`) — finer
    /// control near the active-region center, full reach at the edges, corners exactly preserved.
    /// `nil` disables it (pure linear region stretch).
    public let cdGain: CDGain?

    public init(
        inset: Double = Params.hand.activeRegionInset,
        homography: PerceptionHomography = .identity,
        cdGain: CDGain? = CDGain()
    ) {
        self.inset = inset
        self.homography = homography
        self.cdGain = cdGain
    }

    /// Map a normalized fingertip `[0,1]²` (CG top-left) to a screen point in `screen`'s rect.
    /// The active sub-rectangle `[inset, 1−inset]²` is rescaled to `[0,1]²` (clamped at the edges),
    /// shaped by the **CD-gain** sensitivity curve around the region center (`FR-18`), corrected by
    /// the homography, then placed into `screen`. A degenerate inset (`span ≤ 0`) or empty screen
    /// returns the screen center rather than NaN.
    public func map(fingertip: CGPoint, screen: CGRect) -> CGPoint {
        let span = 1 - 2 * inset
        guard span > 0, screen.width > 0, screen.height > 0 else {
            return CGPoint(x: screen.midX, y: screen.midY)
        }
        let u = cdShape(clamp01((Double(fingertip.x) - inset) / span))
        let v = cdShape(clamp01((Double(fingertip.y) - inset) / span))
        let corrected = homography.apply(SIMD2<Double>(u, v))
        return CGPoint(
            x: screen.minX + CGFloat(corrected.x) * screen.width,
            y: screen.minY + CGFloat(corrected.y) * screen.height
        )
    }

    /// CD-gain sensitivity shaping of one region-normalized axis `t ∈ [0,1]`, **center-relative**:
    /// the offset from the center `0.5` is shaped by the gain curve (convex `pow`), keeping the
    /// endpoints `0`/`0.5`/`1` fixed. Result: a given finger displacement near the center moves the
    /// cursor less (fine control), while the edges still reach the corners exactly. `nil` → linear.
    private func cdShape(_ t: Double) -> Double {
        guard let cdGain else { return t }
        let c = t - 0.5
        let mag = abs(c) / 0.5                  // 0 at center … 1 at either edge
        let shaped = cdGain.shape(mag) * 0.5    // endpoints preserved: shape(0)=0, shape(1)=1
        return 0.5 + (c < 0 ? -shaped : shaped)
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}
