import { describe, expect, it } from "vitest";

import { createCalibrationFlow } from "./calibration-flow";

// Nine non-collinear raw samples so each phase's affine fit is well-defined.
const raws: [number, number][] = [
  [0, 0],
  [0.4, 0],
  [0.8, 0],
  [0, 0.4],
  [0.4, 0.4],
  [0.8, 0.4],
  [0, 0.8],
  [0.4, 0.8],
  [0.8, 0.8],
];

function captureNine(flow: ReturnType<typeof createCalibrationFlow>): void {
  for (const raw of raws) flow.capture(raw);
}

describe("createCalibrationFlow", () => {
  it("starts on the hand phase with a 3×3 display grid", () => {
    const flow = createCalibrationFlow();
    const view = flow.view(0);
    expect(view.active).toBe(true);
    expect(view.phase).toBe("hand");
    expect(view.step).toBe(1);
    expect(view.totalSteps).toBe(2);
    expect(view.targets).toHaveLength(9);
    expect(view.currentIndex).toBe(0);
    expect(flow.outcome()).toBeNull();
  });

  it("passes the live dwell progress through to the view", () => {
    const flow = createCalibrationFlow();
    expect(flow.view(0.42).dwellProgress).toBe(0.42);
  });

  it("advances target-by-target, then from hand to gaze after nine captures", () => {
    const flow = createCalibrationFlow();
    flow.capture(raws[0]!);
    expect(flow.view(0).currentIndex).toBe(1);
    expect(flow.view(0).phase).toBe("hand");
    for (let i = 1; i < 9; i++) flow.capture(raws[i]!);
    const view = flow.view(0);
    expect(view.phase).toBe("gaze");
    expect(view.step).toBe(2);
    expect(view.currentIndex).toBe(0);
    // Not done until gaze is also captured.
    expect(flow.outcome()).toBeNull();
  });

  it("completes with both fitted results after the gaze phase", () => {
    const flow = createCalibrationFlow();
    captureNine(flow); // hand
    captureNine(flow); // gaze
    const outcome = flow.outcome();
    expect(outcome).not.toBeNull();
    expect(outcome?.skipped).toBe(false);
    expect(outcome?.hand?.transform).toBeDefined();
    expect(outcome?.gaze?.transform).toBeDefined();
    expect(flow.view(0).active).toBe(false);
  });

  it("skip ends the flow immediately, keeping whatever completed", () => {
    const flow = createCalibrationFlow();
    captureNine(flow); // hand done, gaze not started
    flow.skip();
    const outcome = flow.outcome();
    expect(outcome?.skipped).toBe(true);
    expect(outcome?.hand?.transform).toBeDefined();
    expect(outcome?.gaze).toBeNull();
    expect(flow.view(0).active).toBe(false);
  });
});
