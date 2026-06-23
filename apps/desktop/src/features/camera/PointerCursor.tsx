import type { Point } from "@handsoff/gesture";

import { glowFromConfidence } from "./cursor-glow";

// A1.3 + A5 — the visible pointer cursor. Renders the 1€-smoothed pointing position (from
// the referent loop) as a dot on the camera stage so the steadiness is visible, and maps
// the referent confidence to a glow so certainty is visible too. Presentational only:
// `point` is in the calibration's coordinate space, normalized here against `bounds`.

interface PointerCursorProps {
  // Smoothed screen-space pointing position, or null when there's no hand to show.
  point: Point | null;
  // The coordinate space `point` lives in (DEMO_SCREEN_BOUNDS when calibrated, unit box when not).
  bounds: { x: number; y: number; w: number; h: number };
  // Mirror the x position to match the selfie-view video flip.
  mirrored: boolean;
  // Referent confidence [0,1] this frame — drives the glow (dim/tight → bright/wide).
  confidence: number;
}

export function PointerCursor({ point, bounds, mirrored, confidence }: PointerCursorProps) {
  if (!point) return null;
  const nx = (point[0] - bounds.x) / bounds.w;
  const ny = (point[1] - bounds.y) / bounds.h;
  const cx = mirrored ? 1 - nx : nx;
  const glow = glowFromConfidence(confidence);
  return (
    <div
      data-testid="pointer-cursor"
      className="camera-panel__cursor"
      style={{
        left: `${cx * 100}%`,
        top: `${ny * 100}%`,
        opacity: glow.opacity,
        boxShadow: `0 0 ${glow.blurPx}px ${glow.blurPx * 0.4}px rgba(56, 189, 248, 0.6)`,
      }}
    />
  );
}
