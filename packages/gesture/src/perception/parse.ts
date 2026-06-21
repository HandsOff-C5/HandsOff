import {
  type Hand,
  type LandmarkFrame,
  LandmarkFrame as LandmarkFrameSchema,
} from "@handsoff/contracts";

// Raw MediaPipe HandLandmarker output shape (the subset we consume). The runtime
// (#25) feeds `HandLandmarker.detectForVideo(...)` results straight in; the #29
// fixtures store the same shape. This is the ONLY parser both paths use.
export interface RawLandmark {
  x: number;
  y: number;
  z: number;
  // MediaPipe sometimes omits visibility for the hand landmarker; we default it.
  visibility?: number;
}

export interface RawCategory {
  categoryName: string;
  score: number;
}

export interface RawHandLandmarkerResult {
  // One entry per detected hand; each is its own list of landmarks.
  landmarks: RawLandmark[][];
  // Current field name. One category list per hand; top category is the handedness.
  handednesses?: RawCategory[][];
  // Deprecated alias still emitted by older `@mediapipe/tasks-vision` builds.
  handedness?: RawCategory[][];
}

// Parse a raw MediaPipe result + its capture timestamp into a validated
// `LandmarkFrame`. Empty `landmarks` => no-hand frame. Throws (via the contract)
// on a structurally invalid hand, so bad perception data can't flow downstream.
export function parseLandmarkFrame(
  raw: RawHandLandmarkerResult,
  timestampMs: number,
): LandmarkFrame {
  const categories = raw.handednesses ?? raw.handedness ?? [];

  const hands: Hand[] = raw.landmarks.map((landmarks, i) => ({
    landmarks: landmarks.map((l) => ({
      x: l.x,
      y: l.y,
      z: l.z,
      visibility: l.visibility ?? 1,
    })),
    handedness: categories[i]?.[0]?.categoryName as Hand["handedness"],
    score: categories[i]?.[0]?.score ?? 0,
  }));

  return LandmarkFrameSchema.parse({ timestampMs, hands });
}
