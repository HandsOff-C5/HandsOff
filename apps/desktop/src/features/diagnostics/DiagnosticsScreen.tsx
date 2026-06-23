import type { PointingEvidence } from "@handsoff/contracts";
import type { ReactNode } from "react";

import { ChannelMonitor } from "./ChannelMonitor";
import { DiagnosticsBoard } from "./DiagnosticsBoard";
import { useSharedWebcam, type GetStream } from "./useSharedWebcam";

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

// The dedicated diagnostics screen: one shared webcam feeding a camera monitor per
// channel (with that model's overlay), the per-model strips with solo/mute, and the
// fusion master bus — so every model is visible separately AND together. Start the
// camera explicitly (privacy); the live evidence + per-channel overlays are injected
// by the host where the loops/frames live.
export function DiagnosticsScreen({
  evidence,
  getStream,
  mirrored = true,
  overlayForChannel,
}: DiagnosticsScreenProps) {
  const camera = useSharedWebcam(getStream);
  const isLive = camera.status === "live";

  return (
    <section className="diagnostics-screen" aria-label="Diagnostics">
      <header className="diagnostics-screen__head">
        <h1 className="diagnostics-screen__title">Diagnostics</h1>
        <button type="button" onClick={isLive ? camera.stop : camera.start}>
          {isLive ? "Stop camera" : "Start camera"}
        </button>
        {camera.status === "error" && camera.error && (
          <p role="alert" className="diagnostics-screen__error">
            {camera.error}
          </p>
        )}
      </header>

      <DiagnosticsBoard
        evidence={evidence}
        renderMonitor={(channelId) => (
          <ChannelMonitor stream={camera.stream} mirrored={mirrored}>
            {overlayForChannel?.(channelId)}
          </ChannelMonitor>
        )}
      />
    </section>
  );
}
