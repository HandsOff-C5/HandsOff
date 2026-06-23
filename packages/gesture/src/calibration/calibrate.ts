import { type CalibrationQuality, PointingCandidate, type Surface } from "@handsoff/contracts";

// #26 — pointing calibration: raw pointing signal → screen px → surface candidate.
// Pure math (STRICT TDD); no camera, no clock. The raw signal (a landmark-derived
// ray, see docs/research/gesture/calibration.md) is supplied by the caller — the
// landmark→ray extractor is the perception seam and lands with #25.

// A 2D point in either the raw pointing-signal space or the global px screen space.
export type Point = readonly [number, number];

// One calibration correspondence: a raw signal observed while pointing at a known
// target whose screen-px position is `target`.
export interface CalibrationPair {
  raw: Point;
  target: Point;
}

// Affine map [x,y] → [a*x + b*y + c, d*x + e*y + f]. 6 DOF; needs ≥3 correspondences.
// Affine is the starting model (scale/rotation/shear/translation); homography (≥4) is
// the documented upgrade path if perspective error stays high — not built yet.
export interface AffineTransform {
  a: number;
  b: number;
  c: number;
  d: number;
  e: number;
  f: number;
}

export const applyTransform = (t: AffineTransform, [x, y]: Point): Point => [
  t.a * x + t.b * y + t.c,
  t.d * x + t.e * y + t.f,
];

// Solve the symmetric 3×3 system S·p = v (S given by its distinct entries) via the
// cofactor inverse. Throws on a singular system (e.g. collinear calibration points —
// the fit is not determined).
const solveSym3 = (
  s00: number,
  s01: number,
  s02: number,
  s11: number,
  s12: number,
  s22: number,
  v0: number,
  v1: number,
  v2: number,
): [number, number, number] => {
  const c00 = s11 * s22 - s12 * s12;
  const c01 = s12 * s02 - s01 * s22;
  const c02 = s01 * s12 - s11 * s02;
  const det = s00 * c00 + s01 * c01 + s02 * c02;
  if (Math.abs(det) < 1e-12) {
    throw new Error("calibration: singular system (collinear or degenerate points)");
  }
  const c11 = s00 * s22 - s02 * s02;
  const c12 = s02 * s01 - s00 * s12;
  const c22 = s00 * s11 - s01 * s01;
  // S is symmetric, so its inverse is too: p = S⁻¹·v = (1/det)·cofactor·v.
  return [
    (c00 * v0 + c01 * v1 + c02 * v2) / det,
    (c01 * v0 + c11 * v1 + c12 * v2) / det,
    (c02 * v0 + c12 * v1 + c22 * v2) / det,
  ];
};

// Least-squares affine fit via the normal equations. The x' and y' coordinates share
// the same design matrix A (rows [x, y, 1]), so we build the symmetric AᵀA once and
// solve it against the two right-hand sides.
export const fitAffine = (pairs: CalibrationPair[]): AffineTransform => {
  if (pairs.length < 3) {
    throw new Error(`fitAffine: need ≥3 correspondences for an affine fit, got ${pairs.length}`);
  }
  let sxx = 0;
  let sxy = 0;
  let sx = 0;
  let syy = 0;
  let sy = 0;
  const n = pairs.length;
  let txx = 0;
  let txy = 0;
  let tx = 0; // Aᵀ·X'
  let tyx = 0;
  let tyy = 0;
  let ty = 0; // Aᵀ·Y'
  for (const { raw, target } of pairs) {
    const [x, y] = raw;
    const [X, Y] = target;
    sxx += x * x;
    sxy += x * y;
    sx += x;
    syy += y * y;
    sy += y;
    txx += x * X;
    txy += y * X;
    tx += X;
    tyx += x * Y;
    tyy += y * Y;
    ty += Y;
  }
  const [a, b, c] = solveSym3(sxx, sxy, sx, syy, sy, n, txx, txy, tx);
  const [d, e, f] = solveSym3(sxx, sxy, sx, syy, sy, n, tyx, tyy, ty);
  return { a, b, c, d, e, f };
};

// 3×3 projective homography, row-major [h0..h8]. Maps [x,y] → the perspective divide
// [(h0x+h1y+h2)/w, (h3x+h4y+h5)/w] with w = h6x+h7y+h8. The h6/h7 terms are the
// perspective DOF an affine map lacks — the upgrade for off-axis displays where a flat
// affine fit leaves residual. Fixed scale: h8 = 1 (a homography is defined up to scale).
export type Homography = readonly [
  number,
  number,
  number,
  number,
  number,
  number,
  number,
  number,
  number,
];

export const applyHomography = (h: Homography, [x, y]: Point): Point => {
  const w = h[6] * x + h[7] * y + h[8];
  return [(h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w];
};

// Guarded array read — under noUncheckedIndexedAccess every `arr[i]` is `number |
// undefined`, so a single checked accessor keeps the linear-algebra below clean. The
// throw is unreachable for the fixed-size systems we build; it just narrows the type.
const at = (arr: readonly number[], i: number): number => {
  const value = arr[i];
  if (value === undefined) throw new Error("calibration: index out of range");
  return value;
};

// Solve the n×n linear system M·x = b by Gauss-Jordan elimination with partial pivoting.
// (The affine fit's 3×3 cofactor inverse doesn't generalize to the homography's 8×8
// system, so we use a general solver.) `m` is a flat row-major n×n matrix; mutates a
// local augmented copy; throws on a singular system.
const solveLinear = (m: readonly number[], b: readonly number[]): number[] => {
  const n = b.length;
  const w = n + 1; // augmented row width: [M | b]
  const aug: number[] = [];
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) aug.push(at(m, r * n + c));
    aug.push(at(b, r));
  }
  for (let col = 0; col < n; col++) {
    // Partial pivot: swap in the row with the largest magnitude in this column.
    let pivot = col;
    for (let r = col + 1; r < n; r++) {
      if (Math.abs(at(aug, r * w + col)) > Math.abs(at(aug, pivot * w + col))) pivot = r;
    }
    if (Math.abs(at(aug, pivot * w + col)) < 1e-12) {
      throw new Error("calibration: singular system (collinear or degenerate points)");
    }
    for (let c = 0; c < w; c++) {
      const a = col * w + c;
      const p = pivot * w + c;
      const tmp = at(aug, a);
      aug[a] = at(aug, p);
      aug[p] = tmp;
    }
    const diag = at(aug, col * w + col);
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const factor = at(aug, r * w + col) / diag;
      for (let c = col; c < w; c++) {
        aug[r * w + c] = at(aug, r * w + c) - factor * at(aug, col * w + c);
      }
    }
  }
  const x: number[] = [];
  for (let i = 0; i < n; i++) x.push(at(aug, i * w + n) / at(aug, i * w + i));
  return x;
};

// Least-squares homography fit via the Direct Linear Transform. Each correspondence
// (x,y)→(X,Y) gives two linear equations in h0..h7 (h8 pinned to 1):
//   h0x + h1y + h2 − h6xX − h7yX = X
//   h3x + h4y + h5 − h6xY − h7yY = Y
// We accumulate the 8×8 normal equations AᵀA·h = Aᵀt and solve. Needs ≥4 non-collinear
// correspondences (8 equations for 8 unknowns).
export const fitHomography = (pairs: CalibrationPair[]): Homography => {
  if (pairs.length < 4) {
    throw new Error(
      `fitHomography: need ≥4 correspondences for a homography fit, got ${pairs.length}`,
    );
  }
  const dof = 8;
  const m = new Array<number>(dof * dof).fill(0); // flat row-major AᵀA
  const v = new Array<number>(dof).fill(0); // Aᵀt
  const accumulate = (row: number[], t: number) => {
    for (let i = 0; i < dof; i++) {
      const ri = at(row, i);
      for (let j = 0; j < dof; j++) {
        const k = i * dof + j;
        m[k] = at(m, k) + ri * at(row, j);
      }
      v[i] = at(v, i) + ri * t;
    }
  };
  for (const { raw, target } of pairs) {
    const [x, y] = raw;
    const [X, Y] = target;
    accumulate([x, y, 1, 0, 0, 0, -x * X, -y * X], X);
    accumulate([0, 0, 0, x, y, 1, -x * Y, -y * Y], Y);
  }
  const h = solveLinear(m, v);
  // Pin h8 = 1 for the fixed projective scale.
  return [at(h, 0), at(h, 1), at(h, 2), at(h, 3), at(h, 4), at(h, 5), at(h, 6), at(h, 7), 1];
};

// RMS reprojection error (screen-px) of a homography over its correspondences — the
// projective counterpart to calibrationResidual.
export const homographyResidual = (h: Homography, pairs: CalibrationPair[]): number => {
  if (pairs.length === 0) return 0;
  let sumSq = 0;
  for (const { raw, target } of pairs) {
    const [px, py] = applyHomography(h, raw);
    sumSq += (px - target[0]) ** 2 + (py - target[1]) ** 2;
  }
  return Math.sqrt(sumSq / pairs.length);
};

// RMS reprojection error (in target/screen-px space) of a transform over the
// correspondences it was fit on — the calibration's residual.
export const calibrationResidual = (t: AffineTransform, pairs: CalibrationPair[]): number => {
  if (pairs.length === 0) return 0;
  let sumSq = 0;
  for (const { raw, target } of pairs) {
    const [px, py] = applyTransform(t, raw);
    sumSq += (px - target[0]) ** 2 + (py - target[1]) ** 2;
  }
  return Math.sqrt(sumSq / pairs.length);
};

// Residual thresholds (global px). Pointing is coarse — it only needs to land NEAR a
// target; dwell + voice (#28/#27) seal it (Bolt "Put-That-There") — so these tolerate
// tens of px rather than aiming for a pixel-perfect cursor.
const GOOD_MAX_PX = 20;
const FAIR_MAX_PX = 60;

export const calibrationQualityFromResidual = (rmsPx: number): CalibrationQuality => {
  if (rmsPx <= GOOD_MAX_PX) return "good";
  if (rmsPx <= FAIR_MAX_PX) return "fair";
  return "poor";
};

// Distance scale (px) over which confidence decays once the point is outside a surface.
const CONFIDENCE_FALLOFF_PX = 200;

// Euclidean distance from a point to a rectangle; 0 when the point is inside.
export const distanceToBounds = ([x, y]: Point, b: Surface["bounds"]): number => {
  const dx = Math.max(b.x - x, 0, x - (b.x + b.w));
  const dy = Math.max(b.y - y, 0, y - (b.y + b.h));
  return Math.hypot(dx, dy);
};

// Resolve a calibrated screen-px point to the nearest surface candidate. Returns null
// when there are no surfaces to point at. Confidence is 1 inside a surface and decays
// with distance outside it; `calibrationQuality` is threaded through from the fit.
export const toCandidate = (
  screenXY: Point,
  surfaces: Surface[],
  calibrationQuality: CalibrationQuality,
): PointingCandidate | null => {
  let nearest: Surface | undefined;
  let nearestDist = Infinity;
  for (const surface of surfaces) {
    const dist = distanceToBounds(screenXY, surface.bounds);
    if (dist < nearestDist) {
      nearest = surface;
      nearestDist = dist;
    }
  }
  if (!nearest) return null;
  const confidence = 1 / (1 + nearestDist / CONFIDENCE_FALLOFF_PX);
  return PointingCandidate.parse({ targetId: nearest.id, confidence, calibrationQuality });
};
