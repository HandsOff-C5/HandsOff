import { type Hand, type Handedness, type LandmarkFrame } from "@handsoff/contracts";

import { type Point } from "../calibration/calibrate";

// #25 perception seam — the landmark→pointing-ray extractor that #26 calibration left
// open. Pure: turns a detected `Hand` into the 2D raw pointing signal (normalized image
// coords) that `fitAffine`/`applyTransform` map to a screen point. No camera, no clock.

// MediaPipe hand-landmark indices (the standard 21-point topology).
const WRIST = 0;
const INDEX_FINGER_MCP = 5;
const INDEX_FINGER_PIP = 6;
const INDEX_FINGER_TIP = 8;
const MIDDLE_FINGER_PIP = 10;
const MIDDLE_FINGER_TIP = 12;

export interface PointingSignalOptions {
  // Ray anchor: the wrist (whole-hand direction) or the index MCP (finger-only). The
  // ray runs anchor → index tip. Default "wrist".
  anchor?: "wrist" | "indexMcp";
  // How far past the fingertip to project along the ray, in ray-length units. 0 = the
  // fingertip itself; 1 = one ray-length beyond it (amplifies small directional
  // changes). Default 0 — calibration absorbs the rest. Tuned in #25 on real frames.
  extend?: number;
  // Which hand to read in `pointingSignalFromFrame`. Default: the first detected hand.
  handedness?: Handedness;
}

const xy = (hand: Hand, index: number): Point => {
  const l = hand.landmarks[index];
  if (!l) throw new Error(`pointingSignal: missing landmark ${index}`);
  return [l.x, l.y];
};

const visibilityOf = (hand: Hand, index: number): number => {
  const l = hand.landmarks[index];
  if (!l) throw new Error(`pointingReliability: missing landmark ${index}`);
  return l.visibility;
};

// How trustworthy this frame's pointing ray is, in [0,1] — the gesture lane's own
// reliability, the weight a downstream sensor-fusion stage should give the hand channel
// (the seam to gaze/voice; FINAL_PLANNING late-fusion A = w_g·G + w_e·E). It is the
// detection score scaled by the LEAST-visible of the ray's two endpoints (anchor + index
// tip): with one camera, an occluded endpoint makes the ray DIRECTION unreliable even
// when the hand is detected confidently, so the weight must fall and fusion lean elsewhere.
export const pointingReliability = (hand: Hand, options: PointingSignalOptions = {}): number => {
  const { anchor = "wrist" } = options;
  const anchorVis = visibilityOf(hand, anchor === "wrist" ? WRIST : INDEX_FINGER_MCP);
  const tipVis = visibilityOf(hand, INDEX_FINGER_TIP);
  return hand.score * Math.min(anchorVis, tipVis);
};

const distToWrist = (hand: Hand, index: number): number => {
  const [wx, wy] = xy(hand, WRIST);
  const [px, py] = xy(hand, index);
  return Math.hypot(px - wx, py - wy);
};

// A finger is extended when its tip reaches farther from the wrist than its PIP joint,
// curled when the tip folds back toward the palm (tip closer than the PIP).
const fingerExtended = (hand: Hand, tip: number, pip: number): boolean =>
  distToWrist(hand, tip) > distToWrist(hand, pip);

// Is the hand making a deliberate index-pointing gesture? Index extended AND middle
// curled — this is what distinguishes a point from an open/raised hand (all fingers
// extended) or a fist (none). The referent loop arms a lock only while this holds, so a
// hand merely raised in view doesn't accumulate a lock (#25 perception gate). 2D only —
// robust for a front-facing camera and unaffected by depth (z) noise.
export const isPointingPose = (hand: Hand): boolean =>
  fingerExtended(hand, INDEX_FINGER_TIP, INDEX_FINGER_PIP) &&
  !fingerExtended(hand, MIDDLE_FINGER_TIP, MIDDLE_FINGER_PIP);

// Derive the raw pointing signal from one hand.
export const pointingSignal = (hand: Hand, options: PointingSignalOptions = {}): Point => {
  const { anchor = "wrist", extend = 0 } = options;
  const [tx, ty] = xy(hand, INDEX_FINGER_TIP);
  const [ax, ay] = xy(hand, anchor === "wrist" ? WRIST : INDEX_FINGER_MCP);
  return [tx + extend * (tx - ax), ty + extend * (ty - ay)];
};

// Derive the pointing signal from a parsed frame, or null when no hand is present
// (or the requested handedness is absent).
export const pointingSignalFromFrame = (
  frame: LandmarkFrame,
  options: PointingSignalOptions = {},
): Point | null => {
  const hand = options.handedness
    ? frame.hands.find((h) => h.handedness === options.handedness)
    : frame.hands[0];
  return hand ? pointingSignal(hand, options) : null;
};
