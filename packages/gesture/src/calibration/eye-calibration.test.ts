import { describe, expect, it } from "vitest";

import { applyPolynomial } from "./calibrate";
import { createEyeCalibration } from "./eye-calibration";

const LAPTOP = { x: 0, y: 0, w: 1000, h: 800 };
const EXTERNAL = { x: 1000, y: 0, w: 500, h: 500 };

// Distinct, full-rank 4-feature vectors so the 9-sample polynomial fit is solvable:
// (f0,f1) walk a 3×3 grid; f2,f3 are permutations that break any affine dependence
// (verified non-singular against the no-cross-term quadratic basis).
const featuresFor = (i: number): number[] => [
  (i % 3) * 0.4 + 0.1,
  Math.floor(i / 3) * 0.4 + 0.1,
  ((i * 7) % 9) / 10 + 0.05,
  ((i * 5 + 2) % 9) / 10 + 0.05,
];

// Drive a whole monitor's 9 dots with `featuresFor`.
const captureMonitor = (cal: ReturnType<typeof createEyeCalibration>): void => {
  for (let i = 0; i < 9; i++) cal.capture(featuresFor(i));
};

describe("createEyeCalibration", () => {
  it("throws when given no monitors", () => {
    expect(() => createEyeCalibration({ monitors: [] })).toThrow();
  });

  it("starts on the first monitor's first dot", () => {
    const cal = createEyeCalibration({ monitors: [LAPTOP, EXTERNAL] });
    const v = cal.view();
    expect(v.done).toBe(false);
    expect(v.monitorIndex).toBe(0);
    expect(v.monitorCount).toBe(2);
    expect(v.dotIndex).toBe(0);
    expect(v.dotsPerMonitor).toBe(9);
    expect(v.totalDots).toBe(18);
  });

  it("places the 3×3 grid in global pixels with a 12% inset (top-left first)", () => {
    const cal = createEyeCalibration({ monitors: [LAPTOP, EXTERNAL] });
    // dot 0 → local (0.12, 0.12) on the 1000×800 laptop → (120, 96).
    expect(cal.view().current?.globalPx).toEqual([120, 96]);
    for (let i = 0; i < 4; i++) cal.capture(featuresFor(i));
    // dot 4 is the center → local (0.5, 0.5) → (500, 400).
    expect(cal.view().current?.globalPx).toEqual([500, 400]);
  });

  it("advances to the external monitor after the laptop's 9 dots, offsetting by its origin", () => {
    const cal = createEyeCalibration({ monitors: [LAPTOP, EXTERNAL] });
    captureMonitor(cal);
    const v = cal.view();
    expect(v.monitorIndex).toBe(1);
    expect(v.dotIndex).toBe(0);
    // external dot 0 → local (0.12, 0.12) on 500×500 at origin (1000,0) → (1060, 60).
    expect(v.current?.globalPx).toEqual([1060, 60]);
  });

  it("withholds the outcome until every monitor is fitted", () => {
    const cal = createEyeCalibration({ monitors: [LAPTOP, EXTERNAL] });
    captureMonitor(cal);
    expect(cal.outcome()).toBeNull(); // laptop done, external not
    captureMonitor(cal);
    const out = cal.outcome();
    expect(out).not.toBeNull();
    expect(out?.fits).toHaveLength(2);
  });

  it("marks the flow done after the last dot and refuses further captures", () => {
    const cal = createEyeCalibration({ monitors: [LAPTOP] });
    captureMonitor(cal);
    expect(cal.view().done).toBe(true);
    expect(cal.view().current).toBeNull();
    expect(() => cal.capture(featuresFor(0))).toThrow();
  });

  it("fits a per-monitor polynomial that reconstructs its training targets", () => {
    const cal = createEyeCalibration({ monitors: [LAPTOP] });
    const targets: Array<[number, number]> = [];
    for (let i = 0; i < 9; i++) {
      targets.push(cal.view().current!.globalPx);
      cal.capture(featuresFor(i));
    }
    const fit = cal.outcome()!.fits[0]!;
    expect(fit.monitorIndex).toBe(0);
    expect(fit.transform.featureCount).toBe(4);
    expect(Number.isFinite(fit.residualPx)).toBe(true);
    // Exactly-determined full-rank fit → predicts each training dot back to its target.
    for (let i = 0; i < 9; i++) {
      const [px, py] = applyPolynomial(fit.transform, featuresFor(i));
      expect(px).toBeCloseTo(targets[i]![0], 3);
      expect(py).toBeCloseTo(targets[i]![1], 3);
    }
    expect(fit.quality).toBe("good");
  });
});
