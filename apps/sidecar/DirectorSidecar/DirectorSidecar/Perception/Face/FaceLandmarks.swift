import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Vision face-landmark lift (`SL-1b`, `FR-6`, `I5`, `NFR-3`).
///
/// Lifted from the salvaged head-track `VisionLandmarks.swift` + the landmark-extraction
/// half of `FaceTrackingModel.swift`, with **all transport stripped** (`I5`): the stdout
/// event writer, the stdin control reader, and every wire emit are gone. This wrapper does ONE
/// thing — turn a captured frame's pixel buffer into the SL-1a `FaceSignal` (nose + eye
/// centroids, pose, confidence) — and returns it in-process. The downstream pointer math
/// (`FaceMapping`, `GainCurve`, `DeadZone`, `FaceFilter`, `DwellSelector`, `Recenter`) consumes
/// that `FaceSignal` unchanged.
///
/// **NFR-3:** `resolve(from:)` takes a `FrameSample`, which by construction holds only a
/// `CVPixelBuffer` (never a `CMSampleBuffer`). Vision reads the pixel buffer through a
/// `VNImageRequestHandler`; nothing is retained past the call.
///
/// **Off-main:** `VNImageRequestHandler.perform` is synchronous and thread-agnostic; in
/// production it is invoked on the camera video queue (`CameraBus.onFrame`), never the main
/// thread. The method is `nonisolated` (a plain struct method) so it can run on any queue.
///
/// Two-pass detection mirrors the salvaged pipeline: detect the face rectangle first, then
/// run landmarks constrained to the best observation. Real detection accuracy is the on-Mac
/// SL-1 gate — a blank synthetic frame correctly yields `nil` (no face).
public struct FaceLandmarks {

    /// The face-landmarks request revision we pin (deterministic across OS updates).
    public static let requestRevision = VNDetectFaceLandmarksRequestRevision3

    /// The face-rectangles request revision we pin.
    public static let rectanglesRevision = VNDetectFaceRectanglesRequestRevision3

    /// Image orientation for Vision: GEOMETRY ONLY (`.up`). The data-output buffer is delivered
    /// upright and UN-mirrored (only the PREVIEW is mirrored), so the orientation must NOT carry a
    /// horizontal flip. The selfie mirror is owned solely by `Params.capture.mirrorX` (`mirroredX()`
    /// in `resolve`, paired with the preview's `isVideoMirrored`); `.upMirrored` here was a second,
    /// unpaired flip that mirror-inverted the landmark vs the preview (double-mirror bug).
    private let orientation: CGImagePropertyOrientation

    /// Minimum eye-distance (normalized) below which the landmark frame is degenerate and
    /// rejected — the salvaged `extractSignal` floor (0.03).
    private let minEyeDistance: CGFloat = 0.03

    public init(orientation: CGImagePropertyOrientation = .up) {
        self.orientation = orientation
    }

    /// Build the landmarks request, revision pinned. Pure factory so it is testable without a
    /// camera (the request is reusable; results are read after `perform`).
    public static func makeRequest() -> VNDetectFaceLandmarksRequest {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = requestRevision
        return request
    }

    private static func makeRectanglesRequest() -> VNDetectFaceRectanglesRequest {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = rectanglesRevision
        return request
    }

    /// Resolve a `FaceSignal` from one captured frame, or `nil` if no usable face is found.
    ///
    /// Reads ONLY `frame.pixelBuffer` (NFR-3 — no `CMSampleBuffer` is reachable from a
    /// `FrameSample`). Runs synchronously on the calling queue (the camera video queue in
    /// production — off the main thread). Returns `nil` for a no-face / degenerate frame so
    /// the frame gate (`FaceFrameGate`) can treat it as a lost frame (`I6`, never `(0,0)`).
    public func resolve(from frame: FrameSample) -> FaceSignal? {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        // Pass 1: detect face rectangles, choose the most confident.
        let rectRequest = Self.makeRectanglesRequest()
        guard (try? handler.perform([rectRequest])) != nil else { return nil }
        let faces = (rectRequest.results ?? [])
        guard let best = faces.max(by: { $0.confidence < $1.confidence }) else { return nil }

        // Pass 2: landmarks constrained to the best face.
        let landmarkRequest = Self.makeRequest()
        landmarkRequest.inputFaceObservations = [best]
        guard (try? handler.perform([landmarkRequest])) != nil,
              let observation = landmarkRequest.results?.first
        else { return nil }

        guard let signal = Self.signal(from: observation) else { return nil }
        // Mirror the live signal so the pointer follows the user (selfie convention, on-Mac knob);
        // applied here so the calibration capture (which also calls resolve) stays consistent.
        return Params.capture.mirrorX ? signal.mirroredX() : signal
    }

    /// Build a `FaceSignal` from a landmarked observation, or `nil` if the eyes/nose are
    /// missing or the frame is degenerate. Pure — testable from a synthetic observation.
    ///
    /// Eyes and nose are reduced to their centroids (the salvaged `centroid`), placed into the
    /// observation's bounding box (the salvaged `landmarkPoints`), then handed to the SL-1a
    /// `FaceSignal`, whose `noseOffset` re-derives the normalized offset the salvaged
    /// `extractSignal` computed by hand.
    static func signal(from observation: VNFaceObservation) -> FaceSignal? {
        guard let landmarks = observation.landmarks,
              let leftEye = centroid(points(landmarks.leftEye, in: observation.boundingBox)),
              let rightEye = centroid(points(landmarks.rightEye, in: observation.boundingBox)),
              let nose = centroid(points(landmarks.nose, in: observation.boundingBox))
        else { return nil }

        let eyeDistance = hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
        guard eyeDistance >= 0.03 else { return nil }

        return FaceSignal(
            nose: nose,
            leftEye: leftEye,
            rightEye: rightEye,
            faceCenter: CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY),
            faceBoxWidth: observation.boundingBox.width,
            yaw: observation.yaw?.doubleValue,
            pitch: observation.pitch?.doubleValue,
            confidence: Double(observation.confidence)
        )
    }

    /// Map a landmark region's normalized points into the face bounding box (salvaged
    /// `landmarkPoints`). Returns `nil` for an empty region.
    static func points(_ region: VNFaceLandmarkRegion2D?, in faceBox: CGRect) -> [CGPoint]? {
        guard let region, region.pointCount > 0 else { return nil }
        return region.normalizedPoints.map { p in
            CGPoint(
                x: faceBox.minX + CGFloat(p.x) * faceBox.width,
                y: faceBox.minY + CGFloat(p.y) * faceBox.height
            )
        }
    }

    /// Centroid of a point set (salvaged `centroid`). `nil` for an empty/absent set.
    static func centroid(_ pts: [CGPoint]?) -> CGPoint? {
        guard let pts, !pts.isEmpty else { return nil }
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
    }
}
