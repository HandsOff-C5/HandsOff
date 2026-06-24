import { describe, expect, it } from "vitest";

import { createCalibrationFlow } from "./calibration-flow";
import { createDwellTracker } from "./dwell";
import { tickCalibration } from "./tick";

describe("tickCalibration", () => {
  it("fills the active dot, captures on hold, and advances the flow", () => {
    const flow = createCalibrationFlow();
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    const target = flow.view(0).targets[0]!;

    expect(tickCalibration(flow, dwell, target, [0.1, 0.1], 0).view.dwellProgress).toBe(0);
    expect(tickCalibration(flow, dwell, target, [0.1, 0.1], 450).view.dwellProgress).toBeCloseTo(
      0.5,
      5,
    );
    const captured = tickCalibration(flow, dwell, target, [0.1, 0.1], 900);
    expect(captured.view.currentIndex).toBe(1);
    expect(captured.done).toBe(false);
  });

  it("resets the fill when the cursor leaves the active dot", () => {
    const flow = createCalibrationFlow();
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    const target = flow.view(0).targets[0]!;
    tickCalibration(flow, dwell, target, [0.1, 0.1], 0);
    tickCalibration(flow, dwell, target, [0.1, 0.1], 450);
    expect(tickCalibration(flow, dwell, [0.9, 0.9], [0.1, 0.1], 500).view.dwellProgress).toBe(0);
  });

  it("does not capture without a raw sample to fit", () => {
    const flow = createCalibrationFlow();
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    const target = flow.view(0).targets[0]!;
    tickCalibration(flow, dwell, target, null, 0);
    // Held long enough, but no raw signal this frame → stay on the same dot.
    const t = tickCalibration(flow, dwell, target, null, 900);
    expect(t.view.currentIndex).toBe(0);
  });

  it("reports done once both phases are captured", () => {
    const flow = createCalibrationFlow();
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 1 });
    // Drive 18 captures (9 hand + 9 gaze): dwell on each glowing dot (cursor = the
    // active target so it's within radius) and capture the same point as the raw
    // sample (the 3×3 grid is non-collinear → each phase's affine fits).
    let done = false;
    for (let i = 0; i < 18 && !done; i++) {
      const target = flow.view(0).targets[flow.view(0).currentIndex]!;
      tickCalibration(flow, dwell, target, target, i * 10);
      done = tickCalibration(flow, dwell, target, target, i * 10 + 5).done;
    }
    expect(done).toBe(true);
    expect(flow.outcome()?.skipped).toBe(false);
  });
});
