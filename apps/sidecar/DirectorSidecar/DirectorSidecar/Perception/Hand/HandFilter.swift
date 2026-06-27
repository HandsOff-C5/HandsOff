import CoreGraphics

/// Fingertip smoothing + confidence-freeze for the hand pointer (`FR-16`, `FR-18`, `I6`, `SL-3`).
///
/// Applies the shared **1€ filter** (`Models/Filtering/PerceptionOneEuroFilter.swift`) to the fingertip's
/// screen-px x and y BEFORE it reaches the overlay, then gates the result through the SAME
/// `FreezeTracker<CGPoint>` contract the face pointer and the capture path use:
///   - a frame at/above `Params.hand.minConfidence` is good — the smoothed point is adopted;
///   - a frame below the floor is a loss — the last good point is HELD (never `(0,0)`), and
///     once losses exceed `Params.capture.lostFrameLimit` the state reports `.frozen`.
///
/// Stateful (the 1€ filters and the freeze tracker carry frame-to-frame state); called serially
/// on the camera video queue in production. Pure of I/O — timestamps are passed in.
public final class HandFilter {

    private let filterX: PerceptionOneEuroFilter
    private let filterY: PerceptionOneEuroFilter
    private let minConfidence: Double
    private var tracker: FreezeTracker<CGPoint>

    public init(
        params: OneEuroParams = OneEuroParams(),
        minConfidence: Double = Params.hand.minConfidence,
        lostFrameLimit: Int = Params.capture.lostFrameLimit
    ) {
        self.filterX = PerceptionOneEuroFilter(params)
        self.filterY = PerceptionOneEuroFilter(params)
        self.minConfidence = minConfidence
        self.tracker = FreezeTracker<CGPoint>(lostFrameLimit: lostFrameLimit)
    }

    /// Feed one frame's mapped fingertip `point` (screen px, CG top-left) with its `confidence`
    /// at time `tMs` (milliseconds). A good frame is smoothed by the 1€ filter and adopted; a
    /// low-confidence frame holds the last good point. Returns the point to render plus the
    /// live/frozen state — the point is NEVER `(0,0)` once a good frame has been seen (`I6`).
    public func update(point: CGPoint, confidence: Double, tMs: Double) -> PointerOutput {
        if confidence >= minConfidence {
            let sx = filterX.filter(Double(point.x), tMs: tMs)
            let sy = filterY.filter(Double(point.y), tMs: tMs)
            tracker.update(.good(CGPoint(x: sx, y: sy)))
        } else {
            tracker.update(.lost)
        }
        let held = tracker.value ?? point
        let state: PointerOutput.State = (tracker.state == .frozen) ? .frozen : .live
        return PointerOutput(point: held, state: state)
    }
}
