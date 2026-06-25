//
//  G4aDashboardTests.swift
//  DirectorSidecarTests
//
//  G4a Home Dashboard logic: SessionVM mapping + flags, the filter (All/Running/Needs-you/Done),
//  load-state derivation, and the fleet reducer (≥2 cards, runResult flip).
//

import Testing
import Foundation
@testable import DirectorSidecar

private func session(_ id: String, _ status: ExecutionStatus, title: String? = nil, agentLabel: String? = nil) -> SupervisionSession {
    SupervisionSession(id: id, status: status, startedAt: "2026-06-24T18:00:00.000Z",
                       updatedAt: "t", finishedAt: nil, title: title, agentLabel: agentLabel)
}

@Test func sessionVMMapsEnrichmentAndFlags() {
    let vm = SessionVM(SupervisionSession(id: "s1", status: .blocked, startedAt: "2026-06-24T18:00:00.000Z", updatedAt: "t", finishedAt: nil, title: "Delete tmp", agentLabel: "Claude Code"))
    #expect(vm.title == "Delete tmp")
    #expect(vm.agent == "Claude Code")
    #expect(vm.needsGreenlight) // blocked
    #expect(!vm.isRunning)
}

@Test func filterPartitionsTheFleet() {
    let fleet = [
        SessionVM(id: "a", title: "A", agent: "Claude Code", status: .running, startedAt: .now),
        SessionVM(id: "b", title: "B", agent: "Cursor", status: .blocked, startedAt: .now),
        SessionVM(id: "c", title: "C", agent: "Claude Code", status: .succeeded, startedAt: .now),
    ]
    #expect(HomeDashboardModel.filtered(fleet, .all).count == 3)
    #expect(HomeDashboardModel.filtered(fleet, .running).map(\.id) == ["a"])
    #expect(HomeDashboardModel.filtered(fleet, .needsYou).map(\.id) == ["b"])
    #expect(HomeDashboardModel.filtered(fleet, .done).map(\.id) == ["c"])
}

@Test func loadStateReflectsConnectionAndCount() {
    #expect(HomeDashboardModel.loadState(sessionCount: 0, connected: false) == .error)
    #expect(HomeDashboardModel.loadState(sessionCount: 0, connected: true) == .empty)
    #expect(HomeDashboardModel.loadState(sessionCount: 2, connected: true) == .loaded)
}

@MainActor
@Test func fleetRendersAndRunResultFlipsCard() {
    let model = HomeDashboardModel()
    model.setConnection(.connected)
    model.apply(.sessions(SessionsPayload(sessions: [
        session("a", .running, title: "Refactor auth"),
        session("b", .running, title: "Fix test"),
    ], counts: nil)))
    #expect(model.sessions.count == 2)
    #expect(model.loadState == .loaded)
    #expect(model.counts.running == 2)

    model.apply(.runResult(RunResultPayload(status: .succeeded, sessionId: "b")))
    #expect(model.sessions.first { $0.id == "b" }?.status == .succeeded)
    #expect(model.counts.running == 1)
    #expect(model.counts.done == 1)
    #expect(HomeDashboardModel.filtered(model.sessions, .done).map(\.id) == ["b"])
}

@MainActor
@Test func emptyFleetWhenConnectedShowsEmptyState() {
    let model = HomeDashboardModel()
    model.setConnection(.connected)
    model.apply(.sessions(SessionsPayload(sessions: [], counts: nil)))
    #expect(model.loadState == .empty)
}
