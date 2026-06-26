//
//  GestureReferentFusionTests.swift
//  DirectorSidecarTests
//
//  The hand-gesture intake fold-in — the migration step that makes the ported `ReferentLoop` reach
//  the intent. Covers the shared `GestureSnapshot` holder and the pure `GestureReferentFusion` (the
//  gesture branch of buildPointingEvidence.ts + `toGestureEvidence` + `displaySurfaceSnapshot`): a
//  `ReferentLoop` frame becomes a `GestureReferent` (locked referent + wrist-ray cursor) without a
//  camera. The end-to-end "a gesture referent reaches the resolver" assertions live alongside the
//  head ones in HeadPointingIntakeTests.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Builders

private func surface(_ id: String, _ title: String? = nil) -> Contracts.Surface {
    Contracts.Surface(
        id: id,
        bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 100, h: 100),
        displayId: id,
        title: title)
}

private func candidate(_ targetId: String, _ confidence: Double, _ quality: Contracts.CalibrationQuality = .good)
    -> Contracts.PointingCandidate {
    Contracts.PointingCandidate(targetId: targetId, confidence: confidence, calibrationQuality: quality)
}

/// A `ReferentLoopResult` with the FSM phase, candidate, point, and hand-reliability the fusion reads.
/// (`confidence`/`active`/`emit` are not read by `GestureReferentFusion`.)
private func loopResult(
    phase: Contracts.GestureState,
    candidate: Contracts.PointingCandidate?,
    point: Vec2,
    reliability: Double
) -> ReferentLoopResult {
    ReferentLoopResult(
        state: GestureMachineState(phase: phase, candidate: candidate, locked: nil),
        candidate: candidate,
        confidence: 0,
        active: phase == .locked,
        point: point,
        reliability: reliability,
        emit: nil)
}

// MARK: - Snapshot

struct GestureSnapshotTests {
    @Test func startsEmptyAndHoldsTheLatestReferent() {
        let snapshot = GestureSnapshot()
        #expect(snapshot.current == nil)

        let first = GestureReferent(cursor: Contracts.PointingEvidence.Cursor(x: 1, y: 2))
        let second = GestureReferent(
            evidence: Contracts.PointingEvidence(
                source: .gesture, confidence: 0.8, strategy: "wrist-ray-calibrated:good",
                surface: nil, cursor: nil),
            cursor: Contracts.PointingEvidence.Cursor(x: 3, y: 4))
        snapshot.record(first)
        snapshot.record(second)   // latest-wins
        #expect(snapshot.current == second)

        // Not cleared between reads — the referent locked during an utterance survives the camera
        // stop until the loop reads it ~1.5s later.
        #expect(snapshot.current == second)
    }

    @Test func emptyReferentReportsItself() {
        #expect(GestureReferent().isEmpty)
        #expect(!GestureReferent(cursor: Contracts.PointingEvidence.Cursor(x: 0, y: 0)).isEmpty)
    }
}

// MARK: - toGestureEvidence (#35 adapter)

struct GestureEvidenceAdapterTests {
    @Test func mapsLockedCandidateToGestureEvidence() {
        let evidence = GestureReferentFusion.toGestureEvidence(
            candidate("disp-1", 0.87, .fair),
            GestureReferentFusion.displaySurfaceSnapshot("disp-1", [surface("disp-1", "Left Monitor")]))

        #expect(evidence.source == .gesture)
        #expect(evidence.confidence == 0.87)
        #expect(evidence.strategy == "wrist-ray-calibrated:fair")   // calibration quality threaded through
        #expect(evidence.surface?.id == "disp-1")
        #expect(evidence.surface?.title == "Left Monitor")
        #expect(evidence.cursor == nil)   // the wrist-ray cursor is a SEPARATE entry, not on the lock
    }

    @Test func displaySurfaceSnapshotFallsBackToTheIdWhenUnknown() {
        let snap = GestureReferentFusion.displaySurfaceSnapshot("disp-2", [surface("disp-1", "Left")])
        #expect(snap.id == "disp-2")
        #expect(snap.title == "Display disp-2")   // no live surface matched → id-derived title
        #expect(snap.app == "Display")
        #expect(snap.availability == .available)
        #expect(snap.accessStatus == .accessible)
    }
}

// MARK: - referent(from:surfaces:) — the CameraPanel rAF derivation

struct GestureReferentDerivationTests {
    @Test func lockedFrameYieldsBothEvidenceAndCursor() {
        let result = loopResult(
            phase: .locked, candidate: candidate("disp-1", 0.9), point: Vec2(640, 360), reliability: 0.7)

        let referent = GestureReferentFusion.referent(from: result, surfaces: [surface("disp-1", "Main")])

        #expect(referent.evidence?.source == .gesture)
        #expect(referent.evidence?.surface?.id == "disp-1")
        #expect(referent.evidence?.confidence == 0.9)
        #expect(referent.cursor == Contracts.PointingEvidence.Cursor(x: 640, y: 360))
    }

    @Test func unlockedHandYieldsCursorButNoEvidence() {
        // A confident candidate that has NOT dwelled to a lock: cursor only, no referent (matches the
        // desktop, which emitted gesture evidence only while `phase === "locked"`).
        let result = loopResult(
            phase: .candidate, candidate: candidate("disp-1", 0.6), point: Vec2(100, 200), reliability: 0.4)

        let referent = GestureReferentFusion.referent(from: result, surfaces: [surface("disp-1")])

        #expect(referent.evidence == nil)
        #expect(referent.cursor == Contracts.PointingEvidence.Cursor(x: 100, y: 200))
    }

    @Test func noHandYieldsNothing() {
        // reliability 0 == no hand this frame → no cursor (the desktop published `null` when
        // `f.hands.length` was 0), and idle phase → no referent.
        let result = loopResult(phase: .idle, candidate: nil, point: Vec2(0, 0), reliability: 0)

        let referent = GestureReferentFusion.referent(from: result, surfaces: [surface("disp-1")])

        #expect(referent.isEmpty)
    }
}
