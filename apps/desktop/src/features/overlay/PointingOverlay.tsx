import { useEffect, useState } from "react";

import { FusionHud } from "./FusionHud";
import { useFusionSignal, type FusionListen } from "./useFusionSignal";
import {
  IDLE_OVERLAY_SIGNAL,
  overlayMarkerStyle,
  VOICE_STATE_LABEL,
  type OverlayPointerUpdate,
  type OverlaySignal,
  type OverlayVoiceState,
} from "./overlay-signal";

// Subscribes the overlay to the main window's streams: pointer updates (geometry +
// confidence + lock) and voice-state changes. Injected so the window wiring uses Tauri
// `listen` while tests push synchronously. Returns an unsubscribe.
export type OverlayListen = (
  onPointer: (update: OverlayPointerUpdate) => void,
  onVoice: (voiceState: OverlayVoiceState) => void,
) => () => void;

export function useOverlaySignal(listen?: OverlayListen): OverlaySignal {
  const [signal, setSignal] = useState<OverlaySignal>(IDLE_OVERLAY_SIGNAL);
  useEffect(() => {
    if (!listen) return;
    return listen(
      (update) => setSignal((prev) => ({ ...prev, ...update })),
      (voiceState) => setSignal((prev) => ({ ...prev, voiceState })),
    );
  }, [listen]);
  return signal;
}

interface PointingOverlayProps {
  // Presentational override (tests). When omitted, the live signal from `listen` is used.
  signal?: OverlaySignal;
  // Live subscription (the overlay window passes the Tauri-backed listener).
  listen?: OverlayListen;
  // Per-frame fused evidence subscription (the overlay window passes the Tauri-backed
  // listener). Drives the on-screen FusionHud so every model's live confidence + vote +
  // the disagreement "drag" is visible on the real desktop, not just in the dashboard.
  fusionListen?: FusionListen;
}

// Full-screen pointing overlay (#25 cursor seam) — the layer that draws where you point
// on the REAL desktop, in its own transparent, click-through, always-on-top window. It
// shows the fused pointer (dot + confidence glow), the locked target, and the voice
// engagement state, so the operator sees all three signals without the dashboard.
export function PointingOverlay({
  signal: signalProp,
  listen,
  fusionListen,
}: PointingOverlayProps) {
  const live = useOverlaySignal(listen);
  const signal = signalProp ?? live;
  const fusion = useFusionSignal(fusionListen);

  // The shared bundle's body is opaque dark (dashboard theme); the overlay window must
  // be see-through, so clear the background while this layer is mounted.
  useEffect(() => {
    const { body, documentElement } = document;
    const prev = { body: body.style.background, html: documentElement.style.background };
    body.style.background = "transparent";
    documentElement.style.background = "transparent";
    return () => {
      body.style.background = prev.body;
      documentElement.style.background = prev.html;
    };
  }, []);

  return (
    <div className="pointing-overlay" aria-hidden="true">
      {signal.point && (
        <div
          data-testid="overlay-marker"
          className="pointing-overlay__marker"
          style={overlayMarkerStyle(signal.point, signal.confidence)}
        />
      )}
      {signal.targetLabel && (
        <p className="pointing-overlay__target" style={markerLabelStyle(signal.point)}>
          {signal.targetLabel}
        </p>
      )}
      <p
        className={`pointing-overlay__voice pointing-overlay__voice--${signal.voiceState}`}
        data-voice-state={signal.voiceState}
      >
        {VOICE_STATE_LABEL[signal.voiceState]}
      </p>
      {/* Live per-model accuracy on the real screen: each tracker's confidence +
          vote + the disagreement drag, fused every frame. */}
      <div className="pointing-overlay__hud">
        <FusionHud fusion={fusion} />
      </div>
    </div>
  );
}

// Pin the target label just under the marker when there's a point; otherwise hide it.
function markerLabelStyle(
  point: OverlaySignal["point"],
): { left: string; top: string } | undefined {
  if (!point) return undefined;
  const clamp = (v: number): number => Math.min(1, Math.max(0, v));
  return { left: `${clamp(point[0]) * 100}%`, top: `${clamp(point[1]) * 100}%` };
}
