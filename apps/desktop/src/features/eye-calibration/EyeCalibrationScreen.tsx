import { useCallback, useEffect, useRef, useState } from "react";
import {
  createCaptureController,
  createEyeCalibration,
  type CaptureController,
  type EyeCalibration,
  type EyeCalibrationOutcome,
  type EyeCalibrationView,
  type MonitorRect,
} from "@handsoff/gesture";

import { unionBounds } from "../overlay/display-map";
import { hasTauriBackend } from "../../lib/tauri";
import { EyeCalibrationStage } from "./EyeCalibrationStage";
import { useIrisTracking, type IrisTrackingDeps } from "./useIrisTracking";

// Per-dot capture timing — let the eye land, then gather confident iris frames.
const CAPTURE = { settleMs: 700, collectMs: 900, minSamples: 6, minConfidence: 0.4 };
// New key — the per-monitor polynomial fits, distinct from the legacy single-correction
// gaze key so we don't clobber it.
const EYE_CALIB_KEY = "handsoff.calibration.eye.v1";

export interface EyeCalibrationScreenProps {
  // Resolve the ordered monitors to calibrate. Default: Tauri's available monitors,
  // primary (laptop) first. Injectable for tests.
  monitorsProvider?: () => Promise<MonitorRect[]>;
  // Webcam + FaceLandmarker injection (see useIrisTracking).
  tracking?: IrisTrackingDeps;
  // Persist the finished fits. Default: localStorage under EYE_CALIB_KEY.
  persist?: (outcome: EyeCalibrationOutcome, monitors: readonly MonitorRect[]) => void;
}

const defaultMonitors = async (): Promise<MonitorRect[]> => {
  if (!hasTauriBackend()) {
    return [{ x: 0, y: 0, w: window.innerWidth || 1280, h: window.innerHeight || 800 }];
  }
  const { availableMonitors, primaryMonitor } = await import("@tauri-apps/api/window");
  const [all, primary] = await Promise.all([availableMonitors(), primaryMonitor()]);
  const tagged = all.map((m) => ({
    name: m.name,
    rect: { x: m.position.x, y: m.position.y, w: m.size.width, h: m.size.height },
  }));
  // Primary (laptop) first, then the rest left-to-right.
  tagged.sort((a, b) => {
    if (primary && a.name === primary.name) return -1;
    if (primary && b.name === primary.name) return 1;
    return a.rect.x - b.rect.x;
  });
  return tagged.map((t) => t.rect);
};

const defaultPersist = (outcome: EyeCalibrationOutcome, monitors: readonly MonitorRect[]): void => {
  try {
    localStorage.setItem(EYE_CALIB_KEY, JSON.stringify({ monitors, fits: outcome.fits }));
  } catch {
    // storage unavailable — non-fatal.
  }
};

export function EyeCalibrationScreen({
  monitorsProvider = defaultMonitors,
  tracking,
  persist = defaultPersist,
}: EyeCalibrationScreenProps) {
  const iris = useIrisTracking(tracking);
  const [monitors, setMonitors] = useState<readonly MonitorRect[] | null>(null);
  const [view, setView] = useState<EyeCalibrationView | null>(null);
  const [outcome, setOutcome] = useState<EyeCalibrationOutcome | null>(null);
  const [captureProgress, setCaptureProgress] = useState(0);

  const calRef = useRef<EyeCalibration | null>(null);
  const captureRef = useRef<CaptureController>(createCaptureController(CAPTURE));

  // Show the overlay (spans the desktop) and make it interactive: calibration is a
  // full-attention modal — clicks should land on it (e.g. "Calibrate again"), not pass
  // through to apps behind. Restore click-through on unmount.
  useEffect(() => {
    if (!hasTauriBackend()) return;
    let invokeRef: ((cmd: string, args?: Record<string, unknown>) => Promise<unknown>) | null =
      null;
    void import("@tauri-apps/api/core").then(({ invoke }) => {
      invokeRef = invoke;
      void invoke("show_overlay").catch(() => undefined);
      void invoke("set_overlay_interactive", { interactive: true }).catch(() => undefined);
    });
    return () => {
      void invokeRef?.("set_overlay_interactive", { interactive: false }).catch(() => undefined);
    };
  }, []);

  // Load monitors once, then start a fresh calibration.
  useEffect(() => {
    let cancelled = false;
    void monitorsProvider().then((mons) => {
      if (cancelled || mons.length === 0) return;
      setMonitors(mons);
      const cal = createEyeCalibration({ monitors: mons });
      calRef.current = cal;
      setView(cal.view());
      captureRef.current.reset(performance.now());
    });
    return () => {
      cancelled = true;
    };
  }, [monitorsProvider]);

  // The capture loop: each frame, feed the live iris read into the dot's capture timer;
  // when it fires, record the median and advance to the next dot / monitor.
  useEffect(() => {
    if (!view || view.done) return;
    let raf = 0;
    const tick = () => {
      const cal = calRef.current;
      if (cal) {
        const f = iris.latest.current;
        const state = captureRef.current.tick(performance.now(), f.confidence, f.vector);
        setCaptureProgress(state.progress);
        if (state.captured) {
          const next = cal.capture(state.captured);
          setView(next);
          setCaptureProgress(0);
          captureRef.current.reset(performance.now());
          if (next.done) {
            const out = cal.outcome();
            setOutcome(out);
            if (out && monitors) persist(out, monitors);
            return; // stop the loop; effect re-runs and bails on view.done
          }
        }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      if (raf) cancelAnimationFrame(raf);
    };
  }, [view, iris.latest, monitors, persist]);

  const redo = useCallback(() => {
    if (!monitors) return;
    const cal = createEyeCalibration({ monitors });
    calRef.current = cal;
    setOutcome(null);
    setCaptureProgress(0);
    captureRef.current.reset(performance.now());
    setView(cal.view());
  }, [monitors]);

  // Compose the current dot's global pixels into union-normalized [0,1] for drawing.
  let dotUnion: readonly [number, number] | null = null;
  if (view?.current && monitors) {
    const u = unionBounds(monitors);
    if (u.w > 0 && u.h > 0) {
      const [gx, gy] = view.current.globalPx;
      dotUnion = [(gx - u.x) / u.w, (gy - u.y) / u.h];
    }
  }

  if (!view) {
    return (
      <div className="eyecal" data-testid="eyecal-loading">
        <div className="eyecal__notice">
          <h2>Preparing eye calibration…</h2>
        </div>
      </div>
    );
  }

  return (
    <EyeCalibrationStage
      status={iris.status}
      error={iris.error}
      stream={iris.stream}
      points={iris.points}
      features={iris.features}
      confidence={iris.confidence}
      view={view}
      dotUnion={dotUnion}
      captureProgress={captureProgress}
      outcome={outcome}
      onRedo={redo}
    />
  );
}
