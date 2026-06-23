// Confidence calibration (#100). Pure temperature scaling of a probability so
// downstream thresholds (dwell #28, glow, fusion reliability) act on calibrated
// scores instead of overconfident raw MediaPipe ones. Deterministic in (raw, T).
// See docs/research/gesture/smoothing-dwell-debounce.md.

function clamp01(p: number): number {
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  return p;
}

// Temperature-scale a confidence: p' = sigmoid(logit(p) / T).
// T=1 passthrough; T>1 softens toward 0.5 (tames overconfidence); T<1 sharpens.
// 0.5 is a fixed point; raw is clamped to [0,1]; the ±Infinity logits at the
// endpoints map back to 0/1 through the sigmoid with no NaN.
export function calibrateConfidence(raw: number, temperature: number): number {
  if (!(temperature > 0)) {
    throw new Error(`temperature must be > 0, got ${temperature}`);
  }
  const p = clamp01(raw);
  const logit = Math.log(p / (1 - p));
  return 1 / (1 + Math.exp(-logit / temperature));
}
