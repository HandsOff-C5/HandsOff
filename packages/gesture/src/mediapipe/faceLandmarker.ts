import { FaceLandmarker, FilesetResolver } from "@mediapipe/tasks-vision";

import { type TimedFrameSource } from "./detector";

// Eye-gaze thin shell — instantiate MediaPipe's FaceLandmarker (478-point iris-refined
// mesh) for the VIDEO running mode. This is the only place the browser/wasm dependency
// is touched for face/iris; downstream gaze-feature extraction (../gaze/features.ts)
// consumes plain {x,y} landmarks, so it stays unit-testable with fixtures. NOT
// unit-tested: needs the wasm runtime + a real video element — proven via the live demo
// (Demo Verified), exactly like handLandmarker.ts.

export interface FaceLandmarkerOptions {
  // Self-hosted MediaPipe wasm dir (copied into the app's public/). Must be local —
  // a CDN fetch is blocked by COEP: require-corp. Default "/wasm".
  wasmPath?: string;
  // Self-hosted model. Default "/models/face_landmarker.task".
  modelAssetPath?: string;
  // "GPU" = WebGL on web. Falls back to "CPU" if WebGL is unavailable. Default "GPU".
  delegate?: "GPU" | "CPU";
  // Max faces to track. Default 1.
  numFaces?: number;
}

// The subset of MediaPipe's FaceLandmarkerResult the gaze pipeline relies on: one face's
// 478 normalized landmarks, plus the 4×4 facial transformation matrix (head pose) when
// outputFacialTransformationMatrixes is enabled.
export interface RawFaceLandmarkerResult {
  faceLandmarks: { x: number; y: number; z: number }[][];
  facialTransformationMatrixes?: { data: number[] }[];
}

export interface FaceLandmarkerHandle {
  detector: {
    detectForVideo: (source: TimedFrameSource, timestampMs: number) => RawFaceLandmarkerResult;
  };
  // Release the underlying wasm graph. Call on unmount.
  close(): void;
}

export const createFaceLandmarker = async (
  options: FaceLandmarkerOptions = {},
): Promise<FaceLandmarkerHandle> => {
  const {
    wasmPath = "/wasm",
    modelAssetPath = "/models/face_landmarker.task",
    delegate = "GPU",
    numFaces = 1,
  } = options;

  const fileset = await FilesetResolver.forVisionTasks(wasmPath);
  const landmarker = await FaceLandmarker.createFromOptions(fileset, {
    baseOptions: { modelAssetPath, delegate },
    runningMode: "VIDEO",
    numFaces,
    outputFacialTransformationMatrixes: true,
  });

  return {
    detector: {
      detectForVideo: (source: TimedFrameSource, timestampMs: number) =>
        landmarker.detectForVideo(
          source as unknown as HTMLVideoElement,
          timestampMs,
        ) as unknown as RawFaceLandmarkerResult,
    },
    close: () => landmarker.close(),
  };
};
