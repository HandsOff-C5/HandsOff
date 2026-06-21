import { describe, expect, it } from "vitest";

import { alphaFromCutoff, createOneEuroFilter, ema } from "./smoothing";

describe("ema", () => {
  it("alpha=1 is passthrough (no smoothing)", () => {
    expect(ema(10, 3, 1)).toBe(10);
  });

  it("alpha=0 is frozen (holds the previous value)", () => {
    expect(ema(10, 3, 0)).toBe(3);
  });

  it("alpha=0.5 is the midpoint", () => {
    expect(ema(10, 0, 0.5)).toBe(5);
  });
});

describe("alphaFromCutoff", () => {
  it("returns an alpha in (0,1)", () => {
    const a = alphaFromCutoff(1, 1);
    expect(a).toBeGreaterThan(0);
    expect(a).toBeLessThan(1);
  });

  it("matches the 1/(1+tau/Te) definition", () => {
    // fc=1Hz, Te=1s → tau=1/(2π)=0.15915..., alpha=1/(1+tau)=0.8627...
    expect(alphaFromCutoff(1, 1)).toBeCloseTo(0.8627, 3);
  });

  it("a higher cutoff yields a larger alpha (tracks faster)", () => {
    expect(alphaFromCutoff(5, 1)).toBeGreaterThan(alphaFromCutoff(0.5, 1));
  });
});

describe("createOneEuroFilter", () => {
  it("returns the first sample unchanged", () => {
    const f = createOneEuroFilter({ minCutoff: 1, beta: 0 });
    expect(f.filter(5, 0)).toBe(5);
  });

  it("converges to a constant input (stays put once settled)", () => {
    const f = createOneEuroFilter({ minCutoff: 1, beta: 0 });
    f.filter(5, 0);
    for (let t = 50; t <= 500; t += 50) f.filter(5, t);
    expect(f.filter(5, 550)).toBeCloseTo(5, 6);
  });

  it("faster motion → less smoothing (higher beta tracks a ramp with less lag)", () => {
    const slow = createOneEuroFilter({ minCutoff: 1, beta: 0 });
    const fast = createOneEuroFilter({ minCutoff: 1, beta: 0.5 });
    let slowOut = 0;
    let fastOut = 0;
    // Same steady ramp into both: x increases by 1 each 50ms frame.
    for (let k = 0; k <= 20; k++) {
      const x = k;
      const t = k * 50;
      slowOut = slow.filter(x, t);
      fastOut = fast.filter(x, t);
    }
    const input = 20;
    expect(Math.abs(input - fastOut)).toBeLessThan(Math.abs(input - slowOut));
  });
});
