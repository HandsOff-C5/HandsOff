import { describe, expect, it, vi } from "vitest";

import { type RawHandLandmarkerResult } from "../perception/parse";
import { createLandmarkProcessor, type LandmarkDetector } from "./detector";

// One synthetic raw result: a single right hand of 21 ramped landmarks.
const rawOneHand = (): RawHandLandmarkerResult => ({
  landmarks: [Array.from({ length: 21 }, (_, i) => ({ x: i / 21, y: i / 21, z: 0 }))],
  handednesses: [[{ categoryName: "Right", score: 0.9 }]],
});

const fakeDetector = (result: RawHandLandmarkerResult): LandmarkDetector => ({
  detectForVideo: () => result,
});

describe("createLandmarkProcessor", () => {
  it("parses a changed frame into a LandmarkFrame and reports it", () => {
    const onResult = vi.fn();
    const processor = createLandmarkProcessor({ detector: fakeDetector(rawOneHand()), onResult });

    const out = processor.process({ currentTime: 0.1 }, 1000);

    expect(out?.frame.hands).toHaveLength(1);
    expect(out?.frame.hands[0]?.handedness).toBe("Right");
    expect(onResult).toHaveBeenCalledOnce();
  });

  it("skips frames whose currentTime has not advanced (the guide's gate)", () => {
    const detect = vi.fn(() => rawOneHand());
    const processor = createLandmarkProcessor({ detector: { detectForVideo: detect } });

    processor.process({ currentTime: 0.1 }, 1000);
    const second = processor.process({ currentTime: 0.1 }, 1016);

    expect(second).toBeNull();
    expect(detect).toHaveBeenCalledOnce();
  });

  it("computes FPS from the wall-clock delta between processed frames", () => {
    const processor = createLandmarkProcessor({ detector: fakeDetector(rawOneHand()) });

    const first = processor.process({ currentTime: 0.1 }, 1000);
    const second = processor.process({ currentTime: 0.2 }, 1100); // 100ms later → 10 fps

    expect(first?.fps).toBe(0); // no prior frame to measure against
    expect(second?.fps).toBeCloseTo(10, 6);
  });

  it("catches a detector error so the loop never crashes the host", () => {
    const onError = vi.fn();
    const processor = createLandmarkProcessor({
      detector: {
        detectForVideo: () => {
          throw new Error("WebGL context lost");
        },
      },
      onError,
    });

    expect(() => processor.process({ currentTime: 0.1 }, 1000)).not.toThrow();
    expect(processor.process({ currentTime: 0.2 }, 1016)).toBeNull();
    expect(onError).toHaveBeenCalledTimes(2);
  });

  it("catches a parse error from a malformed raw result", () => {
    const onError = vi.fn();
    const malformed = { landmarks: [[{ x: 0, y: 0, z: 0 }]] } as RawHandLandmarkerResult; // 1 != 21
    const processor = createLandmarkProcessor({ detector: fakeDetector(malformed), onError });

    expect(processor.process({ currentTime: 0.1 }, 1000)).toBeNull();
    expect(onError).toHaveBeenCalledOnce();
  });
});
