import { describe, expect, it } from "vitest";

import type { Point } from "./calibrate";
import { createCalibrationSession, gridTargets } from "./capture";

const bounds = { x: 0, y: 0, w: 1920, h: 1080 };

describe("gridTargets", () => {
  it("lays out a cols×rows grid of screen targets", () => {
    const targets = gridTargets(bounds, { cols: 3, rows: 3 });
    expect(targets).toHaveLength(9);
  });

  it("spans the bounds corner-to-corner with margin 0, centered point in the middle", () => {
    const targets = gridTargets(bounds, { cols: 3, rows: 3, margin: 0 });
    expect(targets[0]).toEqual([0, 0]); // top-left
    expect(targets[4]).toEqual([960, 540]); // center
    expect(targets[8]).toEqual([1920, 1080]); // bottom-right
  });

  it("insets by a margin fraction of the bounds", () => {
    const targets = gridTargets(bounds, { cols: 3, rows: 3, margin: 0.1 });
    // 10% inset: x ∈ {192, 960, 1728}, y ∈ {108, 540, 972}.
    expect(targets[0]).toEqual([192, 108]);
    expect(targets[8]).toEqual([1728, 972]);
  });
});

describe("createCalibrationSession (9-point)", () => {
  const targets = gridTargets(bounds, { cols: 3, rows: 3, margin: 0 });

  it("starts at the first target and reports progress", () => {
    const session = createCalibrationSession(targets);
    expect(session.current()).toMatchObject({ index: 0, total: 9, done: false, target: [0, 0] });
    expect(session.result()).toBeNull();
  });

  it("advances through every target as samples are captured", () => {
    const session = createCalibrationSession(targets);
    expect(session.capture([0, 0]).index).toBe(1);
    for (let i = 1; i < 9; i++) session.capture([0, 0]);
    expect(session.current().done).toBe(true);
    expect(session.current().target).toBeNull();
  });

  it("fits a transform that recovers the calibration once all targets are captured", () => {
    const session = createCalibrationSession(targets);
    // Simulate the raw pointing signal as the screen target scaled into [0,1] — i.e. the
    // user's raw signal under a known screen = (1920·x, 1080·y) mapping.
    for (const [tx, ty] of targets) {
      session.capture([tx / 1920, ty / 1080] as Point);
    }
    const result = session.result();
    expect(result).not.toBeNull();
    expect(result?.transform.a).toBeCloseTo(1920, 3);
    expect(result?.transform.e).toBeCloseTo(1080, 3);
    expect(result?.transform.b).toBeCloseTo(0, 6);
    expect(result?.transform.d).toBeCloseTo(0, 6);
    expect(result?.residual).toBeCloseTo(0, 3);
    expect(result?.quality).toBe("good");
  });

  it("throws if a sample is captured after all targets are done", () => {
    const session = createCalibrationSession(targets);
    for (let i = 0; i < 9; i++) session.capture([0, 0]);
    expect(() => session.capture([0, 0])).toThrow();
  });
});
