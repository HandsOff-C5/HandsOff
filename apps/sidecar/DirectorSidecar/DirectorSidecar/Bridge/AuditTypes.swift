//
//  AuditTypes.swift
//  DirectorSidecar
//
//  H4 — the `audit` bridge topic: the Intention Log made visible. A flat, decode-only projection
//  of the loop's `Contracts.SupervisionAuditEvent` (Audit.swift) for the log views. The full audit
//  event carries heavy nested state (CuaWindowState, the whole ResolvedIntent, CuaActionRequest);
//  the dashboard log only renders a one-line summary plus — for the per-call `tool_call` record —
//  the tool, the locally-derived risk, the approval gate, and the result the issue calls out. So the
//  engine projects each event to this row (LoopFrameMapping.auditLog), exactly as it projects
//  `ResolvedIntent → ResolvedIntentLite`. Mirrors the TS SessionsPanel `eventSummary` rendering.
//
//  Drift-guarded by decode tests (DirectorSidecarTests); an unknown `kind`/`approval`/`result`/`risk`
//  fails the frame decode (dropped, last-good kept) rather than silently mis-rendering.
//

import Foundation

/// One projected Intention Log row — a lite mirror of `Contracts.SupervisionAuditEvent`.
struct AuditLogEntry: Codable, Sendable, Equatable, Identifiable {
    /// Stable list key: `"\(sessionId)#\(ordinal)"`. A `tool_call` tick records one event per step
    /// with the SAME `recordedAt`, so the projection's array ordinal disambiguates (the TS log keyed
    /// on `${kind}-${recordedAt}-${index}` for the same reason).
    let id: String
    let sessionId: String
    let actionId: String
    let kind: Kind
    let recordedAt: String   // ISO-8601
    /// The human-readable line — mirrors SessionsPanel.eventSummary across all six kinds.
    let summary: String

    // Per-call provenance — present ONLY for `.toolCall` (the Intention Log's core row): the driver
    // tool, the derived risk (never trusted from the model), the approval gate, and the result status.
    let tool: String?
    let risk: RiskLevel?
    let approval: Approval?
    let result: ResultStatus?

    /// The six audit kinds (`supervisionAuditEventSchema`'s discriminant).
    enum Kind: String, Codable, Sendable {
        case intentCreated = "intent_created"
        case approvalDecided = "approval_decided"
        case cuaStateCaptured = "cua_state_captured"
        case cuaCall = "cua_call"
        case toolCall = "tool_call"
        case executionFinished = "execution_finished"
    }

    /// How a per-call action was gated — mirrors `SupervisionAuditEvent.ToolCallApproval`.
    enum Approval: String, Codable, Sendable { case auto, approved, rejected }

    /// The result discriminant — mirrors `CuaActionResult`'s status.
    enum ResultStatus: String, Codable, Sendable { case succeeded, failed, blocked }
}

/// `audit` topic payload: the projected Intention Log for the live/current session, oldest-first.
struct AuditLogPayload: Codable, Sendable, Equatable {
    let entries: [AuditLogEntry]
}
