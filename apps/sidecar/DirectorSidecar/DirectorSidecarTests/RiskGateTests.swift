//
//  RiskGateTests.swift
//  DirectorSidecarTests
//
//  Phase 4a — INVARIANT I9 ("raise, never lower"): the risk that gates a tool call is
//  TOOL-DERIVED. The model (binder) may attach a claimed risk, but it can only RAISE the tier,
//  never lower it — a model that labels a destructive verb as `read_only` to slip past the
//  greenlight is still gated. A tainted arg always escalates. UNKNOWN verbs floor at the highest
//  tier. Ported (adversarial) from App/Tests/LoopSessionsTests/RiskGateTests.swift.

import Testing
@testable import DirectorSidecar

struct RiskGateTests {
    private let gate = RiskGate()

    /// THE I9 PROOF: a destructive verb the model mislabels as read_only is still gated to
    /// approval, and the effective risk stays `destructive` (the model's downgrade is ignored).
    @Test func modelLabelsDestructiveAsReadOnly_stillGated() {
        let call = ToolCall(
            verb: "delete_file",
            args: [ActionArg(name: "path", value: "~/Documents/thesis.txt", taint: .trusted)],
            modelClaimedRisk: .readOnly          // the model LIES — claims it's safe
        )

        let result = gate.gateToolCall(call)
        #expect(result.decision == .requiresApproval)            // destructive can never auto-run
        #expect(result.effectiveRisk == .destructiveExternal)            // model cannot downgrade tool risk
        #expect(gate.planToolRisk(verb: "delete_file") == .destructiveExternal)
    }

    /// Read-only and reversible tool-derived verbs auto-run in the loop (no human needed).
    @Test func readOnlyAndReversible_autoRun() {
        #expect(gate.gateToolCall(ToolCall(verb: "inspect_window_state")).decision == .autoRun)
        #expect(gate.gateToolCall(ToolCall(verb: "launch_app")).decision == .autoRun)
    }

    /// A tainted (attacker-influenceable) arg escalates even a reversible verb to approval.
    @Test func taintedArg_escalatesToApproval() {
        let call = ToolCall(
            verb: "type_text",
            args: [ActionArg(name: "text", value: "rm -rf ~", taint: .attacker_influenceable)]
        )
        #expect(gate.gateToolCall(call).decision == .requiresApproval)
    }

    /// An UNKNOWN verb is never auto-run on the model's word — the floor is the HIGHEST tier, so
    /// even an unknown verb the model calls read_only is gated, and reported at `.destructiveExternal`.
    @Test func unknownVerb_floorsAtHighest_modelClaimReadOnly_stillGated() {
        #expect(gate.planToolRisk(verb: "frobnicate") == .destructiveExternal)
        let call = ToolCall(verb: "frobnicate", modelClaimedRisk: .readOnly)
        let result = gate.gateToolCall(call)
        #expect(result.decision == .requiresApproval)
        #expect(result.effectiveRisk == .destructiveExternal)
    }

    /// The model CAN raise a tier: a read_only verb the model marks mutating is gated to approval.
    @Test func modelMayRaise_readOnlyClaimedMutating_isGated() {
        let call = ToolCall(verb: "screenshot", modelClaimedRisk: .mutating)
        let result = gate.gateToolCall(call)
        #expect(result.effectiveRisk == .mutating)               // raised above the read_only floor
        #expect(result.decision == .requiresApproval)
    }
}
