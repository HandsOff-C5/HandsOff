// Pure gaze-feature extraction from a MediaPipe FaceLandmarker 478-point (iris-refined)
// mesh. No camera, no framework (STRICT) — given the normalized face landmarks, compute
// the iris position WITHIN each eye (fraction across the eye corners / lids), a
// scale-invariant gaze signal, plus an eye-aspect blink gate. These features feed the
// per-monitor polynomial calibration (calibrate.ts fitPolynomial). Head-pose terms
// (yaw/pitch from the facial transform matrix) are appended by the caller at wiring time.
//
// The index groups are the MediaPipe FaceMesh canonical iris/eye landmarks (verified
// against the MediaPipe iris model). "L"/"R" label the two index GROUPS, not anatomical
// sides — sources disagree on which is subject-left; the only invariant that matters is
// that each iris is paired with its OWN eye's corners + lids.

export interface FaceLandmark {
  readonly x: number;
  readonly y: number;
  readonly z?: number;
}

export interface GazeFeatures {
  // Iris horizontal fraction across the palpebral fissure (0 = inner corner, 1 = outer).
  readonly irisXL: number;
  readonly irisXR: number;
  // Iris vertical fraction across the lid opening (0 = top lid, 1 = bottom lid).
  readonly irisYL: number;
  readonly irisYR: number;
  // Mean lid-opening / eye-width — low while blinking/squinting (a capture gate).
  readonly eyeAspect: number;
}

interface EyeIndices {
  readonly iris: number;
  readonly inner: number;
  readonly outer: number;
  readonly top: number;
  readonly bottom: number;
}

// Canonical MediaPipe FaceMesh indices for the two iris/eye groups.
const EYE_L: EyeIndices = { iris: 468, inner: 133, outer: 33, top: 159, bottom: 145 };
const EYE_R: EyeIndices = { iris: 473, inner: 362, outer: 263, top: 386, bottom: 374 };
const MIN_SPAN = 1e-6;

const fraction = (v: number, a: number, b: number): number | null => {
  const span = b - a;
  if (Math.abs(span) < MIN_SPAN) return null;
  return (v - a) / span;
};

interface EyeFractions {
  readonly ix: number;
  readonly iy: number;
  readonly aspect: number;
}

const eyeFractions = (pts: ReadonlyArray<FaceLandmark>, e: EyeIndices): EyeFractions | null => {
  const iris = pts[e.iris];
  const inner = pts[e.inner];
  const outer = pts[e.outer];
  const top = pts[e.top];
  const bottom = pts[e.bottom];
  if (!iris || !inner || !outer || !top || !bottom) return null;

  const ix = fraction(iris.x, inner.x, outer.x);
  const iy = fraction(iris.y, top.y, bottom.y);
  if (ix === null || iy === null) return null;

  const width = Math.hypot(outer.x - inner.x, outer.y - inner.y);
  if (width < MIN_SPAN) return null;
  const opening = Math.hypot(bottom.x - top.x, bottom.y - top.y);
  return { ix, iy, aspect: opening / width };
};

// Extract the gaze feature set, or null when the required landmarks are absent or an
// eye is degenerate (zero width / lid opening) — the caller should drop that frame.
export const gazeFeatures = (landmarks: ReadonlyArray<FaceLandmark>): GazeFeatures | null => {
  const left = eyeFractions(landmarks, EYE_L);
  const right = eyeFractions(landmarks, EYE_R);
  if (!left || !right) return null;
  return {
    irisXL: left.ix,
    irisYL: left.iy,
    irisXR: right.ix,
    irisYR: right.iy,
    eyeAspect: (left.aspect + right.aspect) / 2,
  };
};

// Flatten the iris fractions to the numeric vector the polynomial calibration consumes.
// (eyeAspect is a gate, not a position feature, so it is excluded here.)
export const gazeFeatureVector = (f: GazeFeatures): number[] => [
  f.irisXL,
  f.irisYL,
  f.irisXR,
  f.irisYR,
];

// A drawable landmark for the debug overlay, in normalized [0,1] mesh space.
export interface GazeOverlayPoint {
  readonly x: number;
  readonly y: number;
  readonly kind: "iris" | "corner" | "lid";
}

// The iris/eye landmarks to draw on the debug view (iris centers, eye corners, lids for
// both eyes) so the user can SEE what the tracker reads. Same indices the features use.
// Normalized [0,1]; the overlay applies the selfie mirror (1-x). null if any is missing.
export const gazeOverlayPoints = (
  landmarks: ReadonlyArray<FaceLandmark>,
): readonly GazeOverlayPoint[] | null => {
  const out: GazeOverlayPoint[] = [];
  for (const e of [EYE_L, EYE_R]) {
    const iris = landmarks[e.iris];
    const inner = landmarks[e.inner];
    const outer = landmarks[e.outer];
    const top = landmarks[e.top];
    const bottom = landmarks[e.bottom];
    if (!iris || !inner || !outer || !top || !bottom) return null;
    out.push(
      { x: iris.x, y: iris.y, kind: "iris" },
      { x: inner.x, y: inner.y, kind: "corner" },
      { x: outer.x, y: outer.y, kind: "corner" },
      { x: top.x, y: top.y, kind: "lid" },
      { x: bottom.x, y: bottom.y, kind: "lid" },
    );
  }
  return out;
};
