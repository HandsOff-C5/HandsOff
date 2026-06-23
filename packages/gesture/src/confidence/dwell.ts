// Dwell + debounce guard (#28) — defeats the "Midas touch" problem: a referent
// must stay above threshold continuously for `dwellMs` before it fires, with
// hysteresis (enter > exit) to stop boundary flicker and a cooldown to block
// double-fire. Pure: dt is passed in (ms), no clock read.
// See docs/research/gesture/smoothing-dwell-debounce.md.

export interface DwellDebounceParams {
  // Confidence must reach `enter` to engage the dwell...
  enter: number;
  // ...and stay above `exit` (lower) to remain engaged. enter > exit.
  exit: number;
  // Continuous engaged time required before firing.
  dwellMs: number;
  // Refractory window after a fire during which it cannot fire again.
  cooldownMs: number;
}

export interface DwellResult {
  // Currently engaged (above the hysteresis band) — surface for the
  // clarification / manual-fallback UI when confidence is low (not engaged).
  active: boolean;
  // True on the single update where the dwell completes; false otherwise.
  fired: boolean;
}

export interface DwellDebounce {
  update(confidence: number, dtMs: number): DwellResult;
}

export function createDwellDebounce(params: DwellDebounceParams): DwellDebounce {
  const { enter, exit, dwellMs, cooldownMs } = params;

  let engaged = false;
  let dwell = 0;
  let cooldown = 0;
  let firedThisEngagement = false;

  return {
    update(confidence: number, dtMs: number): DwellResult {
      if (cooldown > 0) cooldown = Math.max(0, cooldown - dtMs);

      // Hysteresis: enter the band at `enter`, leave only below `exit`.
      if (!engaged && confidence >= enter) {
        engaged = true;
        dwell = 0;
        firedThisEngagement = false;
      } else if (engaged && confidence < exit) {
        engaged = false;
        dwell = 0;
        firedThisEngagement = false;
      }

      let fired = false;
      if (engaged) {
        dwell += dtMs;
        if (dwell >= dwellMs && !firedThisEngagement && cooldown === 0) {
          fired = true;
          firedThisEngagement = true;
          cooldown = cooldownMs;
        }
      }

      return { active: engaged, fired };
    },
  };
}
