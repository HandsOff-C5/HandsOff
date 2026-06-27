// HandIntentAdapter — the narrow seam from the ported hand plugin's `PointerOutput` to
// DirectorSidecar's `GestureReferent` intent evidence.
//
// The ported HO-rebuild hand model emits a CURSOR point (the index-tip / finger-ray screen
// position), not a calibrated locked surface. So this contributes the wrist-ray CURSOR channel
// (`GestureReferent.cursor`) only — which `HeadPointingFusion` folds in as the
// `wrist-ray-position` evidence. The locked-referent surface lane (the old `ReferentLoop`
// calibration FSM) is a deliberate follow-up, not reproduced by this adapter.

import Foundation

enum HandIntentAdapter {
    /// A LIVE hand point → a cursor-only `GestureReferent`. Returns nil on a frozen frame (no hand
    /// present), so the gesture snapshot is not overwritten with an empty referent and the last
    /// live cursor survives the dropout (matching the desktop refs that held last gesture state).
    static func referent(from output: PointerOutput) -> GestureReferent? {
        guard output.state == .live else { return nil }
        return GestureReferent(
            cursor: Contracts.PointingEvidence.Cursor(x: output.point.x, y: output.point.y))
    }
}
