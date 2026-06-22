import type {
  CalibrationQuality,
  InterruptIntent,
  LandmarkFrame,
  LockedReferent,
  PointingCandidate,
  Surface,
} from "@handsoff/contracts";

import { applyTransform, toCandidate, type AffineTransform } from "../calibration/calibrate";
import { createDwellDebounce, type DwellDebounceParams } from "../confidence/dwell";
import { pointingSignal, type PointingSignalOptions } from "../perception/pointing";
import { initialState, reduce, type GestureMachineState } from "../state-machine/machine";

// #25 runtime — the live perception→referent loop. Wires the built pure cores into one
// stateful pipeline: each frame is turned into a pointing candidate (calibration), gated
// by detection confidence (dwell/#28), and fed to the FSM (#27). This is the connective
// tissue the architecture assumes (landmarks → calibration → guards → state machine); it
// is NOT a gesture classifier — "point" is simply a confident pointing hand, "hold" is
// the dwell, interrupts come from voice/button. See docs/research/gesture/epic-overview.md.

export interface ReferentLoopOptions {
  // Calibration transform (raw pointing signal → screen space). Identity = uncalibrated.
  transform: AffineTransform;
  // Pointable surfaces in the same coordinate space as the transform output.
  surfaces: Surface[];
  // Quality of the active calibration, carried into the candidate.
  calibrationQuality: CalibrationQuality;
  // Dwell/hysteresis params (#28) gating candidate → locked.
  dwell: DwellDebounceParams;
  // Which hand / ray anchor to read.
  pointing?: PointingSignalOptions;
}

export interface ReferentLoopResult {
  state: GestureMachineState;
  // The candidate this frame (for the overlay highlight), or null when no hand / no surface.
  candidate: PointingCandidate | null;
  // Dwell engaged — surface for the low-confidence / clarification UI.
  active: boolean;
  // FSM side-effect this frame (a referent locked, or an interrupt raised).
  emit?: LockedReferent | InterruptIntent;
}

export interface ReferentLoop {
  process(frame: LandmarkFrame, dtMs: number): ReferentLoopResult;
}

export const createReferentLoop = (options: ReferentLoopOptions): ReferentLoop => {
  const { transform, surfaces, calibrationQuality, dwell: dwellParams, pointing } = options;
  const dwell = createDwellDebounce(dwellParams);
  let state = initialState();

  const pickHand = (frame: LandmarkFrame) =>
    pointing?.handedness
      ? frame.hands.find((h) => h.handedness === pointing.handedness)
      : frame.hands[0];

  return {
    process(frame, dtMs) {
      const hand = pickHand(frame);

      let candidate: PointingCandidate | null = null;
      let confidence = 0;
      if (hand) {
        const screenXY = applyTransform(transform, pointingSignal(hand, pointing));
        candidate = toCandidate(screenXY, surfaces, calibrationQuality);
        // Overall referent confidence = detection score × how well it lands on a target.
        confidence = hand.score * (candidate?.confidence ?? 0);
      }

      const { active, fired } = dwell.update(confidence, dtMs);

      let emit: LockedReferent | InterruptIntent | undefined;
      if (hand && active && candidate) {
        state = reduce(state, { type: "point", candidate }).state;
        if (fired) {
          const held = reduce(
            state,
            { type: "hold", timestampMs: frame.timestampMs },
            { dwellSatisfied: true },
          );
          state = held.state;
          emit = held.emit;
        }
      } else {
        // No confident pointing hand this frame — a candidate (but not a locked
        // referent) is dropped by the FSM's `lost` transition.
        state = reduce(state, { type: "lost" }).state;
      }

      return { state, candidate, active, emit };
    },
  };
};
