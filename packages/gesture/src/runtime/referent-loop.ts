import type {
  CalibrationQuality,
  InterruptIntent,
  LandmarkFrame,
  LockedReferent,
  PointingCandidate,
  Surface,
} from "@handsoff/contracts";

import {
  applyTransform,
  toCandidate,
  type AffineTransform,
  type Point,
} from "../calibration/calibrate";
import { createDwellDebounce, type DwellDebounceParams } from "../confidence/dwell";
import { alphaFromCutoff, createOneEuroFilter, ema } from "../confidence/smoothing";
import {
  isPointingPose,
  pointingReliability,
  pointingSignal,
  type PointingSignalOptions,
} from "../perception/pointing";
import { initialState, reduce, type GestureMachineState } from "../state-machine/machine";

// #25 runtime — the live perception→referent loop. Wires the built pure cores into one
// stateful pipeline: each frame is turned into a pointing candidate (calibration), gated
// by detection confidence (dwell/#28), and fed to the FSM (#27). This is the connective
// tissue the architecture assumes (landmarks → calibration → guards → state machine); it
// is NOT a gesture classifier — "point" is simply a confident pointing hand, "hold" is
// the dwell, interrupts come from voice/button. See docs/research/gesture/epic-overview.md.

export interface ReferentLoopOptions {
  // Calibration transform (raw pointing signal → screen space). Identity = uncalibrated.
  // Ignored when `applyCalibration` is supplied (the multi-monitor path).
  transform: AffineTransform;
  // Multi-monitor calibration applier (raw → global-px). When provided, the loop uses it
  // instead of the single-affine `transform`, so a multi-display fit drives the cursor and
  // candidate hit-test. Optional; the single-screen path omits it.
  applyCalibration?: (raw: Point) => Point;
  // Pointable surfaces in the same coordinate space as the transform output.
  surfaces: Surface[];
  // Quality of the active calibration, carried into the candidate.
  calibrationQuality: CalibrationQuality;
  // Dwell/hysteresis params (#28) gating candidate → locked.
  dwell: DwellDebounceParams;
  // Which hand / ray anchor to read.
  pointing?: PointingSignalOptions;
  // Low-pass cutoff (Hz) for smoothing the referent confidence across frames (#28).
  // Lower = steadier but laggier. Default 2.
  confidenceCutoffHz?: number;
}

export interface ReferentLoopResult {
  state: GestureMachineState;
  // The candidate this frame (for the overlay highlight), or null when no hand / no surface.
  candidate: PointingCandidate | null;
  // The smoothed referent confidence this frame (the value the dwell gates on).
  confidence: number;
  // Dwell engaged — surface for the low-confidence / clarification UI.
  active: boolean;
  // 1€-smoothed screen-space pointer position — the signal for the visible cursor and a
  // steadier feel. Targeting/lock still use the RAW calibrated point; this is display-only.
  point: Point;
  // Per-frame fusion weight for the hand channel, in [0,1] — the gesture lane's own
  // reliability handed across the seam to signal fusion (gaze/voice). Detection score
  // scaled by the least-visible ray endpoint; falls under single-camera occlusion. 0 when
  // no hand is present this frame.
  reliability: number;
  // FSM side-effect this frame (a referent locked, or an interrupt raised).
  emit?: LockedReferent | InterruptIntent;
}

export interface ReferentLoop {
  process(frame: LandmarkFrame, dtMs: number): ReferentLoopResult;
}

export const createReferentLoop = (options: ReferentLoopOptions): ReferentLoop => {
  const {
    transform,
    applyCalibration,
    surfaces,
    calibrationQuality,
    dwell: dwellParams,
    pointing,
    confidenceCutoffHz = 2,
  } = options;
  // Resolve the calibration applier once: the multi-monitor fit when supplied, otherwise the
  // single-affine `transform`. Used for BOTH the visible cursor and the targeting point.
  const applyCalibratedPoint = applyCalibration ?? ((raw: Point) => applyTransform(transform, raw));
  // Hold-to-lock means holding the SAME target: the dwell is reset whenever the pointed
  // target changes (or is lost), so sweeping across surfaces never accumulates to a lock.
  let dwell = createDwellDebounce(dwellParams);
  let lastTargetId: string | null = null;
  // Confidence is EMA-smoothed across frames (#28) before the dwell sees it, so a single
  // spurious frame can't swing engagement.
  let smoothedConfidence = 0;
  // 1€-smooth the screen-space pointer position (x and y independently): steady when the
  // hand holds, low-lag when it moves (research: 1€ > Kalman > EMA for cursor feel). This
  // drives the visible cursor only — targeting/lock stay on the raw point. Held across
  // frames so the cursor doesn't jump when the hand briefly drops out.
  const smoothX = createOneEuroFilter({ minCutoff: 1, beta: 0.007 });
  const smoothY = createOneEuroFilter({ minCutoff: 1, beta: 0.007 });
  let point: Point = [0, 0];
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
      // The hand-channel fusion weight is a raw per-frame signal (occlusion-aware); the
      // consumer smooths/combines it. 0 with no hand so fusion fully discounts us.
      let reliability = 0;
      if (hand) {
        reliability = pointingReliability(hand, pointing);
        const screenXY = applyCalibratedPoint(pointingSignal(hand, pointing));
        // Cursor uses the 1€-smoothed point; targeting/lock use the raw point (unchanged).
        // The cursor tracks whenever a hand is visible, so the user always sees where
        // they're aiming — but only a deliberate index point arms a candidate + confidence,
        // so a hand merely raised in view (open palm, fist) never accumulates a lock.
        point = [
          smoothX.filter(screenXY[0], frame.timestampMs),
          smoothY.filter(screenXY[1], frame.timestampMs),
        ];
        if (isPointingPose(hand)) {
          candidate = toCandidate(screenXY, surfaces, calibrationQuality);
          // Overall referent confidence = detection score × how well it lands on a target.
          confidence = hand.score * (candidate?.confidence ?? 0);
        }
      }

      // Smooth confidence across frames (#28) before it gates anything.
      smoothedConfidence = ema(
        confidence,
        smoothedConfidence,
        alphaFromCutoff(confidenceCutoffHz, dtMs / 1000),
      );

      // Reset the dwell when the target changes or is lost — a lock requires dwelling on
      // one target continuously, not just any confident pointing.
      const targetId = candidate?.targetId ?? null;
      if (targetId !== lastTargetId) {
        dwell = createDwellDebounce(dwellParams);
        lastTargetId = targetId;
      }

      const { active, fired } = dwell.update(smoothedConfidence, dtMs);

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

      return { state, candidate, confidence: smoothedConfidence, active, emit, point, reliability };
    },
  };
};
