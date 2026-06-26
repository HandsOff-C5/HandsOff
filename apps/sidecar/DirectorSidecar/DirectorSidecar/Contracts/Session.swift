//
//  Session.swift
//  DirectorSidecar
//
//  Port of @handsoff/supervision session-store.ts `SupervisionSession` — one supervised agent
//  run's lifecycle row. `startedAt`/`updatedAt`/`finishedAt` are ISO-8601 strings (NOT epoch ms);
//  `status` is the shared top-level `ExecutionStatus`.
//
//  Distinct from the lite top-level `SupervisionSession` (Bridge/SessionTypes.swift), which adds
//  the optional bridge-layer `title`/`agentLabel` enrichment the menu renders. This is the
//  strict core shape — the engine's source of truth — without that enrichment.
//

import Foundation

extension Contracts {
    /// Statuses a session can finish in — `ExecutionStatus` minus the live `queued`/`running`
    /// (mirrors the TS `TerminalSessionStatus = Exclude<ExecutionStatus, "queued" | "running">`).
    static let terminalSessionStatuses: [ExecutionStatus] = [.succeeded, .failed, .blocked, .rejected]

    /// `SupervisionSession`.
    struct SupervisionSession: Codable, Identifiable, Sendable, Equatable {
        let id: String
        let status: ExecutionStatus
        let startedAt: String
        let updatedAt: String
        let finishedAt: String?
    }
}
