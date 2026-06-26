//
//  SupervisionStores.swift
//  DirectorSidecar
//
//  Port of @handsoff/supervision session-store.ts (`createSupervisionSessionStore`) and
//  audit/action-store.ts (`createActionAuditStore`). The controller held these behind
//  `useRef(create…())` — a single mutable, identity-stable instance per controller — so they are
//  reference types here (a `@MainActor final class`), created once and owned by `VoiceCuaLoop`.
//
//  Faithful divergence: the TS audit store re-parses every event through `safeParseSupervisionAuditEvent`
//  (it accepts `unknown`). The Swift loop only ever records already-typed `Contracts.SupervisionAuditEvent`
//  values it constructs in-memory, so the boundary re-validation is unnecessary — the type system is
//  the validation. The drift-loud decode still guards anything that arrives as JSON (the audit decode tests).
//

import Foundation

/// `TerminalSessionStatus` = `ExecutionStatus` minus the live `queued`/`running` (session-store.ts).
/// The loop only finishes a session as one of these; `Contracts.terminalSessionStatuses` lists them.
typealias TerminalSessionStatus = ExecutionStatus

/// `createSupervisionSessionStore`: an in-memory list of supervised runs with stable `session-N` ids.
@MainActor
final class SupervisionSessionStore {
    private var nextId = 1
    private var sessions: [Contracts.SupervisionSession] = []

    /// `start`: a new `queued` session stamped at `startedAt`.
    func start(_ startedAt: String) -> Contracts.SupervisionSession {
        let session = Contracts.SupervisionSession(
            id: "session-\(nextId)", status: .queued,
            startedAt: startedAt, updatedAt: startedAt, finishedAt: nil)
        nextId += 1
        sessions.append(session)
        return session
    }

    /// `run`: transition the session to `running`, bumping `updatedAt`.
    @discardableResult
    func run(_ id: String, _ updatedAt: String) -> Contracts.SupervisionSession {
        update(id) { session in
            Contracts.SupervisionSession(
                id: session.id, status: .running,
                startedAt: session.startedAt, updatedAt: updatedAt, finishedAt: session.finishedAt)
        }
    }

    /// `finish`: terminal transition; sets `finishedAt` and the final status.
    @discardableResult
    func finish(_ id: String, _ status: TerminalSessionStatus, _ finishedAt: String) -> Contracts.SupervisionSession {
        update(id) { session in
            Contracts.SupervisionSession(
                id: session.id, status: status,
                startedAt: session.startedAt, updatedAt: finishedAt, finishedAt: finishedAt)
        }
    }

    func list() -> [Contracts.SupervisionSession] { sessions }

    /// Immutable update-in-place: replace the matching session with `change`'s result. An unknown
    /// id is a programmer error (the loop only updates a session it started), matching the TS throw.
    @discardableResult
    private func update(
        _ id: String,
        _ change: (Contracts.SupervisionSession) -> Contracts.SupervisionSession
    ) -> Contracts.SupervisionSession {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("Unknown supervision session: \(id)")
        }
        let updated = change(sessions[index])
        sessions[index] = updated
        return updated
    }
}

/// `createActionAuditStore`: the append-only Intention Log, queryable by session or action.
@MainActor
final class ActionAuditStore {
    private var records: [Contracts.SupervisionAuditEvent] = []

    @discardableResult
    func record(_ event: Contracts.SupervisionAuditEvent) -> Contracts.SupervisionAuditEvent {
        records.append(event)
        return event
    }

    func list() -> [Contracts.SupervisionAuditEvent] { records }

    func forSession(_ sessionId: String) -> [Contracts.SupervisionAuditEvent] {
        records.filter { $0.sessionId == sessionId }
    }

    func forAction(_ actionId: String) -> [Contracts.SupervisionAuditEvent] {
        records.filter { $0.actionId == actionId }
    }
}

extension Contracts.SupervisionAuditEvent {
    /// The shared `Base` every audit case carries (every event links a session + action).
    var base: Base {
        switch self {
        case let .intentCreated(base, _),
             let .approvalDecided(base, _),
             let .cuaStateCaptured(base, _, _, _),
             let .cuaCall(base, _, _, _),
             let .toolCall(base, _),
             let .executionFinished(base, _, _):
            return base
        }
    }

    /// The session this event belongs to (the audit store's `forSession` key).
    var sessionId: String { base.sessionId }
    /// The action this event belongs to (the audit store's `forAction` key).
    var actionId: String { base.actionId }
}
