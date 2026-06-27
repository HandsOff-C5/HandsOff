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

struct SupervisionReplaySnapshot: Codable, Sendable, Equatable {
    var nextSessionId = 1
    var sessions: [Contracts.SupervisionSession] = []
    var sessionTitles: [String: String] = [:]
    var auditRecords: [SupervisionReplayRecord] = []
}

struct SupervisionReplayRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let entry: AuditLogEntry
    let transcript: String?
    let referent: Contracts.SelectedReferent?
    let planSummary: String?
    let resultSummary: String?

    init(event: Contracts.SupervisionAuditEvent, ordinal: Int) {
        entry = LoopFrameMapping.auditEntry(event, ordinal: ordinal)
        id = entry.id

        switch event {
        case let .intentCreated(_, intent):
            let replay = Self.intentReplay(intent)
            transcript = replay.transcript
            referent = replay.referent
            planSummary = replay.planSummary
            resultSummary = nil
        case let .toolCall(_, call):
            transcript = call.transcript
            referent = call.referent
            planSummary = nil
            resultSummary = LoopFrameMapping.actionResultSummary(call.result)
        case let .cuaCall(_, _, _, result), let .executionFinished(_, _, .some(result)):
            transcript = nil
            referent = nil
            planSummary = nil
            resultSummary = LoopFrameMapping.actionResultSummary(result)
        case .approvalDecided, .cuaStateCaptured, .executionFinished:
            transcript = nil
            referent = nil
            planSummary = nil
            resultSummary = nil
        }
    }

    private static func intentReplay(
        _ intent: Contracts.ResolvedIntent
    ) -> (transcript: String?, referent: Contracts.SelectedReferent?, planSummary: String?) {
        switch intent {
        case let .ready(ready):
            return (ready.input.finalTranscript.text, ready.referent, ready.actionPlan.summary)
        case let .needsClarification(pending), let .blocked(pending):
            return (pending.input.finalTranscript.text, nil, nil)
        case let .satisfied(satisfied):
            return (satisfied.input.finalTranscript.text, nil, satisfied.summary)
        }
    }
}

@MainActor
final class SupervisionReplayStore {
    private let url: URL
    private var cached: SupervisionReplaySnapshot

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        guard fileManager.fileExists(atPath: url.path) else {
            cached = SupervisionReplaySnapshot()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            cached = try JSONDecoder().decode(SupervisionReplaySnapshot.self, from: data)
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: url, to: backup)
            cached = SupervisionReplaySnapshot()
        }
    }

    static func applicationSupport(fileManager: FileManager = .default) -> SupervisionReplayStore {
        let directory = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Director", isDirectory: true)
        return SupervisionReplayStore(url: directory.appendingPathComponent("supervision-replay.json"))
    }

    func snapshot() -> SupervisionReplaySnapshot { cached }

    func saveSessions(_ sessions: [Contracts.SupervisionSession], nextSessionId: Int) {
        cached.sessions = sessions
        cached.nextSessionId = nextSessionId
        persist()
    }

    func saveTitle(_ title: String, for sessionId: String) {
        cached.sessionTitles[sessionId] = title
        persist()
    }

    func record(_ event: Contracts.SupervisionAuditEvent, ordinal: Int) {
        cached.auditRecords.append(SupervisionReplayRecord(event: event, ordinal: ordinal))
        persist()
    }

    private func persist(fileManager: FileManager = .default) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cached)
            try data.write(to: url, options: .atomic)
        } catch {
            preconditionFailure("Unable to persist supervision replay: \(error)")
        }
    }
}

/// `TerminalSessionStatus` = `ExecutionStatus` minus the live `queued`/`running` (session-store.ts).
/// The loop only finishes a session as one of these; `Contracts.terminalSessionStatuses` lists them.
typealias TerminalSessionStatus = ExecutionStatus

/// `createSupervisionSessionStore`: an in-memory list of supervised runs with stable `session-N` ids.
@MainActor
final class SupervisionSessionStore {
    private var nextId: Int
    private var sessions: [Contracts.SupervisionSession]
    private let replay: SupervisionReplayStore?

    init(replay: SupervisionReplayStore? = nil) {
        self.replay = replay
        let snapshot = replay?.snapshot()
        nextId = snapshot?.nextSessionId ?? 1
        sessions = snapshot?.sessions ?? []
    }

    /// `start`: a new `queued` session stamped at `startedAt`.
    func start(_ startedAt: String) -> Contracts.SupervisionSession {
        let session = Contracts.SupervisionSession(
            id: "session-\(nextId)", status: .queued,
            startedAt: startedAt, updatedAt: startedAt, finishedAt: nil)
        nextId += 1
        sessions.append(session)
        replay?.saveSessions(sessions, nextSessionId: nextId)
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
        replay?.saveSessions(sessions, nextSessionId: nextId)
        return updated
    }
}

/// `createActionAuditStore`: the append-only Intention Log, queryable by session or action.
@MainActor
final class ActionAuditStore {
    private var records: [Contracts.SupervisionAuditEvent] = []
    private let replay: SupervisionReplayStore?

    init(replay: SupervisionReplayStore? = nil) {
        self.replay = replay
    }

    @discardableResult
    func record(_ event: Contracts.SupervisionAuditEvent) -> Contracts.SupervisionAuditEvent {
        let ordinal = records.count
        records.append(event)
        replay?.record(event, ordinal: ordinal)
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
