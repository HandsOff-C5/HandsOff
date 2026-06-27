import Foundation

// SL-3 — Hand / fingertip-pointer tuned-knob surface. Lives in its OWN file (not the base
// `Config/Params.swift`) so the hand slice never contends with face / calibration / voice on
// the base Params surface. Values mirror `docs/TUNING_RUNBOOK.md §4` (hand) and `§3` (the
// shared 1€ filter knobs). `I3` — every value is a START POINT, tuned by measurement at the
// on-Mac SL-3 gate; the worked test targets (`CLAUDE §5.3`) pin the FORMULAS, not these seeds.

extension Params {

    /// Hand / index-fingertip-pointer knobs (SL-3).
    public enum hand {

        /// Minimum index-fingertip confidence before a frame is accepted. Below this the
        /// pointer freezes and holds the last good point (`FR-16`, `I6`) — never `(0,0)`.
        /// The index-MCP joint is gated by the SAME floor for the validity check (`IndexTip`).
        /// START 0.5.
        public static let minConfidence: Double = 0.5

        /// Edge-padding of the comfortable pointing region (`FR-17`). The fingertip's
        /// normalized `[inset, 1−inset]²` sub-rectangle maps to the FULL screen via the SL-2
        /// homography, so the user reaches every screen corner without splaying to the camera
        /// frame edges. START 0.2 (a 60%-wide active region centered in the frame).
        public static let activeRegionInset: Double = 0.2

        /// Control/Display gain-curve exponent (`FR-18`/§5, reused from the face `GainCurve`).
        /// `pow(normalized, cdGainExponent)` — gentle near rest, accelerating toward the edge,
        /// with the unit endpoints fixed (`0→0`, `1→1`). START 1.35 (the salvaged shared value;
        /// it is also the SL-1 Filtering-gate A/B context). Tuned only at the on-Mac gate (I3).
        ///
        /// The shared 1€-filter knobs the hand pointer smooths with live in their OWN namespace
        /// (`Params.filter.*`, `Config/Params+Filter.swift`) since the filter spans face + hand.
        public static let cdGainExponent: Double = 1.35
    }
}
