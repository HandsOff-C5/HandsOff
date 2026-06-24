import type { Point } from "@handsoff/gesture";

import type { CalibrationFlow, CalibrationView } from "./calibration-flow";
import type { DwellTracker } from "./dwell";

export interface CalibrationTick {
  view: CalibrationView;
  done: boolean;
}

// One per-frame step of the calibration onboarding: dwell the live cursor against
// the glowing dot; when the hold completes AND a raw sample exists this frame,
// capture it into the flow and re-arm for the next dot. Pure given the (stateful)
// flow + dwell + the frame's cursor/raw/clock — the engine's rAF loop just calls
// this and streams the returned view; `done` flips when both phases are captured.
export function tickCalibration(
  flow: CalibrationFlow,
  dwell: DwellTracker,
  cursor: Point | null,
  raw: Point | null,
  nowMs: number,
): CalibrationTick {
  const current = flow.view(0);
  if (!current.active) return { view: current, done: true };

  const target = current.targets[current.currentIndex];
  if (!target) return { view: current, done: false };

  const d = dwell.update(cursor, target, nowMs);
  if (d.captured && raw) {
    flow.capture(raw);
    dwell.reset();
    const after = flow.view(0);
    return { view: after, done: !after.active };
  }
  return { view: flow.view(d.progress), done: false };
}
