import type { PointingEvidence } from "@handsoff/contracts";

import type { ChannelSample } from "./ChannelStrip";

// Human label per evidence source for the mixing-board strips.
const CHANNEL_LABEL: Record<PointingEvidence["source"], string> = {
  gesture: "Hand",
  gaze: "Gaze",
  head: "Head",
  face: "Face",
  cursor: "Cursor",
  active_window: "Active window",
  fusion: "Fusion",
};

// Reduce the per-frame pointing evidence to one ChannelSample per source — the
// strip readouts. Each channel's confidence is its strongest vote this frame and
// its verdict the surface it resolved; sorted strongest-first.
export function toChannelSamples(_evidence: readonly PointingEvidence[]): ChannelSample[] {
  void _evidence.length;
  throw new Error("not implemented");
}

export { CHANNEL_LABEL };
