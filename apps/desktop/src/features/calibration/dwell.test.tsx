import { describe, expect, it } from "vitest";

import { createDwellTracker } from "./dwell";

const TARGET: [number, number] = [0.5, 0.5];

describe("createDwellTracker", () => {
  it("stays at zero while the cursor is away from the target", () => {
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    expect(dwell.update([0.1, 0.1], TARGET, 0)).toEqual({ progress: 0, captured: false });
    expect(dwell.update([0.2, 0.9], TARGET, 100)).toEqual({ progress: 0, captured: false });
  });

  it("fills toward 1 as the cursor holds on the target, then captures once", () => {
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    expect(dwell.update(TARGET, TARGET, 0).progress).toBe(0);
    expect(dwell.update(TARGET, TARGET, 450).progress).toBeCloseTo(0.5, 5);
    const done = dwell.update(TARGET, TARGET, 900);
    expect(done.progress).toBe(1);
    expect(done.captured).toBe(true);
    // captured fires only once — a later sample past the hold does not re-fire.
    expect(dwell.update(TARGET, TARGET, 1200).captured).toBe(false);
  });

  it("resets the hold when the cursor leaves the radius mid-dwell", () => {
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    dwell.update(TARGET, TARGET, 0);
    expect(dwell.update(TARGET, TARGET, 450).progress).toBeCloseTo(0.5, 5);
    // Cursor jumps away → hold resets.
    expect(dwell.update([0.9, 0.9], TARGET, 500)).toEqual({ progress: 0, captured: false });
    // Coming back restarts the clock from here, not from 0ms.
    expect(dwell.update(TARGET, TARGET, 500).progress).toBe(0);
    expect(dwell.update(TARGET, TARGET, 950).progress).toBeCloseTo(0.5, 5);
  });

  it("resets when the cursor is null (no hand / no gaze this frame)", () => {
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    dwell.update(TARGET, TARGET, 0);
    expect(dwell.update(null, TARGET, 450)).toEqual({ progress: 0, captured: false });
  });

  it("reset() clears progress and re-arms capture for the next target", () => {
    const dwell = createDwellTracker({ radius: 0.06, holdMs: 900 });
    dwell.update(TARGET, TARGET, 0);
    expect(dwell.update(TARGET, TARGET, 900).captured).toBe(true);
    dwell.reset();
    expect(dwell.update(TARGET, TARGET, 1000).progress).toBe(0);
    expect(dwell.update(TARGET, TARGET, 1900).captured).toBe(true);
  });
});
