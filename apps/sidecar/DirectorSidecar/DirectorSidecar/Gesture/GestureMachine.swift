//
//  GestureMachine.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/state-machine/machine.ts (#27) — the pure gesture FSM. Turns
//  smoothed/guarded perception events into bounded, previewable states. No I/O, no timers —
//  timestamps and the #28 dwell verdict are passed in, so it's exhaustively unit-testable.
//  Scope: point/hold/cancel/pause/stop only — no drag/scroll/pan/zoom.
//

import Foundation

struct GestureMachineState: Equatable, Sendable {
    /// The current phase — a plain value, so "visible before act" is trivial.
    var phase: Contracts.GestureState
    /// The target being pointed at while engaged; nil when idle.
    var candidate: Contracts.PointingCandidate?
    /// The committed referent once locked; nil otherwise.
    var locked: Contracts.LockedReferent?
}

enum GestureEvent: Equatable, Sendable {
    /// Perception sees a pointing candidate (above the smoothed enter-threshold).
    case point(candidate: Contracts.PointingCandidate)
    /// A sustained-hold tick; locks only if the dwell guard is satisfied.
    case hold(timestampMs: Double)
    /// Explicit cancel gesture — abandons the selection.
    case cancel
    /// Always-available interrupt gestures.
    case pause
    case stop
    /// Candidate lost / dwell timed out.
    case lost
}

struct GestureGuards: Equatable, Sendable {
    /// Whether #28's dwellDebounce has confirmed a sustained hold this tick.
    var dwellSatisfied: Bool

    init(dwellSatisfied: Bool = false) {
        self.dwellSatisfied = dwellSatisfied
    }
}

struct ReduceResult: Equatable, Sendable {
    let state: GestureMachineState
    /// Side-effect intents the host acts on (lock a referent / raise an interrupt).
    let emit: GestureEmit?

    init(state: GestureMachineState, emit: GestureEmit? = nil) {
        self.state = state
        self.emit = emit
    }
}

/// The FSM's side-effect output — either a locked referent or an interrupt intent. (The TS
/// union `LockedReferent | InterruptIntent`.)
enum GestureEmit: Equatable, Sendable {
    case locked(Contracts.LockedReferent)
    case interrupt(Contracts.InterruptIntent)
}

enum GestureMachine {
    static func initialState() -> GestureMachineState {
        GestureMachineState(phase: .idle, candidate: nil, locked: nil)
    }

    private static func engaged(_ phase: Contracts.GestureState) -> Bool {
        phase == .candidate || phase == .locked
    }

    /// Pure transition function. Illegal transitions are no-ops (state returned unchanged).
    static func reduce(
        _ state: GestureMachineState,
        _ event: GestureEvent,
        _ guards: GestureGuards = GestureGuards()
    ) -> ReduceResult {
        switch event {
        case let .point(candidate):
            // (Re)acquire a candidate from idle/candidate, or recover after an interrupt. While
            // locked the referent is already chosen — ignore new points.
            if state.phase == .locked { return ReduceResult(state: state) }
            return ReduceResult(state: GestureMachineState(phase: .candidate, candidate: candidate, locked: nil))

        case let .hold(timestampMs):
            // Only candidate→locked, and only once the dwell guard fires (#28). The gate that
            // stops a single noisy frame from locking.
            if state.phase == .candidate, guards.dwellSatisfied, let candidate = state.candidate {
                let locked = Contracts.LockedReferent(
                    targetId: candidate.targetId,
                    confidence: candidate.confidence,
                    lockedAtMs: timestampMs
                )
                return ReduceResult(
                    state: GestureMachineState(phase: .locked, candidate: candidate, locked: locked),
                    emit: .locked(locked)
                )
            }
            return ReduceResult(state: state)

        case .cancel:
            if engaged(state.phase) {
                return ReduceResult(state: initialState(), emit: .interrupt(Contracts.InterruptIntent(kind: .cancel)))
            }
            return ReduceResult(state: state)

        case .pause:
            if engaged(state.phase) {
                return ReduceResult(
                    state: GestureMachineState(phase: .interrupt, candidate: state.candidate, locked: state.locked),
                    emit: .interrupt(Contracts.InterruptIntent(kind: .pause))
                )
            }
            return ReduceResult(state: state)

        case .stop:
            if engaged(state.phase) {
                return ReduceResult(
                    state: GestureMachineState(phase: .interrupt, candidate: state.candidate, locked: state.locked),
                    emit: .interrupt(Contracts.InterruptIntent(kind: .stop))
                )
            }
            return ReduceResult(state: state)

        case .lost:
            // A lost candidate or a timed-out interrupt resets to idle. A committed (locked)
            // referent is not silently dropped here.
            if state.phase == .candidate || state.phase == .interrupt {
                return ReduceResult(state: initialState())
            }
            return ReduceResult(state: state)
        }
    }
}
