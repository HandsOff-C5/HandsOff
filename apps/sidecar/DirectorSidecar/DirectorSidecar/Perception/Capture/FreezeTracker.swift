import Foundation

/// Freeze-on-dropout tracker (`I6`, `FR-5`). Generic over the tracked value `T` so it is
/// reusable across signals — SL-1 (face landmark), SL-3 (fingertip confidence), and the
/// capture path all hold the SAME contract: while consecutive losses stay **at or below**
/// `Params.capture.lostFrameLimit`, keep passing through the last good value and report
/// `.live`; once losses **exceed** the limit, report `.frozen` and KEEP holding the last
/// good value — it must NEVER substitute a zero/origin/default (the cursor never snaps to
/// `(0,0)`). A good frame recovers to `.live` and refreshes the held value.
///
/// State is `nil`-safe at the start: before any good value arrives there is nothing to
/// hold, so `value` is `nil` and the tracker stays `.live` (no false freeze on a cold
/// start). The first good frame seeds the held value.
public struct FreezeTracker<T> {

    /// One frame's outcome fed to the tracker.
    public enum Frame {
        /// A good detection carrying its value.
        case good(T)
        /// A lost/low-confidence frame (no new value).
        case lost
    }

    /// Live vs frozen — the only two reportable states.
    public enum State: Equatable {
        /// Passing through the last good value (losses ≤ limit, or a fresh good frame).
        case live
        /// Consecutive losses have exceeded the limit; holding the last good value.
        case frozen
    }

    /// The last good value, held across losses. `nil` only before the first good frame.
    public private(set) var value: T?

    /// Current state. Starts `.live`.
    public private(set) var state: State = .live

    /// Consecutive lost frames since the last good one.
    private var consecutiveLosses = 0

    /// Lost-frame tolerance before declaring a freeze (from the tuned knob — never 3 literal).
    private let lostFrameLimit: Int

    public init(lostFrameLimit: Int = Params.capture.lostFrameLimit) {
        // A negative limit would freeze on the first `.lost`; clamp so the documented
        // `losses > limit` contract only operates on non-negative tolerances.
        self.lostFrameLimit = max(0, lostFrameLimit)
    }

    /// Feed one frame. Updates `value`/`state` per the freeze contract.
    public mutating func update(_ frame: Frame) {
        switch frame {
        case .good(let v):
            value = v
            consecutiveLosses = 0
            state = .live
        case .lost:
            consecutiveLosses += 1
            // Hold the last good value (never cleared). Freeze only once losses EXCEED
            // the limit; up to and including the limit we stay live.
            state = consecutiveLosses > lostFrameLimit ? .frozen : .live
        }
    }
}
