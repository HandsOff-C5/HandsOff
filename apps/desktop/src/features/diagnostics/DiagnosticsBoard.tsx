import type { PointingEvidence } from "@handsoff/contracts";
import type { ReactNode } from "react";

type DiagnosticsBoardProps = {
  // The current frame's pointing evidence from every channel.
  evidence: readonly PointingEvidence[];
  // Optional input-monitor slot per channel (camera canvas / voice waveform).
  renderMonitor?: (channelId: string) => ReactNode;
};

export function DiagnosticsBoard(_props: DiagnosticsBoardProps) {
  void _props.evidence;
  throw new Error("not implemented");
}
