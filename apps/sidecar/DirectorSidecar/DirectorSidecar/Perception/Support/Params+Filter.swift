import Foundation

// Shared 1€-filter tuned-knob surface (`D3`, `FR-18`). The 1€ filter lives in a SHARED home
// (`Models/Filtering/OneEuroFilter.swift`) because it spans two slices: SL-3 hand pointing uses
// it as the shipping smoother, and it is the A/B challenger to SL-1's bespoke face EMA. Its
// knobs therefore get their OWN `Params.filter` namespace (not nested under `hand` or `face`),
// mirrored in `docs/TUNING_RUNBOOK.md §3`. `I3` — START POINTS, tuned at the on-Mac Filtering
// gate; the §5.3 worked test pins the FORMULA (α = 1/(1+τ/Te)), not these seeds.

extension Params {

    /// Shared 1€-filter knobs (Filtering gate — face A/B + hand shipping).
    public enum filter {

        /// Baseline cutoff at low speed (Hz). Lower → less jitter, more lag. With `beta = 0`
        /// this is the FIXED cutoff at all speeds (a plain low-pass EMA). START 1.0 (`§5.3`).
        public static let minCutoffHz: Double = 1.0

        /// Speed coefficient. Higher → less lag on fast motion, more jitter. `0` makes the
        /// filter a fixed-α EMA (the §5.3 worked case: doubling velocity does not change α).
        /// START 0.0 — the shipping start point; the on-Mac gate raises it until fast-move lag
        /// is gone (`RESEARCH Q4`: never ship β=0 in the general case).
        public static let beta: Double = 0.0

        /// Cutoff for the derivative's own low-pass (Hz). START 1.0 (`§5.3`).
        public static let dCutoffHz: Double = 1.0
    }
}
