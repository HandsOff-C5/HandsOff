import type { PointingEvidence } from "@handsoff/contracts";

// A diagnostic channel = one model's evidence source. Solo/mute let the operator
// isolate a channel: solo = drive fusion from ONLY these (mute everything else);
// mute = drop these from fusion. Soloing always wins over muting. Feed the result
// into fuseEvidence to see a channel's contribution alone, or with one removed.
export type ChannelId = PointingEvidence["source"];

export type ChannelControls = {
  solo: readonly ChannelId[];
  mute: readonly ChannelId[];
};

export const NO_CHANNEL_CONTROLS: ChannelControls = { solo: [], mute: [] };

export function applyChannelControls(
  evidence: readonly PointingEvidence[],
  controls: ChannelControls,
): PointingEvidence[] {
  // Solo takes precedence: when any channel is soloed, keep only those.
  if (controls.solo.length > 0) {
    const soloed = new Set<ChannelId>(controls.solo);
    return evidence.filter((e) => soloed.has(e.source));
  }
  const muted = new Set<ChannelId>(controls.mute);
  return evidence.filter((e) => !muted.has(e.source));
}
