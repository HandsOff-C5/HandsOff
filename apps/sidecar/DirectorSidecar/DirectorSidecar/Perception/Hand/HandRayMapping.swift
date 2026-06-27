import CoreGraphics
import Foundation

/// EXPERIMENTAL (branch `experiment/head-ray-gaze`) — an index-finger "laser pointer".
///
/// **Model: point-at-the-spot (ABSOLUTE).** Unlike the head ray (relative steering off a neutral
/// pose), the finger ray maps to where the finger is literally AIMED — point at the top-right of the
/// screen and the cursor goes top-right. There is no neutral and no Recenter: the aim is computed
/// fresh every frame.
///
/// The aim point is the fingertip LED FORWARD along the finger's pointing direction:
///   `aim = indexTip + lead · fingerDir · |indexTip − indexMCP|`
/// — i.e. start at the fingertip's real image position and project ahead by `lead` finger-lengths in
/// the direction the finger points. Because it starts from the fingertip (an absolute image
/// position) and only ADDS a directional lead, it stays on/near the finger and never saturates the
/// way a difference-of-unit-vectors steering model does. `fingerDir` averages the per-segment unit
/// vectors (`MCP→PIP→DIP→TIP`) to damp tip jitter, falling back to the plain `indexTip − indexMCP`
/// direction when the refinement joints are low-confidence.
///
/// The aim is returned in normalized canonical CG **top-left** space (`I7`) — the SAME space and
/// convention as the raw fingertip — so the plugin can run it through the identical active-region /
/// SL-2 calibration mapping the 2D pointer uses (`HandModelPlugin.mapToScreen`). That keeps left/
/// right consistent with the proven 2D mode and preserves calibration. Knobs are env-overridable so
/// the experiment tunes live without a rebuild: `HANDSOFF_HAND_RAY_LEAD`, `HANDSOFF_HAND_RAY_FLIP_X`,
/// `HANDSOFF_HAND_RAY_FLIP_Y`.
public struct HandRayMapping {

    /// How far ahead of the fingertip to project, in multiples of the finger length (`MCP→TIP`).
    /// `0` ≡ the fingertip itself (the 2D mode); larger leads the cursor further in the pointing
    /// direction, exaggerating "aim" so a small wrist pivot reaches a screen corner.
    public let lead: Double
    /// Sign flips around the frame center (`x,y → 1 − x,y`). Off by default — the upstream selfie
    /// mirror (`Params.capture.mirrorX`) already orients the signal like the working 2D mode — but
    /// kept as live escape hatches since pointing-sign conventions vary by rig.
    public let flipX: Bool
    public let flipY: Bool

    /// Below this confidence the PIP/DIP refinement is ignored and `fingerDir` degrades to the plain
    /// `indexTip − indexMCP` direction. The lift stamps defaulted joints with confidence `0`, so any
    /// positive real confidence engages the refinement.
    private let refineConfidenceFloor: Double = 0.1

    public init(
        lead: Double = HandRayMapping.envDouble("HANDSOFF_HAND_RAY_LEAD", 1.5),
        flipX: Bool = HandRayMapping.envBool("HANDSOFF_HAND_RAY_FLIP_X", false),
        flipY: Bool = HandRayMapping.envBool("HANDSOFF_HAND_RAY_FLIP_Y", false)
    ) {
        self.lead = lead
        self.flipX = flipX
        self.flipY = flipY
    }

    /// The unit 2D pointing direction of the index finger (canonical top-left, `+y` DOWN). Averages
    /// the per-segment unit vectors `MCP→PIP→DIP→TIP` to reduce tip jitter; FALLS BACK to the plain
    /// `indexTip − indexMCP` direction when the PIP/DIP joints are low-confidence (defaulted).
    public func fingerDir(_ s: HandSignal) -> CGPoint {
        // The reliable whole-finger vector — the documented fallback (and the first averaging term).
        let base = unit(s.indexTip - s.indexMCP)
        guard s.indexPIPConfidence >= refineConfidenceFloor,
              s.indexDIPConfidence >= refineConfidenceFloor else {
            return base
        }
        // Average the per-segment unit vectors; each is a local estimate of the finger's heading.
        let seg1 = unit(s.indexPIP - s.indexMCP)
        let seg2 = unit(s.indexDIP - s.indexPIP)
        let seg3 = unit(s.indexTip - s.indexDIP)
        let avg = unit(CGPoint(x: seg1.x + seg2.x + seg3.x,
                               y: seg1.y + seg2.y + seg3.y))
        // If the segments cancel (degenerate), fall back to the whole-finger vector.
        return avg == .zero ? base : avg
    }

    /// The ABSOLUTE aim point in normalized canonical top-left image space: the fingertip projected
    /// forward by `lead` finger-lengths along the pointing direction. NOT clamped — the plugin's
    /// active-region / calibration mapping clamps and places it on the screen rect. With `lead == 0`
    /// this is exactly the fingertip (≡ 2D mode). The `flip*` knobs mirror around the frame center.
    public func aim(_ s: HandSignal) -> CGPoint {
        let dir = fingerDir(s)
        let len = length(s.indexTip - s.indexMCP)
        var x = Double(s.indexTip.x) + lead * Double(dir.x) * len
        var y = Double(s.indexTip.y) + lead * Double(dir.y) * len
        if flipX { x = 1 - x }
        if flipY { y = 1 - y }
        return CGPoint(x: x, y: y)
    }

    /// The ray's drawable endpoints for the debug overlay: origin = index MCP (the knuckle), tip =
    /// the AIM point (where the laser lands, leading the fingertip). Both canonical top-left.
    public func rayPoints(of s: HandSignal) -> (origin: CGPoint, tip: CGPoint) {
        (origin: s.indexMCP, tip: aim(s))
    }

    // MARK: - small vector helpers

    private func length(_ p: CGPoint) -> Double { Double(hypot(p.x, p.y)) }

    private func unit(_ p: CGPoint) -> CGPoint {
        let len = length(p)
        guard len > 1e-9 else { return .zero }
        return CGPoint(x: p.x / CGFloat(len), y: p.y / CGFloat(len))
    }

    public static func envDouble(_ key: String, _ fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key], let v = Double(raw) else { return fallback }
        return v
    }
    public static func envBool(_ key: String, _ fallback: Bool) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return fallback }
        return raw == "1" || raw.lowercased() == "true"
    }
}

/// Local CGPoint subtraction for the ray math (kept file-private to avoid leaking an operator).
private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}
