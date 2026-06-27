//
//  HeadPointingIntake.swift
//  DirectorSidecar
//
//  The migration step that makes head/face tracking REACH the intent, not just the overlay cursor.
//  Port of the head path of apps/desktop/src/features/voice-cua/buildPointingEvidence.ts: at goal
//  start, fold the live head point + the windows it falls in/near (ranked by AttentionRegion) into
//  the loop's initial `IntentInput` as `head` PointingEvidence + candidate surfaces, so the
//  next-tool-call resolver can target the window the user is LOOKING at.
//
//  This replaces `SpeechOnlyIntake` (the no-pointing stub) as the app's intake. The head signal is
//  wired in full, and the HAND-gesture lane folds in alongside it (the ported `ReferentLoop` output,
//  via `GestureSnapshot`/`GestureReferentFusion`) — combinatively, not as a priority hierarchy,
//  exactly as buildPointingEvidence combined both. One sibling modality remains its own track and is
//  intentionally NOT folded in here: the temporal multi-deictic binder (U6/U7). Its pure core now
//  exists — `TemporalBinder` (Binding/TemporalBinder.swift) plus the `CaptureTraceRecorder`
//  (Binding/CaptureTrace.swift) that records the head/hand/word trace it consumes — but they are
//  landed-but-unwired: this snapshot intake still folds only the instantaneous head point, not a
//  per-word binding. Wiring the capture hotkey → recorder → binder into the goal-start intake (the
//  buildPointingEvidence.ts:51-60,136-139 path) is the remaining step.
//

import Foundation
import OSLog

/// The latest head point, shared between the head-pointer event consumer (writer — ServiceCoordinator
/// on the main actor) and the intent intake (reader — the loop at goal start). Lock-protected so it
/// is `Sendable` without binding either side to a specific actor, the same self-synchronized pattern
/// `HeadPointerService` uses for its cross-queue state.
///
/// The point is deliberately NOT cleared when tracking stops: the camera stops the instant the user
/// releases the push-to-talk key, but intent resolution reads this ~1.5s later (the loop's retarget
/// grace), so the point captured DURING the utterance must survive the stop to ground the deixis.
/// Faithful to useHeadPointing.ts, which likewise kept the last point across a `stop`. While sensing
/// is on the camera streams at 30fps, so the read is effectively live; the only stale read is a goal
/// somehow started with the camera off, where a slightly old look is still the best deixis available.
final class HeadPointSnapshot: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var latest: HeadPoint?

    init() {}

    func record(_ point: HeadPoint) {
        lock.lock()
        defer { lock.unlock() }
        latest = point
    }

    var current: HeadPoint? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// Pure fusion of the head signal into pointing evidence + candidate surfaces — the head branch of
/// buildPointingEvidence.ts. Pure (no driver / no camera) so it is unit-testable; the intake supplies
/// the live head point and window list.
enum HeadPointingFusion {
    struct Built: Equatable {
        let pointingEvidence: [Contracts.PointingEvidence]
        let surfaceCandidates: [Contracts.SurfaceSnapshot]
    }

    /// Build the initial pointing evidence from the gesture referent + the head point + the live
    /// windows. Combinative (every available signal, not a priority hierarchy) and in array order so
    /// the dedup below keeps the strongest surface first:
    ///   • The gesture branch LEADS — a locked gesture referent is the strongest target signal, so
    ///     its surface wins the dedup. Mirrors buildPointingEvidence's `gesture` push + the
    ///     `wrist-ray-position` cursor entry (added when no locked referent already carries a cursor).
    ///   • `face-tracker-position` — the head cursor as a fixed-0.5-confidence positional cue.
    ///   • `head-neighborhood` (one per ranked candidate) — the window the point fell in/near, its
    ///     closeness `score` carried as the pointing confidence so `candidateSurfaces` ranks it.
    ///   • `head-neighborhood-empty` — a 0-confidence marker when a head point exists but no window
    ///     is in its neighborhood, so the resolver still sees that a face was tracked.
    /// With NO gesture and NO head signal at all, fall back to the active window as a cursor cue so
    /// tick 0 still carries a candidate surface (the loop also grounds on the active window every
    /// later tick).
    static func build(
        head: HeadPoint?,
        windows: [CuaWindow],
        gesture: GestureReferent? = nil,
        perceptionTarget: (surface: Contracts.SurfaceSnapshot, confidence: Double)? = nil,
        radius: Double = AttentionRanking.defaultRadius
    ) -> Built {
        var evidence: [Contracts.PointingEvidence] = []

        // Perception NBest branch (#150): the live `PerceptionBus` continuously ranks the bias-
        // corrected hit against the driver window set and `PointingAligner` fuses the modalities into
        // ONE top window. When present it LEADS the candidate list as a `point-to-window` referent, so
        // the resolved window the user is pointing at wins the dedup over the coarser head-neighborhood
        // and display surfaces. Absent (no live bus / no window under the hit) the head/gesture path
        // below is unchanged — this is purely additive.
        if let perceptionTarget {
            evidence.append(Contracts.PointingEvidence(
                source: .gesture, confidence: perceptionTarget.confidence, strategy: "point-to-window",
                surface: perceptionTarget.surface, cursor: nil))
        }

        // Gesture branch (buildPointingEvidence lines 83-96): the locked referent leads, then the
        // wrist-ray cursor position (even without a lock). The cursor entry is skipped when a locked
        // referent already carries a cursor — faithful to the desktop's `!gesture || !gesture.cursor`.
        if let gesture {
            if let locked = gesture.evidence {
                evidence.append(locked)
            }
            if let cursor = gesture.cursor, gesture.evidence == nil || gesture.evidence?.cursor == nil {
                evidence.append(Contracts.PointingEvidence(
                    source: .gesture,
                    confidence: gesture.evidence?.confidence ?? 0.3,
                    strategy: "wrist-ray-position",
                    surface: nil,
                    cursor: cursor))
            }
        }

        if let head {
            let cursor = Contracts.PointingEvidence.Cursor(x: head.x, y: head.y)
            evidence.append(Contracts.PointingEvidence(
                source: .head, confidence: 0.5, strategy: "face-tracker-position",
                surface: nil, cursor: cursor))

            // Two cooperating rankers, ONE answer (no stacking): when the perception aligner already
            // resolved a leading window (`perceptionTarget`), it IS the point→window answer, so the
            // AttentionRanking head-neighborhood is SUPPRESSED. AttentionRanking is the FALLBACK ranker,
            // run only when the aligner had nothing — so the two never stack competing candidate lists.
            // TODO CONVERGENCE: NBestCluster (ours) and AttentionRanking (theirs) are two rankers doing
            // the same job over the same window source — collapse to one in a later cleanup.
            if perceptionTarget == nil {
                let candidates = AttentionRanking.rank(point: head, windows: windows, radius: radius)
                for candidate in candidates {
                    evidence.append(Contracts.PointingEvidence(
                        source: .head, confidence: candidate.score, strategy: "head-neighborhood",
                        surface: candidate.surface, cursor: cursor))
                }
                if candidates.isEmpty {
                    evidence.append(Contracts.PointingEvidence(
                        source: .head, confidence: 0, strategy: "head-neighborhood-empty",
                        surface: nil, cursor: cursor))
                }
            }
        }

        // No gesture AND no head signal → fall back to the active window as a cursor cue
        // (buildPointingEvidence's active-window fallback, reached only when the combined evidence is
        // still empty). Empty only when the driver reported no windows, in which case the loop still
        // grounds on its own per-tick observation, exactly as the speech-only path did.
        if evidence.isEmpty, let active = windows.first(where: \.focused) ?? windows.first {
            evidence.append(Contracts.PointingEvidence(
                source: .cursor, confidence: 1, strategy: "active-window-current-cursor",
                surface: active.surface, cursor: nil))
        }

        return Built(pointingEvidence: evidence, surfaceCandidates: dedupeSurfaces(evidence))
    }

    /// The deduplicated surfaces referenced by the evidence, in first-seen order — the controller's
    /// `surfaceCandidates` derivation (strongest evidence leads, so the kept candidate is the best).
    private static func dedupeSurfaces(_ evidence: [Contracts.PointingEvidence]) -> [Contracts.SurfaceSnapshot] {
        var seen = Set<String>()
        var surfaces: [Contracts.SurfaceSnapshot] = []
        for item in evidence {
            guard let surface = item.surface, !seen.contains(surface.id) else { continue }
            seen.insert(surface.id)
            surfaces.append(surface)
        }
        return surfaces
    }
}

/// The production intake: fold the live head point + the windows it points at into the loop's initial
/// `IntentInput`. Holds the shared head-point snapshot (updated by the head-pointer consumer) and the
/// loop driver (read to get the live window geometry the head point is ranked against). Swapped in
/// for `SpeechOnlyIntake` at the app's composition root.
struct HeadPointingIntake: IntentIntake {
    let snapshot: HeadPointSnapshot
    let driver: any CuaLoopDriver
    /// The on-screen window list the point→window ranking runs against. The LIVE source is NATIVE
    /// (`NativeWindowSource.onScreenWindows`, CGWindowList) so targeting does NOT depend on the
    /// cua-driver (#150/#148 — the driver returns empty in the bundled app). A closure (matching
    /// `PerceptionService.windowSource`) so the composition root injects native + driver-fallback and
    /// tests feed fixtures. Optional for back-compat: when nil the legacy `driver.listWindows()` path
    /// is used (existing tests).
    var windowSource: (() async -> [CuaWindow])? = nil
    /// The hand-gesture lane's latest referent/cursor (the ported `ReferentLoop` output, recorded by
    /// the live gesture consumer). Optional so the head-only path and tests stay unchanged; when nil
    /// no gesture branch is folded in.
    var gesture: GestureSnapshot? = nil
    /// The perception NBest consumer (#150): the live fused "what is the user pointing at" answer.
    /// Optional so the legacy head/gesture path and tests stay unchanged; when nil no perception
    /// branch is folded in. Paired with `screen` to resolve the ranked id back to a real surface.
    var aligner: PointingAligner? = nil
    var screen: ScreenSnapshotProvider? = nil
    /// Confidence the resolved point-to-window referent leads with (#150 U1 — gesture weight 0.9).
    var perceptionConfidence: Double = 0.9
    var radius: Double = AttentionRanking.defaultRadius

    func makeInput(
        for finalTranscript: Contracts.FinalTranscript,
        sessionId: String
    ) async -> Contracts.IntentInput {
        // Windows from the NATIVE source (#150) when wired; else the legacy driver path (back-compat).
        let windows: [CuaWindow]
        if let windowSource {
            windows = await windowSource()
        } else if case let .succeeded(value) = await driver.listWindows() {
            windows = value
        } else {
            windows = []
        }
        let gestureReferent = gesture?.current

        // Resolve the perception aligner's fused top window back to a real surface (id → driver
        // window). Nil unless the live bus ranked a window under the bias-corrected hit.
        var perceptionTarget: (surface: Contracts.SurfaceSnapshot, confidence: Double)? = nil
        if let aligner, let screen, let top = aligner.top(), let win = screen.surface(forId: top.id) {
            perceptionTarget = (win.surface, perceptionConfidence)
        }

        let built = HeadPointingFusion.build(
            head: snapshot.current, windows: windows, gesture: gestureReferent,
            perceptionTarget: perceptionTarget, radius: radius)
        DirectorDiagnostics.loop.info(
            "intake head=\(snapshot.current != nil, privacy: .public) gesture=\(gestureReferent?.isEmpty == false, privacy: .public) pointToWindow=\(perceptionTarget != nil, privacy: .public) windows=\(windows.count, privacy: .public) evidence=\(built.pointingEvidence.count, privacy: .public) candidates=\(built.surfaceCandidates.count, privacy: .public)")
        return Contracts.IntentInput(
            sessionId: sessionId,
            finalTranscript: finalTranscript,
            pointingEvidence: built.pointingEvidence,
            surfaceCandidates: built.surfaceCandidates,
            goalSession: nil)
    }
}
