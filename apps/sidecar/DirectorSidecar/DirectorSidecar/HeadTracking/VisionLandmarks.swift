//
//  VisionLandmarks.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/VisionLandmarks.swift (ADR 0005 step 5). Maps a
//  `VNFaceObservation`'s normalized landmark regions into the bounding-box-relative points the head
//  signal needs. Namespaced under `HeadLandmarks` (the sidecar had these as free functions named
//  `landmarkPoints` / `landmarkInput`, too generic for the app module).
//

import CoreGraphics
import Vision

enum HeadLandmarks {
    static func points(_ region: VNFaceLandmarkRegion2D?, in faceBox: CGRect) -> [CGPoint]? {
        guard let region, region.pointCount > 0 else { return nil }
        return region.normalizedPoints.map { point in
            CGPoint(
                x: faceBox.minX + CGFloat(point.x) * faceBox.width,
                y: faceBox.minY + CGFloat(point.y) * faceBox.height
            )
        }
    }

    static func input(from observation: VNFaceObservation, id: String) -> LandmarkInput? {
        guard let landmarks = observation.landmarks else { return nil }
        let face = FaceCandidate(
            id: id,
            boundingBox: observation.boundingBox,
            confidence: Double(observation.confidence),
            observation: observation
        )
        return LandmarkInput(
            face: face,
            leftEye: points(landmarks.leftEye, in: observation.boundingBox),
            rightEye: points(landmarks.rightEye, in: observation.boundingBox),
            nose: points(landmarks.nose, in: observation.boundingBox),
            yaw: observation.yaw?.doubleValue,
            pitch: observation.pitch?.doubleValue
        )
    }
}
