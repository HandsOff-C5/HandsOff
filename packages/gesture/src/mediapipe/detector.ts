import { type LandmarkFrame } from "@handsoff/contracts";

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

// A frame source carrying the monotonically increasing `currentTime` MediaPipe uses
// to skip unchanged frames. The real HTMLVideoElement provides it.
export interface TimedFrameSource {
  currentTime: number;
}

export interface DetectionResult {
  frame: LandmarkFrame;
  // Instantaneous frames-per-second from the wall-clock gap to the previous processed
  // frame; 0 for the first frame (nothing to measure against).
  fps: number;
}

export interface LandmarkProcessorOptions {
  detector: LandmarkDetector;
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
  const { detector, onResult, onError } = options;
  let lastVideoTime = -1;
  let lastProcessedNowMs: number | null = null;

  return {
    process(source, nowMs) {
      if (source.currentTime === lastVideoTime) return null;
      lastVideoTime = source.currentTime;
      try {
        const raw = detector.detectForVideo(source, nowMs);
        const frame = parseLandmarkFrame(raw, nowMs);
        const fps =
          lastProcessedNowMs === null || nowMs <= lastProcessedNowMs
            ? 0
            : 1000 / (nowMs - lastProcessedNowMs);
        lastProcessedNowMs = nowMs;
        const result = { frame, fps };
        onResult?.(result);
        return result;
      } catch (error) {
        onError?.(error);
        return null;
      }
    },
  };
};
