//
//  G4bInspectorTests.swift
//  DirectorSidecarTests
//
//  G4b Inspector: plan-step decode + READ/WRITE/EXEC tag mapping, InspectorState derivation, and
//  the Greenlight footer gate for approval-required risks (+ greenlight/reject behavior).
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: plan-step decode + tags

@Test func decodesIntentWithPlanSteps() throws {
    let json = #"""
    {"v":1,"type":"state","topic":"intent","payload":{
      "status":"ready","id":"i1","intent_type":"summarize","risk_level":"mutating","requires_approval":true,
      "action_plan":{"id":"p1","summary":"Summarize and note","risk_level":"mutating","requires_approval":true,"target_agent":"cua-driver",
        "action_plan":[
          {"id":"s1","label":"Read the issue","kind":"inspect_window_state","target":{"surface":{"title":"GitHub"}}},
          {"id":"s2","label":"Type the summary","kind":"type_text","target":{"surface":{"title":"Notes"}},"text":"TL;DR fix the race"}
        ]}}}
    """#
    guard case let .intent(intent) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected intent"); return }
    #expect(intent.steps.count == 2)
    #expect(intent.steps[0].tag == .read)            // inspect_window_state
    #expect(intent.steps[1].tag == .write)           // type_text
    #expect(intent.steps[1].targetTitle == "Notes")
    #expect(intent.steps[1].proposed == "TL;DR fix the race")
}

@Test func capabilityTagFromKind() {
    #expect(CapabilityTag.from(kind: "inspect_window_state") == .read)
    #expect(CapabilityTag.from(kind: "capture_screenshot") == .read)
    #expect(CapabilityTag.from(kind: "click_element") == .write)
    #expect(CapabilityTag.from(kind: "type_text") == .write)
    #expect(CapabilityTag.from(kind: "set_value") == .write)
    #expect(CapabilityTag.from(kind: "launch_app") == .exec)
}

// MARK: InspectorState + footer (main actor)

private func intent(_ risk: RiskLevel, _ status: ResolvedIntentLite.Status = .ready) -> ResolvedIntentLite {
    ResolvedIntentLite(id: "i1", status: status, intentType: "x", riskLevel: risk,
                       requiresApproval: risk.requiresApproval, summary: "s", reason: "needs info",
                       steps: [ActionStepLite(id: "s1", label: "do", kind: "type_text", targetTitle: nil, proposed: "v")])
}

@MainActor
@Test func inspectorEmptyUntilSelectionAndIntent() {
    let model = HomeDashboardModel()
    #expect(model.inspectorState == .empty)          // no selection
    model.apply(.intent(intent(.mutating)))
    #expect(model.inspectorState == .empty)          // intent but still no selection
}

@MainActor
@Test func inspectorReadyShowsPlanNoFooterForReversible() {
    let model = HomeDashboardModel()
    model.select("session-1")                         // sends selectSession (no-op without socket)
    model.apply(.intent(intent(.reversible)))
    guard case let .ready(shown) = model.inspectorState else { Issue.record("expected ready"); return }
    #expect(shown.steps.count == 1)
    #expect(!model.showInspectorFooter)
}

@MainActor
@Test func inspectorFooterShownForApprovalRequiredRisk() {
    let model = HomeDashboardModel()
    model.select("session-1")
    model.apply(.intent(intent(.mutating)))
    #expect(model.showInspectorFooter)
    // After execution, the footer disappears.
    model.apply(.runResult(RunResultPayload(status: .succeeded, sessionId: "session-1")))
    #expect(!model.showInspectorFooter)
}

@MainActor
@Test func inspectorBlockedAndClarificationStates() {
    let model = HomeDashboardModel()
    model.select("session-1")
    model.apply(.intent(intent(.mutating, .blocked)))
    #expect(model.inspectorState == .blocked("needs info"))
    model.apply(.intent(intent(.mutating, .clarificationRequired)))
    #expect(model.inspectorState == .clarification("needs info"))
}

@MainActor
@Test func rejectMarksRunResultAndDropsFooter() {
    let model = HomeDashboardModel()
    model.select("session-1")
    model.apply(.intent(intent(.destructiveExternal)))
    #expect(model.showInspectorFooter)
    model.reject()
    #expect(!model.showInspectorFooter)               // rejected → no longer awaiting
}
