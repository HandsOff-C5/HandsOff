import type { SurfaceBounds } from "@handsoff/contracts";

import { distanceToBounds, type Point } from "../calibration/calibrate";

// A3 — which-display arbitration. Given a calibrated screen-space point (global virtual-
// desktop px; x may be negative) and the attached displays, decide which display the user
// is pointing at. Pure geometry: the OS supplies the display rects (CoreGraphics from the
// Rust shell, keyed by the stable CGDisplay UUID — not the transient DirectDisplayID). The
// per-display backingScaleFactor is a downstream px-conversion concern, not arbitration.

export interface Display {
  // Stable identifier — CGDisplayCreateUUIDFromDisplayID, persistent across reconnects.
  id: string;
  // Display rect in the same global virtual-desktop space as the calibration output.
  bounds: SurfaceBounds;
}

// Is the point inside the rect grown by `margin` on every side?
const insideExpanded = ([x, y]: Point, b: SurfaceBounds, margin: number): boolean =>
  x >= b.x - margin && x <= b.x + b.w + margin && y >= b.y - margin && y <= b.y + b.h + margin;

// Pick the display the point belongs to. With a `currentId` and a positive `marginPx`,
// the choice is sticky: the point must leave the current display's bounds by more than the
// margin before arbitration switches, so a hand hovering on a seam doesn't flicker between
// screens. Without a current display (or once the point is past the margin) it picks the
// containing display, falling back to the nearest one across a gap. Null only if there are
// no displays.
export const pickDisplay = (
  point: Point,
  displays: Display[],
  currentId: string | null = null,
  marginPx = 0,
): string | null => {
  // Hysteresis: hold the current display until the point clears its bounds + margin.
  if (currentId !== null) {
    const current = displays.find((d) => d.id === currentId);
    if (current && insideExpanded(point, current.bounds, marginPx)) return current.id;
  }
  // Otherwise the containing display, or the nearest one across a gap.
  let best: Display | null = null;
  let bestDist = Infinity;
  for (const display of displays) {
    const dist = distanceToBounds(point, display.bounds);
    if (dist < bestDist) {
      best = display;
      bestDist = dist;
    }
  }
  return best ? best.id : null;
};
