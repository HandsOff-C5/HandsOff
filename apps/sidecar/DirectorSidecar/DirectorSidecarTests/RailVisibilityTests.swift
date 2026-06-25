//
//  RailVisibilityTests.swift
//  DirectorSidecarTests
//
//  The Right-edge rail is the Home Dashboard's minimized edge echo, so it must stay hidden whenever
//  Home is open — at launch the user sees only the dashboard. These lock that gating: agents +
//  listening alone never show the rail while Home is open; closing Home brings it back.
//

import Testing
import Foundation
@testable import DirectorSidecar

private func session(_ id: String, _ status: ExecutionStatus) -> SupervisionSession {
    SupervisionSession(id: id, status: status, startedAt: "2026-06-25T18:00:00.000Z",
                       updatedAt: "t", finishedAt: nil, title: "Task", agentLabel: "Claude Code")
}

@MainActor
@Test func railHiddenAtLaunchEvenWithRunningAgents() {
    let rail = RailModel()
    rail.setConnection(.connected)
    rail.apply(.sessions(SessionsPayload(sessions: [session("a", .running)], counts: nil)))
    // homeIsOpen defaults to true (dashboard opens on launch) → rail stays down.
    #expect(!rail.isVisible)
}

@MainActor
@Test func railShowsOnceHomeClosesWithAgents() {
    let rail = RailModel()
    rail.setConnection(.connected)
    rail.apply(.sessions(SessionsPayload(sessions: [session("a", .running)], counts: nil)))
    rail.setHomeOpen(false)
    #expect(rail.isVisible)
    rail.setHomeOpen(true)
    #expect(!rail.isVisible)
}

@MainActor
@Test func listeningNeverShowsRailWhileHomeOpen() {
    let rail = RailModel()
    rail.setListening(true)
    #expect(!rail.isVisible)          // Home open
    rail.setHomeOpen(false)
    #expect(rail.isVisible)           // Home closed → LIVE pip rail returns
}

@MainActor
@Test func railStaysHiddenWhenHomeClosedButNothingToShow() {
    let rail = RailModel()
    rail.setHomeOpen(false)
    #expect(!rail.isVisible)          // no agents, not listening
}
