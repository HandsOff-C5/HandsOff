//
//  Clarification.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts clarification.ts `clarificationRequestSchema` — the structured
//  disambiguation ask the engine emits when it can't confidently bind the referent (AD5:
//  clarify below threshold). Embedded by a `clarification_required` ResolvedIntent.
//

import Foundation

extension Contracts {
    /// Why the engine asked.
    enum ClarificationReason: String, Codable, Sendable, CaseIterable {
        case lowConfidence = "low_confidence"
        case ambiguous
        case noTarget = "no_target"
    }

    /// One disambiguation choice. `confidence` is the calibrated score (#100).
    struct ClarificationOption: Codable, Sendable, Equatable {
        let targetId: String
        let label: String
        let surface: SurfaceSnapshot?
        let confidence: Double
    }

    /// `clarificationRequestSchema`: a reason, a human question, and the options. `options`
    /// is empty for `no_target` (the UI shows a re-point prompt).
    struct ClarificationRequest: Codable, Sendable, Equatable {
        let reason: ClarificationReason
        let question: String
        let options: [ClarificationOption]
    }
}
