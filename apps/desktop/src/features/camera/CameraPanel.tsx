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
  pointingSignalFromFrame,
  type AffineTransform,
  type HandLandmarkerHandle,
  type Point,
  type ReferentLoop,
} from "@handsoff/gesture";
import { useCallback, useEffect, useRef, useState, type MutableRefObject } from "react";

import { toGestureEvidence } from "../fusion/gestureEvidence";
import { normalizeOverlayPoint, type OverlayPointerUpdate } from "../overlay/overlay-signal";
import { CalibrationOverlay } from "./CalibrationOverlay";
import { DEMO_SCREEN_BOUNDS, demoSurfaceSnapshot, demoSurfaces } from "./demo-surfaces";
import { LandmarkOverlay } from "./LandmarkOverlay";
import { PointerCursor } from "./PointerCursor";

// #25/#24 camera shell — owns the webcam + the rAF detection loop, runs the live
// perception→referent loop, and renders the debug overlay + a camera picker, mirror
// toggle, 9-point calibration, and frame dump. Factories are injectable so the panel is
// testable without a real camera; the live aim/lock path is Demo Verified, not unit tested.

interface CameraPanelProps {
  getStream?: (deviceId?: string) => Promise<MediaStream>;
  createDetector?: () => Promise<HandLandmarkerHandle>;
  listDevices?: () => Promise<MediaDeviceInfo[]>;
  // Live gesture referent out (#35): the locked point as intent PointingEvidence,
  // or null when nothing is locked. The dashboard feeds this into fuseIntent.
  onGestureEvidence?: (evidence: PointingEvidence | null) => void;
  // Live pointer out for the screen overlay (#25): normalized point + confidence +
  // locked target, every frame. The dashboard relays this to the overlay window.
  onOverlayPointer?: (update: OverlayPointerUpdate) => void;
  // Live hand evidence out EVERY frame (not just on lock): the current pointing
  // candidate as PointingEvidence, or null with no hand. The dashboard fuses this
  // with the gaze each frame to drive the on-screen observability HUD.
  onFrameEvidence?: (evidence: PointingEvidence | null) => void;
  // Start the camera on mount (the one-command launch auto-starts every tracker
  // instead of making the operator click "Start camera").
  autoStart?: boolean;
  // Mirror of the live raw pointing signal each frame, so the calibration
  // onboarding (which runs in the engine, outside this panel) can capture the raw
  // sample to fit. A ref → no re-render.
  rawPointerRef?: MutableRefObject<Point | null>;
  // Apply a calibration fitted elsewhere (the touch-the-dots onboarding): rebuild
  // the pointing loop with it + persist, exactly like the in-panel Calibrate flow.
  calibrationOverride?: { transform: AffineTransform; quality: Quality } | null;
}

type Status = "idle" | "starting" | "live" | "error";
type Mode = "live" | "calibrating";
type Quality = "good" | "fair" | "poor";

const IDENTITY: AffineTransform = { a: 1, b: 0, c: 0, d: 0, e: 1, f: 0 };
const DWELL = { enter: 0.6, exit: 0.4, dwellMs: 600, cooldownMs: 800 };
// Pointing signal = the index FINGERTIP (extend 0). An earlier "aim ahead" projection
// (extend 1.5 along wrist→tip) threw the visible cursor off the fingertip — and across the
// frame when pointing sideways — so the dot is the fingertip itself. The live loop and the
// calibration capture MUST use the same signal or the fitted mapping is meaningless.
const POINTING = { anchor: "wrist", extend: 0 } as const;
const FRAME_BUFFER = 150;
// v2: invalidates calibrations fit against the old extend:1.5 pointing signal.
const CALIB_KEY = "handsoff.calibration.v2";
// Coordinate space of the smoothed pointer before calibration (identity transform → the
// raw [0,1] pointing signal); after calibration it's DEMO_SCREEN_BOUNDS.
const UNIT_BOUNDS = { x: 0, y: 0, w: 1, h: 1 };

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

export function CameraPanel({
  getStream = defaultGetStream,
  createDetector = createHandLandmarker,
  listDevices = defaultListDevices,
  onGestureEvidence,
  onOverlayPointer,
  onFrameEvidence,
  autoStart = false,
  rawPointerRef,
  calibrationOverride,
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
  const [calibration, setCalibration] = useState<Quality | null>(null);
  const [candidate, setCandidate] = useState<PointingCandidate | null>(null);
  const [referent, setReferent] = useState<LockedReferent | null>(null);
  const [phase, setPhase] = useState<GestureState>("idle");
  const [active, setActive] = useState(false);
  const [pointer, setPointer] = useState<Point | null>(null);
  const [confidence, setConfidence] = useState(0);

  const resources = useRef<Resources>({ raf: 0, handle: null, stream: null, cancelled: false });
  // Live pointing signal this frame — read by the calibration overlay's Capture.
  const latestRaw = useRef<Point | null>(null);
  // Rolling buffer of parsed frames for the dump-to-fixture button.
  const frameBuffer = useRef<LandmarkFrame[]>([]);
  // Current calibration, so the loop can be rebuilt (unlock / restore) without re-fitting.
  const calib = useRef<{ transform: AffineTransform; quality: Quality }>({
    transform: IDENTITY,
    quality: "poor",
  });
  // The stateful referent loop; rebuilt when calibration changes or on unlock.
  const referentLoop = useRef<ReferentLoop>(
    createReferentLoop({
      transform: IDENTITY,
      surfaces: demoSurfaces,
      calibrationQuality: "poor",
      dwell: DWELL,
      pointing: POINTING,
    }),
  );

  const rebuildLoop = useCallback((transform: AffineTransform, quality: Quality) => {
    calib.current = { transform, quality };
    referentLoop.current = createReferentLoop({
      transform,
      surfaces: demoSurfaces,
      calibrationQuality: quality,
      dwell: DWELL,
      pointing: POINTING,
    });
    setReferent(null);
    setCandidate(null);
    setPhase("idle");
    setActive(false);
    setPointer(null);
    setConfidence(0);
  }, []);

  // Restore a saved calibration so pointing works immediately after a restart.
  useEffect(() => {
    try {
      const saved = localStorage.getItem(CALIB_KEY);
      if (!saved) return;
      const { transform, quality } = JSON.parse(saved) as {
        transform: AffineTransform;
        quality: Quality;
      };
      rebuildLoop(transform, quality);
      setCalibration(quality);
    } catch {
      // Corrupt/absent storage — fall back to uncalibrated.
    }
  }, [rebuildLoop]);

  // Apply a calibration fitted by the touch-the-dots onboarding (runs in the engine,
  // outside this panel): rebuild the loop + persist, same as the in-panel Calibrate flow.
  useEffect(() => {
    if (!calibrationOverride) return;
    rebuildLoop(calibrationOverride.transform, calibrationOverride.quality);
    setCalibration(calibrationOverride.quality);
    try {
      localStorage.setItem(CALIB_KEY, JSON.stringify(calibrationOverride));
    } catch {
      // Storage unavailable — the calibration still applies for this session.
    }
  }, [calibrationOverride, rebuildLoop]);

  const stop = useCallback(() => {
    const r = resources.current;
    r.cancelled = true;
    if (r.raf) cancelAnimationFrame(r.raf);
    r.stream?.getTracks().forEach((t) => t.stop());
    r.handle?.close();
    r.raf = 0;
    r.handle = null;
    r.stream = null;
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

        const processor = createLandmarkProcessor({
          detector: handle.detector,
          onResult: ({ frame: f, fps: f2 }) => {
            setFrame(f);
            setFps(f2);
            latestRaw.current = pointingSignalFromFrame(f, POINTING);
            if (rawPointerRef) rawPointerRef.current = latestRaw.current;
            const buf = frameBuffer.current;
            buf.push(f);
            if (buf.length > FRAME_BUFFER) buf.shift();
            // Advance the referent loop on real elapsed time (derived from fps).
            const dtMs = f2 > 0 ? 1000 / f2 : 16;
            const out = referentLoop.current.process(f, dtMs);
            setCandidate(out.candidate);
            setActive(out.active);
            setPhase(out.state.phase);
            setPointer(f.hands.length ? out.point : null);
            setConfidence(out.confidence);
            if (out.emit && "targetId" in out.emit) setReferent(out.emit);
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

  const switchDevice = (id: string) => {
    setDeviceId(id);
    stop();
    void start(id);
  };

  const unlock = () => rebuildLoop(calib.current.transform, calib.current.quality);

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

  // Publish the locked gesture referent as intent evidence (#35). Emits when a
  // candidate is locked, and clears (null) the moment it unlocks, so the intent
  // engine only sees a gesture referent while the user is actively pointing.
  useEffect(() => {
    if (!onGestureEvidence) return;
    if (phase === "locked" && referent && candidate) {
      onGestureEvidence(toGestureEvidence(candidate, demoSurfaceSnapshot(candidate.targetId)));
    } else {
      onGestureEvidence(null);
    }
  }, [phase, referent, candidate, onGestureEvidence]);

  // Publish the live hand evidence EVERY frame (not just on lock) so the on-screen
  // observability HUD shows the hand channel's confidence + vote continuously.
  useEffect(() => {
    if (!onFrameEvidence) return;
    onFrameEvidence(
      candidate ? toGestureEvidence(candidate, demoSurfaceSnapshot(candidate.targetId)) : null,
    );
  }, [candidate, onFrameEvidence]);

  // One-command launch: auto-start the camera on mount. Guarded so it fires once.
  const autoStarted = useRef(false);
  useEffect(() => {
    if (autoStart && !autoStarted.current) {
      autoStarted.current = true;
      void start();
    }
  }, [autoStart, start]);

  // Stream the live pointer to the screen-overlay window (#25): normalized point (same
  // mapping as the in-app PointerCursor), confidence for the glow, and the locked target
  // label. Emits point:null when no hand is shown so the overlay clears.
  useEffect(() => {
    if (!onOverlayPointer) return;
    const bounds = calibration ? DEMO_SCREEN_BOUNDS : UNIT_BOUNDS;
    const point = pointer
      ? normalizeOverlayPoint(pointer, bounds, calibration ? false : mirrored)
      : null;
    const targetLabel = phase === "locked" && referent ? referent.targetId : null;
    onOverlayPointer({ point, confidence, targetLabel });
  }, [pointer, confidence, phase, referent, calibration, mirrored, onOverlayPointer]);

  // Tear down the camera + detector on unmount.
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
            {calibration ? ` · calibrated (${calibration})` : " · uncalibrated — press Calibrate"}
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
          <button type="button" onClick={() => setMode("calibrating")}>
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
        {mode === "live" && (
          <PointerCursor
            point={pointer}
            bounds={calibration ? DEMO_SCREEN_BOUNDS : UNIT_BOUNDS}
            // Flip ONLY the raw uncalibrated signal (it's in raw-image space, so it must be
            // mirrored to line up with the selfie-view video). A calibrated point is already
            // in on-screen stage space — the user aimed at un-flipped targets through the
            // mirrored video, so the mirror is baked into the fit; flipping again double-
            // mirrors it (correct at center, opposite at the edges).
            mirrored={calibration ? false : mirrored}
            confidence={confidence}
          />
        )}

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
            bounds={DEMO_SCREEN_BOUNDS}
            sampleRaw={() => latestRaw.current}
            onComplete={(result) => {
              rebuildLoop(result.transform, result.quality);
              setCalibration(result.quality);
              try {
                localStorage.setItem(
                  CALIB_KEY,
                  JSON.stringify({ transform: result.transform, quality: result.quality }),
                );
              } catch {
                // Persistence is best-effort.
              }
              setMode("live");
            }}
          />
        )}
      </div>
    </section>
  );
}
