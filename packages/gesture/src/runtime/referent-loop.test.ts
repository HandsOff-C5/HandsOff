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

  it("smooths confidence across frames — a single high frame does not jump to full confidence (#28)", () => {
    const out = loop().process(frame(handAt(0.5, 0.5, 0.95)), 50);
    // EMA: the first frame is attenuated well below the raw 0.95, so one frame can't engage.
    expect(out.confidence).toBeGreaterThan(0);
    expect(out.confidence).toBeLessThan(0.95);
    expect(out.active).toBe(false);
  });

  it("engages and produces a candidate after a few frames of steady pointing", () => {
    const l = loop();
    const hand = handAt(0.5, 0.5, 0.95);
    let out = l.process(frame(hand, 50), 50);
    for (let i = 1; i < 4; i++) out = l.process(frame(hand, 50 + i * 50), 50);
    expect(out.candidate?.targetId).toBe("win-1");
    expect(out.active).toBe(true);
    expect(out.state.phase).not.toBe("idle");
  });

  it("locks to a referent once the hand dwells on one target, emitting exactly once", () => {
    const l = loop();
    const hand = handAt(0.5, 0.5, 0.95);
    expect(l.process(frame(hand, 0), 50).state.phase).not.toBe("locked"); // ramps up, not instant
    let emits = 0;
    let lockedAt = -1;
    for (let i = 1; i <= 30; i++) {
      const out = l.process(frame(hand, i * 50), 50);
      if (out.emit && "targetId" in out.emit) {
        emits++;
        if (lockedAt < 0) lockedAt = i;
      }
    }
    expect(lockedAt).toBeGreaterThan(0); // it did lock
    expect(emits).toBe(1); // and emitted the referent exactly once
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

  it("does not lock while the pointed target keeps changing (waving across surfaces)", () => {
    // Two side-by-side surfaces; alternate pointing left/right every frame.
    const split: Surface[] = [
      { id: "left", bounds: { x: 0, y: 0, w: 0.5, h: 1 }, displayId: "d0" },
      { id: "right", bounds: { x: 0.5, y: 0, w: 0.5, h: 1 }, displayId: "d0" },
    ];
    const l = createReferentLoop({
      transform: IDENTITY,
      surfaces: split,
      calibrationQuality: "good",
      dwell,
    });
    for (let i = 0; i < 40; i++) {
      const x = i % 2 === 0 ? 0.25 : 0.75; // left, right, left, right…
      expect(l.process(frame(handAt(x, 0.5, 0.95), i * 50), 50).state.phase).not.toBe("locked");
    }
  });

  it("keeps a locked referent when the hand then disappears", () => {
    const l = loop();
    const hand = handAt(0.5, 0.5, 0.95);
    // Hold long enough to clear the confidence ramp + dwell, then drop the hand.
    for (let i = 1; i <= 30; i++) l.process(frame(hand, i * 50), 50);
    expect(l.process(frame(null, 1600), 50).state.phase).toBe("locked");
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
