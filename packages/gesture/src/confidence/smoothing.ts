// Confidence/pointer smoothing primitives (#28). All pure: time is passed in as
// millisecond timestamps, never read from a clock, so they're deterministic and
// fixture-testable. See docs/research/gesture/smoothing-dwell-debounce.md.

// Exponential moving average — one smoothing step. alpha=1 passthrough (no
// smoothing), alpha→0 frozen (holds previous). It's the inner recurrence of 1€.
export function ema(x: number, prev: number, alpha: number): number {
  return alpha * x + (1 - alpha) * prev;
}

// Smoothing factor for a low-pass cutoff: alpha = 1/(1 + tau/Te), tau = 1/(2π·fc).
// Higher cutoff → larger alpha → tracks faster. fc in Hz, sample period in seconds.
export function alphaFromCutoff(cutoffHz: number, sampleSeconds: number): number {
  const tau = 1 / (2 * Math.PI * cutoffHz);
  return 1 / (1 + tau / sampleSeconds);
}

export interface OneEuroParams {
  // Baseline cutoff at low speed; lower → less jitter, more lag. Default 1.0.
  minCutoff?: number;
  // Speed coefficient; higher → less lag on fast motion, more jitter. Default 0.0.
  beta?: number;
  // Cutoff for the derivative's own low-pass. Default 1.0.
  dCutoff?: number;
}

export interface OneEuroFilter {
  // Filter sample `x` captured at `tMs` (ms). Returns the smoothed value.
  filter(x: number, tMs: number): number;
}

// 1€ filter: adaptive low-pass — low cutoff when still (kills jitter), high cutoff
// when moving fast (kills lag). State lives in the closure; deterministic in (x, t).
export function createOneEuroFilter(params: OneEuroParams = {}): OneEuroFilter {
  const minCutoff = params.minCutoff ?? 1;
  const beta = params.beta ?? 0;
  const dCutoff = params.dCutoff ?? 1;

  let xHat = 0;
  let dxHat = 0;
  let tPrevMs: number | null = null;
  let initialized = false;

  return {
    filter(x: number, tMs: number): number {
      if (!initialized || tPrevMs === null) {
        initialized = true;
        tPrevMs = tMs;
        xHat = x;
        dxHat = 0;
        return x;
      }

      const te = (tMs - tPrevMs) / 1000;
      tPrevMs = tMs;
      // A non-advancing (or backwards) timestamp can't smooth meaningfully — hold.
      if (te <= 0) return xHat;

      // Low-pass the derivative, then set the adaptive cutoff from its magnitude.
      const dx = (x - xHat) / te;
      dxHat = ema(dx, dxHat, alphaFromCutoff(dCutoff, te));
      const cutoff = minCutoff + beta * Math.abs(dxHat);

      xHat = ema(x, xHat, alphaFromCutoff(cutoff, te));
      return xHat;
    },
  };
}
