// A5 — confidence glow. Maps the referent confidence [0,1] to the cursor's glow so the
// user SEES certainty: a dim, tight dot when the aim is unsure, a bright, wide halo when
// it's confident. Pure presentational math (STRICT). Deliberately a soft halo, not a
// dwell ring or eclipse cursor — those interaction patterns are patented (Tobii / Magic
// Leap), so the novelty here is a continuous confidence-mapped glow.

export interface CursorGlow {
  // Dot + halo alpha, 0.35 (unsure) → 1 (confident).
  opacity: number;
  // Halo blur radius in px, 4 (unsure) → 16 (confident).
  blurPx: number;
}

const UNSURE = { opacity: 0.35, blurPx: 4 };
const CONFIDENT = { opacity: 1, blurPx: 16 };

const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;

export const glowFromConfidence = (confidence: number): CursorGlow => {
  // Clamp to [0,1]; a non-finite confidence (NaN from upstream math) reads as unsure.
  const c = Number.isFinite(confidence) ? confidence : 0;
  const t = Math.min(1, Math.max(0, c));
  return {
    opacity: lerp(UNSURE.opacity, CONFIDENT.opacity, t),
    blurPx: lerp(UNSURE.blurPx, CONFIDENT.blurPx, t),
  };
};
