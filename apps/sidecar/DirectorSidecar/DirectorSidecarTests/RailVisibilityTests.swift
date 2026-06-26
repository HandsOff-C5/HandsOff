//
//  RailVisibilityTests.swift
//  DirectorSidecarTests
//
//  The Right-edge rail is the listening surface (Wispr-style): it appears only while Director is
//  actively listening (fn held) AND the Home Dashboard is closed. Running agents alone never summon
//  it; closing Home shows nothing until fn is held. These lock that exact gate.
//

import Testing
import Foundation
@testable import DirectorSidecar

private func session(_ id: String, _ status: ExecutionStatus) -> SupervisionSession {
    SupervisionSession(id: id, status: status, startedAt: "2026-06-25T18:00:00.000Z",
                       updatedAt: "t", finishedAt: nil, title: "Task", agentLabel: "Claude Code")
}

@MainActor
@Test func railHiddenAtLaunchWithRunningAgents() {
    let rail = RailModel()
    rail.setConnection(.connected)
    rail.apply(.sessions(SessionsPayload(sessions: [session("a", .running)], counts: nil)))
    // homeIsOpen defaults true (dashboard opens on launch), not listening → rail down.
    #expect(!rail.isVisible)
}

@MainActor
@Test func closingHomeWithAgentsButNotListeningShowsNothing() {
    let rail = RailModel()
    rail.setConnection(.connected)
    rail.apply(.sessions(SessionsPayload(sessions: [session("a", .running)], counts: nil)))
    rail.setHomeOpen(false)
    // Home closed + agents running but NOT listening → still nothing (only the menu-bar item).
    #expect(!rail.isVisible)
}

@MainActor
@Test func railAppearsOnlyWhileListeningWithHomeClosed() {
    let rail = RailModel()
    rail.setHomeOpen(false)
    rail.setListening(true)
    #expect(rail.isVisible)           // fn held, Home closed → the LIVE waveform rail
    rail.setListening(false)
    #expect(!rail.isVisible)          // fn released → gone
}

@MainActor
@Test func listeningWhileHomeOpenStaysHidden() {
    let rail = RailModel()
    rail.setListening(true)           // homeIsOpen still true
    #expect(!rail.isVisible)
    rail.setHomeOpen(false)
    #expect(rail.isVisible)           // only once Home is closed
}

@MainActor
@Test func railHiddenWhenHomeClosedAndIdle() {
    let rail = RailModel()
    rail.setHomeOpen(false)
    #expect(!rail.isVisible)          // no listening, no rail
}
