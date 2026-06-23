import { LandmarkFrame } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { parseLandmarkFrame, type RawHandLandmarkerResult } from "./parse";

// 21 distinct landmarks so ordering/structure is exercised, not just a repeat.
const rawLandmarks = (visibility?: number) =>
  Array.from({ length: 21 }, (_, i) => ({
    x: i / 21,
    y: 1 - i / 21,
    z: (i - 10) / 100,
    ...(visibility === undefined ? {} : { visibility }),
  }));

const rightHand: RawHandLandmarkerResult = {
  landmarks: [rawLandmarks(0.95)],
  handednesses: [[{ categoryName: "Right", score: 0.9 }]],
};

describe("parseLandmarkFrame", () => {
  it("parses a one-hand raw result into a valid LandmarkFrame", () => {
    const frame = parseLandmarkFrame(rightHand, 1234);

    // Output must satisfy the shared contract (throws otherwise).
    expect(() => LandmarkFrame.parse(frame)).not.toThrow();
    expect(frame.timestampMs).toBe(1234);
    expect(frame.hands).toHaveLength(1);

    const hand = frame.hands[0]!;
    expect(hand.handedness).toBe("Right");
    expect(hand.score).toBe(0.9);
    expect(hand.landmarks).toHaveLength(21);
    expect(hand.landmarks[5]).toEqual({
      x: 5 / 21,
      y: 1 - 5 / 21,
      z: (5 - 10) / 100,
      visibility: 0.95,
    });
  });

  it("maps a no-hand raw result to an empty-hands frame", () => {
    const frame = parseLandmarkFrame({ landmarks: [], handednesses: [] }, 7);
    expect(frame).toEqual({ timestampMs: 7, hands: [] });
  });

  it("defaults a missing landmark visibility to 1", () => {
    const frame = parseLandmarkFrame(
      { landmarks: [rawLandmarks()], handednesses: [[{ categoryName: "Left", score: 0.8 }]] },
      0,
    );
    expect(frame.hands[0]!.landmarks.every((l) => l.visibility === 1)).toBe(true);
  });

  it("accepts the deprecated `handedness` field name as well as `handednesses`", () => {
    const frame = parseLandmarkFrame(
      { landmarks: [rawLandmarks(1)], handedness: [[{ categoryName: "Left", score: 0.7 }]] },
      0,
    );
    expect(frame.hands[0]!.handedness).toBe("Left");
    expect(frame.hands[0]!.score).toBe(0.7);
  });

  it("pairs each hand with its handedness by index for two hands", () => {
    const frame = parseLandmarkFrame(
      {
        landmarks: [rawLandmarks(1), rawLandmarks(1)],
        handednesses: [
          [{ categoryName: "Right", score: 0.9 }],
          [{ categoryName: "Left", score: 0.6 }],
        ],
      },
      0,
    );
    expect(frame.hands.map((h) => h.handedness)).toEqual(["Right", "Left"]);
  });

  it("rejects a malformed hand (wrong landmark count) via contract validation", () => {
    expect(() =>
      parseLandmarkFrame(
        {
          landmarks: [[{ x: 0, y: 0, z: 0, visibility: 1 }]],
          handednesses: [[{ categoryName: "Right", score: 0.9 }]],
        },
        0,
      ),
    ).toThrow();
  });
});
