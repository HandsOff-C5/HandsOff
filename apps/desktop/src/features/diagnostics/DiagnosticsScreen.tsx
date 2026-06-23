import type { PointingEvidence } from "@handsoff/contracts";
import type { ReactNode } from "react";

import type { GetStream } from "./useSharedWebcam";

type DiagnosticsScreenProps = {
  // The current frame's pointing evidence (wired to the live loops on the Mac).
  evidence: readonly PointingEvidence[];
  // Injected webcam acquisition (defaults to navigator.mediaDevices in useSharedWebcam).
  getStream?: GetStream;
  mirrored?: boolean;
  // The model overlay to draw on each channel's camera view: hand → LandmarkOverlay,
  // gaze → Naama's gaze overlay. Injected at the call site where the live frames live.
  overlayForChannel?: (channelId: string) => ReactNode;
};

export function DiagnosticsScreen(_props: DiagnosticsScreenProps) {
  void _props.evidence;
  throw new Error("not implemented");
}
