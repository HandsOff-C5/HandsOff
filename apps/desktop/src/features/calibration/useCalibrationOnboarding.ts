import type { SurfaceBounds } from "@handsoff/contracts";
import type { CalibrationResult, Point } from "@handsoff/gesture";
import { useCallback, useEffect, useRef, useState } from "react";

import { emitOverlayCalibration, listenCalibrationControl } from "../overlay/tauri-overlay";
import { createCalibrationFlow, type CalibrationFlow } from "./calibration-flow";
import { createDwellTracker } from "./dwell";
import { tickCalibration } from "./tick";

// Tuned for a comfortable hands-off hold: stay within ~7% of the dot for a second.
const DWELL = { radius: 0.07, holdMs: 1000 };

export interface CalibrationOnboardingArgs {
  // Only run in the real app (the engine window); false in tests/browser.
  enabled: boolean;
  // Fit space for the hand phase — the camera calibration's screen bounds.
  handBounds: SurfaceBounds;
  // The live cursor the operator SEES per phase, normalized [0,1] (drives the dwell).
  getHandCursor: () => Point | null;
  getGazeCursor: () => Point | null;
  // The raw sample to FIT per phase (hand: the pre-calibration pointing signal).
  getHandRaw: () => Point | null;
  getGazeRaw: () => Point | null;
  // Apply the fitted result: hand → the camera pipeline, gaze → the gaze correction.
  onHandResult: (result: CalibrationResult) => void;
  onGazeResult: (result: CalibrationResult) => void;
  // Skip the onboarding when a usable calibration is already remembered.
  remembered: boolean;
}

export interface CalibrationOnboarding {
  calibrating: boolean;
  // Restart calibration on demand (e.g. a "redo" control / button).
  redo: () => void;
}

// Drives the startup touch-the-dots calibration in the engine window: an rAF loop
// dwells the live cursor on each dot, captures the raw sample, fits per phase
// (reusing the pure flow + tick), and streams the view to the overlay. Skips when a
// calibration is already remembered; honors the overlay's skip/redo control. The
// HUD shows once this finishes (the overlay swaps the gate for the HUD when the
// streamed view goes null).
export function useCalibrationOnboarding(args: CalibrationOnboardingArgs): CalibrationOnboarding {
  const [calibrating, setCalibrating] = useState(false);
  const flowRef = useRef<CalibrationFlow | null>(null);
  const dwellRef = useRef(createDwellTracker(DWELL));
  const argsRef = useRef(args);
  argsRef.current = args;
  const decidedRef = useRef(false);

  const finish = useCallback(() => {
    const flow = flowRef.current;
    if (flow) {
      const outcome = flow.outcome();
      if (outcome?.hand) argsRef.current.onHandResult(outcome.hand);
      if (outcome?.gaze) argsRef.current.onGazeResult(outcome.gaze);
    }
    flowRef.current = null;
    setCalibrating(false);
    emitOverlayCalibration(null);
  }, []);

  const start = useCallback(() => {
    flowRef.current = createCalibrationFlow({ handBounds: argsRef.current.handBounds });
    dwellRef.current.reset();
    setCalibrating(true);
  }, []);

  // Decide once: run calibration on first launch unless it's already remembered.
  useEffect(() => {
    if (!args.enabled || decidedRef.current) return;
    decidedRef.current = true;
    if (!args.remembered) start();
  }, [args.enabled, args.remembered, start]);

  // The dwell loop: tick every animation frame, stream the view, finish when done.
  useEffect(() => {
    if (!calibrating) return;
    let raf = 0;
    const loop = (): void => {
      const flow = flowRef.current;
      if (!flow) return;
      const a = argsRef.current;
      const phase = flow.view(0).phase;
      const cursor = phase === "hand" ? a.getHandCursor() : a.getGazeCursor();
      const raw = phase === "hand" ? a.getHandRaw() : a.getGazeRaw();
      const { view, done } = tickCalibration(
        flow,
        dwellRef.current,
        cursor,
        raw,
        performance.now(),
      );
      emitOverlayCalibration(view);
      if (done) {
        finish();
        return;
      }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [calibrating, finish]);

  // Skip / redo from the overlay (esc / "skip" button → skip; a redo control → restart).
  useEffect(() => {
    if (!args.enabled) return;
    return listenCalibrationControl((control) => {
      if (control === "skip") {
        flowRef.current?.skip();
        finish();
      } else if (control === "redo") {
        start();
      }
    });
  }, [args.enabled, finish, start]);

  return { calibrating, redo: start };
}
