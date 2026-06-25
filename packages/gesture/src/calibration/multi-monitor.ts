import type { CalibrationQuality } from "@handsoff/contracts";

import type { Display } from "../display/arbitration";
import {
  applyTransform,
  calibrationQualityFromResidual,
  fitAffine,
  type AffineTransform,
  type CalibrationPair,
  type Point,
} from "./calibrate";
import { gridTargets, type GridSpec } from "./capture";

// Multi-monitor pointing calibration. A single affine fit across the whole virtual desktop
// degrades at monitor seams and on off-axis secondary displays, so — mirroring the funstuff
// gesture architecture — we fit ONE affine PER display and route a new reading to the right
// display by nearest raw-signal centroid (the two-stage structure: classify display, then
// regress within it). funstuff classifies on a 4D pointing-direction feature; we use the 2D
// raw signal the existing perception seam already produces, which is enough for a front
// camera and keeps the change localized to calibration (see ADR).

// One calibration target: a global-px point (display origin already baked in) on a known
// display. The grid is laid per-display, so a 3×3 grid across 2 monitors yields 18 targets.
export interface CalibrationTarget {
  displayId: string;
  target: Point;
}

// A captured correspondence: the raw pointing signal observed while aiming at `target`.
export interface MultiCalibrationPair {
  raw: Point;
  displayId: string;
  target: Point;
}

// A per-display fit: the affine map raw→global-px plus the centroid of the captured raw
// signals (the nearest-neighbour key used to classify which display a new reading targets).
export interface PerDisplayFit {
  transform: AffineTransform;
  centroid: Point;
}

export interface MultiMonitorCalibration {
  byDisplay: Record<string, PerDisplayFit>;
  // RMS reprojection error (global px) across every correspondence.
  residual: number;
  quality: CalibrationQuality;
}

// Lay a cols×rows grid across EACH display (global-px targets), concatenated in display
// order. `gridTargets` already returns global points for a global `bounds`, so this is the
// per-display generalization of the single-screen 9-point grid.
export const multiMonitorTargets = (displays: Display[], spec: GridSpec): CalibrationTarget[] =>
  displays.flatMap((display) =>
    gridTargets(display.bounds, spec).map((target) => ({ displayId: display.id, target })),
  );

const meanPoint = (points: Point[]): Point => {
  let sx = 0;
  let sy = 0;
  for (const [x, y] of points) {
    sx += x;
    sy += y;
  }
  const n = points.length;
  return [sx / n, sy / n];
};

// Fit one affine per display from the captured correspondences. Each display needs ≥3 points
// (the affine minimum); with one display this collapses to the original single-affine fit.
export const fitMultiMonitor = (pairs: MultiCalibrationPair[]): MultiMonitorCalibration => {
  if (pairs.length === 0) {
    throw new Error("fitMultiMonitor: no correspondences");
  }
  const byDisplay: Record<string, PerDisplayFit> = {};
  let sumSq = 0;
  let count = 0;
  for (const [displayId, group] of Object.entries(groupByDisplay(pairs))) {
    if (group.length < 3) {
      throw new Error(
        `fitMultiMonitor: display ${displayId} has ${group.length} target(s); need ≥3`,
      );
    }
    const calibrationPairs: CalibrationPair[] = group.map(({ raw, target }) => ({ raw, target }));
    const transform = fitAffine(calibrationPairs);
    byDisplay[displayId] = { transform, centroid: meanPoint(group.map((p) => p.raw)) };
    for (const { raw, target } of group) {
      const [px, py] = applyTransform(transform, raw);
      sumSq += (px - target[0]) ** 2 + (py - target[1]) ** 2;
      count += 1;
    }
  }
  const residual = count > 0 ? Math.sqrt(sumSq / count) : 0;
  return { byDisplay, residual, quality: calibrationQualityFromResidual(residual) };
};

const groupByDisplay = (pairs: MultiCalibrationPair[]): Record<string, MultiCalibrationPair[]> => {
  const groups: Record<string, MultiCalibrationPair[]> = {};
  for (const pair of pairs) {
    (groups[pair.displayId] ??= []).push(pair);
  }
  return groups;
};

const nearestDisplay = (cal: MultiMonitorCalibration, raw: Point): PerDisplayFit | null => {
  const fits = Object.values(cal.byDisplay);
  let best: PerDisplayFit | null = null;
  let bestDist = Infinity;
  for (const fit of fits) {
    if (!fit) continue;
    const dist = (raw[0] - fit.centroid[0]) ** 2 + (raw[1] - fit.centroid[1]) ** 2;
    if (best === null || dist < bestDist) {
      bestDist = dist;
      best = fit;
    }
  }
  return best;
};

// Map a raw pointing signal to a global-px point: classify the display by nearest centroid,
// then apply that display's affine. Returns the raw point unchanged when there is no
// calibration (so the loop degrades gracefully before the first fit). The point is NOT
// clamped to a display here — the overlay already clamps for rendering, and clamping in the
// model would make the cursor stick at monitor edges.
export const predictMultiMonitor = (cal: MultiMonitorCalibration | null, raw: Point): Point => {
  if (!cal) return raw;
  const fit = nearestDisplay(cal, raw);
  return fit ? applyTransform(fit.transform, raw) : raw;
};
