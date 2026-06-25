//
//  HomeDashboardModel.swift
//  DirectorSidecar
//
//  G4a Home Dashboard state (native SwiftUI — Option B; a bridge consumer like the HUD). Reads
//  sessions/runResult/readiness; the AgentCard fleet is the AI-engineer Supervise beat. SessionVM
//  is a UI model (NOT the raw contract) built by a pure mapper; the filter + load-state logic are
//  pure/nonisolated and unit-tested.
//

import Foundation
import Observation

/// UI model for an AgentCard. `title`/`agent` come from the (optional) sessions enrichment;
/// `progress` is engine-only (not client-derivable) so it is deferred.
struct SessionVM: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let agent: String
    let status: ExecutionStatus
    let startedAt: Date

    var needsGreenlight: Bool { status == .blocked }
    var isRunning: Bool { status == .running }
    var isDone: Bool { status == .succeeded || status == .failed || status == .rejected }

    init(_ session: SupervisionSession) {
        id = session.id
        title = session.title ?? "Session \(session.id)"
        agent = session.agentLabel ?? "Agent"
        status = session.status
        startedAt = BridgeStore.parseISO(session.startedAt) ?? Date(timeIntervalSince1970: 0)
    }

    init(id: String, title: String, agent: String, status: ExecutionStatus, startedAt: Date) {
        self.id = id
        self.title = title
        self.agent = agent
        self.status = status
        self.startedAt = startedAt
    }
}

@MainActor
@Observable
final class HomeDashboardModel {
    enum LoadState: Equatable, Sendable { case connecting, loaded, empty, error, denied }
    enum Filter: String, CaseIterable, Sendable { case all, running, needsYou, done }

    private(set) var sessions: [SessionVM] = []
    private(set) var counts = SessionCounts(running: 0, needsGreenlight: 0, done: 0)
    private(set) var readiness: ReadinessLevel = .attention
    private(set) var loadState: LoadState = .connecting
    var filter: Filter = .all
    var selectedSessionId: String?

    @ObservationIgnored private var connected = false

    var filteredSessions: [SessionVM] { Self.filtered(sessions, filter) }

    // MARK: frame application

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .sessions(payload):
            sessions = payload.sessions.map(SessionVM.init)
            counts = payload.resolvedCounts
            loadState = Self.loadState(sessionCount: sessions.count, connected: connected)
        case let .runResult(result):
            applyRunResult(result)
        case let .state(topic, readiness):
            if topic == "readiness", let readiness {
                self.readiness = BridgeStore.readinessLevel(for: readiness.capabilities)
            }
        case .cursor, .transcript, .referents, .intent, .gaze, .error, .unknown:
            break
        }
    }

    func setConnection(_ state: ConnectionState) {
        connected = state == .connected
        loadState = Self.loadState(sessionCount: sessions.count, connected: connected)
    }

    func select(_ id: String?) { selectedSessionId = id }

    private func applyRunResult(_ result: RunResultPayload) {
        guard let id = result.sessionId, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let existing = sessions[index]
        sessions[index] = SessionVM(id: existing.id, title: existing.title, agent: existing.agent,
                                    status: result.status, startedAt: existing.startedAt)
        counts = SessionCounts(derivingStatuses: sessions.map(\.status))
    }

    // MARK: pure logic (unit-tested)

    nonisolated static func filtered(_ sessions: [SessionVM], _ filter: Filter) -> [SessionVM] {
        switch filter {
        case .all: return sessions
        case .running: return sessions.filter(\.isRunning)
        case .needsYou: return sessions.filter(\.needsGreenlight)
        case .done: return sessions.filter(\.isDone)
        }
    }

    nonisolated static func loadState(sessionCount: Int, connected: Bool) -> LoadState {
        if !connected { return .error }
        return sessionCount == 0 ? .empty : .loaded
    }
}
