import { describe, expect, it } from "vitest";

import { type Display, pickDisplay } from "./arbitration";

// A3 — which-display arbitration in the global virtual-desktop space (same space as
// calibration output; x may be negative for a monitor left of primary). Pure geometry +
// hysteresis at seams; no OS calls (the display rects are supplied by the Rust shell).

const PRIMARY: Display = { id: "primary", bounds: { x: 0, y: 0, w: 1920, h: 1080 } };
const RIGHT: Display = { id: "right", bounds: { x: 1920, y: 0, w: 1920, h: 1080 } };
const LEFT: Display = { id: "left", bounds: { x: -1920, y: 0, w: 1920, h: 1080 } };
const TOP: Display = { id: "top", bounds: { x: 0, y: -1080, w: 1920, h: 1080 } };

describe("pickDisplay", () => {
  it("returns null when there are no displays", () => {
    expect(pickDisplay([100, 100], [])).toBeNull();
  });

  it("picks the display whose bounds contain the point", () => {
    expect(pickDisplay([960, 540], [PRIMARY, RIGHT])).toBe("primary");
    expect(pickDisplay([2880, 540], [PRIMARY, RIGHT])).toBe("right");
  });

  it("handles a monitor left of primary (negative x)", () => {
    expect(pickDisplay([-500, 540], [PRIMARY, LEFT])).toBe("left");
  });

  it("handles a stacked monitor above primary (negative y)", () => {
    expect(pickDisplay([500, -200], [PRIMARY, TOP])).toBe("top");
  });

  it("falls back to the nearest display when the point is in a gap between non-adjacent screens", () => {
    // PRIMARY ends at x=1920; FAR starts at x=2920 (1000px gap). Point at 2400 is 480px
    // from PRIMARY, 520px from FAR → nearest is PRIMARY.
    const far: Display = { id: "far", bounds: { x: 2920, y: 0, w: 1920, h: 1080 } };
    expect(pickDisplay([2400, 540], [PRIMARY, far])).toBe("primary");
  });

  describe("hysteresis at a seam (margin keeps the current display sticky)", () => {
    const displays = [PRIMARY, RIGHT];
    const MARGIN = 50;

    it("keeps the current display when the point has only just crossed the seam", () => {
      // Point at x=1930 is 10px into RIGHT, but within PRIMARY's bounds + 50px margin.
      expect(pickDisplay([1930, 540], displays, "primary", MARGIN)).toBe("primary");
    });

    it("switches once the point moves fully past the margin into the neighbor", () => {
      // Point at x=2000 is 80px past the seam, beyond PRIMARY+50 → switches to RIGHT.
      expect(pickDisplay([2000, 540], displays, "primary", MARGIN)).toBe("right");
    });

    it("with no current display, picks by containment (no stickiness to apply)", () => {
      expect(pickDisplay([1930, 540], displays, null, MARGIN)).toBe("right");
    });

    it("ignores a stale current id that is no longer among the displays", () => {
      expect(pickDisplay([960, 540], displays, "unplugged", MARGIN)).toBe("primary");
    });
  });
});
