import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { type CalibrationQuality, PointingCandidate, type Surface } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import {
  applyTransform,
  type AffineTransform,
  calibrationQualityFromResidual,
  calibrationResidual,
  type CalibrationPair,
  fitAffine,
  type Point,
  toCandidate,
} from "./calibrate";

// A known affine with rotation/shear/translation — the matrix fitAffine must recover.
const KNOWN: AffineTransform = { a: 1.2, b: -0.3, c: 40, d: 0.25, e: 0.9, f: -15 };

const apply = (t: AffineTransform, [x, y]: Point): Point => [
  t.a * x + t.b * y + t.c,
  t.d * x + t.e * y + t.f,
];

const RAW: Point[] = [
  [0, 0],
  [100, 0],
  [0, 100],
  [100, 100],
  [50, 50],
];

const exactPairs = (): CalibrationPair[] => RAW.map((raw) => ({ raw, target: apply(KNOWN, raw) }));

describe("affine calibration fit", () => {
  it("recovers a KNOWN affine matrix from exact synthetic correspondences", () => {
    const fit = fitAffine(exactPairs());
    for (const k of ["a", "b", "c", "d", "e", "f"] as const) {
      expect(fit[k]).toBeCloseTo(KNOWN[k], 6);
    }
  });

  it("fits with residual ~0 when the correspondences are exact", () => {
    const pairs = exactPairs();
    expect(calibrationResidual(fitAffine(pairs), pairs)).toBeCloseTo(0, 6);
  });

  it("reports a positive residual when a target is perturbed off the fit", () => {
    const pairs = exactPairs();
    pairs[2] = { raw: pairs[2].raw, target: [pairs[2].target[0] + 30, pairs[2].target[1] - 30] };
    expect(calibrationResidual(fitAffine(pairs), pairs)).toBeGreaterThan(0);
  });

  it("throws below the affine minimum of 3 correspondences", () => {
    expect(() => fitAffine(exactPairs().slice(0, 2))).toThrow();
  });
});

describe("applyTransform", () => {
  it("maps a point through the affine exactly", () => {
    // 1.2*10 + -0.3*20 + 40 = 46 ; 0.25*10 + 0.9*20 + -15 = 5.5
    expect(applyTransform(KNOWN, [10, 20])).toEqual([46, 5.5]);
  });
});

describe("calibrationQualityFromResidual (global px thresholds)", () => {
  it("buckets residual into good / fair / poor", () => {
    expect(calibrationQualityFromResidual(5)).toBe("good");
    expect(calibrationQualityFromResidual(20)).toBe("good");
    expect(calibrationQualityFromResidual(40)).toBe("fair");
    expect(calibrationQualityFromResidual(60)).toBe("fair");
    expect(calibrationQualityFromResidual(100)).toBe("poor");
  });
});

describe("toCandidate hit-test", () => {
  const surfaces: Surface[] = [
    { id: "a", bounds: { x: 0, y: 0, w: 100, h: 100 }, displayId: "d0" },
    { id: "b", bounds: { x: 500, y: 0, w: 100, h: 100 }, displayId: "d0" },
  ];

  it("returns a contract-valid PointingCandidate for the nearest surface when outside all", () => {
    // [200,50]: dist to a = 100, dist to b = 300 → nearest a; conf = 1/(1+100/200) = 2/3.
    const candidate = toCandidate([200, 50], surfaces, "fair");
    expect(candidate).not.toBeNull();
    expect(() => PointingCandidate.parse(candidate)).not.toThrow();
    expect(candidate?.targetId).toBe("a");
    expect(candidate?.calibrationQuality).toBe("fair");
    expect(candidate?.confidence).toBeCloseTo(2 / 3, 6);
  });

  it("gives full confidence when the point is inside a surface", () => {
    expect(toCandidate([50, 50], surfaces, "good")?.confidence).toBe(1);
  });

  it("returns null when there are no surfaces", () => {
    expect(toCandidate([50, 50], [], "good")).toBeNull();
  });
});

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures");

interface GoldenCase {
  name: string;
  screenXY: Point;
  calibrationQuality: CalibrationQuality;
  surfaces: Surface[];
  expected: { targetId: string; confidence: number; calibrationQuality: CalibrationQuality } | null;
}

const golden = JSON.parse(
  readFileSync(join(fixturesDir, "calibration.golden.json"), "utf8"),
) as GoldenCase[];

describe("toCandidate golden records (compare stored, not inferred)", () => {
  it.each(golden)("$name", ({ screenXY, surfaces, calibrationQuality, expected }) => {
    expect(toCandidate(screenXY, surfaces, calibrationQuality)).toEqual(expected);
  });
});
