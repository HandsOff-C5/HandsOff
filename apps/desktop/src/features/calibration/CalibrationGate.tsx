import type { Point } from "@handsoff/gesture";

import type { CalibrationView } from "./calibration-flow";

type CalibrationGateProps = {
  view: CalibrationView;
  // The live signal for the current phase (fingertip on hand, gaze point on eyes),
  // normalized [0,1] overlay space, or null when there's no fix this frame.
  cursor: Point | null;
  // Esc / "skip" / the button — bail out of calibration straight to the HUD.
  onSkip: () => void;
};

const PHASE_LABEL: Record<CalibrationView["phase"], string> = {
  hand: "Hand 👆",
  gaze: "Eyes 👁",
};

const PHASE_VERB: Record<CalibrationView["phase"], string> = {
  hand: "Point at the glowing dot and hold",
  gaze: "Look at the glowing dot and hold",
};

const pct = (v: number): string => `${Math.min(100, Math.max(0, v * 100))}%`;

// The fullscreen calibration onboarding shown over the real desktop before the
// supervisor HUD goes live. A 3×3 grid of dots: the glowing one fills as you
// dwell on it (hands-off), captured dots dim, and the live cursor shows where the
// sensor currently thinks you're pointing/looking. Two phases (hand, then eyes).
export function CalibrationGate({ view, cursor, onSkip }: CalibrationGateProps) {
  return (
    <div className="calib" role="dialog" aria-label="Calibration">
      <header className="calib__head">
        <span className="calib__step">
          Calibration · step {view.step} of {view.totalSteps}
        </span>
        <span className="calib__phase">{PHASE_LABEL[view.phase]}</span>
      </header>

      <div className="calib__field">
        {view.targets.map((target, index) => {
          const active = index === view.currentIndex;
          const captured = index < view.currentIndex;
          return (
            <div
              key={`${target[0]}-${target[1]}-${index}`}
              data-testid="calib-dot"
              data-active={active ? "true" : "false"}
              data-captured={captured ? "true" : "false"}
              data-progress={active ? view.dwellProgress : undefined}
              className={`calib__dot${active ? " calib__dot--active" : ""}${
                captured ? " calib__dot--captured" : ""
              }`}
              style={{ left: pct(target[0]), top: pct(target[1]) }}
            >
              {active && (
                <span
                  className="calib__fill"
                  style={{ transform: `scale(${Math.min(1, Math.max(0, view.dwellProgress))})` }}
                  aria-hidden="true"
                />
              )}
            </div>
          );
        })}

        {cursor && (
          <div
            data-testid="calib-cursor"
            className={`calib__cursor calib__cursor--${view.phase}`}
            style={{ left: pct(cursor[0]), top: pct(cursor[1]) }}
            aria-hidden="true"
          />
        )}
      </div>

      <footer className="calib__foot">
        <p className="calib__hint">
          {PHASE_VERB[view.phase]}…{" "}
          <span className="calib__count">
            {view.currentIndex} / {view.targets.length}
          </span>
        </p>
        <button type="button" className="calib__skip" onClick={() => onSkip()}>
          Skip calibration
        </button>
      </footer>
    </div>
  );
}
