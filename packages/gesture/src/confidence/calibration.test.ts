import { describe, expect, it } from "vitest";

import { calibrateConfidence } from "./calibration";

// Temperature scaling of a confidence/probability: p' = sigmoid(logit(p) / T).
// Raw MediaPipe scores are overconfident; T>1 softens them toward 0.5 before any
// threshold (dwell #28, glow, reliability) consumes them. T=1 passthrough,
// T<1 sharpens. Pure + deterministic. See #100 (ties to #28).
describe("calibrateConfidence", () => {
  it("T=1 is a passthrough (identity)", () => {
    for (const p of [0.05, 0.2, 0.5, 0.73, 0.99]) {
      expect(calibrateConfidence(p, 1)).toBeCloseTo(p, 10);
    }
  });

  it("0.5 is a fixed point for any temperature", () => {
    for (const T of [0.25, 0.5, 1, 2, 5]) {
      expect(calibrateConfidence(0.5, T)).toBeCloseTo(0.5, 10);
    }
  });

  it("T>1 softens an overconfident score toward 0.5", () => {
    const hi = calibrateConfidence(0.9, 2);
    expect(hi).toBeLessThan(0.9);
    expect(hi).toBeGreaterThan(0.5);
    const lo = calibrateConfidence(0.1, 2);
    expect(lo).toBeGreaterThan(0.1);
    expect(lo).toBeLessThan(0.5);
  });

  it("T<1 sharpens toward the extremes", () => {
    expect(calibrateConfidence(0.9, 0.5)).toBeGreaterThan(0.9);
    expect(calibrateConfidence(0.1, 0.5)).toBeLessThan(0.1);
  });

  it("is monotonic increasing in the raw score", () => {
    const T = 1.8;
    let prev = -Infinity;
    for (let p = 0.01; p <= 0.99; p += 0.01) {
      const out = calibrateConfidence(p, T);
      expect(out).toBeGreaterThan(prev);
      prev = out;
    }
  });

  it("keeps the endpoints 0 and 1 (no NaN/Infinity)", () => {
    expect(calibrateConfidence(0, 2)).toBe(0);
    expect(calibrateConfidence(1, 2)).toBe(1);
  });

  it("always returns a probability in [0,1]", () => {
    for (const T of [0.3, 1, 3]) {
      for (let p = 0; p <= 1; p += 0.1) {
        const out = calibrateConfidence(p, T);
        expect(out).toBeGreaterThanOrEqual(0);
        expect(out).toBeLessThanOrEqual(1);
      }
    }
  });

  it("clamps a raw score outside [0,1]", () => {
    expect(calibrateConfidence(1.5, 1)).toBe(1);
    expect(calibrateConfidence(-0.5, 1)).toBe(0);
  });

  it("throws on a non-positive temperature", () => {
    expect(() => calibrateConfidence(0.8, 0)).toThrow();
    expect(() => calibrateConfidence(0.8, -1)).toThrow();
  });
});
