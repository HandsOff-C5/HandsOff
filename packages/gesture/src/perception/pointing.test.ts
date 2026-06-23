import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { type Hand, type LandmarkFrame } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { pointingReliability, pointingSignal, pointingSignalFromFrame } from "./pointing";

// A hand whose only meaningful points are wrist (0), index MCP (5), index tip (8);
// the rest are filler so the contract's 21-landmark length holds.
const handPointing = (): Hand => {
  const landmarks = Array.from({ length: 21 }, () => ({ x: 0, y: 0, z: 0, visibility: 1 }));
  landmarks[0] = { x: 0.2, y: 0.8, z: 0, visibility: 1 }; // wrist
  landmarks[5] = { x: 0.4, y: 0.6, z: 0, visibility: 1 }; // index MCP
  landmarks[8] = { x: 0.5, y: 0.5, z: 0, visibility: 1 }; // index tip
  return { landmarks, handedness: "Right", score: 0.9 };
};

describe("pointingSignal", () => {
  it("defaults to the index fingertip (landmark 8)", () => {
    expect(pointingSignal(handPointing())).toEqual([0.5, 0.5]);
  });

  it("extends along the wrist→tip ray when extend > 0", () => {
    // tip [0.5,0.5] + 1*(tip - wrist [0.2,0.8]) = [0.8, 0.2]
    const [x, y] = pointingSignal(handPointing(), { anchor: "wrist", extend: 1 });
    expect(x).toBeCloseTo(0.8, 6);
    expect(y).toBeCloseTo(0.2, 6);
  });

  it("uses the index MCP (landmark 5) as the ray anchor when requested", () => {
    // tip [0.5,0.5] + 1*(tip - mcp [0.4,0.6]) = [0.6, 0.4]
    const [x, y] = pointingSignal(handPointing(), { anchor: "indexMcp", extend: 1 });
    expect(x).toBeCloseTo(0.6, 6);
    expect(y).toBeCloseTo(0.4, 6);
  });
});

describe("pointingReliability (single-camera occlusion seam → fusion weight)", () => {
  it("is the detection score when the ray endpoints are fully visible", () => {
    // score 0.9, wrist + tip visibility 1 → 0.9.
    expect(pointingReliability(handPointing())).toBeCloseTo(0.9, 6);
  });

  it("falls when the index tip is occluded, even at high detection score", () => {
    const hand = handPointing();
    hand.landmarks[8] = { ...hand.landmarks[8]!, visibility: 0.2 };
    // 0.9 × min(1 wrist, 0.2 tip) = 0.18.
    expect(pointingReliability(hand)).toBeCloseTo(0.18, 6);
  });

  it("falls when the anchor is occluded — the ray is only as good as its worst endpoint", () => {
    const hand = handPointing();
    hand.landmarks[0] = { ...hand.landmarks[0]!, visibility: 0.1 }; // wrist occluded
    expect(pointingReliability(hand, { anchor: "wrist" })).toBeCloseTo(0.09, 6);
  });

  it("reads the index-MCP visibility when that is the chosen anchor", () => {
    const hand = handPointing();
    hand.landmarks[0] = { ...hand.landmarks[0]!, visibility: 0.1 }; // wrist occluded but unused
    hand.landmarks[5] = { ...hand.landmarks[5]!, visibility: 0.5 }; // MCP partially occluded
    // anchor=indexMcp ignores the wrist: 0.9 × min(0.5 mcp, 1 tip) = 0.45.
    expect(pointingReliability(hand, { anchor: "indexMcp" })).toBeCloseTo(0.45, 6);
  });

  it("is capped by a low detection score even with full visibility", () => {
    const hand = handPointing();
    hand.score = 0.3;
    expect(pointingReliability(hand)).toBeCloseTo(0.3, 6);
  });
});

describe("pointingSignalFromFrame", () => {
  it("returns null for a no-hand frame", () => {
    expect(pointingSignalFromFrame({ timestampMs: 0, hands: [] })).toBeNull();
  });

  it("derives the signal from the first detected hand", () => {
    const frame: LandmarkFrame = { timestampMs: 0, hands: [handPointing()] };
    expect(pointingSignalFromFrame(frame)).toEqual([0.5, 0.5]);
  });
});

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures");
const load = <T>(file: string): T => JSON.parse(readFileSync(join(fixturesDir, file), "utf8")) as T;

describe("pointing signal off the #29 point fixture (wires #29 → #26)", () => {
  it("computes the fingertip signal from the recorded pointing frame", () => {
    const golden = load<LandmarkFrame[]>("point.golden.json");
    // Fixture frame 0: index tip (landmark 8) = [0.31, 0.53].
    const [x, y] = pointingSignalFromFrame(golden[0]!)!;
    expect(x).toBeCloseTo(0.31, 6);
    expect(y).toBeCloseTo(0.53, 6);
  });
});
