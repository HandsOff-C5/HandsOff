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
export function toChannelSamples(evidence: readonly PointingEvidence[]): ChannelSample[] {
  // The strongest vote per source carries that channel's confidence + verdict.
  const strongest = new Map<PointingEvidence["source"], PointingEvidence>();
  for (const e of evidence) {
    const current = strongest.get(e.source);
    if (!current || e.confidence > current.confidence) strongest.set(e.source, e);
  }

  return [...strongest.values()]
    .sort((a, b) => b.confidence - a.confidence)
    .map((e) => ({
      id: e.source,
      label: CHANNEL_LABEL[e.source],
      status: "live" as const,
      confidence: e.confidence,
      ...(e.surface ? { detail: `→ ${e.surface.app}` } : {}),
    }));
}

export { CHANNEL_LABEL };
