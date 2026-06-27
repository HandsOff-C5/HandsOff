//
//  ActionDispatchTests.swift
//  DirectorSidecarTests
//
//  Track B tests: the pure step → tool / risk / dispatch helpers + the per-call gate + the
//  loop-dedup signature. Mirrors packages/actions/src/step-dispatch.test.ts and
//  gate-tool-call.test.ts, plus the `callSignature`/`failedSignatures` recovery floor lifted
//  from useVoiceCuaController.ts. Fixtures are decoded from real TypeScript-shaped JSON (the
//  Contracts.* types are decode-only), so a contract drift fails the decode loudly.
//
//  Faithful-port divergence exercised here (see StepDispatch.swift / PORTING.md): TS builds an
//  "off-surface tool_call" via a cast to test the hallucinated-name safe default. In Swift a
//  decoded `tool_call` carries a validated DriverTool, so that path is unreachable for a decoded
//  step — the safe default is asserted at its real home (`DriverTool.parse` / `riskForToolName`).
//

import Testing
import Foundation
@testable import DirectorSidecar

private let dec = JSONDecoder()
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try dec.decode(type, from: Data(json.utf8))
}

private struct FixtureError: Error { let message: String }

private func step(_ json: String) throws -> Contracts.ActionStep {
    try decode(Contracts.ActionStep.self, json)
}

// A surface with caller-chosen pid/windowId for the flat-arg translation tests.
private func surfaceJSON(pid: Int? = nil, windowId: Int? = nil) -> String {
    let pidField = pid.map { ",\"pid\":\($0)" } ?? ""
    let winField = windowId.map { ",\"windowId\":\($0)" } ?? ""
    return "{\"id\":\"win-1\",\"title\":\"Doc\",\"app\":\"TextEdit\"\(pidField)\(winField),\"availability\":\"available\",\"accessStatus\":\"accessible\"}"
}

private func targetJSON(pid: Int? = nil, windowId: Int? = nil, elementIndex: Int? = nil) -> String {
    let idxField = elementIndex.map { ",\"elementIndex\":\($0)" } ?? ""
    return "{\"surface\":\(surfaceJSON(pid: pid, windowId: windowId))\(idxField)}"
}

// An observation whose perceived AX element at `index` carries `label`, so a click target
// lookup can resolve a commit element (Send/Delete/…).
private func observationWithElement(index: Int, label: String) throws -> Contracts.GoalLoopObservation {
    let json = """
    {"tick":0,"capturedAt":"2026-06-22T12:00:00.000Z","windows":[],"state":{"surface":\(surfaceJSON()),"capturedAt":"2026-06-22T12:00:00.000Z","elementCount":1,"elements":[{"id":"element-\(index)","index":\(index),"role":"AXButton","label":"\(label)"}]}}
    """
    return try decode(Contracts.GoalLoopObservation.self, json)
}

// A ready intent with a chosen risk and step list (risk_level kept consistent with the gate so
// the action-plan refine passes).
private func readyIntent(stepsJSON: String, risk: String) throws -> Contracts.ResolvedIntent.Ready {
    let requires = (risk == "mutating" || risk == "destructive_external") ? "true" : "false"
    let surface = surfaceJSON()
    let json = """
    {"status":"ready","id":"intent-1","input":{"sessionId":"session-1","speech":{"finalTranscript":{"kind":"final","text":"do it","confidence":0.9,"latencyMs":0,"receivedAt":0}},"pointingEvidence":[],"surfaceCandidates":[\(surface)]},"intent_type":"click","referent":null,"constraints":[],"risk_level":"\(risk)","requires_approval":\(requires),"target_agent":"cua-driver","action_plan":{"id":"plan-1","summary":"Do it","risk_level":"\(risk)","requires_approval":\(requires),"target_agent":"cua-driver","action_plan":[\(stepsJSON)]},"createdAt":"2026-06-22T12:00:00.000Z"}
    """
    guard case let .ready(ready) = try decode(Contracts.ResolvedIntent.self, json) else {
        throw FixtureError(message: "expected a ready intent")
    }
    return ready
}

// MARK: - driverToolForStep

@Test func driverToolPassesVerbatimToolForToolCall() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{}}"#)
    #expect(StepDispatch.driverToolForStep(s) == .scroll)
}

@Test func driverToolMapsLegacyKindsToTheirDriverTool() throws {
    let target = targetJSON()
    #expect(try StepDispatch.driverToolForStep(step(#"{"id":"1","kind":"click_element","label":"Click","target":\#(target)}"#)) == .click)
    #expect(try StepDispatch.driverToolForStep(step(#"{"id":"2","kind":"type_text","label":"Type","target":\#(target),"text":"hi"}"#)) == .typeText)
    #expect(try StepDispatch.driverToolForStep(step(#"{"id":"3","kind":"set_value","label":"Set","target":\#(target),"value":"x"}"#)) == .setValue)
    #expect(try StepDispatch.driverToolForStep(step(#"{"id":"4","kind":"launch_app","label":"Open","appName":"Notes"}"#)) == .launchApp)
    #expect(try StepDispatch.driverToolForStep(step(#"{"id":"5","kind":"inspect_window_state","label":"Look","target":\#(target)}"#)) == .getWindowState)
    #expect(try StepDispatch.driverToolForStep(step(#"{"id":"6","kind":"capture_screenshot","label":"Shot","target":\#(target)}"#)) == .getWindowState)
}

@Test func hallucinatedToolNameHasNoDriverTool() {
    // Divergence: a decoded tool_call can't carry an off-surface tool (decode throws upstream).
    // The safe-default lives here, in the boundary parse the loop calls on a raw model string.
    #expect(Contracts.DriverTool.parse("teleport") == nil)
}

// MARK: - toolNameForStep

@Test func toolNameReturnsRawToolForToolCall() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{}}"#)
    #expect(StepDispatch.toolNameForStep(s) == "scroll")
}

@Test func toolNameReturnsMappedToolForLegacyKind() throws {
    let s = try step(#"{"id":"1","kind":"click_element","label":"Click","target":\#(targetJSON())}"#)
    #expect(StepDispatch.toolNameForStep(s) == "click")
}

// MARK: - elementIndexForStep

@Test func elementIndexReadsFromToolCallArgs() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Click","tool":"click","args":{"element_index":4}}"#)
    #expect(StepDispatch.elementIndexForStep(s) == 4)
}

@Test func elementIndexReadsFromLegacyTypedTarget() throws {
    let s = try step(#"{"id":"1","kind":"click_element","label":"Click","target":\#(targetJSON(elementIndex: 7))}"#)
    #expect(StepDispatch.elementIndexForStep(s) == 7)
}

@Test func elementIndexIsNilWhenAbsent() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{}}"#)
    #expect(StepDispatch.elementIndexForStep(s) == nil)
}

// MARK: - toolCallTargetForStep

@Test func toolCallTargetBuildsElementForClickByIndex() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Click Send","tool":"click","args":{"element_index":2}}"#)
    let target = StepDispatch.toolCallTargetForStep(s, try observationWithElement(index: 2, label: "Send"))
    #expect(target == Contracts.ToolCallTarget(
        element: .init(role: "AXButton", title: "Send", label: "Send", value: nil),
        key: nil, keys: nil, pageAction: nil))
}

@Test func toolCallTargetIsNilForNonClickTool() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Type","tool":"type_text","args":{"element_index":2,"text":"hi"}}"#)
    #expect(StepDispatch.toolCallTargetForStep(s, try observationWithElement(index: 2, label: "Send")) == nil)
}

@Test func toolCallTargetIsNilWhenElementMissing() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Click","tool":"click","args":{"element_index":99}}"#)
    #expect(StepDispatch.toolCallTargetForStep(s, try observationWithElement(index: 2, label: "Send")) == nil)
}

// MARK: - driverCallForStep

@Test func driverCallPassesToolCallArgsStraightThrough() throws {
    let s = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{"pid":42,"direction":"down"}}"#)
    let call = StepDispatch.driverCallForStep(s)
    #expect(call.tool == "scroll")
    #expect(call.args == ["pid": .number(42), "direction": .string("down")])
}

@Test func driverCallTranslatesLaunchAppToSnakeCase() throws {
    let plain = StepDispatch.driverCallForStep(try step(#"{"id":"1","kind":"launch_app","label":"Open","appName":"Notes"}"#))
    #expect(plain.tool == "launch_app")
    #expect(plain.args == ["app_name": .string("Notes")])

    let withBundle = StepDispatch.driverCallForStep(try step(#"{"id":"1","kind":"launch_app","label":"Open","appName":"Notes","bundleId":"com.apple.Notes"}"#))
    #expect(withBundle.args == ["app_name": .string("Notes"), "bundle_id": .string("com.apple.Notes")])
}

@Test func driverCallTranslatesClickToFlatSurfaceArgs() throws {
    let s = try step(#"{"id":"1","kind":"click_element","label":"Click","target":\#(targetJSON(pid: 7, windowId: 3, elementIndex: 5))}"#)
    let call = StepDispatch.driverCallForStep(s)
    #expect(call.tool == "click")
    #expect(call.args == ["pid": .number(7), "window_id": .number(3), "element_index": .number(5)])
}

@Test func driverCallCarriesTextAndValue() throws {
    let typeCall = StepDispatch.driverCallForStep(try step(#"{"id":"1","kind":"type_text","label":"Type","target":\#(targetJSON()),"text":"hi"}"#))
    #expect(typeCall.args["text"] == .string("hi"))
    let setCall = StepDispatch.driverCallForStep(try step(#"{"id":"1","kind":"set_value","label":"Set","target":\#(targetJSON()),"value":"v"}"#))
    #expect(setCall.args["value"] == .string("v"))
}

// MARK: - maxRisk

@Test func maxRiskReturnsHigherRanked() {
    #expect(StepDispatch.maxRisk(.readOnly, .reversible) == .reversible)
    #expect(StepDispatch.maxRisk(.mutating, .reversible) == .mutating)
    #expect(StepDispatch.maxRisk(.mutating, .destructiveExternal) == .destructiveExternal)
    #expect(StepDispatch.maxRisk(.readOnly, .readOnly) == .readOnly)
}

// MARK: - planToolRisk

@Test func planToolRiskEscalatesCommitClickAboveReversiblePlan() throws {
    let intent = try readyIntent(
        stepsJSON: #"{"id":"1","kind":"tool_call","label":"Click Send","tool":"click","args":{"element_index":2}}"#,
        risk: "reversible")
    #expect(StepDispatch.planToolRisk(intent.actionPlan, try observationWithElement(index: 2, label: "Send")) == .mutating)
}

@Test func planToolRiskKeepsBenignNavigationClickReversible() throws {
    let intent = try readyIntent(
        stepsJSON: #"{"id":"1","kind":"tool_call","label":"Click Sort","tool":"click","args":{"element_index":2}}"#,
        risk: "reversible")
    #expect(StepDispatch.planToolRisk(intent.actionPlan, try observationWithElement(index: 2, label: "Sort by")) == .reversible)
}

@Test func planToolRiskGatesHallucinatedToolAsMutating() {
    // The hallucinated-name safe default at its real home: a raw model tool string the loop
    // classifies BEFORE constructing a step. (A decoded tool_call can never reach here off-surface.)
    #expect(Contracts.ToolRisk.riskForToolName("teleport") == .mutating)
}

// MARK: - withEffectiveRisk

@Test func withEffectiveRiskReturnsSameWhenUnchanged() throws {
    let intent = try readyIntent(stepsJSON: "", risk: "reversible")
    #expect(StepDispatch.withEffectiveRisk(intent, risk: .reversible) == intent)
}

@Test func withEffectiveRiskStampsEscalationOntoIntentAndPlan() throws {
    let intent = try readyIntent(stepsJSON: "", risk: "reversible")
    let next = StepDispatch.withEffectiveRisk(intent, risk: .mutating)
    #expect(next.riskLevel == .mutating)
    #expect(next.requiresApproval == true)
    #expect(next.actionPlan.riskLevel == .mutating)
    #expect(next.actionPlan.requiresApproval == true)
    // Immutable: the original is untouched.
    #expect(intent.riskLevel == .reversible)
    #expect(intent.requiresApproval == false)
}

// MARK: - gateToolCall (per-call approval gate)

@Test func gateAllowsReadOnlyWithoutApproval() {
    let gate = ToolCallGate.gate(tool: .getWindowState)
    #expect(gate == .allowed(risk: .readOnly))
}

@Test func gateAllowsDraftWithoutApproval() {
    #expect(ToolCallGate.gate(tool: .typeText) == .allowed(risk: .reversible))
}

@Test func gateAllowsNavigationClickWithoutApproval() {
    let gate = ToolCallGate.gate(
        tool: .click,
        target: .init(element: .init(role: "AXPopUpButton", title: "Sort by", label: nil, value: nil),
                      key: nil, keys: nil, pageAction: nil))
    #expect(gate == .allowed(risk: .reversible))
}

@Test func gateBlocksCommitClickUntilApproved() {
    let gate = ToolCallGate.gate(
        tool: .click,
        target: .init(element: .init(role: "AXButton", title: "Send", label: nil, value: nil),
                      key: nil, keys: nil, pageAction: nil))
    #expect(gate.isAllowed == false)
    #expect(gate.risk == .mutating)
    guard case let .blocked(reason, _)? = gate.blockedResult else {
        Issue.record("expected a blocked result"); return
    }
    #expect(reason.contains("Approval required"))
    #expect(reason.contains("click"))
}

@Test func gateAllowsCommitClickOnceApproved() {
    let gate = ToolCallGate.gate(
        tool: .click,
        target: .init(element: .init(role: "AXButton", title: "Send", label: nil, value: nil),
                      key: nil, keys: nil, pageAction: nil),
        approved: true)
    #expect(gate == .allowed(risk: .mutating))
}

@Test func gateBlocksDestructiveToolUntilApproved() {
    #expect(ToolCallGate.gate(tool: .killApp).isAllowed == false)
    #expect(ToolCallGate.gate(tool: .killApp).risk == .destructiveExternal)
    #expect(ToolCallGate.gate(tool: .killApp, approved: true) == .allowed(risk: .destructiveExternal))
}

@Test func gateDerivesFromRiskNotModelClaim() {
    // The caller supplies only tool + target; risk is computed here. A commit click with no
    // approval stays blocked regardless of any model-supplied risk claim.
    let gate = ToolCallGate.gate(
        tool: .click,
        target: .init(element: .init(role: "AXButton", title: "Delete account", label: nil, value: nil),
                      key: nil, keys: nil, pageAction: nil),
        approved: false)
    #expect(gate.isAllowed == false)
    #expect(gate.risk == .mutating)
}

// MARK: - firstBlockedStep

@Test func firstBlockedStepBlocksUnapprovedCommitClick() throws {
    let sendClick = try step(#"{"id":"1","kind":"tool_call","label":"Click Send","tool":"click","args":{"element_index":2}}"#)
    let blocked = StepDispatch.firstBlockedStep([sendClick], try observationWithElement(index: 2, label: "Send"), approved: false)
    guard case let .blocked(reason, _) = try #require(blocked) else {
        Issue.record("expected a blocked result"); return
    }
    #expect(reason.contains("Approval required"))
}

@Test func firstBlockedStepAllowsApprovedCommitClick() throws {
    let sendClick = try step(#"{"id":"1","kind":"tool_call","label":"Click Send","tool":"click","args":{"element_index":2}}"#)
    #expect(StepDispatch.firstBlockedStep([sendClick], try observationWithElement(index: 2, label: "Send"), approved: true) == nil)
}

@Test func firstBlockedStepAllowsReadOnlyWithoutApproval() throws {
    let scroll = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{}}"#)
    #expect(StepDispatch.firstBlockedStep([scroll], nil, approved: false) == nil)
}

// MARK: - callSignature + failed-action dedup

@Test func callSignatureIsStableAcrossArgKeyOrder() throws {
    // Same logical call, args declared in different key orders → identical signature.
    let a = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{"pid":42,"direction":"down"}}"#)
    let b = try step(#"{"id":"2","kind":"tool_call","label":"Scroll","tool":"scroll","args":{"direction":"down","pid":42}}"#)
    #expect(ActionDedup.callSignature(a) == ActionDedup.callSignature(b))
    #expect(ActionDedup.callSignature(a) == "scroll:direction=\"down\"&pid=42")
}

@Test func callSignatureDistinguishesDifferentArgs() throws {
    let down = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{"pid":42,"direction":"down"}}"#)
    let up = try step(#"{"id":"2","kind":"tool_call","label":"Scroll","tool":"scroll","args":{"pid":42,"direction":"up"}}"#)
    #expect(ActionDedup.callSignature(down) != ActionDedup.callSignature(up))
}

@Test func failedActionMemoryRecordsAndDetectsRepeat() throws {
    let launch = try step(#"{"id":"1","kind":"launch_app","label":"Open","appName":"NoSuchApp"}"#)
    let memory = FailedActionMemory().recording(ActionDedup.callSignature(launch))
    #expect(memory.contains(launch))
    #expect(memory.firstRepeated(in: [launch])?.id == "1")
}

@Test func failedActionMemoryIgnoresNilSignature() {
    // A succeeded step contributes no signature — successful calls are never remembered.
    let memory = FailedActionMemory().recording(nil)
    #expect(memory.signatures.isEmpty)
}

@Test func failedActionMemoryLetsAlternativesThrough() throws {
    // Only the verbatim-failed call is blocked; a different call flows.
    let failed = try step(#"{"id":"1","kind":"launch_app","label":"Open","appName":"NoSuchApp"}"#)
    let alternative = try step(#"{"id":"2","kind":"launch_app","label":"Open","appName":"Notes"}"#)
    let memory = FailedActionMemory().recording(ActionDedup.callSignature(failed))
    #expect(memory.firstRepeated(in: [alternative]) == nil)
}

@Test func repeatedCallBlockNamesTheTool() throws {
    let launch = try step(#"{"id":"1","kind":"launch_app","label":"Open","appName":"NoSuchApp"}"#)
    guard case let .blocked(reason, _) = ActionDedup.repeatedCallBlock(launch) else {
        Issue.record("expected a blocked result"); return
    }
    #expect(reason.contains("kept retrying a call that already failed"))
    #expect(reason.contains("launch_app"))
}

// MARK: - #158 coordinate-click fallback + no-progress escalation

// An observation whose element carries a frame + token, so the coordinate-fallback / target-key
// helpers can resolve it.
private func framedObservation(
    index: Int, token: String, x: Double, y: Double, width: Double, height: Double, label: String = "Battery"
) throws -> Contracts.GoalLoopObservation {
    let json = """
    {"tick":0,"capturedAt":"t","windows":[],"state":{"surface":\(surfaceJSON(pid: 42, windowId: 7)),"capturedAt":"t","elementCount":1,"elements":[{"id":"\(token)","index":\(index),"token":"\(token)","role":"AXStaticText","label":"\(label)","frame":{"x":\(x),"y":\(y),"width":\(width),"height":\(height)}}]}}
    """
    return try decode(Contracts.GoalLoopObservation.self, json)
}

private func clickStep(index: Int? = nil, token: String? = nil, pid: Int = 42, window: Int = 7) throws -> Contracts.ActionStep {
    var args = "\"pid\":\(pid),\"window_id\":\(window)"
    if let index { args += ",\"element_index\":\(index)" }
    if let token { args += ",\"element_token\":\"\(token)\"" }
    return try step("{\"id\":\"c\",\"kind\":\"tool_call\",\"label\":\"Click\",\"tool\":\"click\",\"args\":{\(args)}}")
}

@Test func clickTargetKeyPrefersTokenOverIndex() throws {
    #expect(try StepDispatch.clickTargetKey(clickStep(index: 0, token: "s0001:0")) == "42:7:tok=s0001:0")
    #expect(try StepDispatch.clickTargetKey(clickStep(index: 3)) == "42:7:idx=3")
}

@Test func clickTargetKeyNilForNonClick() throws {
    let scroll = try step(#"{"id":"1","kind":"tool_call","label":"Scroll","tool":"scroll","args":{"pid":42,"direction":"down"}}"#)
    #expect(StepDispatch.clickTargetKey(scroll) == nil)
}

@Test func coordinateClickArgsAimAtFrameCenterAndDropAxAddressing() throws {
    let observation = try framedObservation(index: 0, token: "s0001:0", x: 10, y: 40, width: 100, height: 20)
    let args = try #require(StepDispatch.coordinateClickArgs(for: clickStep(index: 0, token: "s0001:0"), observation))
    #expect(args["x"] == .number(60))   // 10 + 100/2
    #expect(args["y"] == .number(50))   // 40 + 20/2
    #expect(args["pid"] == .number(42))
    #expect(args["window_id"] == .number(7))
    #expect(args["element_index"] == nil)
    #expect(args["element_token"] == nil)
}

@Test func coordinateClickArgsNilWithoutFrame() throws {
    // Element present but no frame → cannot aim a coordinate click; the loop stays AX-only.
    let observation = try observationWithElement(index: 0, label: "Battery")
    #expect(try StepDispatch.coordinateClickArgs(for: clickStep(index: 0), observation) == nil)
}

@Test func windowChangedDetectsNoOpAndProgress() throws {
    let before = try framedObservation(index: 0, token: "s0001:0", x: 10, y: 40, width: 100, height: 20, label: "Battery").state
    let same = try framedObservation(index: 0, token: "s0001:0", x: 10, y: 40, width: 100, height: 20, label: "Battery").state
    let changed = try framedObservation(index: 0, token: "s0002:0", x: 10, y: 40, width: 100, height: 20, label: "Wi-Fi").state
    #expect(ActionDedup.windowChanged(from: before, to: same) == false)    // no-op: identical content
    #expect(ActionDedup.windowChanged(from: before, to: changed) == true)  // navigated: labels changed
    #expect(ActionDedup.windowChanged(from: nil, to: same) == true)        // unknown → assume progress
}

@Test func clickEscalationEscalatesAxThenExhausts() {
    let key = "42:7:tok=s0001:0"
    var escalation = ClickEscalation()
    #expect(escalation.usesCoordinate(key) == false)
    // First AX no-op → escalate the target to the coordinate path.
    escalation = escalation.recordingNoProgress(key, mode: .ax)
    #expect(escalation.usesCoordinate(key) == true)
    #expect(escalation.isExhausted(key) == false)
    // Coordinate no-ops climb to the floor (maxNoProgressRepeats == 3).
    escalation = escalation.recordingNoProgress(key, mode: .coordinate)
    escalation = escalation.recordingNoProgress(key, mode: .coordinate)
    #expect(escalation.isExhausted(key) == true)
}

@Test func clickEscalationClearsOnProgress() {
    let key = "42:7:idx=0"
    let escalation = ClickEscalation().recordingNoProgress(key, mode: .ax).clearing(key)
    #expect(escalation.usesCoordinate(key) == false)
    #expect(escalation.isExhausted(key) == false)
}

@Test func firstExhaustedFindsStalledClickStep() throws {
    let step = try clickStep(index: 0, token: "s0001:0")
    let key = try #require(StepDispatch.clickTargetKey(step))
    var escalation = ClickEscalation()
    for _ in 0..<ClickEscalation.maxNoProgressRepeats {
        escalation = escalation.recordingNoProgress(key, mode: .coordinate)
    }
    #expect(escalation.firstExhausted(in: [step])?.id == "c")
}

@Test func stalledClickBlockNamesTheTool() throws {
    guard case let .blocked(reason, _) = try ActionDedup.stalledClickBlock(clickStep(index: 0)) else {
        Issue.record("expected a blocked result"); return
    }
    #expect(reason.contains("no-op'd"))
    #expect(reason.contains("click"))
}
