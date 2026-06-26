//
//  GazeBracketModel.swift
//  DirectorSidecar
//
//  G7 eye-gaze focus brackets — active overlay #3. Always shown while Director is active
//  (deterministic; no LLM gating). The predicted referent REGION morphs (position + size),
//  smoothed: only the latest-per-ts frame is chased (out-of-order dropped); the view eases the
//  rect. Low confidence dims + holds the last good rect (never chases a guess). On a resolved
//  SelectedReferent the brackets settle (.confirmed). Inactive → hidden.
//

import Foundation
import CoreGraphics
import Observation

enum GazePhase: Equatable, Sendable {
    case hidden
    case tracking        // at rest on the predicted region
    case morphing        // easing position + size to a new region (the signature moment)
    case confirmed       // settled on the resolved referent
    case lowConfidence   // dimmed; holding the last good rect
}

@MainActor
@Observable
final class GazeBracketModel {
    /// The current region the brackets occupy (contract space). The view animates toward it.
    private(set) var region: GazeRegion?
    private(set) var phase: GazePhase = .hidden

    @ObservationIgnored private var active = false
    @ObservationIgnored private var lastTs: Double = 0

    /// Below this, a frame is treated as uncertain — dim + hold last good, do not chase.
    static let confidenceThreshold = 0.45

    var isVisible: Bool { phase != .hidden && region != nil }
    var isDim: Bool { phase == .lowConfidence }

    func setActive(_ on: Bool) {
        active = on
        if !on {
            phase = .hidden
            region = nil
            lastTs = 0
        }
    }

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .gaze(focus):
            applyGaze(focus)
        case let .referents(payload):
            if payload.selected != nil, region != nil { phase = .confirmed }
        case .state, .sessions, .transcript, .intent, .runResult, .audit, .cursor, .error, .unknown:
            break
        }
    }

    func setConnection(_ state: ConnectionState) {
        if state == .engineDown { phase = .hidden; region = nil } // never stranded brackets
    }

    private func applyGaze(_ focus: GazeFocus) {
        guard active else { return }
        guard focus.ts >= lastTs else { return } // stale / out-of-order — drop (smoothing)
        lastTs = focus.ts

        if focus.confidence < Self.confidenceThreshold {
            // Uncertain: hold the last good rect, just dim. Never surface a low-confidence guess.
            if region != nil { phase = .lowConfidence }
            return
        }
        let morphed = region != nil && region != focus.bounds
        region = focus.bounds
        phase = morphed ? .morphing : .tracking
    }
}
