import { useEffect, useRef, useState } from "react";
import {
  createFaceLandmarker,
  eyeTrackingConfidence,
  gazeFeatures,
  gazeFeatureVector,
  gazeOverlayPoints,
  type FaceLandmarkerHandle,
  type GazeFeatures,
  type GazeOverlayPoint,
} from "@handsoff/gesture";

import type { TrackingStatus } from "./EyeCalibrationStage";

// The latest iris read, updated every animation frame. Consumers that capture on their
// own loop read `.current` synchronously (no 30fps re-render); the UI readout mirrors it.
export interface IrisFrame {
  features: GazeFeatures | null;
  // gazeFeatureVector(features) — the 4-vector the calibration consumes — or null.
  vector: number[] | null;
  confidence: number;
  points: readonly GazeOverlayPoint[] | null;
}

export interface IrisTrackingDeps {
  // Open the webcam. Default: getUserMedia({ video }). A rejection → status "denied".
  getStream?: () => Promise<MediaStream>;
  // Create the MediaPipe FaceLandmarker. Default: createFaceLandmarker() (self-hosted wasm).
  createFace?: () => Promise<FaceLandmarkerHandle>;
}

export interface IrisTracking {
  stream: MediaStream | null;
  status: TrackingStatus;
  error: string | null;
  latest: React.MutableRefObject<IrisFrame>;
  features: GazeFeatures | null;
  points: readonly GazeOverlayPoint[] | null;
  confidence: number;
}

const EMPTY_FRAME: IrisFrame = { features: null, vector: null, confidence: 0, points: null };

// Thin I/O shell (proven by demo, not unit tests — like CameraPanel): open the webcam,
// run MediaPipe FaceLandmarker on every frame, and publish the iris features + a live
// eye-tracking confidence. All the math it leans on (gazeFeatures / eyeTrackingConfidence)
// is pure and unit-tested elsewhere.
export const useIrisTracking = (deps: IrisTrackingDeps = {}): IrisTracking => {
  const { getStream, createFace } = deps;
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [status, setStatus] = useState<TrackingStatus>("idle");
  const [error, setError] = useState<string | null>(null);
  const [frame, setFrame] = useState<IrisFrame>(EMPTY_FRAME);
  const latest = useRef<IrisFrame>(EMPTY_FRAME);

  useEffect(() => {
    let cancelled = false;
    let raf = 0;
    let mediaStream: MediaStream | null = null;
    let face: FaceLandmarkerHandle | null = null;
    const video = document.createElement("video");
    video.muted = true;
    video.playsInline = true;

    const open =
      getStream ??
      (() =>
        navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 }, audio: false }));
    const makeFace = createFace ?? (() => createFaceLandmarker());

    const run = async () => {
      setStatus("loading");
      try {
        mediaStream = await open();
      } catch (e) {
        if (cancelled) return;
        setStatus("denied");
        setError(e instanceof Error ? `${e.name}: ${e.message}` : String(e));
        return;
      }
      if (cancelled) {
        mediaStream.getTracks().forEach((t) => t.stop());
        return;
      }
      setStream(mediaStream);
      video.srcObject = mediaStream;
      try {
        await video.play();
      } catch {
        // autoplay/jsdom — the loop still gates on a live frame.
      }

      // The face model can still be downloading on first launch — retry a few times.
      for (let attempt = 0; attempt < 3 && !cancelled; attempt++) {
        try {
          face = await makeFace();
          break;
        } catch {
          face = null;
          await new Promise((r) => setTimeout(r, 800));
        }
      }
      if (cancelled) {
        face?.close();
        return;
      }
      if (!face) {
        setStatus("failed");
        return;
      }
      setStatus("ready");

      const loop = () => {
        if (cancelled) return;
        try {
          const lm = face!.detector.detectForVideo(video, performance.now()).faceLandmarks?.[0];
          const features = lm ? gazeFeatures(lm) : null;
          const next: IrisFrame = {
            features,
            vector: features ? gazeFeatureVector(features) : null,
            confidence: eyeTrackingConfidence(features),
            points: lm ? gazeOverlayPoints(lm) : null,
          };
          latest.current = next;
          setFrame(next);
        } catch {
          // transient detect error — skip this frame.
        }
        raf = requestAnimationFrame(loop);
      };
      raf = requestAnimationFrame(loop);
    };

    void run();

    return () => {
      cancelled = true;
      if (raf) cancelAnimationFrame(raf);
      face?.close();
      mediaStream?.getTracks().forEach((t) => t.stop());
    };
  }, [getStream, createFace]);

  return {
    stream,
    status,
    error,
    latest,
    features: frame.features,
    points: frame.points,
    confidence: frame.confidence,
  };
};
