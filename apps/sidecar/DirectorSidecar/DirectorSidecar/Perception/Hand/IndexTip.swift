import CoreGraphics

/// Index-fingertip cursor extraction (`FR-15`, `SL-3`).
///
/// The cursor is the `.indexTip` joint **directly** — it is NOT the average of the index and
/// middle fingertips (a common mistake that lands the cursor between the two fingers and makes
/// pointing feel "off"). The `.indexMCP` joint is used for VALIDITY only: it gates whether the
/// hand reading is trustworthy; its position never enters the cursor. Pure (no Vision, no I/O).
public enum IndexTip {

    /// The cursor position for a hand reading: the index fingertip, used directly (`FR-15`).
    /// Worked: `indexTip = (0.40, 0.60)`, `middleTip = (0.60, 0.60)` → `(0.40, 0.60)`
    /// (NOT the average `(0.50, 0.60)`).
    public static func cursor(_ signal: HandSignal) -> CGPoint {
        signal.indexTip
    }

    /// Whether the hand reading is valid, gated on the `.indexMCP` joint's confidence ONLY
    /// (a hand-presence check). The MCP position is never consulted — moving it does not change
    /// the cursor. A reading at/above `minConfidence` is valid.
    public static func isValid(
        _ signal: HandSignal,
        minConfidence: Double = Params.hand.minConfidence
    ) -> Bool {
        signal.indexMCPConfidence >= minConfidence
    }
}
