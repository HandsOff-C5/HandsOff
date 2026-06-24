import { describe, expect, it } from "vitest";

import { monitorLocalToUnionNormalized, unionBounds, type MonitorRect } from "./display-map";

const single: MonitorRect[] = [{ x: 0, y: 0, w: 1728, h: 1117 }];
const sideBySide: MonitorRect[] = [
  { x: 0, y: 0, w: 1728, h: 1117 },
  { x: 1728, y: 0, w: 2560, h: 1440 },
];

describe("display-map", () => {
  describe("unionBounds", () => {
    it("a single monitor is its own union", () => {
      expect(unionBounds(single)).toEqual({ x: 0, y: 0, w: 1728, h: 1117 });
    });
    it("spans side-by-side monitors", () => {
      expect(unionBounds(sideBySide)).toEqual({ x: 0, y: 0, w: 1728 + 2560, h: 1440 });
    });
    it("covers monitors in negative space", () => {
      expect(
        unionBounds([
          { x: 0, y: 0, w: 1000, h: 1000 },
          { x: -800, y: -200, w: 800, h: 600 },
        ]),
      ).toEqual({ x: -800, y: -200, w: 1800, h: 1200 });
    });
    it("is a zero rect with no monitors", () => {
      expect(unionBounds([])).toEqual({ x: 0, y: 0, w: 0, h: 0 });
    });
  });

  describe("monitorLocalToUnionNormalized", () => {
    it("maps a monitor-local [0,1] point to the union [0,1] box", () => {
      // Centre of the only monitor stays centred.
      expect(monitorLocalToUnionNormalized(single, 0, [0.5, 0.5])).toEqual([0.5, 0.5]);
    });
    it("places a point on the second display at its union offset", () => {
      // Top-left of the right-hand monitor sits at x = 1728/4288 across the union.
      const [x, y] = monitorLocalToUnionNormalized(sideBySide, 1, [0, 0]);
      expect(x).toBeCloseTo(1728 / 4288, 5);
      expect(y).toBe(0);
    });
    it("clamps an out-of-range monitor index to nothing (returns null)", () => {
      expect(monitorLocalToUnionNormalized(sideBySide, 9, [0.5, 0.5])).toBeNull();
      expect(monitorLocalToUnionNormalized([], 0, [0.5, 0.5])).toBeNull();
    });
  });
});
