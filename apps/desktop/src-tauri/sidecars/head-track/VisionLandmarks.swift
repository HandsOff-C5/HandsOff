import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

func landmarkPoints(_ region: VNFaceLandmarkRegion2D?, in faceBox: CGRect) -> [CGPoint]? {
    guard let region, region.pointCount > 0 else { return nil }
    return region.normalizedPoints.map { point in
        CGPoint(
            x: faceBox.minX + point.x * faceBox.width,
            y: faceBox.minY + point.y * faceBox.height
        )
    }
}

func landmarkInput(from observation: VNFaceObservation, id: String) -> LandmarkInput? {
    guard let landmarks = observation.landmarks else { return nil }
    let face = FaceCandidate(
        id: id,
        boundingBox: observation.boundingBox,
        confidence: Double(observation.confidence),
        observation: observation
    )
    return LandmarkInput(
        face: face,
        leftEye: landmarkPoints(landmarks.leftEye, in: observation.boundingBox),
        rightEye: landmarkPoints(landmarks.rightEye, in: observation.boundingBox),
        nose: landmarkPoints(landmarks.nose, in: observation.boundingBox),
        yaw: observation.yaw?.doubleValue,
        pitch: observation.pitch?.doubleValue
    )
}
