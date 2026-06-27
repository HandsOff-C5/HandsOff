// PerceptionBus — concurrent perception fan-out (RESEARCH_CONVERGENCE §7; MIGRATION §8).
//
// This retires `ModelHost`'s one-active-model rule for the PERCEPTION path: instead of routing a
// frame to a single active plugin, the bus FANS OUT each frame to ALL perception plugins (face +
// hand every frame), runs each on its OWN serial queue (so the plugins — not individually thread-
// safe — never run concurrently with themselves), and wraps each plugin's `PointerOutput` into a
// shared Envelope `PointingEvent` in the 300ms ring. There is no `onPointer` main-thread hop: the
// event is built and published on the plugin's queue. `ModelHost` stays as the OVERLAY model-
// picker (additive — unchanged); voice/STT runs in parallel as its own mic-driven flow.
//
// The bus OWNS the ring (fusion buffer), the adapter (emission seam), the publisher (→ S1 topics),
// and the per-user bias learner (the confirmed-selection learning seam, wired in S4). I5: this is
// an in-process bus — no transport.

import CoreGraphics
import Dispatch
import Foundation

/// A perception source the bus fans frames out to: it processes a frame and exposes the latest
/// `PointerOutput`. Both `HandModelPlugin` and `FaceModelPlugin` already satisfy this.
protocol PerceptionPlugin: AnyObject {
    /// The modality provenance this plugin emits (`.hand_pose` / `.face_gaze`).
    var perceptionSource: EventSource { get }
    /// Process one frame (off-main, on the bus's per-plugin queue).
    func process(_ frame: FrameSample) -> FrameSample
    /// The most recent pointer output produced by `process`.
    var latestOutput: PointerOutput? { get }
}

extension HandModelPlugin: PerceptionPlugin {
    var perceptionSource: EventSource { .hand_pose }
}

extension FaceModelPlugin: PerceptionPlugin {
    var perceptionSource: EventSource { .face_gaze }
}

final class PerceptionBus {

    /// The 300ms fusion ring the aligner (`PointingAligner`) consumes.
    let ring: PointingEventRing
    /// Builds the S1 cursorPosition/gazeFocus/transcript payloads.
    let publisher: PerceptionPublisher
    /// Per-user pointing-bias learner. Lock-protected: `route` reads it (`correct`) off the plugin
    /// queues while `confirmSelection` mutates it from the intent/commit path.
    private(set) var bias: PointingBiasLearner
    private let biasLock = NSLock()

    /// The live AX/driver window set NBestCluster ranks each screen-hit against. Read synchronously
    /// on the plugin queue per frame; nil → no ranking (the pre-wire behavior, empty n-best).
    private let screenProvider: (() -> ScreenEvent?)?

    private let adapter: PointingEventAdapter
    private let entries: [(plugin: PerceptionPlugin, queue: DispatchQueue)]

    /// Published per frame for a hand-sourced plugin (the agent/user reticle).
    var onCursorPosition: ((CursorPositionPayload) -> Void)?
    /// Published per frame for a face-sourced plugin (the gaze region).
    var onGazeFocus: ((GazeFocus) -> Void)?
    /// Raw hand `PointerOutput` per frame — the intent-evidence seam (→ `GestureSnapshot`).
    var onHandOutput: ((PointerOutput) -> Void)?
    /// Raw face `PointerOutput` per frame — the intent-evidence seam (→ `HeadPointSnapshot`).
    var onFaceOutput: ((PointerOutput) -> Void)?

    init(
        plugins: [PerceptionPlugin],
        adapter: PointingEventAdapter = PointingEventAdapter(),
        ring: PointingEventRing = PointingEventRing(),
        publisher: PerceptionPublisher = PerceptionPublisher(),
        bias: PointingBiasLearner = PointingBiasLearner(),
        screenProvider: (() -> ScreenEvent?)? = nil
    ) {
        self.adapter = adapter
        self.ring = ring
        self.publisher = publisher
        self.bias = bias
        self.screenProvider = screenProvider
        self.entries = plugins.map { plugin in
            (plugin, DispatchQueue(label: "com.handsoff.perception.\(plugin.perceptionSource.rawValue)"))
        }
    }

    /// Fan one frame out to every plugin on its own serial queue. Each plugin processes the frame,
    /// emits one `PointingEvent` into the ring, and drives its modality's publish sink — all on the
    /// plugin's queue (no main-thread hop).
    func route(_ frame: FrameSample) {
        for entry in entries {
            entry.queue.async { [weak self] in
                guard let self else { return }
                _ = entry.plugin.process(frame)
                guard let output = entry.plugin.latestOutput else { return }

                // Rank the bias-corrected screen hit against the live window set (FR-4). A frozen
                // (dropout) frame asserts no fresh referent, so it is not ranked — the adapter also
                // clears n-best on a frozen frame (I6), this just avoids the wasted work.
                let nBest: [WindowOrRegionRef]
                if output.state != .frozen, let screen = self.screenProvider?() {
                    let corrected = self.correctedHit(PixelPoint(x: output.point.x, y: output.point.y))
                    nBest = NBestCluster.rank(hit: corrected, in: screen)
                } else {
                    nBest = []
                }

                let event = self.adapter.event(
                    from: output, source: entry.plugin.perceptionSource, nBestTargets: nBest)
                self.ring.insert(event)

                switch entry.plugin.perceptionSource {
                case .hand_pose:
                    self.onCursorPosition?(self.publisher.cursorPosition(from: output))
                    self.onHandOutput?(output)
                case .face_gaze:
                    self.onGazeFocus?(self.publisher.gazeFocus(from: output))
                    self.onFaceOutput?(output)
                default:
                    break
                }
            }
        }
    }

    /// Block until every plugin queue has drained the dispatched work (test/teardown determinism).
    func waitUntilIdle() {
        for entry in entries { entry.queue.sync {} }
    }

    /// Apply the per-user learned bias to a raw screen hit (lock-protected — `route` calls this off
    /// the plugin queues while `confirmSelection` may be mutating the learner).
    private func correctedHit(_ raw: PixelPoint) -> PixelPoint {
        biasLock.lock()
        defer { biasLock.unlock() }
        return bias.correct(raw)
    }

    /// The confirmed-selection learning seam (FR-19, INV-5/INV-12): a user-CONFIRMED commit on a
    /// target feeds the learner so the bias offset (and, with a duration, the integration window)
    /// converge to the owner. ONLY confirmed selections may move the model — raw/unconfirmed
    /// pointing never reaches here. `predicted` is the ray's screen hit at selection time; `actual`
    /// is the confirmed target's center.
    func confirmSelection(predicted: PixelPoint, actual: PixelPoint, gestureDurationMs: Double? = nil) {
        biasLock.lock()
        defer { biasLock.unlock() }
        if let gestureDurationMs {
            bias.observeConfirmed(predicted: predicted, actual: actual, gestureDurationMs: gestureDurationMs)
        } else {
            bias.observeConfirmed(predicted: predicted, actual: actual)
        }
    }

    /// The learned bias snapshot (thread-safe read) — for the intent path's `correct` and tests.
    var currentBias: PointingBiasLearner {
        biasLock.lock()
        defer { biasLock.unlock() }
        return bias
    }
}
