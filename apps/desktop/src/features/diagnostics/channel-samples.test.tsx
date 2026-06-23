import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { toChannelSamples } from "./channel-samples";

const cursor: SurfaceSnapshot = {
  id: "win:cursor",
  app: "Cursor",
  title: "editor",
  availability: "available",
  accessStatus: "accessible",
};
const slack: SurfaceSnapshot = {
  id: "win:slack",
  app: "Slack",
  title: "general",
  availability: "available",
  accessStatus: "accessible",
};
const v = (
  source: PointingEvidence["source"],
  confidence: number,
  surface?: SurfaceSnapshot,
): PointingEvidence => ({ source, confidence, strategy: source, ...(surface ? { surface } : {}) });

describe("toChannelSamples", () => {
  it("maps a source to a live channel with its label, confidence, and verdict", () => {
    const [sample] = toChannelSamples([v("gesture", 0.9, cursor)]);
    expect(sample).toMatchObject({ id: "gesture", label: "Hand", status: "live", confidence: 0.9 });
    expect(sample?.detail).toContain("Cursor");
  });

  it("uses the strongest vote per source as that channel's confidence", () => {
    const [sample] = toChannelSamples([v("gaze", 0.4, slack), v("gaze", 0.7, cursor)]);
    expect(sample?.confidence).toBeCloseTo(0.7);
    expect(sample?.detail).toContain("Cursor");
  });

  it("returns one sample per source, sorted strongest channel first", () => {
    const samples = toChannelSamples([v("gaze", 0.5, slack), v("gesture", 0.9, cursor)]);
    expect(samples.map((s) => s.id)).toEqual(["gesture", "gaze"]);
  });

  it("a source with no resolved surface is still live but has no verdict", () => {
    const [sample] = toChannelSamples([v("head", 0.5)]);
    expect(sample?.status).toBe("live");
    expect(sample?.detail).toBeUndefined();
  });

  it("returns nothing for empty evidence", () => {
    expect(toChannelSamples([])).toEqual([]);
  });
});
