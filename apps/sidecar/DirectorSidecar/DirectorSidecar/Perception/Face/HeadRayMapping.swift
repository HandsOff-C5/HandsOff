import CoreGraphics
import Foundation

/// EXPERIMENTAL (branch `experiment/head-ray-gaze`) — a head-pose RAY pointer.
///
/// Instead of the 2D nose-offset modes, this casts a ray from the head along its facing direction
/// and intersects it with the screen plane, yielding a single "where the face is pointing" screen
/// point. The direction blends **two independent estimates** of head orientation — the user's
/// "two cones that combine into one ray":
///   • **Pose cone** — Vision's 3D head pose (`yaw`/`pitch`), the real rotation of the skull.
///   • **Geometry cone** — the 2D `nose → forehead` vector. The forehead is reconstructed as a
///     point above the eye-midpoint along the face-up axis (perpendicular to the eye line); as the
///     head yaws/pitches, the nose swings relative to the forehead, so the CHANGE in that vector
///     (vs the neutral pose) encodes the pointing direction geometrically. This literally uses the
///     nose and forehead (plus the eyes, for the up axis and the scale).
///
/// Both estimates are taken RELATIVE TO A NEUTRAL pose (seeded by Recenter), so a forward-facing
/// head maps to screen CENTER and turning/tilting drives the point toward the matching edge.
///
/// Output is canonical CG **top-left** (`I7`). All knobs are env-overridable so the experiment can
/// be tuned live without a rebuild: `HANDSOFF_RAY_GAIN`, `HANDSOFF_RAY_POSE_WEIGHT`,
/// `HANDSOFF_RAY_FLIP_X`, `HANDSOFF_RAY_FLIP_Y`.
public struct HeadRayMapping {

    /// Screen travel per unit of combined head-direction. Larger = more reach per head turn.
    public let gain: Double
    /// Blend weight of the pose cone vs the geometry cone (`0…1`; `0.5` = equal). `1` = pose only.
    public let poseWeight: Double
    /// Sign flips (the experiment's mirror knobs — yaw/pitch sign conventions vary by SDK/rig).
    public let flipX: Bool
    public let flipY: Bool

    public init(
        gain: Double = HeadRayMapping.envDouble("HANDSOFF_RAY_GAIN", 1.6),
        poseWeight: Double = HeadRayMapping.envDouble("HANDSOFF_RAY_POSE_WEIGHT", 0.5),
        flipX: Bool = HeadRayMapping.envBool("HANDSOFF_RAY_FLIP_X", false),
        flipY: Bool = HeadRayMapping.envBool("HANDSOFF_RAY_FLIP_Y", false)
    ) {
        self.gain = gain
        self.poseWeight = max(0, min(1, poseWeight))
        self.flipX = flipX
        self.flipY = flipY
    }

    /// The reconstructed forehead point (normalized image space, bottom-left) — above the eye
    /// midpoint along the face-up axis (perpendicular to the eye line), ~0.9 eye-distances up. Used
    /// by the geometry cone and the on-screen ray visualization.
    public static func forehead(of s: FaceSignal) -> CGPoint {
        let mid = s.eyeMidpoint
        let dist = max(Double(s.eyeDistance), 1e-6)
        // Eye line vector; rotate +90° for "up" in the image plane (handles head roll).
        let ex = Double(s.rightEye.x - s.leftEye.x)
        let ey = Double(s.rightEye.y - s.leftEye.y)
        let len = max((ex * ex + ey * ey).squareRoot(), 1e-6)
        let upX = -ey / len
        let upY = ex / len
        return CGPoint(x: mid.x + CGFloat(upX * 0.9 * dist),
                       y: mid.y + CGFloat(upY * 0.9 * dist))
    }

    /// The geometry cone: the `nose → forehead` pointing vector, eye-distance-normalized (scale
    /// invariant). In a frontal face the nose sits below the forehead; the vector CHANGES as the
    /// head rotates, which is the pointing signal once differenced against neutral.
    private func noseForeheadVector(_ s: FaceSignal) -> CGPoint {
        let f = Self.forehead(of: s)
        let dist = max(Double(s.eyeDistance), 1e-6)
        return CGPoint(x: (s.nose.x - f.x) / CGFloat(dist),
                       y: (s.nose.y - f.y) / CGFloat(dist))
    }

    /// Combined head-pointing direction in SCREEN space (`+x` right, `+y` DOWN), relative to
    /// neutral. Pure — the headless test seam.
    public func direction(signal: FaceSignal, neutral: FaceSignal) -> CGPoint {
        // Pose cone (radians, vs neutral). tan() maps the rotation angle to a screen-plane offset.
        let dYaw = (signal.yaw ?? neutral.yaw ?? 0) - (neutral.yaw ?? 0)
        let dPitch = (signal.pitch ?? neutral.pitch ?? 0) - (neutral.pitch ?? 0)
        let poseX = tan(dYaw)
        let poseYup = tan(dPitch)   // pitch up → positive (y-UP)

        // Geometry cone (nose→forehead vector change vs neutral). Its y is bottom-left (y-UP).
        let g = noseForeheadVector(signal)
        let gN = noseForeheadVector(neutral)
        let geoX = Double(g.x - gN.x)
        let geoYup = Double(g.y - gN.y)

        let w = poseWeight
        var x = w * poseX + (1 - w) * geoX
        var yUp = w * poseYup + (1 - w) * geoYup
        if flipX { x = -x }
        if flipY { yUp = -yUp }
        // Screen space is y-DOWN, so a positive (up) direction maps to a negative screen-y.
        return CGPoint(x: x, y: -yUp)
    }

    /// Project the head ray onto `screen` (CG top-left). Neutral pose → screen center.
    public func project(signal: FaceSignal, neutral: FaceSignal, screen: CGRect) -> CGPoint {
        guard screen.width > 0, screen.height > 0 else {
            return CGPoint(x: screen.midX, y: screen.midY)
        }
        let d = direction(signal: signal, neutral: neutral)
        let nx = clamp01(0.5 + Double(d.x) * gain)
        let ny = clamp01(0.5 + Double(d.y) * gain)
        return CGPoint(x: screen.minX + CGFloat(nx) * screen.width,
                       y: screen.minY + CGFloat(ny) * screen.height)
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    public static func envDouble(_ key: String, _ fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key], let v = Double(raw) else { return fallback }
        return v
    }
    public static func envBool(_ key: String, _ fallback: Bool) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return fallback }
        return raw == "1" || raw.lowercased() == "true"
    }
}
