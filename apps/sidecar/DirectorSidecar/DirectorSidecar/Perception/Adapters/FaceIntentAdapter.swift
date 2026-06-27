// FaceIntentAdapter — the narrow seam from the ported face plugin's `PointerOutput` to
// DirectorSidecar's `HeadPoint` intent evidence.
//
// Face replaces the old head-pointer as the live gaze/face evidence source: the face point grounds
// the deixis through the existing `HeadPointSnapshot` → `HeadPointingIntake` path. The migration
// plan left open whether to keep the `HeadPoint` name for face-derived evidence; we keep it, so the
// intake and its tests are unchanged (the point is the face-tracked screen position either way).

import Foundation

enum FaceIntentAdapter {
    /// A LIVE face point → `HeadPoint` (x/y already CG top-left). Returns nil on a frozen or
    /// no-confidence frame so a dropout never overwrites the last good face point with a
    /// zero-confidence one (I6: hold last good — the snapshot keeps the last live point).
    static func headPoint(
        from output: PointerOutput,
        ts: Int64 = HeadPointerEvent.epochMillis()
    ) -> HeadPoint? {
        guard output.state == .live, let confidence = output.confidence else { return nil }
        return HeadPoint(
            x: output.point.x, y: output.point.y,
            yaw: nil, pitch: nil,
            confidence: confidence, ts: ts)
    }
}
