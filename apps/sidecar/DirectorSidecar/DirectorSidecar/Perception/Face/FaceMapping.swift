import CoreGraphics

/// The three pointer movement modes (`FR-7`), ported from the salvaged head-track motion.
public enum PointerMode: String, Equatable, Sendable {
    /// Velocity-integrated reach: a sustained head turn drives the cursor toward the edge.
    case edge
    /// Face-position-relative drive (trackpad-like), scaled by the neutral face-box width.
    case relative
    /// Direct offset-from-neutral → screen point (holding a pose holds the cursor); the mode
    /// calibration dwells on.
    case absolute
    /// EXPERIMENTAL (branch `experiment/head-ray-gaze`): cast a 3D head-pose ray (nose + forehead +
    /// pose) and intersect it with the screen — "where the face is pointing". See `HeadRayMapping`.
    case ray
}

/// Face-pointer signal → control-vector → screen-point mapping (`FR-7`, `FR-11`, `I7`).
///
/// `controlVector` blends the normalized 2D nose offset with face-center motion and a CAPPED
/// 3D yaw/pitch fine-correction (`FR-11`): the 3D term is clamped to `±correctionWeight`, so a
/// large pose never lets the head-pose term dominate the 2D offset — DEMOTED from the salvaged
/// 0.55 raw weight (I3). `correctionWeight == 0` removes the 3D term entirely (pure-2D mapping).
///
/// `absolutePoint` maps a control vector to a screen point in canonical CG **top-left**
/// coordinates: the control vector is positive-up (image space), and CG y grows DOWN, so the
/// y axis is flipped here at the boundary (`I7`).
public struct FaceMapping {

    public let mode: PointerMode
    /// Reach speed `1…10`; scales how far a given head turn reaches.
    public let speed: Double
    /// 3D fine-correction cap (`FR-11`). Start `Params.face.correctionWeight`.
    public let correctionWeight: Double
    /// Gain/accel curve (`FR-10`) — shapes the edge-mode velocity drive (pow exponent + the
    /// per-second pixel ceiling). The single home for the gain curve in the live face pipeline.
    private let gainCurve: GainCurve
    /// Dead-zone (`FR-9`): control-vector magnitude below this drives no edge motion (at rest).
    private let deadZone: Double

    // Fixed structural blend weights (the salvaged controlVector mix). Not tuned knobs.
    private let noseWeightEdge: Double = 0.75
    private let centerWeightEdge: Double = 0.25
    private let noseWeightRelative: Double = 0.25

    public init(
        mode: PointerMode,
        speed: Double,
        correctionWeight: Double = Params.face.correctionWeight,
        gainCurve: GainCurve = GainCurve(),
        deadZone: Double = Params.face.deadZone
    ) {
        self.mode = mode
        self.speed = speed
        self.correctionWeight = correctionWeight
        self.gainCurve = gainCurve
        self.deadZone = deadZone
    }

    /// Offset-from-neutral control vector. Edge/absolute share one formula; relative uses the
    /// face-center-over-scale drive. The yaw/pitch 3D term is capped at `±correctionWeight`.
    public func controlVector(signal: FaceSignal, neutral: FaceSignal) -> CGPoint {
        let noseX = signal.noseOffset.x - neutral.noseOffset.x
        let noseY = signal.noseOffset.y - neutral.noseOffset.y
        let centerX = signal.faceCenter.x - neutral.faceCenter.x
        let centerY = signal.faceCenter.y - neutral.faceCenter.y

        switch mode {
        case .edge, .absolute, .ray:
            // 3D fine-correction, capped at ±correctionWeight (FR-11). weight 0 → exactly 0.
            let yaw = (signal.yaw ?? neutral.yaw ?? 0) - (neutral.yaw ?? 0)
            let pitch = (signal.pitch ?? neutral.pitch ?? 0) - (neutral.pitch ?? 0)
            let yawTerm = cappedCorrection(yaw)
            let pitchTerm = cappedCorrection(pitch)
            return CGPoint(
                x: noseX * noseWeightEdge + yawTerm + centerX * centerWeightEdge,
                y: noseY * noseWeightEdge + pitchTerm + centerY * centerWeightEdge
            )
        case .relative:
            let scale = max(neutral.faceBoxWidth, 0.1)
            return CGPoint(
                x: centerX / scale + noseX * noseWeightRelative,
                y: centerY / scale + noseY * noseWeightRelative
            )
        }
    }

    /// The 3D contribution for one pose axis: `pose · correctionWeight`, clamped so its
    /// magnitude never exceeds `correctionWeight` regardless of how large the pose is. At
    /// `correctionWeight == 0` this is exactly `0` (pure-2D mapping).
    private func cappedCorrection(_ pose: Double) -> Double {
        let term = pose * correctionWeight
        return max(-correctionWeight, min(correctionWeight, term))
    }

    /// Edge-mode velocity drive (`FR-10`, px/sec, canonical CG top-left). The control vector's
    /// magnitude past the dead-zone is normalized to `0…1`, shaped by the convex `GainCurve`
    /// (fine near rest, accelerating), and scaled by the per-second pixel ceiling
    /// `maxPixelsPerSecond(speed)`. The velocity points along the control vector with the y axis
    /// flipped (control is positive-up; CG y grows down, `I7`). Inside the dead-zone → `.zero`.
    /// Pure: the caller integrates `velocity · dt` into a position.
    public func edgeVelocity(vector: CGPoint, speed: Double) -> CGPoint {
        let mag = Double(hypot(vector.x, vector.y))
        guard mag > deadZone else { return .zero }
        let normalized = min(1, (mag - deadZone) / max(1 - deadZone, 1e-9))
        let speedPxPerSec = gainCurve.shape(normalized) * gainCurve.maxPixelsPerSecond(speed: speed)
        let dirX = Double(vector.x) / mag
        let dirY = Double(vector.y) / mag
        // Flip: positive-up control → negative CG-y velocity.
        return CGPoint(x: dirX * speedPxPerSec, y: -dirY * speedPxPerSec)
    }

    /// Map a control vector to an ABSOLUTE screen point in canonical CG top-left coordinates.
    /// `nx`/`ny` are normalized into `0…1` and placed within the screen rect; the y axis is
    /// flipped because the control vector is positive-up and CG y grows down (`I7`).
    public func absolutePoint(vector: CGPoint, screen: CGRect) -> CGPoint {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        let gain = speed * 0.45
        let nx = clamp01(0.5 + Double(vector.x) * gain)
        // Flip: positive (up) control vector → smaller CG y.
        let ny = clamp01(0.5 - Double(vector.y) * gain)
        return CGPoint(
            x: screen.minX + CGFloat(nx) * screen.width,
            y: screen.minY + CGFloat(ny) * screen.height
        )
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}
