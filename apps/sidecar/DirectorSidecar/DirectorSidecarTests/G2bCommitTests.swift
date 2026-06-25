//
//  G2bCommitTests.swift
//  DirectorSidecarTests
//
//  G2b: commit-to-execute (fn-end) for read-only/reversible intents, and the Greenlight/Reject
//  path for approval-required contract risks. Mutating and destructive_external hold until
//  approval; reject dismisses without executing.
//

import Testing
import Foundation
@testable import DirectorSidecar

private func readyIntent(_ risk: RiskLevel, id: String = "intent-1") -> ResolvedIntentLite {
    ResolvedIntentLite(id: id, status: .ready, intentType: "x", riskLevel: risk,
                       requiresApproval: risk.requiresApproval, summary: "s", reason: nil)
}

@Test func canCommitForAutoRunnableRiskOnly() {
    #expect(HUDModel.canCommit(readyIntent(.readOnly)))
    #expect(HUDModel.canCommit(readyIntent(.reversible)))
    #expect(!HUDModel.canCommit(readyIntent(.mutating)))
    #expect(!HUDModel.canCommit(readyIntent(.destructiveExternal)))
    #expect(!HUDModel.canCommit(nil))
}

@MainActor
@Test func commitExecutesAutoRunnableIntent() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.reversible)))
    #expect(model.phase == .intentReady)
    model.commit()
    #expect(model.phase == .executing)
}

@MainActor
@Test func commitIsNoOpForApprovalRequiredRisk() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.mutating)))
    #expect(model.phase == .awaitingGreenlight)
    model.commit() // must NOT execute — approval-required risk needs greenlight
    #expect(model.phase == .awaitingGreenlight)
}

@MainActor
@Test func greenlightExecutesApprovalRequiredIntent() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.destructiveExternal)))
    #expect(model.showFooter)
    model.greenlight()
    #expect(model.phase == .executing)
}

@MainActor
@Test func greenlightIsNoOpForAutoRunnableRisk() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.readOnly)))
    model.greenlight() // greenlight only applies to approval-required risks
    #expect(model.phase == .intentReady)
}

@MainActor
@Test func rejectDismissesWithoutExecuting() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.destructiveExternal)))
    model.reject()
    #expect(model.phase == .hidden)
    #expect(model.intent == nil)
}
