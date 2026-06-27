import Foundation

/// The tuned-knob surface for the Signal-lock harness (SL-0).
///
/// **Exactly three knobs live here** — this is the whole tunable surface for SL-0,
/// mirrored in `docs/TUNING_RUNBOOK.md` §1/§2. Structural constants (e.g. the metrics
/// window length) are NOT knobs and deliberately live next to their code, not here.
public enum Params {

    /// Signal / capture knobs (Gate 0 — SL-0).
    public enum capture {
        /// Target capture frame-rate. 60 is the target; 30 is the documented floor used
        /// when the device cannot sustain 60 (enumerate `videoSupportedFrameRateRanges`
        /// first). `FR-3`, `RESEARCH.md Q2`.
        public static let targetFPS: Int = 60

        /// Consecutive dropped/late frames tolerated before the capture path is treated
        /// as lost. `FR-5`, `MASTER.md §3.1`.
        public static let lostFrameLimit: Int = 3

        /// Horizontally mirror the resolved pointer signal so the cursor FOLLOWS the user
        /// (front-camera selfie convention: move left → cursor left). Default `true`. The
        /// flip is applied ONCE at the Vision `resolve(...)` boundary, so the live pointer
        /// AND the calibration capture see the SAME mirrored signal (they stay consistent).
        /// Override at read time with `HANDSOFF_MIRROR_X` (`0`/`false` disables). On-Mac knob.
        public static var mirrorX: Bool {
            guard let raw = ProcessInfo.processInfo.environment["HANDSOFF_MIRROR_X"] else { return true }
            return !(raw == "0" || raw.lowercased() == "false")
        }
    }

    /// Gate knobs.
    public enum gate {
        /// p95 motion-to-photon latency budget, in milliseconds. Default 50 (`NFR-1`,
        /// `SM-1`). Overridable at read time by the `HANDSOFF_LATENCY_BUDGET_MS` env var;
        /// a missing or unparseable value falls back to 50.
        public static var p95LatencyMs: Double {
            let fallback = 50.0
            guard let raw = ProcessInfo.processInfo.environment["HANDSOFF_LATENCY_BUDGET_MS"],
                  let parsed = Double(raw),
                  parsed.isFinite, parsed >= 0  // a negative budget makes the gate always-fail
            else { return fallback }
            return parsed
        }

        /// Latency-jitter budget: the population VARIANCE of motion-to-photon latency (ms²) the
        /// lock tolerates (`I2` — "gate on p95 AND variance", since variable latency reads as
        /// shakiness even when the median is fine). Default 25 ms² (≈ 5 ms std-dev) is a START
        /// point tuned at the on-Mac gate (`TUNING_RUNBOOK §1`); overridable by the
        /// `HANDSOFF_VARIANCE_BUDGET_MS2` env var.
        public static var varianceBudgetMs2: Double {
            let fallback = 25.0
            guard let raw = ProcessInfo.processInfo.environment["HANDSOFF_VARIANCE_BUDGET_MS2"],
                  let parsed = Double(raw),
                  parsed.isFinite, parsed >= 0  // a negative variance budget is nonsensical
            else { return fallback }
            return parsed
        }
    }
}
