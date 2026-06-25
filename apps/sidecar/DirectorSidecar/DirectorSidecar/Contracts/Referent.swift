//
//  Referent.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts referent.ts `selectedReferentSchema` — the persisted
//  deictic referent (*what* the user pointed at). Persisting it is what lets the audit
//  trail replay a selection (#23).
//
//  Scope note: the gesture-pipeline schema-only types (Landmark/Hand/LandmarkFrame/
//  PointingCandidate/LockedReferent/…) in referent.ts are NOT ported here — they belong to
//  the gesture lane (area:gesture), not the contracts-first / audit decode path.
//

import Foundation

extension Contracts {
    /// Which perception modality produced the referent. `fusion` == resolved from more
    /// than one cue (e.g. a gesture narrowed by gaze).
    enum ReferentSource: String, Codable, Sendable, CaseIterable {
        case gesture
        case gaze
        case head
        case fusion
    }

    /// `selectedReferentSchema`: a stable id, the modality, and the confidence in [0,1].
    /// (The [0,1] bound is enforced TS-side; decode keeps the raw value.)
    struct SelectedReferent: Codable, Sendable, Equatable {
        let id: String
        let source: ReferentSource
        let confidence: Double
    }
}
