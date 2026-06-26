//
//  ConfidenceCalibration.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/confidence/calibration.ts (#100) — pure temperature scaling of
//  a probability so downstream thresholds (dwell #28, glow, fusion reliability) act on
//  calibrated scores instead of overconfident raw MediaPipe ones. Deterministic in (raw, T).
//

import Foundation

enum ConfidenceCalibration {
    private static func clamp01(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        return p
    }

    /// Temperature-scale a confidence: p' = sigmoid(logit(p) / T). T=1 passthrough; T>1 softens
    /// toward 0.5 (tames overconfidence); T<1 sharpens. 0.5 is a fixed point; raw is clamped to
    /// [0,1]; the ±Infinity logits at the endpoints map back to 0/1 through the sigmoid with no NaN.
    static func calibrateConfidence(_ raw: Double, _ temperature: Double) throws -> Double {
        guard temperature > 0 else {
            throw GestureContractError.outOfRange("temperature must be > 0, got \(temperature)")
        }
        let p = clamp01(raw)
        let logit = Foundation.log(p / (1 - p))
        return 1 / (1 + Foundation.exp(-logit / temperature))
    }
}
