import type { SurfaceBounds } from "@handsoff/contracts";
import {
  createCalibrationSession,
  gridTargets,
  type CalibrationResult,
  type Point,
} from "@handsoff/gesture";
import { useMemo, useState } from "react";

// #26 calibration UI — walks the user through a 3×3 grid of on-screen targets. For each,
// the user points and presses Capture; we read the current raw pointing signal and fit
// the affine once all 9 are in. `sampleRaw` is injected (the live loop's current pointing
// signal) so this is testable without a camera. The live aim/accuracy is Demo Verified.

interface CalibrationOverlayProps {
  // Screen bounds the grid is laid over (same space as the eventual candidate hit-test).
  bounds: SurfaceBounds;
  // Read the current raw pointing signal, or null if no hand is pointing right now.
  sampleRaw: () => Point | null;
  // Called with the fitted transform/quality once all targets are captured.
  onComplete: (result: CalibrationResult) => void;
  // Grid inset (0 = corner-to-corner). Default 0.1.
  margin?: number;
}

export function CalibrationOverlay({
  bounds,
  sampleRaw,
  onComplete,
  margin,
}: CalibrationOverlayProps) {
  const targets = useMemo(
    () => gridTargets(bounds, { cols: 3, rows: 3, margin }),
    [bounds, margin],
  );
  const session = useMemo(() => createCalibrationSession(targets), [targets]);
  const [progress, setProgress] = useState(session.current());

  const capture = () => {
    const raw = sampleRaw();
    if (!raw || progress.done) return;
    const next = session.capture(raw);
    setProgress(next);
    if (next.done) {
      const result = session.result();
      if (result) onComplete(result);
    }
  };

  // Position the target dot as a percentage of the bounds so it scales to the container.
  const target = progress.target;
  const left = target ? `${((target[0] - bounds.x) / bounds.w) * 100}%` : "50%";
  const top = target ? `${((target[1] - bounds.y) / bounds.h) * 100}%` : "50%";

  return (
    <div className="calibration-overlay">
      <p className="calibration-overlay__progress">
        Point at the dot and press Capture · {progress.index} / {progress.total}
      </p>
      {target && (
        <span
          data-testid="calibration-target"
          className="calibration-overlay__target"
          style={{ left, top }}
        />
      )}
      <button type="button" className="calibration-overlay__capture" onClick={capture}>
        Capture
      </button>
    </div>
  );
}
