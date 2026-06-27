//
//  ContractsDecodeTests.swift
//  DirectorSidecarTests
//
//  JSON fixture decode tests for the faithful @handsoff/contracts ports (Contracts.*).
//  Fixtures are real TypeScript-shaped payloads mirroring the zod schemas + their vitest
//  fixtures (action-plan, audit.test.ts, intent, supervision session-store). If a TS contract
//  drifts — an enum case, a field, the risk vocabulary, an approval refinement — the matching
//  decode here fails loudly rather than silently mis-decoding.
//

import Testing
import Foundation
@testable import DirectorSidecar

private let dec = JSONDecoder()
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try dec.decode(type, from: Data(json.utf8))
}

// Shared surface fixture — @handsoff/contracts surfaceSnapshotSchema (matches audit.test.ts).
private let surfaceJSON = #"""
{"id":"surface-1","title":"issue #23 — GitHub","app":"Google Chrome","pid":4210,"windowId":71,"availability":"available","accessStatus":"accessible"}
"""#

// MARK: - Risk levels + approval policy (action-plan.ts)

@Test func riskVocabularyMatchesContract() throws {
    // The four wire tiers decode to the four cases; the order is severity-ascending.
    #expect(try decode(RiskLevel.self, "\"read_only\"") == .readOnly)
    #expect(try decode(RiskLevel.self, "\"reversible\"") == .reversible)
    #expect(try decode(RiskLevel.self, "\"mutating\"") == .mutating)
    #expect(try decode(RiskLevel.self, "\"destructive_external\"") == .destructiveExternal)
    #expect(RiskLevel.levels == [.readOnly, .reversible, .mutating, .destructiveExternal])
}

@Test func unknownRiskLevelFailsLoudly() {
    #expect(throws: (any Error).self) { try decode(RiskLevel.self, "\"destructive\"") }
}

@Test func approvalPolicyGatesMutatingAndDestructive() {
    // riskLevelRequiresApproval: read_only/reversible auto-run, mutating/destructive_external gate.
    #expect(RiskLevel.readOnly.requiresApproval == false)
    #expect(RiskLevel.reversible.requiresApproval == false)
    #expect(RiskLevel.mutating.requiresApproval == true)
    #expect(RiskLevel.destructiveExternal.requiresApproval == true)
}

@Test func effectiveRiskFoldsToMax() {
    // effectiveToolCallRisk: a read + a send gates as a send.
    #expect(RiskLevel.effective(of: []) == .readOnly)
    #expect(RiskLevel.effective(of: [.readOnly, .mutating, .reversible]) == .mutating)
    #expect(RiskLevel.effective(of: [.reversible, .destructiveExternal]) == .destructiveExternal)
}

// MARK: - Driver tools (driver-tools.ts)

// 37 = the 36 cua-driver passthrough tools + `write_note`, the locally-handled compose-and-write
// surface (U3). It lives in the enum so a model `write_note` call parses as a known tool, but it
// dispatches NATIVELY (StepDispatch.localToolNames → NoteWriter), never through `driver.call`.
@Test func driverToolSurfaceIs37AndDecodes() throws {
    #expect(Contracts.DriverTool.allCases.count == 37)
    #expect(try decode(Contracts.DriverTool.self, "\"get_window_state\"") == .getWindowState)
    #expect(try decode(Contracts.DriverTool.self, "\"type_text\"") == .typeText)
    #expect(try decode(Contracts.DriverTool.self, "\"kill_app\"") == .killApp)
    #expect(try decode(Contracts.DriverTool.self, "\"write_note\"") == .writeNote)
}

@Test func unknownDriverToolFailsLoudly() {
    #expect(throws: (any Error).self) { try decode(Contracts.DriverTool.self, "\"format_disk\"") }
    #expect(Contracts.DriverTool.parse("format_disk") == nil)
}

// MARK: - Surface (surface.ts)

@Test func decodesSurfaceSnapshot() throws {
    let s = try decode(Contracts.SurfaceSnapshot.self, surfaceJSON)
    #expect(s.id == "surface-1")
    #expect(s.app == "Google Chrome")
    #expect(s.availability == .available)
    #expect(s.accessStatus == .accessible)
}

// MARK: - Action steps (action-plan.ts)

@Test func decodesTypedActionStep() throws {
    let json = #"{"id":"s1","label":"Type into composer","kind":"type_text","target":{"surface":\#(surfaceJSON),"elementIndex":3},"text":"hello"}"#
    guard case let .typeText(id, _, target, text) = try decode(Contracts.ActionStep.self, json) else {
        Issue.record("expected a type_text step"); return
    }
    #expect(id == "s1")
    #expect(target.elementIndex == 3)
    #expect(text == "hello")
}

@Test func decodesGenericToolCallStepWithRawArgs() throws {
    // U3b generic passthrough — args is the driver's raw flat snake_case shape.
    let json = #"{"id":"s9","label":"scroll down","kind":"tool_call","tool":"scroll","args":{"pid":4210,"window_id":71,"direction":"down","amount":3}}"#
    guard case let .toolCall(_, _, tool, args) = try decode(Contracts.ActionStep.self, json) else {
        Issue.record("expected a tool_call step"); return
    }
    #expect(tool == .scroll)
    #expect(args["direction"] == .string("down"))
    #expect(args["amount"] == .number(3))
}

@Test func toolCallStepDefaultsArgsToEmpty() throws {
    let json = #"{"id":"s9","label":"snapshot","kind":"tool_call","tool":"get_window_state"}"#
    guard case let .toolCall(_, _, _, args) = try decode(Contracts.ActionStep.self, json) else {
        Issue.record("expected a tool_call step"); return
    }
    #expect(args.isEmpty)
}

@Test func unknownActionStepKindFailsLoudly() {
    let json = #"{"id":"s1","label":"x","kind":"format_disk"}"#
    #expect(throws: (any Error).self) { try decode(Contracts.ActionStep.self, json) }
}

// MARK: - Action plan (action-plan.ts refine)

@Test func decodesActionPlanWithConsistentApproval() throws {
    let json = #"{"id":"p1","summary":"Summarize and note","risk_level":"mutating","requires_approval":true,"target_agent":"cua-driver","action_plan":[]}"#
    let plan = try decode(Contracts.ActionPlan.self, json)
    #expect(plan.riskLevel == .mutating)
    #expect(plan.requiresApproval == true)
    #expect(plan.targetAgent == .cuaDriver)
}

@Test func actionPlanRejectsApprovalRiskMismatch() {
    // requires_approval must match riskLevelRequiresApproval(risk_level).
    let json = #"{"id":"p1","summary":"x","risk_level":"read_only","requires_approval":true,"target_agent":"none","action_plan":[]}"#
    #expect(throws: (any Error).self) { try decode(Contracts.ActionPlan.self, json) }
}

// MARK: - Sessions (supervision session-store.ts)

@Test func decodesSupervisionSession() throws {
    let json = #"{"id":"session-1","status":"running","startedAt":"2026-06-24T18:00:00.000Z","updatedAt":"2026-06-24T18:01:00.000Z"}"#
    let s = try decode(Contracts.SupervisionSession.self, json)
    #expect(s.id == "session-1")
    #expect(s.status == .running)
    #expect(s.finishedAt == nil)
}

// MARK: - Audit entries (audit.test.ts fixtures)

@Test func roundTripsCuaCallAuditEvent() throws {
    let json = #"""
    {"kind":"cua_call","sessionId":"session-1","actionId":"action-1","stepId":"step-1","recordedAt":"2026-06-22T12:00:00.000Z","request":{"kind":"click","target":{"surface":\#(surfaceJSON),"elementIndex":0}},"result":{"status":"succeeded","summary":"Clicked selected target"}}
    """#
    guard case let .cuaCall(base, stepId, request, result) = try decode(Contracts.SupervisionAuditEvent.self, json) else {
        Issue.record("expected a cua_call event"); return
    }
    #expect(base.sessionId == "session-1")
    #expect(stepId == "step-1")
    if case .click = request {} else { Issue.record("expected a click request") }
    if case .succeeded = result {} else { Issue.record("expected a succeeded result") }
}

@Test func roundTripsToolCallAuditEventWithProvenance() throws {
    let json = #"""
    {"kind":"tool_call","sessionId":"session-1","actionId":"plan-1","recordedAt":"2026-06-22T12:00:00.000Z","transcript":"send it","referent":{"id":"mail:1","source":"head","confidence":0.9},"tool":"click","target":{"element":{"role":"AXButton","title":"Send"}},"risk":"mutating","approval":"approved","result":{"status":"succeeded","summary":"Clicked Send"}}
    """#
    guard case let .toolCall(_, call) = try decode(Contracts.SupervisionAuditEvent.self, json) else {
        Issue.record("expected a tool_call event"); return
    }
    #expect(call.transcript == "send it")
    #expect(call.referent?.source == .head)
    #expect(call.tool == .click)
    #expect(call.target?.element?.title == "Send")
    #expect(call.risk == .mutating)
    #expect(call.approval == .approved)
}

@Test func acceptsReferentLessToolCall() throws {
    let json = #"""
    {"kind":"tool_call","sessionId":"session-1","actionId":"plan-1","recordedAt":"2026-06-22T12:00:00.000Z","transcript":"what is open","referent":null,"tool":"get_window_state","risk":"read_only","approval":"auto","result":{"status":"succeeded","summary":"Window state captured"}}
    """#
    guard case let .toolCall(_, call) = try decode(Contracts.SupervisionAuditEvent.self, json) else {
        Issue.record("expected a tool_call event"); return
    }
    #expect(call.referent == nil)
    #expect(call.tool == .getWindowState)
    #expect(call.approval == .auto)
}

@Test func rejectsToolCallWithToolOutsideDriverSurface() {
    let json = #"""
    {"kind":"tool_call","sessionId":"session-1","actionId":"plan-1","recordedAt":"2026-06-22T12:00:00.000Z","transcript":"do the thing","referent":null,"tool":"format_disk","risk":"mutating","approval":"auto","result":{"status":"succeeded","summary":"ok"}}
    """#
    #expect(throws: (any Error).self) { try decode(Contracts.SupervisionAuditEvent.self, json) }
}

@Test func rejectsApprovalEventPointingAtDifferentAction() {
    let json = #"""
    {"kind":"approval_decided","sessionId":"session-1","actionId":"action-1","recordedAt":"2026-06-22T12:00:00.000Z","approval":{"actionId":"action-2","decision":"approved","decidedAt":"2026-06-22T12:00:00.000Z"}}
    """#
    #expect(throws: (any Error).self) { try decode(Contracts.SupervisionAuditEvent.self, json) }
}

@Test func rejectsAuditEventWithNoActionLink() {
    let json = #"""
    {"kind":"execution_finished","sessionId":"session-1","recordedAt":"2026-06-22T12:00:00.000Z","status":"succeeded"}
    """#
    #expect(throws: (any Error).self) { try decode(Contracts.SupervisionAuditEvent.self, json) }
}

// MARK: - Surface selection record (audit.ts)

@Test func decodesSurfaceSelectionRecord() throws {
    let json = #"""
    {"referent":{"id":"ref-1","source":"gesture","confidence":0.82},"surface":\#(surfaceJSON),"sessionId":"session-1","actionId":"action-1","selectedAt":"2026-06-20T12:00:00.000Z"}
    """#
    let rec = try decode(Contracts.SurfaceSelectionRecord.self, json)
    #expect(rec.referent.source == .gesture)
    #expect(rec.actionId == "action-1")
}

@Test func decodesSurfaceSelectionRecordWithoutActionId() throws {
    // Selection precedes the action — actionId is optional.
    let json = #"""
    {"referent":{"id":"ref-1","source":"gaze","confidence":0.6},"surface":\#(surfaceJSON),"sessionId":"session-1","selectedAt":"2026-06-20T12:00:00.000Z"}
    """#
    let rec = try decode(Contracts.SurfaceSelectionRecord.self, json)
    #expect(rec.actionId == nil)
}

// MARK: - Resolved intent (intent.ts) — the intent_created audit payload closure

private let readyIntentJSON = #"""
{"status":"ready","id":"i1","input":{"sessionId":"session-1","speech":{"finalTranscript":{"kind":"final","text":"summarize this","confidence":0.95,"latencyMs":280,"receivedAt":1750000000000}},"pointingEvidence":[{"source":"head","confidence":0.88,"strategy":"fusion"}],"surfaceCandidates":[\#(surfaceJSON)]},"intent_type":"inspect","referent":{"id":"ref-1","source":"head","confidence":0.88},"constraints":[],"risk_level":"read_only","requires_approval":false,"target_agent":"cua-driver","action_plan":{"id":"p1","summary":"Summarize the window","risk_level":"read_only","requires_approval":false,"target_agent":"cua-driver","action_plan":[]},"createdAt":"2026-06-22T12:00:00.000Z"}
"""#

@Test func decodesReadyResolvedIntent() throws {
    guard case let .ready(ready) = try decode(Contracts.ResolvedIntent.self, readyIntentJSON) else {
        Issue.record("expected a ready intent"); return
    }
    #expect(ready.intentType == .inspect)
    #expect(ready.referent?.source == .head)
    #expect(ready.input.finalTranscript.text == "summarize this")
    #expect(ready.input.pointingEvidence.first?.source == .head)
    #expect(ready.actionPlan.summary == "Summarize the window")
}

@Test func decodesIntentCreatedAuditEventEmbeddingResolvedIntent() throws {
    let json = #"""
    {"kind":"intent_created","sessionId":"session-1","actionId":"i1","recordedAt":"2026-06-22T12:00:00.000Z","intent":\#(readyIntentJSON)}
    """#
    guard case let .intentCreated(base, intent) = try decode(Contracts.SupervisionAuditEvent.self, json) else {
        Issue.record("expected an intent_created event"); return
    }
    #expect(base.actionId == "i1")
    if case .ready = intent {} else { Issue.record("expected the embedded intent to be ready") }
}
