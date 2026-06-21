import { describe, expect, it } from "vitest";

import { createDwellDebounce } from "./dwell";

const params = { enter: 0.7, exit: 0.4, dwellMs: 200, cooldownMs: 500 };

describe("createDwellDebounce", () => {
  it("a single high-confidence frame never fires (dwell not yet met)", () => {
    const d = createDwellDebounce(params);
    const r = d.update(0.9, 50); // one 50ms frame, dwell needs 200ms
    expect(r.active).toBe(true);
    expect(r.fired).toBe(false);
  });

  it("sustained confidence past dwellMs fires exactly once", () => {
    const d = createDwellDebounce(params);
    let fires = 0;
    for (let i = 0; i < 40; i++) if (d.update(0.9, 50).fired) fires++; // 2000ms total
    expect(fires).toBe(1);
  });

  it("hysteresis: once engaged, dips between exit and enter don't disengage (no flicker)", () => {
    const d = createDwellDebounce(params);
    d.update(0.9, 50); // engage (>= enter)
    // Values below `enter` but above `exit` must keep it active.
    for (const c of [0.5, 0.45, 0.6, 0.5]) {
      expect(d.update(c, 50).active).toBe(true);
    }
    // Dropping below `exit` finally disengages.
    expect(d.update(0.3, 50).active).toBe(false);
  });

  it("a noisy single high frame between low frames cannot fire", () => {
    const d = createDwellDebounce(params);
    const seq = [0.1, 0.95, 0.1, 0.1, 0.2]; // one spike, never sustained
    const fired = seq.map((c) => d.update(c, 50).fired);
    expect(fired.some(Boolean)).toBe(false);
  });

  it("cooldown blocks an immediate re-fire after a fire", () => {
    const d = createDwellDebounce({ ...params, dwellMs: 100, cooldownMs: 500 });
    const fireFrames: number[] = [];
    let tMs = 0;
    // Drive: engage→fire, drop out, re-engage repeatedly. dt=50ms.
    const pattern = [
      // first dwell → fires around 100ms
      0.9, 0.9, 0.9,
      // drop below exit (disengage), then immediately re-dwell while cooling down
      0.1, 0.9, 0.9, 0.9, 0.9, 0.9,
      // keep going long enough for cooldown (500ms) to lapse, then it may fire again
      0.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9,
    ];
    pattern.forEach((c) => {
      if (d.update(c, 50).fired) fireFrames.push(tMs);
      tMs += 50;
    });
    // Exactly two fires, and the second is at least cooldownMs after the first.
    expect(fireFrames).toHaveLength(2);
    expect(fireFrames[1]! - fireFrames[0]!).toBeGreaterThanOrEqual(500);
  });
});
