import type { PointingCandidate, PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { calibrateConfidence } from "@handsoff/gesture";

// Adapter (#35): turn a locked gesture pointing candidate + its resolved surface
// into the intent engine's PointingEvidence, so the live referent feeds fuseIntent
// as the deictic "point" channel (~20% of intent). The desktop app is the only
// place allowed to bridge the gesture and intent lanes. When a temperature is
// given the raw MediaPipe score is calibrated first (#100).
export function toGestureEvidence(
  candidate: PointingCandidate,
  surface: SurfaceSnapshot,
  temperature?: number,
): PointingEvidence {
  const confidence =
    temperature === undefined
      ? candidate.confidence
      : calibrateConfidence(candidate.confidence, temperature);
  return {
    source: "gesture",
    confidence,
    strategy: `wrist-ray-calibrated:${candidate.calibrationQuality}`,
    surface,
  };
}
