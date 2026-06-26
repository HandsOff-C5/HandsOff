//
//  LoopFrameMapping.swift
//  DirectorSidecar
//
//  ADR 0005 Track D. The pure projection of the in-process loop's @Observable state onto the
//  `BridgeFrame` family the existing UI already consumes (HUD / Home Dashboard / menu). Wiring the
//  Swift loop directly does NOT mean rewriting every view model: the UI speaks frames, so the
//  engine PRODUCES the same frames the socket used to deliver — same types, no socket, no bridge
//  expansion. Kept pure (no actor state) so every mapping is unit-tested without a running loop.
//
//  Type edge cases this file bridges (see PORTING.md):
//   • TWO `ResolvedIntent` families: the loop's faithful `Contracts.ResolvedIntent` vs the UI's
//     decode-only `ResolvedIntentLite` (status/risk/summary/steps). `satisfied` has NO lite case —
//     terminal success is carried by the session + runResult frames, so `lite(from:)` returns nil
//     for it (the caller emits no `.intent` frame, exactly as the bridge contract intended).
//   • TWO `SupervisionSession` families: the loop's strict `Contracts.SupervisionSession` (no
//     title/agentLabel) vs the wire `SupervisionSession` the menu renders (optional enrichment).
//   • TWO transcript families: the loop's `Contracts.FinalTranscript` (decode-only, the resolver
//     input) vs the HUD's `TranscriptEvent` (partial|final wire frame).
//   • `RiskLevel` is ONE shared top-level enum, so the ready intent's risk crosses with no mapping.
//

import Foundation

enum LoopFrameMapping {

    /// `Contracts.ResolvedIntent` → the HUD/Inspector `ResolvedIntentLite`. Returns `nil` for the
    /// terminal `satisfied` intent (no lite status exists; success rides the session/runResult
    /// frames instead), so the engine emits no intent frame for a finished goal.
    static func lite(from intent: Contracts.ResolvedIntent?) -> ResolvedIntentLite? {
        switch intent {
        case .none, .satisfied:
            return nil
        case let .ready(ready):
            return ResolvedIntentLite(
                id: ready.id,
                status: .ready,
                intentType: ready.intentType.rawValue,
                riskLevel: ready.riskLevel,
                requiresApproval: ready.requiresApproval,
                summary: ready.actionPlan.summary,
                reason: nil,
                steps: ready.actionPlan.actionPlan.map(stepLite))
        case let .needsClarification(pending):
            return pendingLite(pending, status: .clarificationRequired)
        case let .blocked(pending):
            return pendingLite(pending, status: .blocked)
        }
    }

    private static func pendingLite(
        _ pending: Contracts.ResolvedIntent.Pending,
        status: ResolvedIntentLite.Status
    ) -> ResolvedIntentLite {
        ResolvedIntentLite(
            id: pending.id,
            status: status,
            intentType: pending.intentType?.rawValue,
            riskLevel: pending.riskLevel,
            requiresApproval: pending.requiresApproval,
            summary: nil,
            reason: pending.reason,
            steps: [])
    }

    /// `Contracts.ActionStep` → the Inspector's `ActionStepLite`, faithful to what the lite wire
    /// decoder would have produced: `kind` is the contract kind string, `targetTitle` comes from a
    /// step that carries a target, and `proposed` is the type/set text (only kinds that carry it).
    /// The autonomous resolver emits only `tool_call` steps; the other kinds are mapped for parity.
    static func stepLite(_ step: Contracts.ActionStep) -> ActionStepLite {
        let kind: String
        var targetTitle: String?
        var proposed: String?
        switch step {
        case let .inspectWindowState(_, _, target):
            kind = "inspect_window_state"; targetTitle = target.surface.title
        case let .clickElement(_, _, target):
            kind = "click_element"; targetTitle = target.surface.title
        case let .typeText(_, _, target, text):
            kind = "type_text"; targetTitle = target.surface.title; proposed = text
        case let .setValue(_, _, target, value):
            kind = "set_value"; targetTitle = target.surface.title; proposed = value
        case let .captureScreenshot(_, _, target):
            kind = "capture_screenshot"; targetTitle = target.surface.title
        case .launchApp:
            kind = "launch_app"   // no `target` in the contract → targetTitle stays nil (faithful lite)
        case .toolCall:
            kind = "tool_call"    // generic passthrough: no target/text/value at the top level
        }
        return ActionStepLite(id: step.id, label: step.label, kind: kind,
                              targetTitle: targetTitle, proposed: proposed)
    }

    /// The loop's strict `Contracts.SupervisionSession` → the menu/dashboard wire `SupervisionSession`,
    /// adding the optional bridge-layer enrichment (`title` from the goal transcript, `agentLabel`).
    static func wireSession(
        _ session: Contracts.SupervisionSession,
        title: String?,
        agentLabel: String?
    ) -> SupervisionSession {
        SupervisionSession(
            id: session.id,
            status: session.status,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt,
            finishedAt: session.finishedAt,
            title: title,
            agentLabel: agentLabel)
    }

    /// A speech event → the HUD `transcript` wire frame.
    static func transcript(
        partial: Bool,
        text: String,
        confidence: Double,
        latencyMs: Double,
        receivedAt: Double
    ) -> TranscriptEvent {
        TranscriptEvent(
            kind: partial ? "partial" : "final",
            text: text,
            confidence: confidence,
            latencyMs: latencyMs,
            receivedAt: receivedAt)
    }

    // MARK: - Audit projection (H4 — the Intention Log made visible)

    /// The loop's `[Contracts.SupervisionAuditEvent]` → the `audit` topic `AuditLogPayload` the log
    /// views render. Oldest-first (the recording order). Each row is flattened to a one-line summary
    /// plus — for the per-call `tool_call` record — the tool / derived risk / approval / result the
    /// Intention Log replays. The array ordinal is folded into the row id so the SAME-`recordedAt`
    /// steps of one tick stay distinct (the TS log keyed `${kind}-${recordedAt}-${index}` for this).
    static func auditLog(_ events: [Contracts.SupervisionAuditEvent]) -> AuditLogPayload {
        AuditLogPayload(entries: events.enumerated().map { ordinal, event in
            auditEntry(event, ordinal: ordinal)
        })
    }

    /// One `SupervisionAuditEvent` → one `AuditLogEntry`. The structured tool/risk/approval/result
    /// fields are populated ONLY for `.toolCall`; every other kind carries just its summary line.
    static func auditEntry(_ event: Contracts.SupervisionAuditEvent, ordinal: Int) -> AuditLogEntry {
        let base = event.base
        let id = "\(base.sessionId)#\(ordinal)"
        switch event {
        case let .toolCall(_, call):
            return AuditLogEntry(
                id: id, sessionId: base.sessionId, actionId: base.actionId,
                kind: .toolCall, recordedAt: base.recordedAt, summary: auditSummary(event),
                tool: call.tool.rawValue, risk: call.risk,
                approval: auditApproval(call.approval), result: resultStatus(call.result))
        case .intentCreated:
            return auditEntry(id, base, .intentCreated, event)
        case .approvalDecided:
            return auditEntry(id, base, .approvalDecided, event)
        case .cuaStateCaptured:
            return auditEntry(id, base, .cuaStateCaptured, event)
        case .cuaCall:
            return auditEntry(id, base, .cuaCall, event)
        case .executionFinished:
            return auditEntry(id, base, .executionFinished, event)
        }
    }

    /// A non-`tool_call` entry: summary only, no per-call provenance.
    private static func auditEntry(
        _ id: String, _ base: Contracts.SupervisionAuditEvent.Base,
        _ kind: AuditLogEntry.Kind, _ event: Contracts.SupervisionAuditEvent
    ) -> AuditLogEntry {
        AuditLogEntry(
            id: id, sessionId: base.sessionId, actionId: base.actionId,
            kind: kind, recordedAt: base.recordedAt, summary: auditSummary(event),
            tool: nil, risk: nil, approval: nil, result: nil)
    }

    /// The human-readable Intention Log line — a faithful port of the TS SessionsPanel `eventSummary`
    /// (every one of the six audit kinds). `summarizeCuaFailure` (a friendlier-message enrichment) is
    /// not ported; the TS already falls back to `reason`/`error`, which is what `actionResultSummary`
    /// returns here.
    static func auditSummary(_ event: Contracts.SupervisionAuditEvent) -> String {
        switch event {
        case let .intentCreated(_, intent):
            switch intent {
            case let .ready(ready): return "Plan ready: \(ready.actionPlan.summary)"
            case let .satisfied(satisfied): return "Satisfied: \(satisfied.summary)"
            case let .blocked(pending): return "Blocked: \(pending.reason)"
            case let .needsClarification(pending): return "Blocked: \(pending.reason)"
            }
        case let .approvalDecided(_, approval):
            return "Approval \(approval.decision.rawValue)"
        case let .cuaCall(_, _, request, result):
            return "CUA \(cuaRequestKind(request)): \(actionResultSummary(result))"
        case let .toolCall(_, call):
            // Per-call Intention Log line (U3): tool · approval state · result.
            return "Tool \(call.tool.rawValue) [\(call.approval.rawValue)]: \(actionResultSummary(call.result))"
        case let .executionFinished(_, status, result):
            let detail = result.map { ": \(actionResultSummary($0))" } ?? ""
            return "Finished: \(status.rawValue)\(detail)"
        case let .cuaStateCaptured(_, phase, _, _):
            return "\(phase == .pre ? "Before" : "After") state captured"
        }
    }

    /// `actionResultSummary`: the succeeded summary, else the blocked reason / failed error.
    static func actionResultSummary(_ result: Contracts.CuaActionResult) -> String {
        switch result {
        case let .succeeded(summary, _): return summary
        case let .blocked(reason, _): return reason
        case let .failed(error, _): return error
        }
    }

    private static func resultStatus(_ result: Contracts.CuaActionResult) -> AuditLogEntry.ResultStatus {
        switch result {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .blocked: return .blocked
        }
    }

    private static func auditApproval(
        _ approval: Contracts.SupervisionAuditEvent.ToolCallApproval
    ) -> AuditLogEntry.Approval {
        switch approval {
        case .auto: return .auto
        case .approved: return .approved
        case .rejected: return .rejected
        }
    }

    /// The `cua_call` request's wire kind — mirrors the TS `event.request.kind`. (The autonomous loop
    /// records only `tool_call`/`intent_created`/`execution_finished`; this keeps the legacy
    /// six-kind request faithful for any `cua_call` that arrives over the wire.)
    private static func cuaRequestKind(_ request: Contracts.CuaActionRequest) -> String {
        switch request {
        case .launchApp: return "launch_app"
        case .getWindowState: return "get_window_state"
        case .click: return "click"
        case .typeText: return "type_text"
        case .setValue: return "set_value"
        case .screenshot: return "screenshot"
        }
    }
}

// MARK: - FinalTranscript construction seam

extension Contracts.FinalTranscript {
    /// `Contracts.FinalTranscript` is decode-only (a custom `init(from:)` rejecting non-"final"
    /// payloads suppresses the memberwise init). The engine PRODUCES one every push-to-talk turn
    /// from the live STT `.final` event, so it needs an in-memory initializer — the same
    /// construction-seam pattern `LoopContractsSupport`/`ResolvedIntentFactory` use for the other
    /// decode-only contract types.
    init(text: String, confidence: Double, latencyMs: Double, receivedAt: Double,
         words: [Contracts.TranscriptWord]? = nil) {
        self.text = text
        self.confidence = confidence
        self.latencyMs = latencyMs
        self.receivedAt = receivedAt
        self.words = words
    }
}
