import type { LandmarkFrame } from "@handsoff/contracts";
import {
  createHandLandmarker,
  createLandmarkProcessor,
  type HandLandmarkerHandle,
} from "@handsoff/gesture";
import { useCallback, useEffect, useRef, useState } from "react";

import { LandmarkOverlay } from "./LandmarkOverlay";

// #25/#24 camera shell — owns the webcam + the rAF detection loop and renders the debug
// overlay, a camera picker, and a mirror toggle. The detector/stream/device factories
// are injectable so the panel is testable without a real camera; the defaults wire the
// live webcam + MediaPipe. The live detection path is proven by the demo (Demo
// Verified), not unit tests.

interface CameraPanelProps {
  getStream?: (deviceId?: string) => Promise<MediaStream>;
  createDetector?: () => Promise<HandLandmarkerHandle>;
  listDevices?: () => Promise<MediaDeviceInfo[]>;
}

type Status = "idle" | "starting" | "live" | "error";

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
}: CameraPanelProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  // Idle until the user explicitly starts the camera — don't grab the webcam on mount.
  const [status, setStatus] = useState<Status>("idle");
  const [error, setError] = useState<string | null>(null);
  const [frame, setFrame] = useState<LandmarkFrame | null>(null);
  const [fps, setFps] = useState(0);
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([]);
  const [deviceId, setDeviceId] = useState<string | undefined>(undefined);
  const [mirrored, setMirrored] = useState(true);

  const resources = useRef<Resources>({ raf: 0, handle: null, stream: null, cancelled: false });

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

        // Device labels are only populated after permission is granted, so enumerate
        // now that we have a stream.
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

  // Tear down the camera + detector on unmount.
  useEffect(() => stop, [stop]);

  const canStart = status === "idle" || status === "error";
  const isLive = status === "live";

  return (
    <section className="panel camera-panel">
      <h2 className="panel__title">Camera</h2>
      <div className="camera-panel__status" role="status">
        {status === "idle" && <span>Camera off.</span>}
        {status === "starting" && <span>Starting camera…</span>}
        {status === "live" && <span>Live</span>}
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
      </div>
    </section>
  );
}
