import { glowFromConfidence } from "../camera/cursor-glow";

// The signal the main window streams to the transparent screen-overlay window (#25):
// where the fused pointer is on screen, how confident, what it's locked on, and the
// voice engagement state. Both windows load the same bundle, so this contract is the
// seam between the dashboard (emit) and the overlay (listen).

// Pointer geometry + lock, emitted by the camera/referent loop.
export const OVERLAY_POINTER_EVENT = "overlay://pointer";
// Voice engagement state, emitted by the voice controller.
export const OVERLAY_VOICE_EVENT = "overlay://voice";
// Per-frame pointing evidence (hand + gaze + cursor), fused in the overlay into
// the FusionHud's meters + drag. Carries the raw votes so the HUD's fusion stays
// the single fuseEvidence call site.
export const OVERLAY_FUSION_EVENT = "overlay://fusion";

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

// Camera-stage point → normalized overlay [0,1], matching the in-app PointerCursor math
// (normalize against the calibration bounds, then mirror x for the un-calibrated selfie
// signal). STRICT — the overlay dot must track the same way the camera-preview dot does.
export function normalizeOverlayPoint(
  point: readonly [number, number],
  bounds: { x: number; y: number; w: number; h: number },
  mirrored: boolean,
): [number, number] {
  const nx = (point[0] - bounds.x) / bounds.w;
  const ny = (point[1] - bounds.y) / bounds.h;
  return [mirrored ? 1 - nx : nx, ny];
}

// The voice engagement state shown on the overlay, derived from the capture + intent
// lifecycle (STRICT). acting (a plan is running) wins over listening (mic open) wins
// over heard (an intent is resolved) wins over idle.
export function deriveVoiceState(args: {
  captureStatus: "idle" | "capturing" | "finalizing" | "error";
  hasIntent: boolean;
  running: boolean;
}): OverlayVoiceState {
  if (args.running) return "acting";
  if (args.captureStatus === "capturing" || args.captureStatus === "finalizing") return "listening";
  if (args.hasIntent) return "heard";
  return "idle";
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
