//
//  SessionTypes.swift
//  DirectorSidecar
//
//  G1 loop-state wire types for the `sessions` + `runResult` bridge topics. Mirrors
//  @handsoff/supervision `SupervisionSession` (session-store.ts) and @handsoff/contracts
//  `ExecutionStatus` (action-plan.ts). Drift-guarded by decode tests in
//  DirectorSidecarTests; if the TS types change, those fail loudly.
//
//  NOTE (co-owned, engine): the `sessions` topic is not published yet (bridge.rs handles
//  only getReadiness). The `SessionsPayload` envelope below — `{ sessions, counts? }` — is
//  the shape G1 consumes; confirm with the contracts owner when `bridge_publish` lands
//  (director-bridge-contract.md §4.1 / §7.3). Until then the #if DEBUG mock fleet feeds it.
//

import Foundation

/// Lifecycle status of a supervision session — @handsoff/contracts `ExecutionStatus`
/// (action-plan.ts `executionStatusSchema`). String-backed so it decodes the wire value
/// directly; an unknown value fails the frame decode (drift-loud, per BridgeFrame).
enum ExecutionStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case blocked
    case rejected
}

/// One supervised agent run — @handsoff/supervision `SupervisionSession` (session-store.ts).
/// `startedAt`/`updatedAt`/`finishedAt` are ISO-8601 strings (NOT epoch ms).
///
/// `title`/`agentLabel` are an OPTIONAL bridge-layer enrichment (data-plane dep #3): the core
/// session-store type has neither, so the engine derives them from `ActionPlan.summary` +
/// `target_agent` when publishing, and the menu falls back to id/status when absent. Confirm
/// the enrichment with the contracts owner.
struct SupervisionSession: Codable, Identifiable, Sendable {
    let id: String
    let status: ExecutionStatus
    let startedAt: String
    let updatedAt: String
    let finishedAt: String?
    let title: String?
    let agentLabel: String?
}

/// Derived fleet counts (director-bridge-contract.md §4.1). The engine may not compute
/// these (data-plane dep #4); when `counts` is absent on the wire the store derives them
/// from `sessions` via `SessionCounts(deriving:)`.
struct SessionCounts: Codable, Sendable, Equatable {
    let running: Int
    let needsGreenlight: Int
    let done: Int

    /// Derive counts from a session list when the engine doesn't send them.
    init(deriving sessions: [SupervisionSession]) {
        self.init(derivingStatuses: sessions.map(\.status))
    }

    /// Derive counts from statuses alone (used after a `runResult` flips one row).
    /// `done` == terminal statuses (incl. `blocked`); `running` == actively executing.
    ///
    /// NOTE: `needsGreenlight` is NOT derivable from status alone. In the in-process loop (ADR 0005)
    /// a goal that ends `.blocked` is a TERMINAL FAILURE (budget / dedup / gate / resolver-blocked),
    /// not a pending approval — the old "blocked == awaiting destructive approval" equivalence was a
    /// TS-bridge-era assumption that the migration invalidated. Real "needs your approval" is a LIVE
    /// intent state (a `.ready` mutating action awaiting `approve()`), surfaced via the intent frame
    /// (HUD greenlight footer), not the session status. So status-only derivation reports 0 here;
    /// wiring the session-fleet "needs you" badge to the live approval intent is deferred (see issue).
    init(derivingStatuses statuses: [ExecutionStatus]) {
        running = statuses.filter { $0 == .running }.count
        needsGreenlight = 0
        done = statuses.filter { $0 == .succeeded || $0 == .failed || $0 == .rejected || $0 == .blocked }.count
    }

    init(running: Int, needsGreenlight: Int, done: Int) {
        self.running = running
        self.needsGreenlight = needsGreenlight
        self.done = done
    }
}

/// `sessions` topic payload: the fleet list plus optional engine-derived counts.
struct SessionsPayload: Codable, Sendable {
    let sessions: [SupervisionSession]
    let counts: SessionCounts?

    /// Counts the menu renders — engine-provided when present, else derived locally.
    var resolvedCounts: SessionCounts {
        counts ?? SessionCounts(deriving: sessions)
    }
}

/// `runResult` topic payload: a single session's terminal/updated status, used to flip a
/// row to complete/failed and decrement the running count live without a full re-fetch.
struct RunResultPayload: Codable, Sendable {
    let status: ExecutionStatus
    let sessionId: String?
}
