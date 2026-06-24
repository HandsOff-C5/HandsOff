import { FaceLandmarker, FilesetResolver, HandLandmarker } from "@mediapipe/tasks-vision";

import {
  type FaceLandmarkerDetector,
  type LandmarkDetector,
  type RawFaceLandmarkerResult,
  type TimedFrameSource,
} from "./detector";
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
  // Self-hosted model. Default "/models/face_landmarker.task".
  faceModelAssetPath?: string;
  // "GPU" = WebGL on web. Falls back to "CPU" if WebGL is unavailable. Default "GPU".
  delegate?: "GPU" | "CPU";
  // Max hands to track. Default 2.
  numHands?: number;
  // Max faces to track. Default 1.
  numFaces?: number;
}

export class MediaPipeModelLoadError extends Error {
  readonly kind = "model-load";
  readonly task = "vision-landmarker";

  constructor(cause: unknown) {
    const message = cause instanceof Error ? cause.message : String(cause);
    super(`MediaPipe model load failed: ${message}`);
    this.name = "MediaPipeModelLoadError";
    this.cause = cause;
  }
}

export interface HandLandmarkerHandle {
  detector: LandmarkDetector;
  faceDetector?: FaceLandmarkerDetector;
  // Release the underlying wasm graph. Call on unmount.
  close(): void;
}

export const createHandLandmarker = async (
  options: HandLandmarkerOptions = {},
): Promise<HandLandmarkerHandle> => {
  const {
    wasmPath = "/wasm",
    modelAssetPath = "/models/hand_landmarker.task",
    faceModelAssetPath = "/models/face_landmarker.task",
    delegate = "GPU",
    numHands = 2,
    numFaces = 1,
  } = options;

  let handLandmarker: HandLandmarker | null = null;
  let faceLandmarker: FaceLandmarker | null = null;
  try {
    const fileset = await FilesetResolver.forVisionTasks(wasmPath);
    handLandmarker = await HandLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath, delegate },
      runningMode: "VIDEO",
      numHands,
    });
    faceLandmarker = await FaceLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath: faceModelAssetPath, delegate },
      runningMode: "VIDEO",
      numFaces,
      outputFaceBlendshapes: false,
      outputFacialTransformationMatrixes: false,
    });
  } catch (error) {
    handLandmarker?.close();
    faceLandmarker?.close();
    throw new MediaPipeModelLoadError(error);
  }

  const hand = handLandmarker;
  const face = faceLandmarker;

  return {
    detector: {
      // MediaPipe's result (landmarks[][], handednesses[][]) structurally matches the
      // RawHandLandmarkerResult the shared parser expects.
      detectForVideo: (source: TimedFrameSource, timestampMs: number) =>
        hand.detectForVideo(
          source as unknown as HTMLVideoElement,
          timestampMs,
        ) as unknown as RawHandLandmarkerResult,
    },
    faceDetector: {
      detectForVideo: (source: TimedFrameSource, timestampMs: number) =>
        face.detectForVideo(
          source as unknown as HTMLVideoElement,
          timestampMs,
        ) as unknown as RawFaceLandmarkerResult,
    },
    close: () => {
      hand.close();
      face.close();
    },
  };
};
