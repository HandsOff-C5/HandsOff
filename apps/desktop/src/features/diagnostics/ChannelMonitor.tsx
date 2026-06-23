import type { ReactNode } from "react";

// One model's input monitor: a webcam preview with that model's overlay drawn on
// top (hand landmarks, gaze ray, …). Several monitors share ONE injected stream
// (the two-canvas-one-feed layout) so hand-cam and eye-cam show the same input
// interpreted differently. Presentational; the overlay is passed as children.
type ChannelMonitorProps = {
  stream?: MediaStream | null;
  mirrored?: boolean;
  label?: string;
  children?: ReactNode;
};

export function ChannelMonitor(_props: ChannelMonitorProps) {
  void _props.label;
  throw new Error("not implemented");
}
