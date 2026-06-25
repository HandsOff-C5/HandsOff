import { describe, expect, it } from "vitest";

import type { Display } from "../display/arbitration";
import {
  fitMultiMonitor,
  multiMonitorTargets,
  predictMultiMonitor,
  type MultiCalibrationPair,
  type Point,
} from "./multi-monitor";

// Two displays in the same global virtual-desktop space as the contracts SurfaceBounds: a
// primary at the origin and a secondary to the left of it (negative x), like a real layout.
const primary: Display = { id: "1", bounds: { x: 0, y: 0, w: 1920, h: 1080 } };
const secondary: Display = { id: "2", bounds: { x: -1920, y: 0, w: 1920, h: 1080 } };

describe("multiMonitorTargets", () => {
  it("lays a grid across every display in global coords", () => {
    const targets = multiMonitorTargets([primary, secondary], { cols: 3, rows: 3, margin: 0 });
    // 3×3 per display × 2 displays.
    expect(targets).toHaveLength(18);
    // Primary targets start at its origin (0,0); secondary targets start at its origin (-1920,0).
    expect(targets[0]).toEqual({ displayId: "1", target: [0, 0] });
    const firstSecondary = targets.find((t) => t.displayId === "2");
    expect(firstSecondary?.target[0]).toBe(-1920);
  });
});

const buildPairs = (display: Display, count: number): MultiCalibrationPair[] => {
  // Raw signal = local [0,1]²; target = global px (origin + raw·size). A clean per-display fit
  // recovers the scale (1920/1080) and the display origin.
  const pairs: MultiCalibrationPair[] = [];
  const grid = [
    [0, 0],
    [1, 0],
    [0, 1],
    [1, 1],
    [0.5, 0.5],
  ] as const;
  for (let i = 0; i < count; i++) {
    const [rx, ry] = grid[i % grid.length] as Point;
    pairs.push({
      raw: [rx, ry],
      displayId: display.id,
      target: [display.bounds.x + rx * display.bounds.w, display.bounds.y + ry * display.bounds.h],
    });
  }
  return pairs;
};

describe("fitMultiMonitor", () => {
  it("recovers a per-display affine (scale + origin) for a single display", () => {
    const cal = fitMultiMonitor(buildPairs(primary, 9));
    const fit = cal.byDisplay["1"];
    expect(fit).toBeDefined();
    expect(fit.transform.a).toBeCloseTo(1920, 3);
    expect(fit.transform.e).toBeCloseTo(1080, 3);
    expect(fit.transform.c).toBeCloseTo(0, 3);
    expect(fit.transform.f).toBeCloseTo(0, 3);
    expect(cal.quality).toBe("good");
  });

  it("fits each display independently so the secondary's negative origin is recovered", () => {
    const cal = fitMultiMonitor([...buildPairs(primary, 5), ...buildPairs(secondary, 5)]);
    // Primary origin (0,0); secondary origin (-1920,0).
    expect(cal.byDisplay["1"].transform.c).toBeCloseTo(0, 3);
    expect(cal.byDisplay["2"].transform.c).toBeCloseTo(-1920, 3);
    expect(cal.byDisplay["2"].transform.a).toBeCloseTo(1920, 3);
  });

  it("throws when any display has fewer than 3 correspondences", () => {
    expect(() => fitMultiMonitor(buildPairs(primary, 2))).toThrow(/need ≥3/);
  });
});

describe("predictMultiMonitor", () => {
  // Pointing at the left monitor puts the hand on the LEFT of the camera image and pointing
  // at the right monitor puts it on the RIGHT — so the two displays occupy disjoint raw-
  // signal regions, which is what nearest-centroid classification keys on. Build a fit where
  // primary raws cluster right (≈0.8) and secondary raws cluster left (≈0.2).
  const separatedFit = (): ReturnType<typeof fitMultiMonitor> => {
    const primaryRaws = [
      [0.6, 0],
      [1, 0],
      [0.6, 1],
      [1, 1],
      [0.8, 0.5],
    ] as const;
    const secondaryRaws = [
      [0, 0],
      [0.4, 0],
      [0, 1],
      [0.4, 1],
      [0.2, 0.5],
    ] as const;
    const pairs: MultiCalibrationPair[] = [
      ...primaryRaws.map(([rx, ry]) => ({
        raw: [rx, ry] as Point,
        displayId: "1",
        target: [rx * 1920, ry * 1080] as Point,
      })),
      ...secondaryRaws.map(([rx, ry]) => ({
        raw: [rx, ry] as Point,
        displayId: "2",
        target: [rx * 1920 - 1920, ry * 1080] as Point,
      })),
    ];
    return fitMultiMonitor(pairs);
  };

  it("routes a left-side reading to the secondary display (negative global x)", () => {
    const cal = separatedFit();
    const [gx] = predictMultiMonitor(cal, [0.2, 0.5]);
    expect(gx).toBeLessThan(0);
    expect(gx).toBeCloseTo(0.2 * 1920 - 1920, 1);
  });

  it("routes a right-side reading to the primary display (non-negative global x)", () => {
    const cal = separatedFit();
    const [gx] = predictMultiMonitor(cal, [0.8, 0.5]);
    expect(gx).toBeGreaterThanOrEqual(0);
    expect(gx).toBeCloseTo(0.8 * 1920, 1);
  });

  it("passes the raw point through unchanged when there is no calibration", () => {
    expect(predictMultiMonitor(null, [0.3, 0.4])).toEqual([0.3, 0.4]);
  });
});
