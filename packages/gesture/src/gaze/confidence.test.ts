import { describe, expect, it } from "vitest";

import { eyeTrackingConfidence } from "./confidence";
import type { GazeFeatures } from "./features";

// A fully-open, centered, both-eyes-agree read — the best-case frame.
const ideal: GazeFeatures = {
  irisXL: 0.5,
  irisYL: 0.5,
  irisXR: 0.5,
  irisYR: 0.5,
  eyeAspect: 0.3,
};

describe("eyeTrackingConfidence", () => {
  it("is 0 when there is no face (null features)", () => {
    expect(eyeTrackingConfidence(null)).toBe(0);
  });

  it("is ~1 for an ideal open, centered, agreeing read", () => {
    expect(eyeTrackingConfidence(ideal)).toBeCloseTo(1, 5);
  });

  it("collapses toward 0 during a blink (eyes closed → tiny eye-aspect)", () => {
    expect(eyeTrackingConfidence({ ...ideal, eyeAspect: 0.02 })).toBe(0);
  });

  it("ramps openness linearly between the blink and open thresholds", () => {
    // aspect 0.19 sits halfway between BLINK_ASPECT (0.12) and OPEN_ASPECT (0.26).
    expect(eyeTrackingConfidence({ ...ideal, eyeAspect: 0.19 })).toBeCloseTo(0.5, 5);
  });

  it("drops when iris fractions drift outside the valid [0,1] band", () => {
    // Both eyes drift equally (agreement preserved), each 0.3 past the band.
    const drifted = { ...ideal, irisXL: 1.3, irisXR: 1.3 };
    // mean drift = (0.3 + 0 + 0.3 + 0)/4 = 0.15; validity = 1 - 0.15/0.6 = 0.75.
    expect(eyeTrackingConfidence(drifted)).toBeCloseTo(0.75, 5);
  });

  it("drops when the two eyes disagree on horizontal gaze direction", () => {
    // |0.2 - 0.45| = 0.25 → agreement = 1 - 0.25/0.5 = 0.5.
    expect(eyeTrackingConfidence({ ...ideal, irisXL: 0.2, irisXR: 0.45 })).toBeCloseTo(0.5, 5);
  });

  it("stays within [0,1] for extreme garbage input", () => {
    const c = eyeTrackingConfidence({
      irisXL: 9,
      irisYL: -9,
      irisXR: -4,
      irisYR: 7,
      eyeAspect: 5,
    });
    expect(c).toBeGreaterThanOrEqual(0);
    expect(c).toBeLessThanOrEqual(1);
  });
});
