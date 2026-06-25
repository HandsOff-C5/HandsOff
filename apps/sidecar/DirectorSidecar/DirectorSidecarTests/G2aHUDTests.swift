//
//  G2aHUDTests.swift
//  DirectorSidecarTests
//
//  G2a drift + state-model guards: transcript/referents/intent decode, the HUDModel phase reducer
//  per HUDPhase (the headless "snapshot per phase"), and the revised Greenlight-policy derivations
//  (approval footer for locally gated contract risk levels; read-only/reversible auto-run).
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: loop-type decode (T-G2.4)

@Test func decodesTranscriptPartialAndFinal() throws {
    let partial = #"{"v":1,"type":"state","topic":"transcript","payload":{"kind":"partial","text":"summarize that","confidence":0.4,"latencyMs":120,"receivedAt":1719240000000}}"#
    guard case let .transcript(p) = try JSONDecoder().decode(BridgeFrame.self, from: Data(partial.utf8))
    else { Issue.record("expected transcript"); return }
    #expect(p.isPartial)
    #expect(p.isLowConfidence) // 0.4 < 0.5

    let final = #"{"v":1,"type":"state","topic":"transcript","payload":{"kind":"final","text":"summarize that issue","confidence":0.95,"latencyMs":130,"receivedAt":1719240000001}}"#
    guard case let .transcript(f) = try JSONDecoder().decode(BridgeFrame.self, from: Data(final.utf8))
    else { Issue.record("expected transcript"); return }
    #expect(!f.isPartial)
    #expect(!f.isLowConfidence)
}

@Test func decodesReferentsWithSelection() throws {
    let json = #"{"v":1,"type":"state","topic":"referents","payload":{"surfaces":[{"id":"w1","title":"Issue 42","app":"GitHub","availability":"available","accessStatus":"granted"}],"selected":{"id":"w1","source":"point","confidence":0.9}}}"#
    guard case let .referents(payload) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected referents"); return }
    #expect(payload.surfaces.count == 1)
    #expect(payload.surfaces.first?.app == "GitHub")
    #expect(payload.selected?.id == "w1")
}

@Test func decodesReadyIntentPullingPlanSummary() throws {
    let json = #"{"v":1,"type":"state","topic":"intent","payload":{"status":"ready","id":"i1","intent_type":"summarize","risk_level":"read_only","requires_approval":false,"action_plan":{"id":"p1","summary":"Summarize issue #42","risk_level":"read_only","requires_approval":false,"target_agent":"cua-driver","action_plan":[]}}}"#
    guard case let .intent(intent) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected intent"); return }
    #expect(intent.status == .ready)
    #expect(intent.intentType == "summarize")
    #expect(intent.riskLevel == .readOnly)
    #expect(intent.summary == "Summarize issue #42")
}

@Test func decodesClarificationIntentWithReason() throws {
    let json = #"{"v":1,"type":"state","topic":"intent","payload":{"status":"clarification_required","id":"i2","requires_approval":false,"target_agent":"none","reason":"Which window did you mean?"}}"#
    guard case let .intent(intent) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected intent"); return }
    #expect(intent.status == .clarificationRequired)
    #expect(intent.reason == "Which window did you mean?")
}

// MARK: Greenlight-policy derivations

private func intent(_ risk: RiskLevel?, _ status: ResolvedIntentLite.Status = .ready) -> ResolvedIntentLite {
    ResolvedIntentLite(status: status, intentType: "x", riskLevel: risk, requiresApproval: false, summary: "s", reason: nil)
}

@Test func decodesDestructiveExternalRisk() throws {
    let json = #"{"v":1,"type":"state","topic":"intent","payload":{"status":"ready","id":"i3","intent_type":"delete","risk_level":"destructive_external","requires_approval":true,"action_plan":{"id":"p1","summary":"Delete exported files","risk_level":"destructive_external","requires_approval":true,"target_agent":"cua-driver","action_plan":[]}}}"#
    guard case let .intent(intent) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected intent"); return }
    #expect(intent.riskLevel == .destructiveExternal)
}

@Test func footerShowsForApprovalRequiredRisk() {
    #expect(!HUDModel.showFooter(for: intent(.readOnly)))
    #expect(!HUDModel.showFooter(for: intent(.reversible)))
    #expect(HUDModel.showFooter(for: intent(.mutating)))
    #expect(HUDModel.showFooter(for: intent(.destructiveExternal)))
}

@Test func autoRunIsReadOnlyAndReversibleOnly() {
    #expect(HUDModel.autoRun(for: intent(.readOnly)))
    #expect(HUDModel.autoRun(for: intent(.reversible)))
    #expect(!HUDModel.autoRun(for: intent(.mutating)))
    #expect(!HUDModel.autoRun(for: intent(.destructiveExternal)))
}

@Test func intentPhaseGatesApprovalRequiredRisk() {
    #expect(HUDModel.phase(for: intent(.reversible)) == .intentReady)
    #expect(HUDModel.phase(for: intent(.mutating)) == .awaitingGreenlight)
    #expect(HUDModel.phase(for: intent(.destructiveExternal)) == .awaitingGreenlight)
    #expect(HUDModel.phase(for: intent(.readOnly, .clarificationRequired)) == .error)
}

// MARK: HUDModel reducer (headless snapshot per phase)

@MainActor
@Test func reducerWalksTheReadOnlyLoopToComplete() {
    let model = HUDModel()
    #expect(model.phase == .hidden)

    model.setListening(true)
    #expect(model.phase == .listening)

    model.apply(.transcript(TranscriptEvent(kind: "partial", text: "summarize that", confidence: 0.9, latencyMs: 100, receivedAt: 0)))
    #expect(model.phase == .transcribing)

    model.apply(.referents(ReferentsPayload(surfaces: [SurfaceSnapshot(id: "w1", title: "#42", app: "GitHub", pid: nil, windowId: nil, availability: "available", accessStatus: "granted")], selected: nil)))
    #expect(model.phase == .referentsResolved)
    #expect(model.referents.count == 1)

    model.apply(.intent(intent(.readOnly)))
    #expect(model.phase == .intentReady)
    #expect(!model.showFooter)

    model.apply(.runResult(RunResultPayload(status: .succeeded, sessionId: nil)))
    #expect(model.phase == .complete)
}

@MainActor
@Test func reducerGatesApprovalRequiredIntent() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(intent(.mutating)))
    #expect(model.phase == .awaitingGreenlight)
    #expect(model.showFooter)
}

@MainActor
@Test func cancelResetsToHidden() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.transcript(TranscriptEvent(kind: "partial", text: "x", confidence: 0.9, latencyMs: 1, receivedAt: 0)))
    #expect(model.isVisible)
    model.cancel()
    #expect(model.phase == .hidden)
    #expect(model.transcript == nil)
}
