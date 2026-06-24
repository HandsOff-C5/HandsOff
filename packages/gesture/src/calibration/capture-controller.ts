// Per-dot capture timing for the eye-calibration pass. When a new dot lights up the eye
// needs a moment to land on it (settle), then we gather iris feature vectors for a window
// (collect) and take the MEDIAN so a single bad frame can't poison the sample. Frames
// below a confidence floor (blinks, look-aways) are dropped, so the window simply extends
// until enough good frames arrive. Pure (STRICT): the caller passes the clock + per-frame
// confidence/features; no timers, no camera here.

// Per-dimension median of a set of equal-length numeric vectors.
export const medianVector = (samples: ReadonlyArray<readonly number[]>): number[] => {
  if (samples.length === 0) throw new Error("medianVector: no samples");
  const dims = samples[0]!.length;
  const out: number[] = [];
  for (let d = 0; d < dims; d++) {
    const col = samples.map((s) => s[d] ?? 0).sort((a, b) => a - b);
    const mid = Math.floor(col.length / 2);
    out.push(col.length % 2 === 1 ? col[mid]! : (col[mid - 1]! + col[mid]!) / 2);
  }
  return out;
};

export interface CaptureConfig {
  // Time to let the eye land on a freshly shown dot before sampling.
  readonly settleMs: number;
  // Sampling window once settled.
  readonly collectMs: number;
  // Minimum confident frames required before a capture can fire.
  readonly minSamples: number;
  // Per-frame eye-tracking confidence floor for a frame to count.
  readonly minConfidence: number;
}

export type CapturePhase = "settle" | "collect";

export interface CaptureState {
  readonly phase: CapturePhase;
  // 0→1 progress through the collect window (0 while settling).
  readonly progress: number;
  // The median feature vector on the frame the capture completes; null otherwise.
  readonly captured: number[] | null;
}

export interface CaptureController {
  // Begin capturing a new dot at `nowMs`.
  reset(nowMs: number): void;
  // Advance one frame. `featureVector` is null when no face/iris this frame.
  tick(nowMs: number, confidence: number, featureVector: readonly number[] | null): CaptureState;
}

export const createCaptureController = (config: CaptureConfig): CaptureController => {
  const { settleMs, collectMs, minSamples, minConfidence } = config;
  let startMs = 0;
  let samples: number[][] = [];
  let fired = false;

  return {
    reset(nowMs) {
      startMs = nowMs;
      samples = [];
      fired = false;
    },
    tick(nowMs, confidence, featureVector) {
      const elapsed = nowMs - startMs;
      if (elapsed < settleMs) {
        return { phase: "settle", progress: 0, captured: null };
      }
      // Collecting.
      if (featureVector && confidence >= minConfidence) {
        samples.push([...featureVector]);
      }
      const collectElapsed = elapsed - settleMs;
      const timeProgress = Math.min(1, collectElapsed / collectMs);
      const enough = samples.length >= minSamples;
      // Hold progress just under 1 until both the window has passed AND enough good
      // frames exist — so a blinking operator sees the ring wait, not a false capture.
      const ready = timeProgress >= 1 && enough;
      const progress = ready ? 1 : Math.min(timeProgress, 0.99);

      if (ready && !fired) {
        fired = true;
        return { phase: "collect", progress: 1, captured: medianVector(samples) };
      }
      return { phase: "collect", progress, captured: null };
    },
  };
};
