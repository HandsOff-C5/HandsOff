//
//  AttentionRegion.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts head-pointing.ts `attentionRegionCandidateSchema` — a ranked
//  attention region: the surface a head/face cue resolved toward, its score, and the distance to it.
//  The head-face fixtures (#29) carry these as the gesture lane's output candidates; the head-track
//  attention ranking (AttentionRanking — recreated from candidates.ts/.rs) is their producer.
//

import Foundation

extension Contracts {
    /// `attentionRegionCandidateSchema`: `score` in [0,1], `distance` non-negative (bounds enforced
    /// TS-side; decode keeps the raw value).
    struct AttentionRegionCandidate: Codable, Equatable, Sendable {
        let surface: SurfaceSnapshot
        let score: Double
        let distance: Double
    }
}
