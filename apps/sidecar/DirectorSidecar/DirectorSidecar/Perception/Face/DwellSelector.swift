import CoreGraphics

/// Dwell-to-click selector with a refire cooldown (`FR-13`).
///
/// Holding the cursor steady within `dwellRadius` (screen px) for `dwellMs` fires a single
/// click at the dwell point. Moving outside the radius RESETS the dwell timer. After a click a
/// `dwellCooldownMs` window suppresses any refire (and the dwell timer does not accumulate
/// during the cooldown — a fresh dwell only begins once the cooldown ends).
///
/// Time is supplied by the CALLER (`nowMs`), so the selector is driven by an injected clock in
/// tests and by the frame timestamp in production — never wall-clock internally.
public struct DwellSelector {

    private let dwellMs: Double
    private let cooldownMs: Double
    private let radius: CGFloat

    /// The point the current dwell is anchored on, and when that dwell began.
    private var anchor: CGPoint?
    private var dwellStartMs: Double = 0
    /// Clicks are suppressed until this time.
    private var cooldownUntilMs: Double = -Double.infinity

    public init(
        dwellMs: Double = Params.face.dwellMs,
        cooldownMs: Double = Params.face.dwellCooldownMs,
        radius: CGFloat = CGFloat(Params.face.dwellRadius)
    ) {
        self.dwellMs = dwellMs
        self.cooldownMs = cooldownMs
        self.radius = radius
    }

    /// Feed the current cursor point and time (ms). Returns a `ClickEvent` on the frame a dwell
    /// completes, otherwise `nil`.
    public mutating func update(point: CGPoint, nowMs: Double) -> ClickEvent? {
        // (Re)anchor if this is the first frame or the cursor moved outside the dwell radius.
        if let a = anchor, distance(a, point) <= radius {
            // still dwelling on the same anchor
        } else {
            anchor = point
            dwellStartMs = nowMs
        }

        // During the cooldown the dwell timer does not accumulate: keep re-arming the start so
        // a fresh dwell only begins once the cooldown ends.
        if nowMs < cooldownUntilMs {
            dwellStartMs = nowMs
            return nil
        }

        if nowMs - dwellStartMs >= dwellMs {
            let firePoint = anchor ?? point
            cooldownUntilMs = nowMs + cooldownMs
            // Reset the dwell so the next click requires a fresh full dwell.
            anchor = nil
            return ClickEvent(point: firePoint)
        }
        return nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
