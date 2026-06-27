import Foundation

// SL-1 — Face / head-pointer tuned-knob surface. Lives in its OWN file (not
// `Config/Params.swift`) so the parallel hand / calibration / voice slices can edit the base
// Params surface without a merge conflict here. Values mirror `docs/TUNING_RUNBOOK.md §2/§3`.
//
// I3 — measurement-beats-seed: every value below is a START POINT, tuned by measurement on the
// target Mac at the on-Mac SL-1 gate, never auto-rewritten to a seed. The worked test targets
// (CLAUDE §5) pin the FORMULAS, not these defaults.

extension Params {

    /// Face / head-pointer knobs (SL-1).
    public enum face {

        /// Minimum detection confidence before a frame is accepted by the frame gate. Below
        /// this the pointer freezes and holds the last good point (`FR-12`, I6). The salvaged
        /// head-track `FrameGate` used 0.45. START 0.45.
        public static let minConfidence: Double = 0.45

        /// Weight cap on the 3D yaw/pitch fine-correction term (`FR-11`). DEMOTED from the
        /// salvaged 0.55 to a small fine-correction so the 2D nose offset stays dominant
        /// (I3 — measured, not seed). 0 disables the 3D term entirely (pure-2D mapping).
        /// START 0.15 (kept in 0.10–0.20).
        public static let correctionWeight: Double = 0.15

        /// Gain/accel curve exponent applied to the normalized drive magnitude (`FR-10`).
        /// `gain = pow(normalized, gainExponent)`. Salvaged value 1.35. START 1.35.
        public static let gainExponent: Double = 1.35

        /// Max-pixels-per-second velocity curve: `gainBase + speed · gainSpeedScale`
        /// (`FR-10`). Salvaged `180 + speed·90`. At speed 5 → 630 px/s. START 180 / 90.
        public static let gainBase: Double = 180
        public static let gainSpeedScale: Double = 90

        /// Dead-zone (the salvaged `distanceToEdge`): control-vector magnitude below this is
        /// suppressed — no cursor motion at rest (`FR-9`). START 0.12.
        public static let deadZone: Double = 0.12

        /// Hysteresis: the OUTER latch threshold (motion starts once magnitude exceeds it) is
        /// the dead-zone; the INNER threshold (motion stops once magnitude falls below it) is
        /// `deadZone · hysteresisInnerRatio`. Inner ≈ 0.12·0.55 ≈ 0.066 (`FR-9`). START 0.55.
        public static let hysteresisInnerRatio: Double = 0.55
        public static var hysteresisOuter: Double { deadZone }
        public static var hysteresisInner: Double { deadZone * hysteresisInnerRatio }

        /// Adaptive-EMA constants (D3 — bespoke salvaged formula re-homed AS-IS; NOT a 1€
        /// filter). `alpha = clamp(emaBase + |v|·emaVelocityGain + min(speed·emaSpeedGain,
        /// emaSpeedCap), emaMin…emaMax)`. See `FaceFilter`. TUNING_RUNBOOK §3 records the A/B
        /// intent (bespoke EMA vs 1€). START values are the salvaged constants verbatim.
        public static let emaBase: Double = 0.10
        public static let emaVelocityGain: Double = 0.55
        public static let emaSpeedGain: Double = 0.025
        public static let emaSpeedCap: Double = 0.28
        public static let emaMin: Double = 0.10
        public static let emaMax: Double = 0.52

        /// Dwell-to-click (`FR-13`): the cursor must hold within `dwellRadius` for `dwellMs`
        /// before a click fires; after a click a `dwellCooldownMs` window suppresses a refire.
        /// START 500 ms dwell, 800 ms cooldown, 0.04 radius (normalized control units).
        public static let dwellMs: Double = 500
        public static let dwellCooldownMs: Double = 800
        public static let dwellRadius: Double = 0.04

        /// Recenter + auto neutral-drift (`FR-8`): after the control vector stays inside the
        /// inner dead-zone (at rest) for `recenterStableSeconds`, the neutral pose drifts
        /// toward the current pose with a tiny per-frame blend `α ≤ recenterDriftAlpha`.
        /// START 2.0 s, α 0.02.
        public static let recenterStableSeconds: Double = 2.0
        public static let recenterDriftAlpha: Double = 0.02
    }
}
