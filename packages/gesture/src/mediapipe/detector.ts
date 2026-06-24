import { type LandmarkFrame } from "@handsoff/contracts";

import {
  parseHeadFaceFrame,
  type HeadFaceFrame,
  type HeadFaceBox,
  type RawHeadFaceFrame,
  type RawHeadFacePoint,
} from "../perception/head-face";
import { parseLandmarkFrame, type RawHandLandmarkerResult } from "../perception/parse";

// #25 detector loop — the testable core of the MediaPipe video loop, kept free of
// requestAnimationFrame / getUserMedia / FilesetResolver so the gating, parsing, FPS,
// and error handling can be unit-tested with a fake detector. The thin shell
// (handLandmarker.ts + the React component) drives `process` once per rAF tick.

// The minimal slice of MediaPipe's HandLandmarker we depend on. The real
// `HandLandmarker` satisfies this structurally (it accepts an HTMLVideoElement).
export interface LandmarkDetector {
  detectForVideo(source: TimedFrameSource, timestampMs: number): RawHandLandmarkerResult;
}

export interface RawFaceLandmarkerResult {
  faceLandmarks: RawHeadFacePoint[][];
  // MediaPipe FaceLandmarker filters by presence but does not expose this score
  // in its public type. Tests and future native bridges can provide it; the web
  // runtime defaults accepted faces to 1.
  facePresenceScores?: number[];
}

export interface FaceLandmarkerDetector {
  detectForVideo(source: TimedFrameSource, timestampMs: number): RawFaceLandmarkerResult;
}

const FACE_LANDMARK_INDICES = {
  leftEye: [33, 133],
  rightEye: [263, 362],
  nose: [1, 4],
} as const;

// A frame source carrying the monotonically increasing `currentTime` MediaPipe uses
// to skip unchanged frames. The real HTMLVideoElement provides it.
export interface TimedFrameSource {
  currentTime: number;
}

export interface DetectionResult {
  frameId: number;
  frame: LandmarkFrame;
  faceFrame: HeadFaceFrame;
  // Instantaneous frames-per-second from the wall-clock gap to the previous processed
  // frame; 0 for the first frame (nothing to measure against).
  fps: number;
}

export interface LandmarkProcessorOptions {
  detector: LandmarkDetector;
  faceDetector?: FaceLandmarkerDetector;
  // Called with each successfully parsed frame + its FPS.
  onResult?: (result: DetectionResult) => void;
  // Called when detection or parsing throws — the loop swallows the error so a lost
  // GPU context or a malformed frame can't crash the dashboard.
  onError?: (error: unknown) => void;
}

export interface LandmarkProcessor {
  // Process one tick. Returns the result, or null when the frame was skipped
  // (currentTime unchanged) or detection/parsing failed.
  process(source: TimedFrameSource, nowMs: number): DetectionResult | null;
}

export const createLandmarkProcessor = (options: LandmarkProcessorOptions): LandmarkProcessor => {
  const { detector, faceDetector, onResult, onError } = options;
  let lastVideoTime = -1;
  let lastProcessedNowMs: number | null = null;
  let frameId = 0;

  return {
    process(source, nowMs) {
      if (source.currentTime === lastVideoTime) return null;
      lastVideoTime = source.currentTime;
      try {
        const nextFrameId = frameId + 1;
        const raw = detector.detectForVideo(source, nowMs);
        const rawFace = faceDetector?.detectForVideo(source, nowMs) ?? { faceLandmarks: [] };
        const frame = parseLandmarkFrame(raw, nowMs);
        const faceFrame = parseHeadFaceFrame(toRawHeadFaceFrame(rawFace), nowMs, nextFrameId);
        const fps =
          lastProcessedNowMs === null || nowMs <= lastProcessedNowMs
            ? 0
            : 1000 / (nowMs - lastProcessedNowMs);
        lastProcessedNowMs = nowMs;
        frameId = nextFrameId;
        const result = { frameId, frame, faceFrame, fps };
        onResult?.(result);
        return result;
      } catch (error) {
        onError?.(error);
        return null;
      }
    },
  };
};

function toRawHeadFaceFrame(raw: RawFaceLandmarkerResult): RawHeadFaceFrame {
  return {
    faces: raw.faceLandmarks.map((landmarks, index) => ({
      id: `face-${index}`,
      confidence: raw.facePresenceScores?.[index] ?? 1,
      boundingBox: boundingBox(landmarks),
      landmarks: {
        leftEye: pick(landmarks, FACE_LANDMARK_INDICES.leftEye),
        rightEye: pick(landmarks, FACE_LANDMARK_INDICES.rightEye),
        nose: pick(landmarks, FACE_LANDMARK_INDICES.nose),
      },
    })),
  };
}

function pick(
  landmarks: readonly RawHeadFacePoint[],
  indices: readonly number[],
): RawHeadFacePoint[] {
  return indices.flatMap((index) => {
    const landmark = landmarks[index];
    return landmark ? [landmark] : [];
  });
}

function boundingBox(landmarks: readonly RawHeadFacePoint[]): HeadFaceBox {
  if (landmarks.length === 0) {
    throw new Error("face landmarks are required for a face bounding box");
  }
  const xs = landmarks.map((point) => point.x);
  const ys = landmarks.map((point) => point.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  return {
    x: minX,
    y: minY,
    width: maxX - minX,
    height: maxY - minY,
  };
}
