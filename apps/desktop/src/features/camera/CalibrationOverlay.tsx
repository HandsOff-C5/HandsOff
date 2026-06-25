import {
  fitMultiMonitor,
  type CalibrationTarget,
  type MultiCalibrationPair,
  type MultiMonitorCalibration,
  type Point,
} from "@handsoff/gesture";
import { useEffect, useMemo, useState } from "react";

// Multi-monitor calibration UI. Walks the user through a grid of targets laid across EVERY
// connected display; each target is drawn as a ring on the real desktop by the gesture-
// overlay sidecar (`onShowTarget`), NOT inside the camera panel — the user looks at the
// screen, points, and presses Capture. We collect the raw pointing signal per target, fit one
// affine per display, and hand the multi-monitor calibration back. Pure collection: the raw
// signal is injected (`sampleRaw`) so this stays testable without a camera.

interface CalibrationOverlayProps {
  // Per-display grid (global-px targets), from `multiMonitorTargets`.
  targets: CalibrationTarget[];
  // Read the current raw pointing signal, or null if no hand is pointing right now.
  sampleRaw: () => Point | null;
  // Drive the overlay: show the next target's ring, or null to clear it (on finish/cancel).
  onShowTarget: (target: CalibrationTarget | null) => void;
  // Called with the fitted multi-monitor calibration once every target is captured.
  onComplete: (result: MultiMonitorCalibration) => void;
  onCancel?: () => void;
}

export function CalibrationOverlay({
  targets,
  sampleRaw,
  onShowTarget,
  onComplete,
  onCancel,
}: CalibrationOverlayProps) {
  const pairs = useMemo(() => [] as MultiCalibrationPair[], []);
  const [index, setIndex] = useState(0);
  const total = targets.length;
  const current: CalibrationTarget | null = index < total ? (targets[index] ?? null) : null;

  // Keep the overlay's target ring in sync with whichever target we're capturing, and clear it
  // when the run finishes (or the component goes away).
  useEffect(() => {
    onShowTarget(current);
    return () => onShowTarget(null);
  }, [current, onShowTarget]);

  const capture = () => {
    const target = targets[index];
    if (!target) return;
    const raw = sampleRaw();
    if (!raw) return;
    pairs.push({ raw, displayId: target.displayId, target: target.target });
    const next = index + 1;
    setIndex(next);
    if (next >= total) {
      onComplete(fitMultiMonitor(pairs));
    }
  };

  return (
    <div className="calibration-overlay">
      <p className="calibration-overlay__progress">
        Point at the ring on screen
        {current ? ` · display ${current.displayId}` : ""} · {index} / {total}
      </p>
      <div className="calibration-overlay__actions">
        <button type="button" className="calibration-overlay__capture" onClick={capture}>
          Capture
        </button>
        {onCancel && (
          <button type="button" className="calibration-overlay__cancel" onClick={onCancel}>
            Cancel
          </button>
        )}
      </div>
    </div>
  );
}
