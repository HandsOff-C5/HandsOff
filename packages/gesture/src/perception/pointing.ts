import { type Hand, type Handedness, type LandmarkFrame } from "@handsoff/contracts";

import { type Point } from "../calibration/calibrate";

// #25 perception seam — the landmark→pointing-ray extractor that #26 calibration left
// open. Pure: turns a detected `Hand` into the 2D raw pointing signal (normalized image
// coords) that `fitAffine`/`applyTransform` map to a screen point. No camera, no clock.

// MediaPipe hand-landmark indices (the standard 21-point topology).
const WRIST = 0;
const INDEX_FINGER_MCP = 5;
const INDEX_FINGER_TIP = 8;

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
