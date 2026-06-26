//
//  ReferentLoop.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/runtime/referent-loop.ts (#25) — the live perception→referent
//  loop. Wires the pure cores into one stateful pipeline: each frame becomes a pointing
//  candidate (calibration), gated by detection confidence (dwell/#28), and fed to the FSM
//  (#27). NOT a gesture classifier — "point" is a confident pointing hand, "hold" is the dwell,
//  interrupts come from voice/button. The connective tissue the architecture assumes.
//

import Foundation

struct ReferentLoopOptions {
    /// Calibration transform (raw pointing signal → screen space). Identity = uncalibrated.
    /// Ignored when `applyCalibration` is supplied (the multi-monitor path).
    let transform: CalibrationAffine
    /// Multi-monitor calibration applier (raw → global-px). When provided, used instead of the
    /// single-affine `transform` for BOTH the visible cursor and the candidate hit-test.
    let applyCalibration: (@Sendable (Vec2) -> Vec2)?
    /// Pointable surfaces in the same coordinate space as the transform output.
    let surfaces: [Contracts.Surface]
    /// Quality of the active calibration, carried into the candidate.
    let calibrationQuality: Contracts.CalibrationQuality
    /// Dwell/hysteresis params (#28) gating candidate → locked.
    let dwell: DwellDebounceParams
    /// Which hand / ray anchor to read.
    let pointing: GesturePointing.Options?
    /// Low-pass cutoff (Hz) for smoothing the referent confidence across frames (#28). Default 2.
    let confidenceCutoffHz: Double

    init(
        transform: CalibrationAffine,
        applyCalibration: (@Sendable (Vec2) -> Vec2)? = nil,
        surfaces: [Contracts.Surface],
        calibrationQuality: Contracts.CalibrationQuality,
        dwell: DwellDebounceParams,
        pointing: GesturePointing.Options? = nil,
        confidenceCutoffHz: Double = 2
    ) {
        self.transform = transform
        self.applyCalibration = applyCalibration
        self.surfaces = surfaces
        self.calibrationQuality = calibrationQuality
        self.dwell = dwell
        self.pointing = pointing
        self.confidenceCutoffHz = confidenceCutoffHz
    }
}

struct ReferentLoopResult: Equatable, Sendable {
    let state: GestureMachineState
    /// The candidate this frame (for the overlay highlight), or nil when no hand / no surface.
    let candidate: Contracts.PointingCandidate?
    /// The smoothed referent confidence this frame (the value the dwell gates on).
    let confidence: Double
    /// Dwell engaged — surface for the low-confidence / clarification UI.
    let active: Bool
    /// 1€-smoothed screen-space pointer position — display-only (targeting/lock use the RAW point).
    let point: Vec2
    /// Per-frame fusion weight for the hand channel, in [0,1]. 0 when no hand is present.
    let reliability: Double
    /// FSM side-effect this frame (a referent locked, or an interrupt raised).
    let emit: GestureEmit?
}

/// The live referent loop. Owns the smoothing/dwell state across frames.
final class ReferentLoop {
    private let options: ReferentLoopOptions
    private let applyCalibratedPoint: (Vec2) -> Vec2

    // Hold-to-lock means holding the SAME target: the dwell resets whenever the pointed target
    // changes (or is lost), so sweeping across surfaces never accumulates to a lock.
    private var dwell: DwellDebounce
    private var lastTargetId: String?
    // Confidence is EMA-smoothed across frames (#28) before the dwell sees it.
    private var smoothedConfidence: Double = 0
    // 1€-smooth the screen-space pointer (x/y independently): steady when held, low-lag when
    // moving. Drives the visible cursor only; targeting/lock stay on the raw point.
    private let smoothX = OneEuroFilter(minCutoff: 1, beta: 0.007)
    private let smoothY = OneEuroFilter(minCutoff: 1, beta: 0.007)
    private var point = Vec2(0, 0)
    private var state = GestureMachine.initialState()

    init(_ options: ReferentLoopOptions) {
        self.options = options
        if let applyCalibration = options.applyCalibration {
            self.applyCalibratedPoint = applyCalibration
        } else {
            let transform = options.transform
            self.applyCalibratedPoint = { GestureCalibration.applyTransform(transform, $0) }
        }
        self.dwell = DwellDebounce(options.dwell)
    }

    private func pickHand(_ frame: Contracts.LandmarkFrame) -> Contracts.Hand? {
        GesturePointing.handFor(frame, options.pointing?.handedness)
    }

    func process(_ frame: Contracts.LandmarkFrame, _ dtMs: Double) throws -> ReferentLoopResult {
        let hand = pickHand(frame)

        var candidate: Contracts.PointingCandidate?
        var confidence = 0.0
        // The hand-channel fusion weight is a raw per-frame signal (occlusion-aware); 0 with no
        // hand so fusion fully discounts us.
        var reliability = 0.0
        if let hand {
            let opts = options.pointing ?? GesturePointing.Options()
            reliability = try GesturePointing.pointingReliability(hand, opts)
            let screenXY = applyCalibratedPoint(try GesturePointing.pointingSignal(hand, opts))
            // Cursor uses the 1€-smoothed point; targeting/lock use the raw point. The cursor
            // tracks whenever a hand is visible; only a deliberate index point arms a candidate.
            point = Vec2(
                smoothX.filter(screenXY.x, frame.timestampMs),
                smoothY.filter(screenXY.y, frame.timestampMs)
            )
            if try GesturePointing.isPointingPose(hand) {
                candidate = GestureCalibration.toCandidate(screenXY, options.surfaces, options.calibrationQuality)
                // Overall referent confidence = detection score × how well it lands on a target.
                confidence = hand.score * (candidate?.confidence ?? 0)
            }
        }

        // Smooth confidence across frames (#28) before it gates anything.
        smoothedConfidence = GestureSmoothing.ema(
            confidence,
            smoothedConfidence,
            GestureSmoothing.alphaFromCutoff(options.confidenceCutoffHz, dtMs / 1000)
        )

        // Reset the dwell when the target changes or is lost — a lock requires dwelling on one
        // target continuously, not just any confident pointing.
        let targetId = candidate?.targetId
        if targetId != lastTargetId {
            dwell = DwellDebounce(options.dwell)
            lastTargetId = targetId
        }

        let result = dwell.update(smoothedConfidence, dtMs)

        var emit: GestureEmit?
        if hand != nil, result.active, let candidate {
            state = GestureMachine.reduce(state, .point(candidate: candidate)).state
            if result.fired {
                let held = GestureMachine.reduce(
                    state,
                    .hold(timestampMs: frame.timestampMs),
                    GestureGuards(dwellSatisfied: true)
                )
                state = held.state
                emit = held.emit
            }
        } else {
            // No confident pointing hand this frame — a candidate (not a locked referent) is
            // dropped by the FSM's `lost` transition.
            state = GestureMachine.reduce(state, .lost).state
        }

        return ReferentLoopResult(
            state: state,
            candidate: candidate,
            confidence: smoothedConfidence,
            active: result.active,
            point: point,
            reliability: reliability,
            emit: emit
        )
    }
}
