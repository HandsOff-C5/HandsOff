import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { applyChannelControls, NO_CHANNEL_CONTROLS } from "./channel-controls";

const cursor: SurfaceSnapshot = {
  id: "win:cursor",
  app: "Cursor",
  title: "editor",
  availability: "available",
  accessStatus: "accessible",
};
const v = (source: PointingEvidence["source"], confidence: number): PointingEvidence => ({
  source,
  confidence,
  strategy: source,
  surface: cursor,
});

const hand = v("gesture", 0.9);
const gaze = v("gaze", 0.5);
const cur = v("cursor", 0.3);
const all = [hand, gaze, cur];

describe("applyChannelControls", () => {
  it("passes all evidence through when nothing is soloed or muted", () => {
    expect(applyChannelControls(all, NO_CHANNEL_CONTROLS)).toEqual(all);
  });

  it("drops a muted channel and keeps the rest", () => {
    expect(applyChannelControls(all, { solo: [], mute: ["gaze"] })).toEqual([hand, cur]);
  });

  it("keeps only soloed channels (everything else is dropped)", () => {
    expect(applyChannelControls(all, { solo: ["gesture"], mute: [] })).toEqual([hand]);
  });

  it("soloing wins over muting the same channel", () => {
    expect(applyChannelControls(all, { solo: ["gesture"], mute: ["gesture"] })).toEqual([hand]);
  });

  it("supports soloing several channels at once", () => {
    expect(applyChannelControls(all, { solo: ["gesture", "cursor"], mute: [] })).toEqual([
      hand,
      cur,
    ]);
  });

  it("muting every present channel yields nothing", () => {
    expect(applyChannelControls(all, { solo: [], mute: ["gesture", "gaze", "cursor"] })).toEqual(
      [],
    );
  });
});
