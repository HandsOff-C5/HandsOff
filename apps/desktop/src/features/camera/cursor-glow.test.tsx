import { describe, expect, it } from "vitest";

import { glowFromConfidence } from "./cursor-glow";

// A5 confidence glow — pure presentational mapping (STRICT). The cursor must SHOW
// certainty: dim + tight when the aim is unsure, bright + wide when confident.
describe("glowFromConfidence", () => {
  it("returns the unsure end (dim, tight) at zero confidence", () => {
    expect(glowFromConfidence(0)).toEqual({ opacity: 0.35, blurPx: 4 });
  });

  it("returns the confident end (bright, wide) at full confidence", () => {
    expect(glowFromConfidence(1)).toEqual({ opacity: 1, blurPx: 16 });
  });

  it("interpolates linearly at the midpoint", () => {
    const glow = glowFromConfidence(0.5);
    expect(glow.opacity).toBeCloseTo(0.675, 6);
    expect(glow.blurPx).toBeCloseTo(10, 6);
  });

  it("clamps out-of-range confidence to the endpoints", () => {
    expect(glowFromConfidence(-2)).toEqual({ opacity: 0.35, blurPx: 4 });
    expect(glowFromConfidence(5)).toEqual({ opacity: 1, blurPx: 16 });
  });

  it("treats a non-finite confidence as unsure (defends against NaN math)", () => {
    expect(glowFromConfidence(Number.NaN)).toEqual({ opacity: 0.35, blurPx: 4 });
  });

  it("is monotonic — more confidence never dims or shrinks the glow", () => {
    const a = glowFromConfidence(0.2);
    const b = glowFromConfidence(0.8);
    expect(b.opacity).toBeGreaterThan(a.opacity);
    expect(b.blurPx).toBeGreaterThan(a.blurPx);
  });
});
