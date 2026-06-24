// Dwell-to-capture for the calibration onboarding: the operator holds their
// fingertip (then their gaze) on the glowing target dot; when the cursor stays
// within `radius` of the target for `holdMs`, the point is captured and the flow
// advances — fully hands-off, no button. Time is injected (nowMs) so the dwell
// math is deterministic and unit-tested without timers; coordinates are
// normalized overlay space [0,1].

export type Point = readonly [number, number];

export interface DwellConfig {
  // How close (in normalized [0,1] units) the cursor must be to count as "on" the target.
  radius: number;
  // How long the cursor must stay on target before it captures.
  holdMs: number;
}

export interface DwellState {
  // 0..1 fill toward capture.
  progress: number;
  // True on the single frame the hold completes (edge-triggered).
  captured: boolean;
}

export interface DwellTracker {
  update(cursor: Point | null, target: Point, nowMs: number): DwellState;
  reset(): void;
}

const within = (a: Point, b: Point, radius: number): boolean => {
  const dx = a[0] - b[0];
  const dy = a[1] - b[1];
  return Math.hypot(dx, dy) <= radius;
};

export function createDwellTracker({ radius, holdMs }: DwellConfig): DwellTracker {
  // When the current uninterrupted hold began, or null when not holding.
  let holdStart: number | null = null;
  // Latched once this dwell has captured, so capture is edge-triggered (fires once).
  let fired = false;

  const reset = (): void => {
    holdStart = null;
    fired = false;
  };

  return {
    reset,
    update(cursor, target, nowMs) {
      if (!cursor || !within(cursor, target, radius)) {
        holdStart = null;
        return { progress: 0, captured: false };
      }
      if (holdStart === null) holdStart = nowMs;
      const held = nowMs - holdStart;
      const progress = holdMs <= 0 ? 1 : Math.min(1, Math.max(0, held / holdMs));
      const captured = progress >= 1 && !fired;
      if (captured) fired = true;
      return { progress, captured };
    },
  };
}
