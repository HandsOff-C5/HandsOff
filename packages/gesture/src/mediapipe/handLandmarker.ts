import { FilesetResolver, HandLandmarker } from "@mediapipe/tasks-vision";

import { type LandmarkDetector, type TimedFrameSource } from "./detector";
import { type RawHandLandmarkerResult } from "../perception/parse";

// #25 thin shell — instantiate MediaPipe's HandLandmarker for the VIDEO running mode.
// This is the only place the browser/wasm dependency is touched; everything downstream
// consumes the framework-agnostic LandmarkDetector interface (see detector.ts), so the
// detection-loop logic stays unit-testable with a fake. NOT unit-tested: needs the wasm
// runtime + a real video element — proven via the live demo (Demo Verified).

export interface HandLandmarkerOptions {
  // Self-hosted MediaPipe wasm dir (copied into the app's public/). Must be local —
  // a CDN fetch is blocked by COEP: require-corp. Default "/wasm".
  wasmPath?: string;
  // Self-hosted model. Default "/models/hand_landmarker.task".
  modelAssetPath?: string;
  // "GPU" = WebGL on web. Falls back to "CPU" if WebGL is unavailable. Default "GPU".
  delegate?: "GPU" | "CPU";
  // Max hands to track. Default 2.
  numHands?: number;
}

export interface HandLandmarkerHandle {
  detector: LandmarkDetector;
  // Release the underlying wasm graph. Call on unmount.
  close(): void;
}

export const createHandLandmarker = async (
  options: HandLandmarkerOptions = {},
): Promise<HandLandmarkerHandle> => {
  const {
    wasmPath = "/wasm",
    modelAssetPath = "/models/hand_landmarker.task",
    delegate = "GPU",
    numHands = 2,
  } = options;

  const fileset = await FilesetResolver.forVisionTasks(wasmPath);
  const landmarker = await HandLandmarker.createFromOptions(fileset, {
    baseOptions: { modelAssetPath, delegate },
    runningMode: "VIDEO",
    numHands,
  });

  return {
    detector: {
      // MediaPipe's result (landmarks[][], handednesses[][]) structurally matches the
      // RawHandLandmarkerResult the shared parser expects.
      detectForVideo: (source: TimedFrameSource, timestampMs: number) =>
        landmarker.detectForVideo(
          source as unknown as HTMLVideoElement,
          timestampMs,
        ) as unknown as RawHandLandmarkerResult,
    },
    close: () => landmarker.close(),
  };
};
