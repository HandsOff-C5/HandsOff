import type { ReactNode } from "react";

// One model's live readout for the mixing-board view: its status, confidence, and
// current verdict, plus solo/mute and a slot for the input monitor (camera canvas
// or voice waveform). Presentational — state lives in the diagnostics controller.
export type ChannelStatus = "live" | "idle" | "no_signal" | "error";

export type ChannelSample = {
  id: string;
  label: string;
  status: ChannelStatus;
  confidence: number;
  detail?: string;
  fps?: number;
};

type ChannelStripProps = {
  sample: ChannelSample;
  soloed?: boolean;
  muted?: boolean;
  onSolo?: () => void;
  onMute?: () => void;
  children?: ReactNode;
};

export function ChannelStrip(_props: ChannelStripProps) {
  void _props.sample;
  throw new Error("not implemented");
}
