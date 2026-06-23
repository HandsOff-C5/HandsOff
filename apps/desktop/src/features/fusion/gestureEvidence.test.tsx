import type { PointingCandidate, SurfaceSnapshot } from "@handsoff/contracts";
import { pointingEvidenceSchema } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { toGestureEvidence } from "./gestureEvidence";

const surface: SurfaceSnapshot = {
  id: "win-1",
  title: "GitHub #88",
  app: "Chrome",
  availability: "available",
  accessStatus: "accessible",
};
const candidate: PointingCandidate = { targetId: "win-1", confidence: 0.8, calibrationQuality: "good" };

describe("toGestureEvidence", () => {
  it("maps a pointing candidate + surface to gesture PointingEvidence", () => {
    const e = toGestureEvidence(candidate, surface);
    expect(e.source).toBe("gesture");
    expect(e.surface).toEqual(surface);
    expect(pointingEvidenceSchema.safeParse(e).success).toBe(true);
  });

  it("passes raw confidence through when no temperature is given", () => {
    expect(toGestureEvidence(candidate, surface).confidence).toBe(0.8);
  });

  it("applies temperature calibration to the confidence (#100)", () => {
    const e = toGestureEvidence(candidate, surface, 2);
    expect(e.confidence).toBeLessThan(0.8);
    expect(e.confidence).toBeGreaterThan(0.5);
  });

  it("records the calibration quality in the strategy", () => {
    expect(toGestureEvidence(candidate, surface).strategy).toContain("good");
  });
});
