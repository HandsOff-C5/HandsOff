//
//  PointingReferent.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts referent.ts pointing-pipeline OUTPUT schemas — the
//  downstream side the calibration (#26) and state machine (#27) emit:
//  `CalibrationQuality`, `PointingCandidate`, `LockedReferent`, `GestureState`,
//  `InterruptIntent`. The intent engine consumes `PointingCandidate`; `SelectedReferent`
//  (Referent.swift) is the persisted audit result.
//

import Foundation

extension Contracts {
    /// Calibration-fit quality bucket, derived from the RMS reprojection residual.
    enum CalibrationQuality: String, Codable, Sendable, CaseIterable {
        case good
        case fair
        case poor
    }

    /// A pointing referent candidate — output of calibration (#26). Not yet committed.
    /// `confidence` is in [0,1] (enforced TS-side; always in range as constructed here).
    struct PointingCandidate: Codable, Equatable, Sendable {
        let targetId: String
        let confidence: Double
        let calibrationQuality: CalibrationQuality
    }

    /// A candidate promoted to a locked referent by the state machine (#27).
    struct LockedReferent: Codable, Equatable, Sendable {
        let targetId: String
        let confidence: Double
        let lockedAtMs: Double
    }

    /// Gesture state-machine phases (#27).
    enum GestureState: String, Codable, Sendable, CaseIterable {
        case idle
        case candidate
        case locked
        case interrupt
    }

    /// Explicit interrupt emitted by cancel / pause / stop gestures (#27) — the
    /// always-available interrupt path from FINAL_PLANNING AD5.
    struct InterruptIntent: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case pause
            case stop
            case cancel
        }
        let kind: Kind
    }
}
