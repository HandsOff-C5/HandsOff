import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { Hand, LandmarkFrame, Surface } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import type { AffineTransform } from "../calibration/calibrate";
import { createReferentLoop } from "./referent-loop";

// Identity calibration: the pointing signal (normalized [0,1]) maps straight to screen
// space, and one surface covers the whole space so any pointing hand lands on it.
const IDENTITY: AffineTransform = { a: 1, b: 0, c: 0, d: 0, e: 1, f: 0 };
const surfaces: Surface[] = [{ id: "win-1", bounds: { x: 0, y: 0, w: 1, h: 1 }, displayId: "d0" }];

const dwell = { enter: 0.6, exit: 0.4, dwellMs: 200, cooldownMs: 1000 };

// A hand whose index tip (landmark 8) sits at (x,y); wrist (0) at origin so the default
// wrist→tip signal with extend 0 is just the tip.
const handAt = (x: number, y: number, score: number): Hand => {
  const landmarks = Array.from({ length: 21 }, () => ({ x: 0, y: 0, z: 0, visibility: 1 }));
  landmarks[8] = { x, y, z: 0, visibility: 1 };
  return { landmarks, handedness: "Right", score };
};

const frame = (hand: Hand | null, timestampMs = 0): LandmarkFrame => ({
  timestampMs,
  hands: hand ? [hand] : [],
});

const loop = () =>
  createReferentLoop({ transform: IDENTITY, surfaces, calibrationQuality: "good", dwell });

describe("createReferentLoop", () => {
  it("stays idle for a no-hand frame", () => {
    const out = loop().process(frame(null), 50);
    expect(out.state.phase).toBe("idle");
    expect(out.candidate).toBeNull();
    expect(out.active).toBe(false);
  });

  it("a confident pointing hand produces a candidate (not yet locked)", () => {
    const out = loop().process(frame(handAt(0.5, 0.5, 0.95)), 50);
    expect(out.state.phase).toBe("candidate");
    expect(out.candidate?.targetId).toBe("win-1");
    expect(out.emit).toBeUndefined();
  });

  it("locks to a referent once the hand dwells past dwellMs, emitting once", () => {
    const l = loop();
    const hand = handAt(0.5, 0.5, 0.95);
    // 50ms ticks: dwell reaches 200ms on the 4th tick.
    expect(l.process(frame(hand, 50), 50).state.phase).toBe("candidate");
    expect(l.process(frame(hand, 100), 50).state.phase).toBe("candidate");
    expect(l.process(frame(hand, 150), 50).state.phase).toBe("candidate");
    const locked = l.process(frame(hand, 200), 50);
    expect(locked.state.phase).toBe("locked");
    expect(locked.emit).toEqual({
      targetId: "win-1",
      confidence: expect.any(Number),
      lockedAtMs: 200,
    });
    // Holding longer must not re-emit.
    expect(l.process(frame(hand, 250), 50).emit).toBeUndefined();
  });

  it("never locks while detection confidence stays below the enter threshold", () => {
    const l = loop();
    const jittery = handAt(0.5, 0.5, 0.3); // 0.3 < enter 0.6
    for (let t = 0; t < 2000; t += 50) {
      const out = l.process(frame(jittery, t), 50);
      expect(out.state.phase).not.toBe("locked");
      expect(out.active).toBe(false);
    }
  });

  it("keeps a locked referent when the hand then disappears", () => {
    const l = loop();
    const hand = handAt(0.5, 0.5, 0.95);
    for (let t = 50; t <= 200; t += 50) l.process(frame(hand, t), 50);
    expect(l.process(frame(null, 250), 50).state.phase).toBe("locked");
  });
});

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures");
const load = <T>(file: string): T => JSON.parse(readFileSync(join(fixturesDir, file), "utf8")) as T;

describe("referent loop over #29 fixtures", () => {
  it("the point fixture drives the loop to a locked referent", () => {
    const frames = load<LandmarkFrame[]>("point.golden.json");
    const l = loop();
    let phase = "idle";
    // Big dt so the sustained point clears dwellMs within the short fixture.
    for (const f of frames) phase = l.process(f, 250).state.phase;
    expect(phase).toBe("locked");
  });

  it("the low-confidence fixture never locks", () => {
    const frames = load<LandmarkFrame[]>("low-confidence.golden.json");
    const l = loop();
    for (const f of frames) expect(l.process(f, 250).state.phase).not.toBe("locked");
  });
});
