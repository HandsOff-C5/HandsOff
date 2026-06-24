import type { GazeFeatures } from "./features";

// Live, per-frame eye-tracking confidence in [0,1]: how much to trust THIS frame's iris
// read. It needs no calibration fit — it grades the raw signal so the operator can SEE
// tracking quality on screen, frame by frame, during calibration and use. Pure (STRICT):
// no camera, no clock. Three independent factors are multiplied so any one failing
// (closed eyes, garbage landmarks, eyes disagreeing) pulls confidence down:
//
//   1. openness  — eye-aspect ramps 0→1 between a blink floor and an open reference.
//   2. validity  — iris fractions should sit inside (a little past) the [0,1] band.
//   3. agreement — both eyes' horizontal iris fraction should point the same way.

// Eye-aspect (lid-opening / eye-width) thresholds.
const BLINK_ASPECT = 0.12; // at/below → eyes closed/closing → openness 0
const OPEN_ASPECT = 0.26; // at/above → fully open → openness 1

// How far an iris fraction may drift outside [0,1] (averaged over the 4 fractions)
// before validity reaches 0.
const IRIS_OUT_TOL = 0.6;

// Horizontal disagreement between the two eyes (|irisXL − irisXR|) at which agreement
// reaches 0.
const IRIS_AGREE_TOL = 0.5;

const clamp01 = (v: number): number => (v < 0 ? 0 : v > 1 ? 1 : v);

// How far `v` sits OUTSIDE the [0,1] band (0 when inside).
const outside01 = (v: number): number => (v < 0 ? -v : v > 1 ? v - 1 : 0);

export const eyeTrackingConfidence = (features: GazeFeatures | null): number => {
  if (!features) return 0;
  const { irisXL, irisYL, irisXR, irisYR, eyeAspect } = features;

  const openness = clamp01((eyeAspect - BLINK_ASPECT) / (OPEN_ASPECT - BLINK_ASPECT));

  const drift = (outside01(irisXL) + outside01(irisYL) + outside01(irisXR) + outside01(irisYR)) / 4;
  const validity = clamp01(1 - drift / IRIS_OUT_TOL);

  const agreement = clamp01(1 - Math.abs(irisXL - irisXR) / IRIS_AGREE_TOL);

  return openness * validity * agreement;
};
