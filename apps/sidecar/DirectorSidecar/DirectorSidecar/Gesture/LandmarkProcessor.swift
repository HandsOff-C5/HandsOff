//
//  LandmarkProcessor.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/mediapipe/detector.ts (#25) — the testable core of the
//  hand-landmarker video loop, kept free of the camera/Vision request so the gating, parsing,
//  FPS, and error handling are unit-testable with a fake detector. The live shell
//  (`HandLandmarkerService`) drives `process` once per captured frame.
//

import Foundation

/// A frame source carrying the monotonically increasing `currentTime` used to skip unchanged
/// frames (the live capture provides it; MediaPipe's HTMLVideoElement did on web).
struct TimedFrameSource: Equatable, Sendable {
    let currentTime: Double
}

/// The minimal slice of a hand landmarker the loop depends on. The live Vision detector and the
/// test fakes both satisfy it structurally.
protocol LandmarkDetector {
    func detectForVideo(_ source: TimedFrameSource, _ timestampMs: Double) throws -> LandmarkParsing.RawHandLandmarkerResult
}

struct DetectionResult: Equatable, Sendable {
    let frame: Contracts.LandmarkFrame
    /// Instantaneous frames-per-second from the wall-clock gap to the previous processed frame;
    /// 0 for the first frame (nothing to measure against).
    let fps: Double
}

/// Process one tick per captured frame, swallowing detector/parse errors so a lost GPU context
/// or a malformed frame can't crash the host. Stateful (last video time + FPS clock) → class.
final class LandmarkProcessor {
    private let detector: LandmarkDetector
    private let onResult: ((DetectionResult) -> Void)?
    private let onError: ((Error) -> Void)?

    private var lastVideoTime: Double = -1
    private var lastProcessedNowMs: Double?

    init(
        detector: LandmarkDetector,
        onResult: ((DetectionResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        self.detector = detector
        self.onResult = onResult
        self.onError = onError
    }

    /// Process one tick. Returns the result, or nil when the frame was skipped (currentTime
    /// unchanged) or detection/parsing failed.
    @discardableResult
    func process(_ source: TimedFrameSource, _ nowMs: Double) -> DetectionResult? {
        if source.currentTime == lastVideoTime { return nil }
        lastVideoTime = source.currentTime
        do {
            let raw = try detector.detectForVideo(source, nowMs)
            let frame = try LandmarkParsing.parseLandmarkFrame(raw, timestampMs: nowMs)
            let fps: Double
            if let last = lastProcessedNowMs, nowMs > last {
                fps = 1000 / (nowMs - last)
            } else {
                fps = 0
            }
            lastProcessedNowMs = nowMs
            let result = DetectionResult(frame: frame, fps: fps)
            onResult?(result)
            return result
        } catch {
            onError?(error)
            return nil
        }
    }
}
