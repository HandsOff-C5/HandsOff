import type { CalibrationQuality } from "@handsoff/contracts";

import {
  calibrationQualityFromResidual,
  fitPolynomial,
  polynomialResidual,
  type PolynomialSample,
  type PolynomialTransform,
} from "./calibrate";
import { gridTargets, type GridSpec } from "./capture";

// Per-monitor eye-gaze calibration orchestration (#25 hardware pass). The operator looks
// at a 3×3 grid of dots on ONE screen, the runtime captures a (median) iris feature vector
// per dot, then a polynomial (calibrate.ts) is fit for THAT screen. It then walks to the
// next monitor and repeats — each display gets its own fit, because the iris→screen map
// differs per panel (size, distance, angle). Pure (STRICT): the caller supplies the
// captured feature vectors (no camera here); dot positions are emitted in GLOBAL screen
// pixels so the UI can place them on the right monitor (laptop, then external).

// A monitor's bounds in physical pixels: top-left (x,y) + size (w,h).
export interface MonitorRect {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

export interface EyeCalibrationConfig {
  // Ordered monitors to calibrate — typically the laptop first, then external display(s).
  readonly monitors: readonly MonitorRect[];
  // Calibration grid. Default 3×3 with a 12% inset (9 dots = the exact-fit size for the
  // 4-feature polynomial's 9-term basis).
  readonly grid?: GridSpec;
}

// The dot to show right now.
export interface EyeCalibrationDot {
  readonly monitorIndex: number;
  readonly dotIndex: number;
  // Where to draw it — absolute desktop pixels (compose to union-normalized in the UI).
  readonly globalPx: readonly [number, number];
  // The same point normalized [0,1] within its own monitor.
  readonly local: readonly [number, number];
}

export interface EyeCalibrationView {
  readonly done: boolean;
  readonly monitorIndex: number;
  readonly monitorCount: number;
  readonly dotIndex: number;
  readonly dotsPerMonitor: number;
  readonly capturedTotal: number;
  readonly totalDots: number;
  // The dot to capture now, or null once every monitor is done.
  readonly current: EyeCalibrationDot | null;
}

export interface EyeMonitorFit {
  readonly monitorIndex: number;
  readonly transform: PolynomialTransform;
  readonly residualPx: number;
  readonly quality: CalibrationQuality;
}

export interface EyeCalibrationOutcome {
  readonly fits: readonly EyeMonitorFit[];
}

export interface EyeCalibration {
  view(): EyeCalibrationView;
  // Record the (median) iris feature vector for the current dot and advance. Completing a
  // monitor's last dot fits that monitor's polynomial. Throws once the flow is done.
  capture(featureVector: readonly number[]): EyeCalibrationView;
  // The per-monitor fits once EVERY monitor is calibrated; null until then.
  outcome(): EyeCalibrationOutcome | null;
}

const DEFAULT_GRID: GridSpec = { cols: 3, rows: 3, margin: 0.12 };
const UNIT = { x: 0, y: 0, w: 1, h: 1 };

export const createEyeCalibration = (config: EyeCalibrationConfig): EyeCalibration => {
  const { monitors, grid = DEFAULT_GRID } = config;
  if (monitors.length === 0) {
    throw new Error("createEyeCalibration: need at least one monitor");
  }

  // Local-normalized [0,1] dot layout, shared by every monitor.
  const local = gridTargets(UNIT, grid);
  const dotsPerMonitor = local.length;
  const totalDots = dotsPerMonitor * monitors.length;

  const fits: EyeMonitorFit[] = [];
  let pending: PolynomialSample[] = [];
  let monitorIndex = 0;
  let dotIndex = 0;
  let capturedTotal = 0;

  const globalPxFor = (m: MonitorRect, [lx, ly]: readonly [number, number]): [number, number] => [
    m.x + lx * m.w,
    m.y + ly * m.h,
  ];

  const currentDot = (): EyeCalibrationDot | null => {
    const monitor = monitors[monitorIndex];
    if (!monitor) return null;
    const localPt = local[dotIndex];
    if (!localPt) return null;
    return {
      monitorIndex,
      dotIndex,
      globalPx: globalPxFor(monitor, localPt),
      local: localPt,
    };
  };

  const view = (): EyeCalibrationView => ({
    done: monitorIndex >= monitors.length,
    monitorIndex,
    monitorCount: monitors.length,
    dotIndex,
    dotsPerMonitor,
    capturedTotal,
    totalDots,
    current: currentDot(),
  });

  const fitMonitor = (index: number, samples: PolynomialSample[]): void => {
    const transform = fitPolynomial(samples);
    const residualPx = polynomialResidual(transform, samples);
    fits.push({
      monitorIndex: index,
      transform,
      residualPx,
      quality: calibrationQualityFromResidual(residualPx),
    });
  };

  return {
    view,
    capture(featureVector) {
      const dot = currentDot();
      if (!dot) throw new Error("eye-calibration: all dots already captured");
      pending.push({ features: [...featureVector], target: [...dot.globalPx] });
      capturedTotal += 1;
      dotIndex += 1;
      if (dotIndex >= dotsPerMonitor) {
        fitMonitor(monitorIndex, pending);
        pending = [];
        monitorIndex += 1;
        dotIndex = 0;
      }
      return view();
    },
    outcome() {
      if (monitorIndex < monitors.length) return null;
      return { fits };
    },
  };
};
