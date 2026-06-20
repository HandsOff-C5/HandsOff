import { describe, expect, it } from "vitest";

import {
  GestureState,
  Hand,
  InterruptIntent,
  LandmarkFrame,
  LockedReferent,
  PointingCandidate,
} from "./referent";

const landmark = { x: 0.1, y: 0.2, z: 0, visibility: 1 };
const hand = {
  landmarks: Array.from({ length: 21 }, () => landmark),
  handedness: "Right",
  score: 0.9,
};

describe("referent contracts", () => {
  it("LandmarkFrame accepts a well-formed frame and an empty (no-hand) frame", () => {
    expect(LandmarkFrame.parse({ timestampMs: 1, hands: [hand] }).hands).toHaveLength(1);
    expect(LandmarkFrame.parse({ timestampMs: 1, hands: [] }).hands).toHaveLength(0);
  });

  it("Hand requires exactly 21 landmarks", () => {
    expect(() => Hand.parse({ ...hand, landmarks: [landmark] })).toThrow();
  });

  it("PointingCandidate validates shape and rejects out-of-range confidence", () => {
    expect(
      PointingCandidate.parse({ targetId: "win-1", confidence: 0.8, calibrationQuality: "good" })
        .targetId,
    ).toBe("win-1");
    expect(() =>
      PointingCandidate.parse({ targetId: "win-1", confidence: 2, calibrationQuality: "good" }),
    ).toThrow();
  });

  it("LockedReferent validates shape", () => {
    expect(
      LockedReferent.parse({ targetId: "win-1", confidence: 0.9, lockedAtMs: 123 }).targetId,
    ).toBe("win-1");
  });

  it("GestureState enumerates the four states and rejects unknown", () => {
    expect(GestureState.parse("locked")).toBe("locked");
    expect(() => GestureState.parse("flying")).toThrow();
  });

  it("InterruptIntent accepts pause/stop/cancel and rejects others", () => {
    expect(InterruptIntent.parse({ kind: "pause" }).kind).toBe("pause");
    expect(() => InterruptIntent.parse({ kind: "explode" })).toThrow();
  });
});
