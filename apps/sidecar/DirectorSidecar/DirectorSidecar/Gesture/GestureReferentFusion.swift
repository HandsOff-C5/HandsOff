//
//  GestureReferentFusion.swift
//  DirectorSidecar
//
//  The migration step that makes the HAND-gesture lane REACH the intent, not just the overlay
//  cursor — the sibling of HeadPointingIntake's head fold-in. Ports the gesture path of
//  apps/desktop/src/features/voice-cua/buildPointingEvidence.ts (the `gesture`/`gestureCursor`
//  branch, lines 83-96) plus its two producers in the desktop app:
//    • apps/desktop/src/features/fusion/gestureEvidence.ts `toGestureEvidence` — a locked
//      pointing candidate + its resolved surface → intent `PointingEvidence`.
//    • apps/desktop/src/features/camera/display-surfaces.ts `displaySurfaceSnapshot` — the
//      best-effort audit snapshot for the display a referent resolved to.
//    • apps/desktop/src/features/camera/CameraPanel.tsx — the rAF that, per `ReferentLoop`
//      frame, publishes the locked referent (when phase == locked) and the wrist-ray cursor
//      (when a hand is present) into the refs `buildPointingEvidence` reads at intent time.
//
//  The `ReferentLoop` (the live perception→referent pipeline) and `HandLandmarkerService` (the
//  camera shell) were ported but left UNREFERENCED by the app — so pointing a hand at a target
//  yielded no referent. This is the seam that feeds their output into `IntentInput`: the live
//  gesture consumer records a `GestureReferent` into the shared `GestureSnapshot`, and the loop's
//  `HeadPointingIntake` reads it at goal start and folds it into the resolver's input.
//

import Foundation

/// The gesture lane's contribution to the next intent, read once at goal start. Mirrors the
/// desktop `PointingContext.gestureEvidence` + `.gestureCursor` refs: a locked referent (a
/// specific surface the camera held a point on) and/or the live wrist-ray cursor (present even
/// without a lock). Either may be nil — no lock, no hand, or neither.
struct GestureReferent: Equatable, Sendable {
    /// The locked referent as intent `PointingEvidence` (source `.gesture`, carries the surface).
    /// Nil unless the FSM is in `locked` with a candidate this frame.
    let evidence: Contracts.PointingEvidence?
    /// The live wrist-ray cursor position (even without a lock). Nil when no hand is present.
    let cursor: Contracts.PointingEvidence.Cursor?

    init(evidence: Contracts.PointingEvidence? = nil, cursor: Contracts.PointingEvidence.Cursor? = nil) {
        self.evidence = evidence
        self.cursor = cursor
    }

    /// True when this contributes no signal — neither a lock nor a cursor.
    var isEmpty: Bool { evidence == nil && cursor == nil }
}

/// The latest gesture referent, shared between the gesture-lane consumer (writer — the live
/// `ReferentLoop` driver) and the intent intake (reader — the loop at goal start). Lock-protected
/// so it is `Sendable` without binding either side to an actor, the same self-synchronized pattern
/// `HeadPointSnapshot`/`HeadPointerService` use for cross-queue state.
///
/// Like the head point, the referent is NOT cleared when sensing stops: intent resolution reads it
/// ~1.5s after push-to-talk release (the loop's retarget grace), so the referent locked DURING the
/// utterance must survive the camera stop to ground the deixis — faithful to the desktop refs,
/// which likewise held the last gesture evidence/cursor across a stop.
final class GestureSnapshot: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var latest: GestureReferent?

    init() {}

    func record(_ referent: GestureReferent) {
        lock.lock()
        defer { lock.unlock() }
        latest = referent
    }

    var current: GestureReferent? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// Pure derivation of a `GestureReferent` from a `ReferentLoop` frame — the desktop CameraPanel rAF
/// + `toGestureEvidence` + `displaySurfaceSnapshot`, lifted out of the camera so it is unit-testable
/// (no camera, no React refs). The live consumer supplies the loop result + the pointable surfaces
/// the candidate's `targetId` resolves against.
enum GestureReferentFusion {
    /// Turn a locked pointing candidate + its resolved surface into intent `PointingEvidence` — the
    /// `toGestureEvidence` adapter (#35). Confidence is the candidate's (calibrated upstream); the
    /// strategy carries the calibration-fit quality so the resolver can weigh it. No cursor here:
    /// the wrist-ray cursor is a separate evidence entry (see `referent`), matching the desktop,
    /// where a locked referent carried only its surface.
    static func toGestureEvidence(
        _ candidate: Contracts.PointingCandidate,
        _ surface: Contracts.SurfaceSnapshot
    ) -> Contracts.PointingEvidence {
        Contracts.PointingEvidence(
            source: .gesture,
            confidence: candidate.confidence,
            strategy: "wrist-ray-calibrated:\(candidate.calibrationQuality.rawValue)",
            surface: surface,
            cursor: nil)
    }

    /// Best-effort audit snapshot for the display/surface a referent resolved to — the
    /// `displaySurfaceSnapshot` helper. The candidate's `targetId` is a pointable-surface id; match
    /// it to the live surfaces for the title, falling back to the id itself when unknown. While
    /// each monitor is itself the pointable surface (pre-area:desktop), `app` is "Display".
    static func displaySurfaceSnapshot(
        _ targetId: String,
        _ surfaces: [Contracts.Surface]
    ) -> Contracts.SurfaceSnapshot {
        let match = surfaces.first { $0.id == targetId }
        return Contracts.SurfaceSnapshot(
            id: targetId,
            title: match?.title ?? "Display \(targetId)",
            app: "Display",
            pid: nil,
            windowId: nil,
            availability: .available,
            accessStatus: .accessible)
    }

    /// Derive the gesture contribution from one `ReferentLoop` frame:
    ///   • A locked referent (FSM phase `locked` with a candidate) → `toGestureEvidence`, so a held
    ///     point reaches the intent as the deictic "point" channel.
    ///   • The wrist-ray cursor, present whenever a hand is (`reliability > 0` — the loop sets a
    ///     positive per-frame fusion weight only when a hand is detected), so even an un-locked hand
    ///     contributes a positional cue. The point is the 1€-smoothed screen-space pointer.
    /// Returns an empty referent when there is neither a lock nor a hand.
    static func referent(
        from result: ReferentLoopResult,
        surfaces: [Contracts.Surface]
    ) -> GestureReferent {
        var evidence: Contracts.PointingEvidence?
        if result.state.phase == .locked, let candidate = result.state.candidate {
            evidence = toGestureEvidence(candidate, displaySurfaceSnapshot(candidate.targetId, surfaces))
        }

        let cursor: Contracts.PointingEvidence.Cursor? = result.reliability > 0
            ? Contracts.PointingEvidence.Cursor(x: result.point.x, y: result.point.y)
            : nil

        return GestureReferent(evidence: evidence, cursor: cursor)
    }
}
