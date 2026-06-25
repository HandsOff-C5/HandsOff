//
//  HeadSignal.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/FaceTrackingModel.swift (ADR 0005 step 5). Pure
//  perception types: a detected face candidate, the per-frame landmark input, the normalized head
//  signal extracted from it, and the plausibility gate that rejects implausible frames. No camera,
//  no Tauri — queue-agnostic value types, directly unit-testable.
//
//  Type edge case (Optional yaw/pitch): Vision does not always estimate yaw/pitch, so they stay
//  `Double?` end to end. The sidecar serialized `nil` as JSON `null`; in-process the optionality is
//  carried as-is and the control vector falls back to the neutral value (see HeadPointerMotion).
//

import CoreGraphics
import Foundation
import Vision

struct FaceCandidate {
    let id: String
    let boundingBox: CGRect
    let confidence: Double
    let observation: VNFaceObservation?

    init(id: String, boundingBox: CGRect, confidence: Double, observation: VNFaceObservation? = nil) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.observation = observation
    }
}

struct LandmarkInput {
    let face: FaceCandidate
    let leftEye: [CGPoint]?
    let rightEye: [CGPoint]?
    let nose: [CGPoint]?
    let yaw: Double?
    let pitch: Double?
}

struct HeadSignal {
    let faceBox: CGRect
    let faceCenter: CGPoint
    let eyeMidpoint: CGPoint
    let eyeDistance: Double
    let noseOffset: CGPoint
    let roll: Double
    let yaw: Double?
    let pitch: Double?
    let confidence: Double

    init(
        faceBox: CGRect,
        faceCenter: CGPoint,
        eyeMidpoint: CGPoint,
        eyeDistance: Double,
        noseOffset: CGPoint,
        roll: Double,
        yaw: Double?,
        pitch: Double?,
        confidence: Double
    ) {
        self.faceBox = faceBox
        self.faceCenter = faceCenter
        self.eyeMidpoint = eyeMidpoint
        self.eyeDistance = eyeDistance
        self.noseOffset = noseOffset
        self.roll = roll
        self.yaw = yaw
        self.pitch = pitch
        self.confidence = confidence
    }

    init(_ signal: HeadSignal, faceBox: CGRect? = nil, eyeDistance: Double? = nil, confidence: Double? = nil) {
        self.faceBox = faceBox ?? signal.faceBox
        self.faceCenter = faceBox.map(HeadGeometry.center) ?? signal.faceCenter
        self.eyeMidpoint = signal.eyeMidpoint
        self.eyeDistance = eyeDistance ?? signal.eyeDistance
        self.noseOffset = signal.noseOffset
        self.roll = signal.roll
        self.yaw = signal.yaw
        self.pitch = signal.pitch
        self.confidence = confidence ?? signal.confidence
    }

    func blended(with raw: HeadSignal, alpha: Double) -> HeadSignal {
        HeadSignal(
            faceBox: CGRect(
                x: faceBox.origin.x + (raw.faceBox.origin.x - faceBox.origin.x) * alpha,
                y: faceBox.origin.y + (raw.faceBox.origin.y - faceBox.origin.y) * alpha,
                width: faceBox.width + (raw.faceBox.width - faceBox.width) * alpha,
                height: faceBox.height + (raw.faceBox.height - faceBox.height) * alpha
            ),
            faceCenter: HeadGeometry.blend(faceCenter, raw.faceCenter, alpha: alpha),
            eyeMidpoint: HeadGeometry.blend(eyeMidpoint, raw.eyeMidpoint, alpha: alpha),
            eyeDistance: eyeDistance + (raw.eyeDistance - eyeDistance) * alpha,
            noseOffset: HeadGeometry.blend(noseOffset, raw.noseOffset, alpha: alpha),
            roll: roll + (raw.roll - roll) * alpha,
            yaw: HeadGeometry.blendOptional(yaw, raw.yaw, alpha: alpha),
            pitch: HeadGeometry.blendOptional(pitch, raw.pitch, alpha: alpha),
            confidence: raw.confidence
        )
    }
}

func extractSignal(from input: LandmarkInput) -> HeadSignal? {
    guard let leftEye = HeadGeometry.centroid(input.leftEye),
          let rightEye = HeadGeometry.centroid(input.rightEye),
          let nose = HeadGeometry.centroid(input.nose)
    else {
        return nil
    }

    let eyeDistance = HeadGeometry.distance(leftEye, rightEye)
    guard eyeDistance >= 0.03 else { return nil }

    let eyeMidpoint = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    let noseOffset = CGPoint(
        x: (nose.x - eyeMidpoint.x) / eyeDistance,
        y: (nose.y - eyeMidpoint.y) / eyeDistance
    )

    return HeadSignal(
        faceBox: input.face.boundingBox,
        faceCenter: HeadGeometry.center(input.face.boundingBox),
        eyeMidpoint: eyeMidpoint,
        eyeDistance: eyeDistance,
        noseOffset: noseOffset,
        roll: atan2(rightEye.y - leftEye.y, rightEye.x - leftEye.x),
        yaw: input.yaw,
        pitch: input.pitch,
        confidence: input.face.confidence
    )
}

struct FrameGate {
    private let minConfidence = 0.45
    private let maxCenterJump = 0.28
    private let maxScaleRatio = 1.7
    private let minScaleRatio = 0.58

    func accepts(_ signal: HeadSignal, previous: HeadSignal?, predictedBox: CGRect?) -> Bool {
        guard signal.confidence >= minConfidence, signal.eyeDistance >= 0.03 else {
            return false
        }

        if let predictedBox,
           HeadGeometry.distance(HeadGeometry.center(signal.faceBox), HeadGeometry.center(predictedBox)) > maxCenterJump {
            return false
        }

        if let previous {
            let ratio = signal.eyeDistance / previous.eyeDistance
            if ratio > maxScaleRatio || ratio < minScaleRatio {
                return false
            }
        }

        return true
    }
}
