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

    /// Inspector body state (the trust anchor), bound to the selected session's intent.
    enum InspectorState: Equatable, Sendable {
        case empty
        case ready(ResolvedIntentLite)
        case blocked(String)
        case clarification(String)
    }

    private(set) var sessions: [SessionVM] = []
    private(set) var counts = SessionCounts(running: 0, needsGreenlight: 0, done: 0)
    private(set) var readiness: ReadinessLevel = .attention
    private(set) var loadState: LoadState = .connecting
    private(set) var selectedIntent: ResolvedIntentLite?
    private(set) var selectedRunResult: ExecutionStatus?
    /// H4: the live Intention Log (every tool call, derived risk, approval state, result) the
    /// "Agent Logs" view renders — fed by the `audit` topic, scoped to the current goal's session.
    private(set) var auditLog: [AuditLogEntry] = []
    var filter: Filter = .all
    var selectedSessionId: String?

    /// The command sink (set by the app) — for selectSession / greenlight / reject. In-process
    /// `LoopEngine` after ADR 0005 Track D (greenlight → loop.approve, reject → loop.reject).
    @ObservationIgnored var bridge: (any CommandSink)?
    @ObservationIgnored private var connected = false

    var filteredSessions: [SessionVM] { Self.filtered(sessions, filter) }

    /// Inspector body — empty until a session is selected and its intent arrives.
    var inspectorState: InspectorState {
        guard selectedSessionId != nil, let intent = selectedIntent else { return .empty }
        switch intent.status {
        case .ready: return .ready(intent)
        case .blocked: return .blocked(intent.reason ?? "Blocked")
        case .clarificationRequired: return .clarification(intent.reason ?? "Needs clarification")
        }
    }

    /// Greenlight/Reject footer — approval-required risk AND not yet executed.
    var showInspectorFooter: Bool {
        guard case let .ready(intent) = inspectorState else { return false }
        return intent.riskLevel?.requiresApproval == true && selectedRunResult == nil
    }

    // MARK: frame application

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .sessions(payload):
            sessions = payload.sessions.map(SessionVM.init)
            counts = payload.resolvedCounts
            recomputeLoadState()
        case let .runResult(result):
            applyRunResult(result)
        case let .intent(intent):
            selectedIntent = intent
            selectedRunResult = nil
        case let .audit(payload):
            auditLog = payload.entries
        case let .state(topic, readiness):
            if topic == "readiness", let readiness {
                self.readiness = BridgeStore.readinessLevel(for: readiness.capabilities)
                recomputeLoadState()
            }
        case .cursor, .transcript, .referents, .gaze, .error, .unknown:
            break
        }
    }

    func setConnection(_ state: ConnectionState) {
        connected = state == .connected
        recomputeLoadState()
    }

    /// Select a session → bind the Inspector and ask the engine to (re)publish its intent.
    func select(_ id: String?) {
        selectedSessionId = id
        selectedIntent = nil
        selectedRunResult = nil
        if let id { send(.selectSession(id)) }
    }

    func greenlight(now: Date = Date()) {
        guard case let .ready(intent) = inspectorState, intent.riskLevel?.requiresApproval == true,
              let actionId = intent.id else { return }
        send(.greenlight(actionId: actionId, decidedAt: Self.iso(now)))
    }

    func reject(now: Date = Date()) {
        if case let .ready(intent) = inspectorState, let actionId = intent.id {
            send(.reject(actionId: actionId, decidedAt: Self.iso(now)))
        }
        selectedRunResult = .rejected
    }

    private func send(_ command: Command) {
        guard let bridge else { return }
        Task { await bridge.send(command) }
    }

    private func recomputeLoadState() {
        loadState = Self.loadState(sessionCount: sessions.count, connected: connected, readiness: readiness)
    }

    private nonisolated static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func applyRunResult(_ result: RunResultPayload) {
        if result.sessionId == selectedSessionId { selectedRunResult = result.status }
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

    nonisolated static func loadState(sessionCount: Int, connected: Bool, readiness: ReadinessLevel) -> LoadState {
        if !connected { return .error }
        if readiness == .blocked { return .denied }
        return sessionCount == 0 ? .empty : .loaded
    }
}
