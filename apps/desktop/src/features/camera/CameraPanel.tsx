import type {
  GestureState,
  LandmarkFrame,
  LockedReferent,
  PointingCandidate,
  PointingEvidence,
} from "@handsoff/contracts";
import {
  createHandLandmarker,
  createLandmarkProcessor,
  createReferentLoop,
  multiMonitorTargets,
  pointingSignalFromFrame,
  predictMultiMonitor,
  type AffineTransform,
  type CalibrationTarget,
  type HandLandmarkerHandle,
  type MultiMonitorCalibration,
  type Point,
  type ReferentLoop,
} from "@handsoff/gesture";
import { useCallback, useEffect, useRef, useState } from "react";

import { toGestureEvidence } from "../fusion/gestureEvidence";
import {
  displaySurfaceSnapshot,
  toArbitrationDisplays,
  toDisplaySurfaces,
} from "./display-surfaces";
import { CalibrationOverlay } from "./CalibrationOverlay";
import { LandmarkOverlay } from "./LandmarkOverlay";
import { useGestureOverlay, type DisplayInfo, type GestureOverlay } from "./useGestureOverlay";

// Hand-gesture camera shell. Owns the webcam + the rAF detection loop and runs the live
// perception→referent loop. The visible cursor is NO LONGER drawn inside the camera panel —
// it is a separate pointer rendered over the real desktop by the gesture-overlay sidecar,
// one transparent window per display, so it can travel across ALL connected monitors and
// calibrate against each of them (ported from the funstuff gesture architecture). Factories
// are injectable so the panel is testable without a real camera; the live aim/lock path is
// Demo Verified, not unit tested.

interface CameraPanelProps {
  getStream?: (deviceId?: string) => Promise<MediaStream>;
  createDetector?: () => Promise<HandLandmarkerHandle>;
  listDevices?: () => Promise<MediaDeviceInfo[]>;
  // Overlay sidecar handle. Injected for tests (jsdom has no Tauri `invoke`); defaults to the
  // real `useGestureOverlay` handle in production.
  overlay?: GestureOverlay;
  // Live gesture referent out: the locked point as intent PointingEvidence, or null when
  // nothing is locked. The dashboard feeds this into fuseIntent.
  onGestureEvidence?: (evidence: PointingEvidence | null) => void;
  // Live gesture cursor position (even without a locked referent). Called each frame with
  // the wrist-ray projected point when hands are present, or null when no hands are detected.
  // The dashboard feeds this into the intent fusion as an additional pointing signal.
  onGestureCursor?: (cursor: { x: number; y: number } | null) => void;
  // Full per-frame hand sample for the capture-trace recorder (U5): the frame's
  // `performance.now`-based timestamp, the projected point, the loop's candidate
  // (null when no surface/hand), and the FSM phase. Fired every frame regardless of
  // hand presence so the recorder can window the stream; the recorder normalizes
  // the timestamp onto the shared epoch clock. The dashboard wires this when a
  // capture window is open.
  onGestureSample?: (sample: {
    frameTimestampMs: number;
    point: { x: number; y: number };
    candidate: PointingCandidate | null;
    phase: GestureState;
  }) => void;
  // When true the camera starts automatically on mount without requiring a button click.
  autoStart?: boolean;
}

type Status = "idle" | "starting" | "live" | "error";
type Mode = "live" | "calibrating";

const IDENTITY: AffineTransform = { a: 1, b: 0, c: 0, d: 0, e: 1, f: 0 };
const DWELL = { enter: 0.6, exit: 0.4, dwellMs: 600, cooldownMs: 800 };
// Pointing signal = the index FINGERTIP (extend 0). The live loop and the calibration capture
// MUST use the same signal or the fitted mapping is meaningless.
const POINTING = { anchor: "wrist", extend: 0 } as const;
const FRAME_BUFFER = 150;
// v3: multi-monitor per-display affine fit (replaces the single-affine v2 calibration).
const CALIB_KEY = "handsoff.calibration.v3";
// Calibration grid inset per display — matches the funstuff margin so targets sit comfortably
// inside each screen rather than at the extreme edges.
const CALIB_MARGIN = 0.12;

const defaultGetStream = (deviceId?: string) =>
  navigator.mediaDevices.getUserMedia({
    video: deviceId ? { deviceId: { exact: deviceId } } : true,
  });

const defaultListDevices = () =>
  navigator.mediaDevices.enumerateDevices().then((d) => d.filter((x) => x.kind === "videoinput"));

interface Resources {
  raf: number;
  handle: HandLandmarkerHandle | null;
  stream: MediaStream | null;
  cancelled: boolean;
}

const isMultiCal = (value: unknown): value is MultiMonitorCalibration => {
  if (!value || typeof value !== "object") return false;
  const byDisplay = (value as MultiMonitorCalibration).byDisplay;
  return !!byDisplay && typeof byDisplay === "object";
};

export function CameraPanel({
  getStream = defaultGetStream,
  createDetector = createHandLandmarker,
  listDevices = defaultListDevices,
  overlay: injectedOverlay,
  onGestureEvidence,
  onGestureCursor,
  onGestureSample,
  autoStart = false,
}: CameraPanelProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [status, setStatus] = useState<Status>("idle");
  const [mode, setMode] = useState<Mode>("live");
  const [error, setError] = useState<string | null>(null);
  const [frame, setFrame] = useState<LandmarkFrame | null>(null);
  const [fps, setFps] = useState(0);
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([]);
  const [deviceId, setDeviceId] = useState<string | undefined>(undefined);
  const [mirrored, setMirrored] = useState(true);
  const [displays, setDisplays] = useState<DisplayInfo[]>([]);
  const [multiCal, setMultiCal] = useState<MultiMonitorCalibration | null>(null);
  const [candidate, setCandidate] = useState<PointingCandidate | null>(null);
  const [referent, setReferent] = useState<LockedReferent | null>(null);
  const [phase, setPhase] = useState<GestureState>("idle");
  const [active, setActive] = useState(false);

  const resources = useRef<Resources>({ raf: 0, handle: null, stream: null, cancelled: false });
  // Live pointing signal this frame — read by the calibration overlay's Capture.
  const latestRaw = useRef<Point | null>(null);
  // Rolling buffer of parsed frames for the dump-to-fixture button.
  const frameBuffer = useRef<LandmarkFrame[]>([]);
  // The stateful referent loop; rebuilt when displays or the calibration change.
  const referentLoop = useRef<ReferentLoop>(
    createReferentLoop({
      transform: IDENTITY,
      surfaces: [],
      calibrationQuality: "poor",
      dwell: DWELL,
      pointing: POINTING,
    }),
  );

  // Holds the latest onGestureCursor callback so the rAF closure can call it without
  // being rebuilt on every render.
  const gestureCursorCallbackRef = useRef<
    ((cursor: { x: number; y: number } | null) => void) | undefined
  >(onGestureCursor);
  gestureCursorCallbackRef.current = onGestureCursor;
  // Same pattern for the capture-trace hand-sample callback (U5).
  const gestureSampleCallbackRef = useRef(onGestureSample);
  gestureSampleCallbackRef.current = onGestureSample;

  // Refs mirror the state the per-frame loop reads, so the rAF closure always sees the latest
  // calibration + overlay handle without being rebuilt.
  const multiCalRef = useRef<MultiMonitorCalibration | null>(null);
  useEffect(() => {
    multiCalRef.current = multiCal;
  }, [multiCal]);
  const overlay = injectedOverlay ?? useGestureOverlay();
  const overlayRef = useRef(overlay);
  overlayRef.current = overlay;

  // Rebuild the referent loop around the current displays + calibration. The multi-monitor
  // fit is read live via `predictMultiMonitor`, so the cursor + candidate hit-test share one
  // per-display model; surfaces are the connected displays until area:desktop supplies real
  // app/window targets.
  const rebuildLoop = useCallback(() => {
    referentLoop.current = createReferentLoop({
      transform: IDENTITY,
      applyCalibration: (raw) => predictMultiMonitor(multiCalRef.current, raw),
      surfaces: toDisplaySurfaces(displays),
      calibrationQuality: multiCalRef.current?.quality ?? "poor",
      dwell: DWELL,
      pointing: POINTING,
    });
    setReferent(null);
    setCandidate(null);
    setPhase("idle");
    setActive(false);
  }, [displays]);

  // Rebuild whenever the displays or the calibration change (surfaces + quality depend on
  // them), and hide the overlay cursor whenever there is no active calibration.
  useEffect(() => {
    rebuildLoop();
    if (!multiCal) overlayRef.current.clear("main");
  }, [rebuildLoop, multiCal]);

  const stop = useCallback(() => {
    const r = resources.current;
    r.cancelled = true;
    if (r.raf) cancelAnimationFrame(r.raf);
    r.stream?.getTracks().forEach((t) => t.stop());
    r.handle?.close();
    r.raf = 0;
    r.handle = null;
    r.stream = null;
    overlayRef.current.clear("main");
    void overlayRef.current.stop();
    gestureCursorCallbackRef.current?.(null);
  }, []);

  const start = useCallback(
    async (selectedDeviceId?: string) => {
      setError(null);
      setStatus("starting");
      const r = resources.current;
      r.cancelled = false;
      try {
        const [stream, handle] = await Promise.all([getStream(selectedDeviceId), createDetector()]);
        if (r.cancelled) {
          stream.getTracks().forEach((t) => t.stop());
          handle.close();
          return;
        }
        r.stream = stream;
        r.handle = handle;

        const video = videoRef.current;
        if (video) {
          video.srcObject = stream;
          try {
            await video.play();
          } catch {
            // jsdom / autoplay restrictions — the loop still gates on currentTime.
          }
        }

        try {
          setDevices(await listDevices());
        } catch {
          // Non-fatal: the picker is just unavailable.
        }

        // Bring up the desktop overlay (one window per display) and adopt its CoreGraphics
        // layout so calibration targets and the drawn cursor share one coordinate space.
        try {
          const infos = await overlayRef.current.start();
          setDisplays(infos);
          restoreCalibration(infos);
        } catch (overlayError) {
          // The camera still works without the overlay; the cursor just won't appear on the
          // desktop. Surface this quietly rather than failing the whole camera start.
          console.warn("[handsoff gesture-overlay] start failed", overlayError);
        }

        const processor = createLandmarkProcessor({
          detector: handle.detector,
          onResult: ({ frame: f, fps: f2 }) => {
            setFrame(f);
            setFps(f2);
            latestRaw.current = pointingSignalFromFrame(f, POINTING);
            const buf = frameBuffer.current;
            buf.push(f);
            if (buf.length > FRAME_BUFFER) buf.shift();
            // Advance the referent loop on real elapsed time (derived from fps).
            const dtMs = f2 > 0 ? 1000 / f2 : 16;
            const out = referentLoop.current.process(f, dtMs);
            setCandidate(out.candidate);
            setActive(out.active);
            setPhase(out.state.phase);
            if (out.emit && "targetId" in out.emit) setReferent(out.emit);
            // Publish the raw gesture cursor position each frame so the intent engine
            // can use it as a pointing signal even without a locked referent.
            if (f.hands.length) {
              gestureCursorCallbackRef.current?.({ x: out.point[0], y: out.point[1] });
            } else {
              gestureCursorCallbackRef.current?.(null);
            }
            // Publish the full hand sample to the capture-trace recorder (U5). Fire
            // every frame, including no-hand frames (candidate null), so the recorder
            // sees the real hand timeline; `f.timestampMs` is the frame's
            // `performance.now` stamp, which the recorder normalizes to epoch ms.
            gestureSampleCallbackRef.current?.({
              frameTimestampMs: f.timestampMs,
              point: { x: out.point[0], y: out.point[1] },
              candidate: out.candidate,
              phase: out.state.phase,
            });
            // Drive the separate desktop cursor only while calibrated; hide it when no hand.
            if (multiCalRef.current) {
              if (f.hands.length) overlayRef.current.move("main", out.point[0], out.point[1]);
              else overlayRef.current.clear("main");
            }
          },
          onError: (e) => setError(e instanceof Error ? e.message : String(e)),
        });

        setStatus("live");

        const loop = () => {
          if (r.cancelled) return;
          if (videoRef.current) processor.process(videoRef.current, performance.now());
          r.raf = requestAnimationFrame(loop);
        };
        r.raf = requestAnimationFrame(loop);
      } catch (e) {
        if (r.cancelled) return;
        setStatus("error");
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [getStream, createDetector, listDevices],
  );

  // Restore a saved multi-monitor calibration, but ONLY for displays still attached — a
  // CGDirectDisplayID can change across reboot/reconnect, so a stale id would route the cursor
  // to the wrong per-display affine.
  const restoreCalibration = (infos: DisplayInfo[]) => {
    try {
      const saved = localStorage.getItem(CALIB_KEY);
      if (!saved) return;
      const parsed = JSON.parse(saved) as unknown;
      if (!isMultiCal(parsed)) return;
      const ids = Object.keys(parsed.byDisplay);
      if (ids.length === 0) return;
      if (ids.every((id) => infos.some((d) => d.id === id))) {
        setMultiCal(parsed);
      }
    } catch {
      // Corrupt/absent storage — fall back to uncalibrated.
    }
  };

  const switchDevice = (id: string) => {
    setDeviceId(id);
    stop();
    void start(id);
  };

  const unlock = () => rebuildLoop();

  const dumpFrames = () => {
    const json = JSON.stringify(frameBuffer.current, null, 2);
    if (typeof URL.createObjectURL !== "function") return;
    const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = "captured.golden.json";
    a.click();
    URL.revokeObjectURL(url);
  };

  const calibrationTargets: CalibrationTarget[] =
    displays.length > 0
      ? multiMonitorTargets(toArbitrationDisplays(displays), {
          cols: 3,
          rows: 3,
          margin: CALIB_MARGIN,
        })
      : [];

  const completeCalibration = (result: MultiMonitorCalibration) => {
    setMultiCal(result);
    overlayRef.current.untarget();
    setMode("live");
    try {
      localStorage.setItem(CALIB_KEY, JSON.stringify(result));
    } catch {
      // Persistence is best-effort.
    }
  };

  // Publish the locked gesture referent as intent evidence. Emits when a candidate is locked,
  // and clears (null) the moment it unlocks, so the intent engine only sees a gesture referent
  // while the user is actively pointing at a display.
  useEffect(() => {
    if (!onGestureEvidence) return;
    if (phase === "locked" && referent && candidate) {
      onGestureEvidence(
        toGestureEvidence(candidate, displaySurfaceSnapshot(candidate.targetId, displays)),
      );
    } else {
      onGestureEvidence(null);
    }
  }, [phase, referent, candidate, displays, onGestureEvidence]);

  // Auto-start the camera on mount when requested, without requiring a button click.
  useEffect(() => {
    if (autoStart) void start();
  }, [autoStart, start]);

  // Tear down the camera + detector + overlay on unmount.
  useEffect(() => stop, [stop]);

  const canStart = status === "idle" || status === "error";
  const isLive = status === "live";
  const locked = phase === "locked" && referent;

  return (
    <section className="panel camera-panel">
      <h2 className="panel__title">Camera</h2>
      <div className="camera-panel__status" role="status">
        {status === "idle" && <span>Camera off.</span>}
        {status === "starting" && <span>Starting camera…</span>}
        {status === "live" && (
          <span>
            Live
            {multiCal ? ` · calibrated (${multiCal.quality})` : " · uncalibrated — press Calibrate"}
          </span>
        )}
        {status === "error" && <span className="camera-panel__error">Camera error: {error}</span>}
      </div>

      {canStart && (
        <button type="button" className="camera-panel__start" onClick={() => void start(deviceId)}>
          Start camera
        </button>
      )}

      {isLive && (
        <div className="camera-panel__controls">
          {devices.length > 0 && (
            <label className="camera-panel__device">
              Camera
              <select
                value={deviceId ?? devices[0]?.deviceId ?? ""}
                onChange={(e) => switchDevice(e.target.value)}
              >
                {devices.map((d, i) => (
                  <option key={d.deviceId} value={d.deviceId}>
                    {d.label || `Camera ${i + 1}`}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label className="camera-panel__mirror">
            <input
              type="checkbox"
              checked={mirrored}
              onChange={(e) => setMirrored(e.target.checked)}
            />
            Mirror
          </label>
          <button
            type="button"
            disabled={displays.length === 0}
            onClick={() => setMode("calibrating")}
          >
            Calibrate
          </button>
          <button type="button" onClick={dumpFrames}>
            Dump frames
          </button>
        </div>
      )}

      <div className="camera-panel__stage">
        <video
          ref={videoRef}
          className={`camera-panel__video${mirrored ? " camera-panel__video--mirrored" : ""}`}
          muted
          playsInline
          aria-label="webcam"
        />
        <LandmarkOverlay frame={frame} fps={fps} mirrored={mirrored} />

        {mode === "live" && locked && (
          <div className="camera-panel__candidate camera-panel__candidate--locked">
            🔒 Locked: {referent.targetId}
            <button type="button" onClick={unlock}>
              Unlock
            </button>
          </div>
        )}
        {mode === "live" && !locked && candidate && (
          <p className="camera-panel__candidate">
            {active
              ? `Holding ${candidate.targetId}… keep still`
              : `Aiming at: ${candidate.targetId}`}
          </p>
        )}

        {isLive && mode === "calibrating" && (
          <CalibrationOverlay
            targets={calibrationTargets}
            sampleRaw={() => latestRaw.current}
            onShowTarget={(target) =>
              target
                ? overlayRef.current.target(target.target[0], target.target[1])
                : overlayRef.current.untarget()
            }
            onComplete={completeCalibration}
            onCancel={() => {
              overlayRef.current.untarget();
              setMode("live");
            }}
          />
        )}
      </div>
    </section>
  );
}
