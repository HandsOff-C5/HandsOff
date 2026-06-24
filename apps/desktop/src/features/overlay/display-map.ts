// Per-display geometry for the overlay-as-UI HUD. The overlay window spans the
// UNION of every monitor (see the Rust `union_bounds` in commands/overlay.rs);
// the cursors are positioned in union-normalized [0,1]. A tracker that reports a
// point local to one display must be mapped into that union box, or the dot lands
// on the wrong screen. These are the pure transforms for that mapping (the TS
// mirror of the Rust union geometry) so the multi-monitor math is unit-tested
// without a display. Wiring each tracker's monitor is the hardware-pass step.

// A monitor's bounds in physical pixels: top-left (x,y) + size (w,h).
export interface MonitorRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

// The bounding box that covers every monitor. Empty input → a zero rect.
export function unionBounds(monitors: readonly MonitorRect[]): MonitorRect {
  const first = monitors[0];
  if (!first) return { x: 0, y: 0, w: 0, h: 0 };
  let minX = first.x;
  let minY = first.y;
  let maxX = first.x + first.w;
  let maxY = first.y + first.h;
  for (const m of monitors.slice(1)) {
    minX = Math.min(minX, m.x);
    minY = Math.min(minY, m.y);
    maxX = Math.max(maxX, m.x + m.w);
    maxY = Math.max(maxY, m.y + m.h);
  }
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

// A point normalized [0,1] within monitor `index` → the union-normalized [0,1]
// position the overlay uses. Returns null for an unknown monitor or empty union.
export function monitorLocalToUnionNormalized(
  monitors: readonly MonitorRect[],
  index: number,
  local: readonly [number, number],
): [number, number] | null {
  const monitor = monitors[index];
  if (!monitor) return null;
  const union = unionBounds(monitors);
  if (union.w <= 0 || union.h <= 0) return null;
  const globalX = monitor.x + local[0] * monitor.w;
  const globalY = monitor.y + local[1] * monitor.h;
  return [(globalX - union.x) / union.w, (globalY - union.y) / union.h];
}
