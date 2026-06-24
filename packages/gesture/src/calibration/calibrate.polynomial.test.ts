import { describe, expect, it } from "vitest";

import {
  applyPolynomial,
  fitPolynomial,
  polynomialResidual,
  type PolynomialSample,
} from "./calibrate";

// A known quadratic over a 2-feature vector; basis = [1, f0, f1, f0², f1²].
const truthX = (f: readonly number[]) =>
  2 + 3 * f[0]! - 1.5 * f[1]! + 0.5 * f[0]! ** 2 + 0.25 * f[1]! ** 2;
const truthY = (f: readonly number[]) =>
  -1 + 0.7 * f[0]! + 2 * f[1]! - 0.3 * f[0]! ** 2 + 0.1 * f[1]! ** 2;

const grid: number[][] = [];
for (const a of [-1, 0, 1]) for (const b of [-1, 0, 1]) grid.push([a, b]);
const samples: PolynomialSample[] = grid.map((f) => ({
  features: f,
  target: [truthX(f), truthY(f)] as const,
}));

describe("fitPolynomial", () => {
  it("recovers a known quadratic mapping within tolerance", () => {
    const t = fitPolynomial(samples);
    for (const s of samples) {
      const [x, y] = applyPolynomial(t, s.features);
      expect(x).toBeCloseTo(s.target[0], 4);
      expect(y).toBeCloseTo(s.target[1], 4);
    }
    expect(polynomialResidual(t, samples)).toBeLessThan(1e-6);
  });

  it("throws when there are too few samples for the basis", () => {
    expect(() => fitPolynomial(samples.slice(0, 3))).toThrow();
  });

  it("throws on inconsistent feature lengths", () => {
    expect(() =>
      fitPolynomial([...samples, { features: [1, 2, 3], target: [0, 0] as const }]),
    ).toThrow();
  });
});
