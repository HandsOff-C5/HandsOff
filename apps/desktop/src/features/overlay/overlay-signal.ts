import { glowFromConfidence } from "../camera/cursor-glow";

// The signal the main window streams to the transparent screen-overlay window (#25):
// where the fused pointer is on screen, how confident, what it's locked on, and the
// voice engagement state. Both windows load the same bundle, so this contract is the
// seam between the dashboard (emit) and the overlay (listen).

// Pointer geometry + lock, emitted by the camera/referent loop.
export const OVERLAY_POINTER_EVENT = "overlay://pointer";
// Voice engagement state, emitted by the voice controller.
export const OVERLAY_VOICE_EVENT = "overlay://voice";

// listening = mic open, heard = final utterance in, acting = plan executing.
export type OverlayVoiceState = "idle" | "listening" | "heard" | "acting";

export interface OverlayPointerUpdate {
  // Normalized overlay-space position [0,1] (x,y), or null when no hand is shown.
  point: [number, number] | null;
  // Referent confidence [0,1] this frame — drives the glow.
  confidence: number;
  // The locked target's label, or null when nothing is locked.
  targetLabel: string | null;
}

export interface OverlaySignal extends OverlayPointerUpdate {
  voiceState: OverlayVoiceState;
}

export const IDLE_OVERLAY_SIGNAL: OverlaySignal = {
  point: null,
  confidence: 0,
  targetLabel: null,
  voiceState: "idle",
};

// User-facing label for each voice state (shown as the overlay's "listening/heard/
// acting" indicator so the operator sees the system's attention without the dashboard).
export const VOICE_STATE_LABEL: Record<OverlayVoiceState, string> = {
  idle: "Ready",
  listening: "Listening…",
  heard: "Heard you",
  acting: "Acting…",
};

export interface OverlayMarkerStyle {
  left: string;
  top: string;
  opacity: number;
  boxShadow: string;
}

// Presentational math (STRICT): normalized point + confidence → the marker's CSS. The
// glow reuses the camera cursor's confidence→halo mapping so the on-screen dot reads
// the same as the in-app one. Clamps the point into the visible [0,1] box.
export function overlayMarkerStyle(
  point: [number, number],
  confidence: number,
): OverlayMarkerStyle {
  const clamp = (v: number): number => Math.min(1, Math.max(0, Number.isFinite(v) ? v : 0));
  const glow = glowFromConfidence(confidence);
  return {
    left: `${clamp(point[0]) * 100}%`,
    top: `${clamp(point[1]) * 100}%`,
    opacity: glow.opacity,
    boxShadow: `0 0 ${glow.blurPx}px ${glow.blurPx * 0.4}px rgba(56, 189, 248, 0.6)`,
  };
}
