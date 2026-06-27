import CoreGraphics

/// Confidence floor + frame gate (`FR-12`, `FR-5`, `I6`).
///
/// A `FaceSignal` below `Params.face.minConfidence` is treated as a LOST frame: the pointer
/// freezes and **holds the last good point** — it must NEVER snap to `(0,0)`. The freeze
/// timing is delegated to the existing generic `FreezeTracker<T>` (`Capture/FreezeTracker.swift`)
/// so the face pointer, the hand pointer, and the capture path all share the SAME contract:
/// up to and including `Params.capture.lostFrameLimit` consecutive losses stay `.live` (still
/// holding the last good point), and only once the losses EXCEED the limit does it report
/// `.frozen`.
///
/// This gate is the SL-1a confidence floor only. The richer salvaged checks (center-jump,
/// scale-ratio) are pose-stability heuristics that belong with the Vision lift and are not
/// part of the pure-math half built here.
public struct FaceFrameGate {

    /// Held-point freeze tracker. The tracked value is the last good cursor point.
    private var tracker: FreezeTracker<CGPoint>
    /// Confidence floor.
    private let minConfidence: Double

    public init(
        minConfidence: Double = Params.face.minConfidence,
        lostFrameLimit: Int = Params.capture.lostFrameLimit
    ) {
        self.minConfidence = minConfidence
        self.tracker = FreezeTracker<CGPoint>(lostFrameLimit: lostFrameLimit)
    }

    /// Feed one frame's signal plus the cursor point the rest of the pipeline computed for it
    /// (`heldPoint`). A signal at or above `minConfidence` is a good frame: the tracker adopts
    /// `heldPoint` and reports `.live`. A signal below the floor is a loss: the tracker holds
    /// its last good point and reports `.live` (losses ≤ limit) or `.frozen` (losses > limit).
    /// The returned `PointerOutput` always carries a real held point — never `(0,0)` once a
    /// good frame has been seen.
    public mutating func accept(_ signal: FaceSignal, heldPoint: CGPoint) -> PointerOutput {
        let isGood = signal.confidence >= minConfidence && signal.eyeDistance > 0
        tracker.update(isGood ? .good(heldPoint) : .lost)
        // value is the last good point; before any good frame fall back to heldPoint (still
        // never forced to origin by this gate).
        let point = tracker.value ?? heldPoint
        let state: PointerOutput.State = (tracker.state == .frozen) ? .frozen : .live
        return PointerOutput(point: point, state: state)
    }
}
