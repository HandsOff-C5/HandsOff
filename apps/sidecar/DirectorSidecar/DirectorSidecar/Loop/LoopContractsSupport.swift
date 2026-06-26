//
//  LoopContractsSupport.swift
//  DirectorSidecar
//
//  Construction seams the autonomous loop (Track A) needs over the decode-ONLY contract types.
//  Several contract types (`IntentInput`, `Contracts.CuaWindowState`) declare a custom
//  `init(from:)` so they faithfully reject malformed JSON — which suppresses the synthesized
//  memberwise initializer. The loop, like the TS controller, PRODUCES these in memory every
//  tick (rebuilding the per-tick `IntentInput`, projecting a live driver window-state into the
//  observation record), so this file adds the memberwise inits + the small accessors/mappers the
//  loop composes. Kept OUT of the contract files (mirrors ResolvedIntentFactory / StepDispatch's
//  construction extensions) so the contract ports stay pure decoders independently owned.
//

import Foundation

// MARK: - IntentInput construction (custom init(from:) suppresses the memberwise init)

extension Contracts.IntentInput {
    init(
        sessionId: String,
        finalTranscript: Contracts.FinalTranscript,
        pointingEvidence: [Contracts.PointingEvidence],
        surfaceCandidates: [Contracts.SurfaceSnapshot],
        goalSession: Contracts.GoalSessionInput?
    ) {
        self.sessionId = sessionId
        self.finalTranscript = finalTranscript
        self.pointingEvidence = pointingEvidence
        self.surfaceCandidates = surfaceCandidates
        self.goalSession = goalSession
    }

    /// An immutable copy overriding only the named fields — the controller's per-tick
    /// `{ ...run.baseInput, pointingEvidence, surfaceCandidates, goalSession }` spread.
    func with(
        pointingEvidence: [Contracts.PointingEvidence]? = nil,
        surfaceCandidates: [Contracts.SurfaceSnapshot]? = nil,
        goalSession: Contracts.GoalSessionInput?
    ) -> Contracts.IntentInput {
        Contracts.IntentInput(
            sessionId: sessionId,
            finalTranscript: finalTranscript,
            pointingEvidence: pointingEvidence ?? self.pointingEvidence,
            surfaceCandidates: surfaceCandidates ?? self.surfaceCandidates,
            goalSession: goalSession)
    }
}

// MARK: - Contract window-state construction + adapter projection

extension Contracts.CuaWindowState {
    init(surface: Contracts.SurfaceSnapshot, capturedAt: String, elementCount: Int, elements: [Contracts.CuaElement]) {
        self.surface = surface
        self.capturedAt = capturedAt
        self.elementCount = elementCount
        self.elements = elements
    }
}

extension CuaWindowState {
    /// Project the adapter's RICH window state (its `surface` is the full `CuaWindow` superset)
    /// onto the PLAIN `Contracts.CuaWindowState` the loop's observation record + audit trail use
    /// (its `surface` is a `SurfaceSnapshot`). PORTING.md notes 3/4/6: the two are deliberately
    /// distinct families; the loop is where the rich adapter output crosses into the audit shape.
    var asContractState: Contracts.CuaWindowState {
        Contracts.CuaWindowState(
            surface: surface.surface,
            capturedAt: capturedAt,
            elementCount: elementCount,
            elements: elements.map {
                Contracts.CuaElement(id: $0.id, index: $0.index, role: $0.role, label: $0.label, value: $0.value)
            })
    }
}

// MARK: - ResolvedIntent accessors the controller reads

extension Contracts.ResolvedIntent {
    /// The intent's own id, regardless of status (the controller's `next.id`). For a `ready`
    /// intent the AUDIT actionId is its `action_plan.id`, not this — see `recordIntent`.
    var id: String {
        switch self {
        case let .ready(ready): return ready.id
        case let .needsClarification(pending), let .blocked(pending): return pending.id
        case let .satisfied(satisfied): return satisfied.id
        }
    }

    /// The input the resolver saw (carried on every variant), for the interrupt/blocked records.
    var input: Contracts.IntentInput {
        switch self {
        case let .ready(ready): return ready.input
        case let .needsClarification(pending), let .blocked(pending): return pending.input
        case let .satisfied(satisfied): return satisfied.input
        }
    }

    /// True only for the terminal `satisfied` status (the controller's `next.status === "satisfied"`).
    var isSatisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }
}
