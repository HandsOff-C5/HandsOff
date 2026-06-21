import type {
  GestureState,
  InterruptIntent,
  LockedReferent,
  PointingCandidate,
} from "@handsoff/contracts";

// Pure gesture FSM (#27): turns smoothed/guarded perception events into bounded,
// previewable states. No I/O, no timers — timestamps and the #28 dwell verdict
// are passed in, so it's exhaustively unit-testable.
// See docs/research/gesture/state-machine.md. Scope: point/hold/cancel/pause/stop
// only — no drag/scroll/pan/zoom.

export interface GestureMachineState {
  // The current phase — a plain value, so "visible before act" is trivial (AC).
  phase: GestureState; // "idle" | "candidate" | "locked" | "interrupt"
  // The target being pointed at while engaged; null when idle.
  candidate: PointingCandidate | null;
  // The committed referent once locked; null otherwise.
  locked: LockedReferent | null;
}

export type GestureEvent =
  // Perception sees a pointing candidate (above the smoothed enter-threshold).
  | { type: "point"; candidate: PointingCandidate }
  // A sustained-hold tick; locks only if the dwell guard is satisfied.
  | { type: "hold"; timestampMs: number }
  // Explicit cancel gesture — abandons the selection.
  | { type: "cancel" }
  // Always-available interrupt gestures.
  | { type: "pause" }
  | { type: "stop" }
  // Candidate lost / dwell timed out.
  | { type: "lost" };

export interface GestureGuards {
  // Whether #28's dwellDebounce has confirmed a sustained hold this tick.
  dwellSatisfied?: boolean;
}

export interface ReduceResult {
  state: GestureMachineState;
  // Side-effect intents the host acts on (lock a referent / raise an interrupt).
  emit?: LockedReferent | InterruptIntent;
}

export function initialState(): GestureMachineState {
  return { phase: "idle", candidate: null, locked: null };
}

const engaged = (phase: GestureState): boolean => phase === "candidate" || phase === "locked";

// Pure transition function. Illegal transitions are no-ops (state returned unchanged).
export function reduce(
  state: GestureMachineState,
  event: GestureEvent,
  guards: GestureGuards = {},
): ReduceResult {
  switch (event.type) {
    case "point": {
      // (Re)acquire a candidate from idle/candidate, or recover after an interrupt.
      // While locked the referent is already chosen — ignore new points.
      if (state.phase === "locked") return { state };
      return { state: { phase: "candidate", candidate: event.candidate, locked: null } };
    }

    case "hold": {
      // Only candidate→locked, and only once the dwell guard fires (#28). This is
      // the gate that stops a single noisy frame from locking.
      if (state.phase === "candidate" && guards.dwellSatisfied && state.candidate) {
        const locked: LockedReferent = {
          targetId: state.candidate.targetId,
          confidence: state.candidate.confidence,
          lockedAtMs: event.timestampMs,
        };
        return { state: { phase: "locked", candidate: state.candidate, locked }, emit: locked };
      }
      return { state };
    }

    case "cancel": {
      if (engaged(state.phase)) return { state: initialState(), emit: { kind: "cancel" } };
      return { state };
    }

    case "pause":
    case "stop": {
      if (engaged(state.phase)) {
        return {
          state: { phase: "interrupt", candidate: state.candidate, locked: state.locked },
          emit: { kind: event.type },
        };
      }
      return { state };
    }

    case "lost": {
      // A lost candidate or a timed-out interrupt resets to idle. A committed
      // (locked) referent is not silently dropped here.
      if (state.phase === "candidate" || state.phase === "interrupt")
        return { state: initialState() };
      return { state };
    }
  }
}
