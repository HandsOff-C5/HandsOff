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
//  This replaces `SpeechOnlyIntake` (the no-pointing stub) as the app's intake. Two sibling pointing
//  modalities remain their own tracks and are intentionally NOT folded in here: hand gesture
//  (MediaPipe, unported to Swift) and the temporal multi-deictic binder (U6/U7 — needs a head/word
//  capture-trace recorder that Swift does not record yet; HeadPointerService emits instantaneous
//  points, not a trace). The head signal itself is wired in full.
//

import Foundation

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

    /// Build the initial pointing evidence from the head point + the live windows. Mirrors the head
    /// branches of buildPointingEvidence, in array order so the dedup below keeps the strongest
    /// surface first:
    ///   • `face-tracker-position` — the head cursor as a fixed-0.5-confidence positional cue.
    ///   • `head-neighborhood` (one per ranked candidate) — the window the point fell in/near, its
    ///     closeness `score` carried as the pointing confidence so `candidateSurfaces` ranks it.
    ///   • `head-neighborhood-empty` — a 0-confidence marker when a head point exists but no window
    ///     is in its neighborhood, so the resolver still sees that a face was tracked.
    /// With no head point at all, fall back to the active window as a cursor cue so tick 0 still
    /// carries a candidate surface (the loop also grounds on the active window every later tick).
    static func build(
        head: HeadPoint?,
        windows: [CuaWindow],
        radius: Double = AttentionRanking.defaultRadius
    ) -> Built {
        var evidence: [Contracts.PointingEvidence] = []

        if let head {
            let cursor = Contracts.PointingEvidence.Cursor(x: head.x, y: head.y)
            evidence.append(Contracts.PointingEvidence(
                source: .head, confidence: 0.5, strategy: "face-tracker-position",
                surface: nil, cursor: cursor))

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

        // No head signal → fall back to the active window as a cursor cue (buildPointingEvidence's
        // active-window fallback). Empty only when the driver reported no windows, in which case the
        // loop still grounds on its own per-tick observation, exactly as the speech-only path did.
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
    var radius: Double = AttentionRanking.defaultRadius

    func makeInput(
        for finalTranscript: Contracts.FinalTranscript,
        sessionId: String
    ) async -> Contracts.IntentInput {
        let windows: [CuaWindow]
        if case let .succeeded(value) = await driver.listWindows() {
            windows = value
        } else {
            windows = []
        }
        let built = HeadPointingFusion.build(head: snapshot.current, windows: windows, radius: radius)
        DirectorDiagnostics.loop.info(
            "head intake head=\(snapshot.current != nil, privacy: .public) windows=\(windows.count, privacy: .public) evidence=\(built.pointingEvidence.count, privacy: .public) candidates=\(built.surfaceCandidates.count, privacy: .public)")
        return Contracts.IntentInput(
            sessionId: sessionId,
            finalTranscript: finalTranscript,
            pointingEvidence: built.pointingEvidence,
            surfaceCandidates: built.surfaceCandidates,
            goalSession: nil)
    }
}
