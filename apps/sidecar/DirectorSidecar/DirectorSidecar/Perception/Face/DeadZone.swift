/// Dead-zone + hysteresis latch for the edge-mode velocity drive (`FR-9`).
///
/// At rest the control vector jitters around a small magnitude; without a dead-zone the cursor
/// would creep. The latch suppresses motion below the dead-zone and uses HYSTERESIS to avoid
/// flicker at the boundary: motion ACTIVATES only when the magnitude exceeds the OUTER
/// threshold (`Params.face.deadZone`, 0.12) and DEACTIVATES only when it falls back below the
/// INNER threshold (`deadZone · hysteresisInnerRatio` ≈ 0.066). Between the two it holds its
/// current state. Ported from the salvaged head-track `pointerVelocity` latch.
public struct DeadZone {

    /// Activate-above threshold (the dead-zone).
    public let outerThreshold: Double
    /// Deactivate-below threshold (inner band edge).
    public let innerThreshold: Double

    /// Whether motion is currently latched active.
    private var movementActive = false

    public init(
        outerThreshold: Double = Params.face.hysteresisOuter,
        innerThreshold: Double = Params.face.hysteresisInner
    ) {
        self.outerThreshold = outerThreshold
        self.innerThreshold = innerThreshold
    }

    /// Feed the current control-vector magnitude; returns whether motion is active this frame.
    /// Inactive → active requires `magnitude > outerThreshold`; active → inactive requires
    /// `magnitude < innerThreshold`. In the band the latch holds.
    public mutating func active(magnitude: Double) -> Bool {
        if movementActive {
            if magnitude < innerThreshold {
                movementActive = false
            }
        } else if magnitude > outerThreshold {
            movementActive = true
        }
        return movementActive
    }
}
