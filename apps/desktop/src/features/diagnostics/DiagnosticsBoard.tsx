import type { PointingEvidence } from "@handsoff/contracts";
import {
  applyChannelControls,
  fuseEvidence,
  NO_CHANNEL_CONTROLS,
  type ChannelControls,
  type ChannelId,
} from "@handsoff/intent";
import { useState, type ReactNode } from "react";

import { FusionHud } from "../overlay/FusionHud";
import { ChannelStrip } from "./ChannelStrip";
import { toChannelSamples } from "./channel-samples";

type DiagnosticsBoardProps = {
  // The current frame's pointing evidence from every channel.
  evidence: readonly PointingEvidence[];
  // Optional input-monitor slot per channel (camera canvas / voice waveform).
  renderMonitor?: (channelId: string) => ReactNode;
};

function toggle(list: readonly ChannelId[], id: ChannelId): ChannelId[] {
  return list.includes(id) ? list.filter((entry) => entry !== id) : [...list, id];
}

// The mixing board: a ChannelStrip per model (with solo/mute) above the FusionHud
// master bus. Solo/mute filter the evidence through applyChannelControls before
// fusion, so toggling a channel re-fuses the master LIVE — mute the noisy channel
// and watch the drag clear, or solo one to see its contribution alone.
export function DiagnosticsBoard({ evidence, renderMonitor }: DiagnosticsBoardProps) {
  const [controls, setControls] = useState<ChannelControls>(NO_CHANNEL_CONTROLS);

  const samples = toChannelSamples(evidence);
  const fusion = fuseEvidence(applyChannelControls(evidence, controls));

  return (
    <section className="diagnostics-board" aria-label="Diagnostics board">
      <div className="diagnostics-board__channels">
        {samples.map((sample) => {
          const id = sample.id as ChannelId;
          return (
            <ChannelStrip
              key={sample.id}
              sample={sample}
              soloed={controls.solo.includes(id)}
              muted={controls.mute.includes(id)}
              onSolo={() => setControls((c) => ({ ...c, solo: toggle(c.solo, id) }))}
              onMute={() => setControls((c) => ({ ...c, mute: toggle(c.mute, id) }))}
            >
              {renderMonitor?.(sample.id)}
            </ChannelStrip>
          );
        })}
      </div>
      <FusionHud fusion={fusion} />
    </section>
  );
}
