import type { LandmarkFrame } from "@handsoff/contracts";
import {
  createHandLandmarker,
  createLandmarkProcessor,
  type HandLandmarkerHandle,
} from "@handsoff/gesture";
import { useCallback, useEffect, useRef, useState } from "react";

import { LandmarkOverlay } from "./LandmarkOverlay";

// #25 camera shell — owns the webcam + the rAF detection loop and renders the debug
// overlay. The detector/stream factories are injectable so the panel is testable
// without a real camera; the defaults wire the live webcam + MediaPipe. The live
// detection path is proven by the demo (Demo Verified), not unit tests.

interface CameraPanelProps {
  getStream?: () => Promise<MediaStream>;
  createDetector?: () => Promise<HandLandmarkerHandle>;
}

type Status = "idle" | "starting" | "live" | "error";

const defaultGetStream = () => navigator.mediaDevices.getUserMedia({ video: true });

interface Resources {
  raf: number;
  handle: HandLandmarkerHandle | null;
  stream: MediaStream | null;
  cancelled: boolean;
}

export function CameraPanel({
  getStream = defaultGetStream,
  createDetector = createHandLandmarker,
}: CameraPanelProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  // Idle until the user explicitly starts the camera — don't grab the webcam on mount.
  const [status, setStatus] = useState<Status>("idle");
  const [error, setError] = useState<string | null>(null);
  const [frame, setFrame] = useState<LandmarkFrame | null>(null);
  const [fps, setFps] = useState(0);

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

  const start = useCallback(async () => {
    setError(null);
    setStatus("starting");
    const r = resources.current;
    r.cancelled = false;
    try {
      const [stream, handle] = await Promise.all([getStream(), createDetector()]);
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
  }, [getStream, createDetector]);

  // Tear down the camera + detector on unmount.
  useEffect(() => stop, [stop]);

  const canStart = status === "idle" || status === "error";

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
        <button type="button" className="camera-panel__start" onClick={() => void start()}>
          Start camera
        </button>
      )}
      <div className="camera-panel__stage">
        <video
          ref={videoRef}
          className="camera-panel__video"
          muted
          playsInline
          aria-label="webcam"
        />
        <LandmarkOverlay frame={frame} fps={fps} />
      </div>
    </section>
  );
}
