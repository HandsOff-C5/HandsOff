import type { CalibrationQuality, SurfaceBounds } from "@handsoff/contracts";

import {
  calibrationQualityFromResidual,
  calibrationResidual,
  fitAffine,
  type AffineTransform,
  type CalibrationPair,
  type Point,
} from "./calibrate";

// #26 calibration capture flow — collects the target→raw correspondences the pure
// `fitAffine` needs. The user is shown known screen targets one at a time; for each, the
// runtime captures the raw pointing signal, then the session fits the affine. Pure: the
// caller supplies the captured raw points (no camera here).

export interface GridSpec {
  cols: number;
  rows: number;
  // Fraction of the bounds to inset the outer points by (0 = corner-to-corner). Default 0.1.
  margin?: number;
}

// A cols×rows grid of screen-space target points across `bounds`, row-major (top-left
// first). 3×3 is the default calibration layout — more correspondences than a 4-corner
// fit, and enough to upgrade to a homography later.
export const gridTargets = (bounds: SurfaceBounds, spec: GridSpec): Point[] => {
  const { cols, rows, margin = 0.1 } = spec;
  const insetX = bounds.w * margin;
  const insetY = bounds.h * margin;
  const spanX = bounds.w - 2 * insetX;
  const spanY = bounds.h - 2 * insetY;
  const targets: Point[] = [];
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const x = bounds.x + insetX + (cols === 1 ? 0 : (spanX * c) / (cols - 1));
      const y = bounds.y + insetY + (rows === 1 ? 0 : (spanY * r) / (rows - 1));
      targets.push([x, y]);
    }
  }
  return targets;
};

export interface CalibrationProgress {
  index: number;
  total: number;
  done: boolean;
  // The target to display now, or null when the session is complete.
  target: Point | null;
}

export interface CalibrationResult {
  transform: AffineTransform;
  residual: number;
  quality: CalibrationQuality;
}

export interface CalibrationSession {
  current(): CalibrationProgress;
  // Record the raw pointing signal for the current target and advance.
  capture(raw: Point): CalibrationProgress;
  // The fitted result once every target is captured; null until then.
  result(): CalibrationResult | null;
}

export const createCalibrationSession = (targets: Point[]): CalibrationSession => {
  const pairs: CalibrationPair[] = [];

  const progress = (): CalibrationProgress => ({
    index: pairs.length,
    total: targets.length,
    done: pairs.length >= targets.length,
    target: targets[pairs.length] ?? null,
  });

  return {
    current: progress,
    capture(raw) {
      const target = targets[pairs.length];
      if (!target) throw new Error("calibration: all targets already captured");
      pairs.push({ raw, target });
      return progress();
    },
    result() {
      if (pairs.length < targets.length) return null;
      const transform = fitAffine(pairs);
      const residual = calibrationResidual(transform, pairs);
      return { transform, residual, quality: calibrationQualityFromResidual(residual) };
    },
  };
};
