//
//  HeadTrackingModel.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/FaceTrackingModel.swift (ADR 0005 step 5). The
//  perception state machine: face selection → frame gate → pointer motion. The camera service feeds
//  it candidates + signals per frame and reads back a screen-space point. Pure value type; the
//  service owns all the threading.
//

import CoreGraphics

struct HeadTrackingModel {
    private var faceTracker = ActiveFaceTracker()
    private var motion = HeadPointerMotion(config: .default)
    private let gate = FrameGate()
    private var lastAcceptedSignal: HeadSignal?

    mutating func reset() {
        faceTracker.reset()
        motion.reset()
        lastAcceptedSignal = nil
    }

    mutating func applyConfig(_ config: HeadPointerConfig) {
        motion.applyConfig(config)
    }

    mutating func requestRecenter() {
        motion.requestRecenter()
    }

    mutating func chooseFace(from faces: [FaceCandidate]) -> FaceCandidate? {
        faceTracker.choose(from: faces)
    }

    mutating func rejectFrame() {
        faceTracker.rejectFrame()
        _ = motion.rejectFrame()
        if motion.state == .lost {
            lastAcceptedSignal = nil
        }
    }

    mutating func missFace() {
        _ = motion.rejectFrame()
        if motion.state == .lost {
            lastAcceptedSignal = nil
        }
    }

    mutating func point(for signal: HeadSignal, timestamp: Double, screens: [CGRect]) -> CGPoint? {
        let freshTrack = faceTracker.needsFreshSignal
        guard gate.accepts(
            signal,
            previous: freshTrack ? nil : lastAcceptedSignal,
            predictedBox: faceTracker.predictedBox
        ) else {
            rejectFrame()
            return nil
        }

        faceTracker.accept(signal)
        lastAcceptedSignal = signal
        return motion.step(signal: signal, timestamp: timestamp, screens: screens)
    }
}
