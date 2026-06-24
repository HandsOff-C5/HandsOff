import type { CalibrationQuality, SurfaceBounds } from "@handsoff/contracts";
import {
  createCalibrationSession,
  gridTargets,
  type CalibrationResult,
  type GridSpec,
  type Point,
} from "@handsoff/gesture";

// The two-phase calibration onboarding flow (hand 👆 then eyes 👁). Pure: it
// drives target-by-target capture for each phase, reusing the gesture package's
// createCalibrationSession + fitAffine, and exposes a CalibrationView the overlay
// renders. The engine feeds it raw samples (the live fingertip / gaze signal) as
// each dwell completes, and reads the fitted outcome at the end to apply + persist.
//
// Display targets are normalized [0,1] (where the dots are drawn on the overlay).
// Each phase fits in its own space: hand against the camera calibration's bounds
// (so the fit feeds the existing pointing pipeline), gaze against [0,1].

export type CalibrationPhase = "hand" | "gaze";

export interface CalibrationView {
  // False once the flow is done/skipped — the overlay drops the gate and shows the HUD.
  active: boolean;
  phase: CalibrationPhase;
  step: number; // 1 (hand) or 2 (gaze)
  totalSteps: number; // 2
  // The 3×3 dot positions in normalized [0,1] overlay space, row-major.
  targets: Point[];
  // Which dot is glowing now.
  currentIndex: number;
  // 0..1 fill of the active dot (the live dwell), passed through from the engine.
  dwellProgress: number;
  // Quality of the previously completed phase (hand, while on the gaze phase), or null.
  quality: CalibrationQuality | null;
}

export interface CalibrationOutcome {
  hand: CalibrationResult | null;
  gaze: CalibrationResult | null;
  // True when the operator skipped (esc / "skip") rather than completing both phases.
  skipped: boolean;
}

export interface CalibrationFlow {
  view(dwellProgress: number): CalibrationView;
  // Record the raw signal for the current target and advance; ignored once done.
  capture(raw: Point): void;
  // End the flow now, keeping whatever phases completed.
  skip(): void;
  // The fitted results once done/skipped; null until then.
  outcome(): CalibrationOutcome | null;
}

export interface CalibrationFlowConfig {
  // Fit space for the hand phase — default the camera calibration's screen bounds.
  handBounds?: SurfaceBounds;
  // Fit space for the gaze phase — default normalized [0,1].
  gazeBounds?: SurfaceBounds;
  // Where the dots are drawn — default normalized [0,1].
  displayBounds?: SurfaceBounds;
  grid?: GridSpec;
}

const UNIT_BOUNDS: SurfaceBounds = { x: 0, y: 0, w: 1, h: 1 };
const DEFAULT_GRID: GridSpec = { cols: 3, rows: 3, margin: 0.12 };

export function createCalibrationFlow(config: CalibrationFlowConfig = {}): CalibrationFlow {
  const grid = config.grid ?? DEFAULT_GRID;
  const displayTargets = gridTargets(config.displayBounds ?? UNIT_BOUNDS, grid);
  const sessions = {
    hand: createCalibrationSession(gridTargets(config.handBounds ?? UNIT_BOUNDS, grid)),
    gaze: createCalibrationSession(gridTargets(config.gazeBounds ?? UNIT_BOUNDS, grid)),
  };
  const results: { hand: CalibrationResult | null; gaze: CalibrationResult | null } = {
    hand: null,
    gaze: null,
  };
  let phase: CalibrationPhase = "hand";
  let done = false;
  let skipped = false;

  return {
    capture(raw) {
      if (done) return;
      const session = sessions[phase];
      const progress = session.capture(raw);
      if (!progress.done) return;
      results[phase] = session.result();
      if (phase === "hand") phase = "gaze";
      else done = true;
    },
    skip() {
      done = true;
      skipped = true;
    },
    view(dwellProgress) {
      return {
        active: !done,
        phase,
        step: phase === "hand" ? 1 : 2,
        totalSteps: 2,
        targets: displayTargets,
        currentIndex: sessions[phase].current().index,
        dwellProgress,
        quality: phase === "gaze" ? (results.hand?.quality ?? null) : null,
      };
    },
    outcome() {
      if (!done) return null;
      return { hand: results.hand, gaze: results.gaze, skipped };
    },
  };
}
