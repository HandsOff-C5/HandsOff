import { describe, expect, it } from "vitest";

import { createCaptureController, medianVector } from "./capture-controller";

describe("medianVector", () => {
  it("takes the per-dimension median for an odd count", () => {
    expect(
      medianVector([
        [1, 10],
        [3, 30],
        [2, 20],
      ]),
    ).toEqual([2, 20]);
  });

  it("averages the two middle values for an even count", () => {
    expect(
      medianVector([
        [1, 8],
        [3, 2],
        [2, 4],
        [4, 6],
      ]),
    ).toEqual([2.5, 5]);
  });

  it("throws on an empty sample set", () => {
    expect(() => medianVector([])).toThrow();
  });
});

const CONFIG = { settleMs: 600, collectMs: 800, minSamples: 5, minConfidence: 0.4 };
const GOOD = 0.9;
const fv = [0.5, 0.5, 0.5, 0.5];

describe("createCaptureController", () => {
  it("stays in the settle phase before settleMs elapses", () => {
    const c = createCaptureController(CONFIG);
    c.reset(1000);
    const s = c.tick(1300, GOOD, fv); // 300ms < 600ms
    expect(s.phase).toBe("settle");
    expect(s.captured).toBeNull();
  });

  it("enters the collect phase after the settle delay", () => {
    const c = createCaptureController(CONFIG);
    c.reset(1000);
    expect(c.tick(1700, GOOD, fv).phase).toBe("collect"); // 700ms > 600ms
  });

  it("captures the median once enough confident samples are gathered past collectMs", () => {
    const c = createCaptureController(CONFIG);
    c.reset(0);
    let captured: readonly number[] | null = null;
    // 10 confident frames spanning past settle(600) + collect(800) = 1400ms.
    for (let t = 700; t <= 1600; t += 100) {
      const s = c.tick(t, GOOD, [t / 1000, 0.5, 0.5, 0.5]);
      if (s.captured) captured = s.captured;
    }
    expect(captured).not.toBeNull();
    expect(captured).toHaveLength(4);
  });

  it("does NOT capture while the operator is blinking (low confidence frames are dropped)", () => {
    const c = createCaptureController(CONFIG);
    c.reset(0);
    let captured: readonly number[] | null = null;
    // Past the full window, but every collect-phase frame is below minConfidence.
    for (let t = 700; t <= 3000; t += 100) {
      const s = c.tick(t, 0.1, fv);
      if (s.captured) captured = s.captured;
    }
    expect(captured).toBeNull();
  });

  it("reports collect progress climbing toward 1", () => {
    const c = createCaptureController(CONFIG);
    c.reset(0);
    const early = c.tick(700, GOOD, fv).progress; // just entered collect
    const late = c.tick(1300, GOOD, fv).progress; // ~700ms into collect
    expect(late).toBeGreaterThan(early);
    expect(late).toBeLessThanOrEqual(1);
  });
});
