import CoreGraphics
import Foundation

/// The synthetic-testable INPUT to the face-pointer math pipeline.
///
/// SL-1a (this slice) is the headless pure-math half: every component is driven from this
/// type with hand-built (synthetic) values so the math is unit-testable without a camera or
/// Vision. The real Vision face-landmark lift (`Models/Face/FaceLandmarks.swift`) is a
/// SEPARATE later dispatch — it will resolve a `FaceSignal` from a `FrameSample` and feed the
/// SAME type into this pipeline, so the math here never changes.
///
/// Coordinates of the landmark points are in whatever pixel space Vision reports; the math
/// downstream is built on the **normalized** `noseOffset` (scale-invariant to face distance),
/// so the absolute pixel scale of the inputs does not matter (see `testNoseOffsetScaleInvariance`).
public struct FaceSignal: Equatable {

    /// Nose-tip landmark.
    public let nose: CGPoint
    /// Left- and right-eye landmarks (outer-corner / pupil centroids; the math only needs the
    /// midpoint and the distance between them).
    public let leftEye: CGPoint
    public let rightEye: CGPoint
    /// Face-bounding-box center, used by the relative pointer mode. Defaults to `nose` when a
    /// synthetic test does not care about relative mode.
    public let faceCenter: CGPoint
    /// Face-box width, used to scale the relative mode. Defaults to `1.0`.
    public let faceBoxWidth: CGFloat
    /// Head yaw / pitch in radians (optional — Vision may not always supply pose). Feed the
    /// 3D fine-correction term (`FR-11`); `nil` is treated as `0`.
    public let yaw: Double?
    public let pitch: Double?
    /// Detection confidence `0…1`. The frame gate (`FR-12`) refuses below `face.minConfidence`.
    public let confidence: Double

    public init(
        nose: CGPoint,
        leftEye: CGPoint,
        rightEye: CGPoint,
        faceCenter: CGPoint? = nil,
        faceBoxWidth: CGFloat = 1.0,
        yaw: Double? = nil,
        pitch: Double? = nil,
        confidence: Double
    ) {
        self.nose = nose
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.faceCenter = faceCenter ?? nose
        self.faceBoxWidth = faceBoxWidth
        self.yaw = yaw
        self.pitch = pitch
        self.confidence = confidence
    }

    /// Midpoint between the two eyes.
    public var eyeMidpoint: CGPoint {
        CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    }

    /// Euclidean distance between the two eyes — the normalization scale.
    public var eyeDistance: CGFloat {
        hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
    }

    /// Linear blend toward another signal by `alpha` (`0` keeps self, `1` adopts `other`).
    /// Used by the auto neutral-drift (`FR-8`) to nudge the neutral pose toward the current
    /// one. Blends every landmark and the pose terms component-wise.
    public func blended(with other: FaceSignal, alpha: Double) -> FaceSignal {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(alpha) }
        func lerpPoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: lerp(a.x, b.x), y: lerp(a.y, b.y))
        }
        func lerpOpt(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return a ?? b }
            return a + (b - a) * alpha
        }
        return FaceSignal(
            nose: lerpPoint(nose, other.nose),
            leftEye: lerpPoint(leftEye, other.leftEye),
            rightEye: lerpPoint(rightEye, other.rightEye),
            faceCenter: lerpPoint(faceCenter, other.faceCenter),
            faceBoxWidth: lerp(faceBoxWidth, other.faceBoxWidth),
            yaw: lerpOpt(yaw, other.yaw),
            pitch: lerpOpt(pitch, other.pitch),
            confidence: confidence + (other.confidence - confidence) * alpha
        )
    }

    /// Nose offset from the eye midpoint, **normalized by inter-eye distance** so it is
    /// scale-invariant to how close the face is to the camera (`CLAUDE §5.5`, FR-6, D2).
    ///
    ///   `noseOffset = (nose − eyeMidpoint) / eyeDistance`
    ///
    /// Worked: nose `(320,250)`, eyes `(300,200)`/`(360,200)` → `(−0.16667, 0.83333)`.
    /// Guards a zero eye-distance (degenerate landmark frame) by returning `.zero`.
    public var noseOffset: CGPoint {
        let mid = eyeMidpoint
        let dist = eyeDistance
        guard dist > 0 else { return .zero }
        return CGPoint(x: (nose.x - mid.x) / dist, y: (nose.y - mid.y) / dist)
    }

    /// Horizontally mirror the signal across the frame center (`x → 1 − x`) and negate `yaw`
    /// (handedness flips), keeping `pitch`/scale/confidence. Applied at the `FaceLandmarks.resolve`
    /// boundary when `Params.capture.mirrorX` so the pointer FOLLOWS the user (selfie convention).
    /// `noseOffset`/`eyeMidpoint`/`eyeDistance` stay consistent because every landmark X flips
    /// together. Y is untouched.
    public func mirroredX() -> FaceSignal {
        FaceSignal(
            nose: CGPoint(x: 1 - nose.x, y: nose.y),
            leftEye: CGPoint(x: 1 - leftEye.x, y: leftEye.y),
            rightEye: CGPoint(x: 1 - rightEye.x, y: rightEye.y),
            faceCenter: CGPoint(x: 1 - faceCenter.x, y: faceCenter.y),
            faceBoxWidth: faceBoxWidth,
            yaw: yaw.map { -$0 },
            pitch: pitch,
            confidence: confidence
        )
    }
}

/// The pipeline OUTPUT: a cursor point in canonical CoreGraphics **top-left** space (`I7`),
/// the pointer's live/frozen state (`I6`), and an optional dwell click event (`FR-13`).
public struct PointerOutput: Equatable {

    /// Pointer state — mirrors `FreezeTracker.State` semantics at the pipeline boundary.
    public enum State: Equatable {
        /// Tracking a fresh signal.
        case live
        /// Signal dropped out (low confidence / lost frames); holding the last good point,
        /// NEVER `(0,0)` (`I6`).
        case frozen
    }

    /// The cursor position in CG top-left coordinates.
    public let point: CGPoint
    /// Live vs frozen.
    public let state: State
    /// A click fired this frame by the dwell selector, if any. `nil` on most frames.
    public let click: ClickEvent?
    /// The signal confidence [0,1] that produced this point, for the observability HUD (NFR-10).
    /// `nil` on a lost/frozen frame or when not applicable.
    public let confidence: Double?

    public init(point: CGPoint, state: State, click: ClickEvent? = nil, confidence: Double? = nil) {
        self.point = point
        self.state = state
        self.click = click
        self.confidence = confidence
    }
}

/// A dwell-to-click event (`FR-13`). Carries the screen point the click lands on.
public struct ClickEvent: Equatable {
    public let point: CGPoint
    public init(point: CGPoint) {
        self.point = point
    }
}
