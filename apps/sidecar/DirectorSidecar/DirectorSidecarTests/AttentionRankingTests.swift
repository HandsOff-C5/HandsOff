//
//  AttentionRankingTests.swift
//  DirectorSidecarTests
//
//  The recreated head-pointing attention-region ranker (AttentionRanking). Ports the SAME cases the
//  original ranker shipped with — apps/desktop/src-tauri/src/commands/head_track/candidates.rs and
//  @handsoff/intent src/attention/candidates.ts — so the Swift recreation ranks identically: a
//  radius-bounded neighborhood, the `1 - distance/radius` score, and the score↓ → distance↑ →
//  zIndex↓ → id↑ tie-break, plus the rankability gate (available + accessible + not cua-driver +
//  measured bounds).
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Builders

private func bounds(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CuaWindowBounds {
    CuaWindowBounds(x: x, y: y, width: width, height: height)
}

private func window(
    _ id: String,
    _ bounds: CuaWindowBounds?,
    zIndex: Int = 0,
    app: String = "Codex",
    availability: Contracts.SurfaceAvailability = .available,
    accessStatus: Contracts.SurfaceAccessStatus = .accessible
) -> CuaWindow {
    CuaWindow(
        id: id, title: id, app: app, pid: 42, windowId: 7,
        availability: availability, accessStatus: accessStatus, focused: false,
        bounds: bounds, zIndex: zIndex)
}

private func head(_ x: Double, _ y: Double) -> HeadPoint {
    HeadPoint(x: x, y: y, yaw: nil, pitch: nil, confidence: 1, ts: 0)
}

// MARK: - Tests

struct AttentionRankingTests {
    // Port of candidates.rs `ranks_accessible_windows_by_distance_then_z_index`: two equidistant
    // windows tie on score+distance, so the higher zIndex wins the order.
    @Test func ranksAccessibleWindowsByDistanceThenZIndex() {
        let candidates = AttentionRanking.rank(
            point: head(100, 100),
            windows: [
                window("a:1", bounds(0, 200, 100, 100), zIndex: 1),
                window("b:2", bounds(200, 0, 100, 100), zIndex: 2),
                window("outside:3", bounds(251, 0, 100, 100), zIndex: 3),
            ],
            radius: 100)

        #expect(candidates.map(\.surface.id) == ["b:2", "a:1"])
        #expect(candidates[0].score == 0)        // exactly at the radius edge → score 0
        #expect(candidates[0].distance == 100)
    }

    // Port of candidates.rs `returns_empty_candidates_when_no_window_is_in_the_neighborhood`.
    @Test func emptyWhenNoWindowInNeighborhood() {
        let candidates = AttentionRanking.rank(
            point: head(0, 0),
            windows: [window("far:1", bounds(500, 500, 100, 100))],
            radius: 100)

        #expect(candidates.isEmpty)
    }

    // A point inside a window is distance 0 → the strongest possible score (1).
    @Test func scoresPointInsideWindowAsOne() {
        let candidates = AttentionRanking.rank(
            point: head(150, 150),
            windows: [window("inside:1", bounds(100, 100, 200, 200))])

        #expect(candidates.count == 1)
        #expect(candidates[0].surface.id == "inside:1")
        #expect(candidates[0].distance == 0)
        #expect(candidates[0].score == 1)
    }

    // The rankability gate drops minimized, AX-restricted, cua-driver, and zero/absent-bounds windows
    // BEFORE ranking — only the genuinely pointable window survives.
    @Test func dropsUnrankableWindows() {
        let candidates = AttentionRanking.rank(
            point: head(150, 150),
            windows: [
                window("ok:1", bounds(100, 100, 200, 200)),
                window("minimized:2", bounds(100, 100, 200, 200), availability: .minimized),
                window("restricted:3", bounds(100, 100, 200, 200), accessStatus: .restricted),
                window("cua:4", bounds(100, 100, 200, 200), app: "CUA Driver"),
                window("zero:5", bounds(150, 150, 0, 0)),
                window("nobounds:6", nil),
            ])

        #expect(candidates.map(\.surface.id) == ["ok:1"])
    }

    // A non-positive radius is a disabled neighborhood — nothing ranks (matches candidates.rs/.ts).
    @Test func nonPositiveRadiusRanksNothing() {
        let candidates = AttentionRanking.rank(
            point: head(150, 150),
            windows: [window("inside:1", bounds(100, 100, 200, 200))],
            radius: 0)

        #expect(candidates.isEmpty)
    }
}
