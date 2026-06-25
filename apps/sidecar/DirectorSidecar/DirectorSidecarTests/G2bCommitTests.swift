//
//  G2bCommitTests.swift
//  DirectorSidecarTests
//
//  G2b: commit-to-execute (fn-end) for non-destructive intents, and the optional destructive
//  Greenlight/Reject path. Verifies the revised policy — non-destructive commits directly;
//  destructive holds until greenlight; reject dismisses without executing.
//

import Testing
import Foundation
@testable import DirectorSidecar

private func readyIntent(_ risk: RiskLevel, id: String = "intent-1") -> ResolvedIntentLite {
    ResolvedIntentLite(id: id, status: .ready, intentType: "x", riskLevel: risk,
                       requiresApproval: risk == .destructive, summary: "s", reason: nil)
}

@Test func canCommitForNonDestructiveOnly() {
    #expect(HUDModel.canCommit(readyIntent(.readOnly)))
    #expect(HUDModel.canCommit(readyIntent(.mutating)))
    #expect(!HUDModel.canCommit(readyIntent(.destructive)))
    #expect(!HUDModel.canCommit(nil))
}

@MainActor
@Test func commitExecutesNonDestructiveIntent() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.mutating)))
    #expect(model.phase == .intentReady)
    model.commit()
    #expect(model.phase == .executing)
}

@MainActor
@Test func commitIsNoOpForDestructive() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.destructive)))
    #expect(model.phase == .awaitingGreenlight)
    model.commit() // must NOT execute — destructive needs greenlight
    #expect(model.phase == .awaitingGreenlight)
}

@MainActor
@Test func greenlightExecutesDestructiveIntent() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.destructive)))
    #expect(model.showFooter)
    model.greenlight()
    #expect(model.phase == .executing)
}

@MainActor
@Test func greenlightIsNoOpForNonDestructive() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.readOnly)))
    model.greenlight() // greenlight only applies to destructive
    #expect(model.phase == .intentReady)
}

@MainActor
@Test func rejectDismissesWithoutExecuting() {
    let model = HUDModel()
    model.setListening(true)
    model.apply(.intent(readyIntent(.destructive)))
    model.reject()
    #expect(model.phase == .hidden)
    #expect(model.intent == nil)
}
