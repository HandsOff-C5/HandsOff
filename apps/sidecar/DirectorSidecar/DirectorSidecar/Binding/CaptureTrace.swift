//
//  CaptureTrace.swift
//  DirectorSidecar
//
//  Capture-trace recorder (U5). Port of apps/desktop/src/features/capture-trace
//  (types.ts + createCaptureTrace.ts).
//
//  Records the head, hand, and word streams for exactly one capture-mode window and hands them
//  back, on ONE epoch-ms clock, when the window closes — the timestamped traces the temporal binder
//  (TemporalBinder, U6) brackets each deictic word against. The recorder is the pure core: it owns
//  the buffering, the windowing, and — the load-bearing part — the clock normalization.
//
//  ONE CLOCK. Head and word timestamps are epoch ms already; hand-sample timestamps are off a
//  monotonic frame clock (a clock with an arbitrary origin — `performance.now` in the desktop
//  build). At `start()` we pin an (epochAtStart, performanceAtStart) pair and convert every hand
//  stamp to epoch ms via that offset, so all three streams end up on the same timeline the binder
//  can align against.
//
//  The HeadTraceSample / HandTraceSample / CaptureTrace shapes also feed TemporalBinder directly:
//  the desktop kept two structurally-identical copies (binding/ vs capture-trace/) only to preserve
//  a contracts-only package boundary that this single-module Swift app does not have, so they are
//  declared ONCE here and consumed by both the recorder and the binder.
//

import Foundation

// MARK: - Trace samples & the closed trace

/// One head-pointing sample: the projected screen point the head was aimed at and the host's
/// confidence in it, stamped in epoch ms. (types.ts `HeadTraceSample`.)
struct HeadTraceSample: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
    let tsMs: Double
}

/// One hand-pointing sample: the smoothed screen-space pointer this frame, the loop's candidate
/// (nil when no surface/hand), the gesture FSM phase, and the epoch-ms timestamp (already normalized
/// off the monotonic frame clock). (types.ts `HandTraceSample`.)
struct HandTraceSample: Equatable, Sendable {
    let x: Double
    let y: Double
    let candidate: Contracts.PointingCandidate?
    let phase: Contracts.GestureState
    let tsMs: Double
}

/// The recorded capture window: three streams sharing one epoch-ms clock. (types.ts `CaptureTrace`.)
struct CaptureTrace: Equatable, Sendable {
    let headTrace: [HeadTraceSample]
    let handTrace: [HandTraceSample]
    let words: [Contracts.TranscriptWord]
}

// MARK: - Recorder inputs

/// A head sample as it arrives off the head-pointing stream — already epoch-ms stamped.
struct HeadPointInput: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
    let tsMs: Double
}

/// A hand sample as it arrives off the gesture stream — monotonic frame-clock stamped
/// (`frameTimestampMs`), converted to epoch ms on the way in.
struct HandSampleInput: Equatable, Sendable {
    let frameTimestampMs: Double
    let x: Double
    let y: Double
    let candidate: Contracts.PointingCandidate?
    let phase: Contracts.GestureState
}

// MARK: - Clocks

/// The two clocks the recorder reads. Injected so the normalization math is deterministic in tests.
struct CaptureTraceClocks {
    /// Epoch-ms clock (head + word stamps; `Date.now` in production).
    let now: () -> Double
    /// Monotonic clock matching the hand-sample `frameTimestampMs` origin (`performance.now` in the
    /// desktop build; `ProcessInfo.systemUptime` is the macOS monotonic analogue here).
    let performanceNow: () -> Double

    static var system: CaptureTraceClocks {
        CaptureTraceClocks(
            now: { Date().timeIntervalSince1970 * 1000 },
            performanceNow: { ProcessInfo.processInfo.systemUptime * 1000 })
    }
}

// MARK: - Recorder

/// Records one capture-mode window's head/hand/word streams and returns them on a single epoch-ms
/// clock at `stop()`. Single-threaded by design (driven from the capture-hotkey edges on one
/// queue), matching the desktop recorder's closure-object lifecycle.
final class CaptureTraceRecorder {
    private struct OpenWindow {
        let epochAtStart: Double
        let performanceAtStart: Double
        var head: [HeadTraceSample]
        var hand: [HandTraceSample]
        var words: [Contracts.TranscriptWord]
    }

    private let clocks: CaptureTraceClocks
    private var open: OpenWindow?

    init(clocks: CaptureTraceClocks = .system) {
        self.clocks = clocks
    }

    var recording: Bool { open != nil }

    /// Open a fresh window: pin the clock pair and discard any prior buffers. A second `start()`
    /// without a `stop()` simply re-pins and re-arms.
    func start() {
        open = OpenWindow(
            epochAtStart: clocks.now(),
            performanceAtStart: clocks.performanceNow(),
            head: [],
            hand: [],
            words: [])
    }

    /// Record a head sample. Ignored when no window is open.
    func recordHead(_ sample: HeadPointInput) {
        guard open != nil else { return }
        open?.head.append(
            HeadTraceSample(x: sample.x, y: sample.y, confidence: sample.confidence, tsMs: sample.tsMs))
    }

    /// Record a hand sample. Ignored when no window is open. The monotonic frame stamp is normalized
    /// onto the epoch clock pinned at `start()`.
    func recordHand(_ sample: HandSampleInput) {
        guard let window = open else { return }
        let tsMs = window.epochAtStart + (sample.frameTimestampMs - window.performanceAtStart)
        open?.hand.append(
            HandTraceSample(
                x: sample.x, y: sample.y, candidate: sample.candidate, phase: sample.phase, tsMs: tsMs))
    }

    /// Set/replace the per-word epoch-ms timeline (from the final transcript, U4). Ignored when no
    /// window is open.
    func setWords(_ words: [Contracts.TranscriptWord]) {
        guard open != nil else { return }
        open?.words = words
    }

    /// Close the window and return the recorded trace, windowed to [start, stop] on the shared epoch
    /// clock and ordered by timestamp, so a late head event (or a hand frame whose normalized stamp
    /// lands outside the window) is dropped rather than mis-aligned. Returns nil when no window was
    /// open.
    func stop() -> CaptureTrace? {
        guard let closed = open else { return nil }
        let epochAtStop = clocks.now()
        open = nil

        func inWindow(_ tsMs: Double) -> Bool {
            tsMs >= closed.epochAtStart && tsMs <= epochAtStop
        }

        let headTrace = closed.head.filter { inWindow($0.tsMs) }.sorted { $0.tsMs < $1.tsMs }
        let handTrace = closed.hand.filter { inWindow($0.tsMs) }.sorted { $0.tsMs < $1.tsMs }
        return CaptureTrace(headTrace: headTrace, handTrace: handTrace, words: closed.words)
    }
}
