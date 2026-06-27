import CoreGraphics

/// Recenter + auto neutral-drift (`FR-8`), ported from the salvaged head-track motion.
///
/// The face pointer measures every pose as an OFFSET from a captured NEUTRAL pose. Two things
/// keep that neutral honest:
///
/// 1. **Explicit recenter** (`requestRecenter`) — the next observed pose is adopted wholesale
///    as the new neutral, so the user can re-home the cursor with a hotkey.
/// 2. **Auto neutral-drift** — when the control vector stays at-rest for
///    `recenterStableSeconds` (2.0 s), the neutral slowly DRIFTS toward the current pose with a
///    tiny per-frame blend `alpha = min(dt · recenterDriftAlpha, recenterDriftAlpha)`, always
///    `≤ recenterDriftAlpha` (0.02). This absorbs slow postural change without yanking the
///    cursor. Any non-at-rest frame resets the stable timer (no drift while you are moving).
public struct Recenter {

    /// The captured neutral pose; `nil` until the first observation.
    public private(set) var neutral: FaceSignal?
    /// The drift `alpha` applied on the most recent frame (for assertions / telemetry).
    public private(set) var lastDriftAlpha: Double = 0

    private let stableSeconds: Double
    private let driftAlpha: Double

    private var pendingRecenter = false
    private var stableTime: Double = 0

    public init(
        stableSeconds: Double = Params.face.recenterStableSeconds,
        driftAlpha: Double = Params.face.recenterDriftAlpha
    ) {
        self.stableSeconds = stableSeconds
        self.driftAlpha = driftAlpha
    }

    /// Request that the next observed pose become the new neutral.
    public mutating func requestRecenter() {
        pendingRecenter = true
    }

    /// Feed a frame. `atRest` is whether the control vector is inside the dead-zone (supplied
    /// by `DeadZone`); `dt` is the frame delta in seconds. Updates `neutral` per the recenter /
    /// drift rules.
    public mutating func observe(_ signal: FaceSignal, atRest: Bool, dt: Double) {
        lastDriftAlpha = 0

        // First observation, or an explicit recenter, snaps neutral to this pose.
        if neutral == nil || pendingRecenter {
            neutral = signal
            pendingRecenter = false
            stableTime = 0
            return
        }

        guard atRest else {
            // Moving → reset the stable window, no drift.
            stableTime = 0
            return
        }

        stableTime += dt
        guard stableTime >= stableSeconds, let current = neutral else { return }

        // Past the stable window: drift the neutral toward the current pose by a tiny alpha.
        let alpha = min(dt * driftAlpha, driftAlpha)
        lastDriftAlpha = alpha
        neutral = current.blended(with: signal, alpha: alpha)
    }
}
