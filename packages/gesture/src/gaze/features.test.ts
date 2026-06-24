import { describe, expect, it } from "vitest";

import { gazeFeatures, gazeFeatureVector, gazeOverlayPoints, type FaceLandmark } from "./features";

// Build a 478-point mesh of neutral points, then override the iris/eye indices we use.
const baseMesh = (): FaceLandmark[] => Array.from({ length: 478 }, () => ({ x: 0.5, y: 0.5 }));
const set = (
  pts: FaceLandmark[],
  overrides: Record<number, { x: number; y: number }>,
): FaceLandmark[] => {
  for (const [i, p] of Object.entries(overrides)) pts[Number(i)] = p;
  return pts;
};

// Symmetric "looking straight ahead" config: iris centered between corners + lids.
const centered = () =>
  set(baseMesh(), {
    468: { x: 0.5, y: 0.5 },
    133: { x: 0.4, y: 0.5 },
    33: { x: 0.6, y: 0.5 },
    159: { x: 0.5, y: 0.45 },
    145: { x: 0.5, y: 0.55 },
    473: { x: 0.5, y: 0.5 },
    362: { x: 0.4, y: 0.5 },
    263: { x: 0.6, y: 0.5 },
    386: { x: 0.5, y: 0.45 },
    374: { x: 0.5, y: 0.55 },
  });

describe("gazeFeatures", () => {
  it("reports iris centered (≈0.5) when the pupil sits mid-eye", () => {
    const f = gazeFeatures(centered());
    expect(f).not.toBeNull();
    expect(f!.irisXL).toBeCloseTo(0.5, 6);
    expect(f!.irisYL).toBeCloseTo(0.5, 6);
    expect(f!.irisXR).toBeCloseTo(0.5, 6);
    expect(gazeFeatureVector(f!)).toEqual([f!.irisXL, f!.irisYL, f!.irisXR, f!.irisYR]);
  });

  it("reports irisX→1 when the pupil sits at the outer corner", () => {
    const pts = set(centered(), { 468: { x: 0.6, y: 0.5 } }); // left iris at outer corner (33.x)
    const f = gazeFeatures(pts);
    expect(f!.irisXL).toBeCloseTo(1, 6);
  });

  it("drops eyeAspect when the lids are nearly closed", () => {
    const open = gazeFeatures(centered())!;
    const closed = gazeFeatures(
      set(centered(), {
        159: { x: 0.5, y: 0.49 },
        145: { x: 0.5, y: 0.51 },
        386: { x: 0.5, y: 0.49 },
        374: { x: 0.5, y: 0.51 },
      }),
    )!;
    expect(closed.eyeAspect).toBeLessThan(open.eyeAspect);
  });

  it("returns null when required landmarks are missing", () => {
    expect(gazeFeatures(Array.from({ length: 100 }, () => ({ x: 0.5, y: 0.5 })))).toBeNull();
  });

  it("returns null on a degenerate (zero-width) eye", () => {
    expect(
      gazeFeatures(set(centered(), { 133: { x: 0.6, y: 0.5 }, 33: { x: 0.6, y: 0.5 } })),
    ).toBeNull();
  });
});

describe("gazeOverlayPoints", () => {
  it("returns the iris/corner/lid points for both eyes", () => {
    const pts = gazeOverlayPoints(centered());
    expect(pts).not.toBeNull();
    // 5 per eye (iris + 2 corners + 2 lids) × 2 eyes.
    expect(pts!).toHaveLength(10);
    expect(pts!.filter((p) => p.kind === "iris")).toHaveLength(2);
    expect(pts!.filter((p) => p.kind === "corner")).toHaveLength(4);
    expect(pts!.filter((p) => p.kind === "lid")).toHaveLength(4);
    // The left iris center is index 468 = (0.5, 0.5) in the centered fixture.
    const iris = pts!.filter((p) => p.kind === "iris");
    expect(iris[0]!.x).toBeCloseTo(0.5, 6);
    expect(iris[0]!.y).toBeCloseTo(0.5, 6);
  });

  it("returns null when a required landmark is missing", () => {
    expect(gazeOverlayPoints(Array.from({ length: 100 }, () => ({ x: 0.5, y: 0.5 })))).toBeNull();
  });
});
