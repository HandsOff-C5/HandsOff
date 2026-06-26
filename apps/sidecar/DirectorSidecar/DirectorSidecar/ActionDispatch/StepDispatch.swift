//
//  StepDispatch.swift
//  DirectorSidecar
//
//  Port of @handsoff/actions step-dispatch.ts — the pure, UI-free step → tool / risk /
//  dispatch helpers for the autonomous loop (Track B). They translate a `Contracts.ActionStep`
//  (the six legacy kinds + the full-surface `tool_call`) into the driver tool name, the
//  risk-relevant target, and the flat (tool, args) the generic `driver.call` passthrough (U1)
//  executes — and fold a plan's effective risk + find the first step that fails the per-call
//  gate. The loop (PORTING.md § Porting Order 3) composes these with the live driver.
//
//  FAITHFUL-PORT DIVERGENCE (typed tool_call): TS types `tool_call.tool` as a string and
//  re-parses it with `safeParseDriverTool`, so `driverToolForStep` has a "hallucinated name →
//  get_window_state placeholder" branch. In Swift the decoded `ActionStep.toolCall` already
//  carries a validated `Contracts.DriverTool` (an off-surface name fails the decode upstream),
//  so that placeholder branch is unreachable for a decoded step — the safe-default for a raw
//  model string still lives in `Contracts.DriverTool.parse` / `ToolRisk.riskForToolName`,
//  which the loop calls BEFORE a step is constructed. See PORTING.md note for Track B.
//

import Foundation

/// Caseless namespace for the step-dispatch helpers (free functions TS-side).
enum StepDispatch {
    // Driver tools that click an element (and so get commit-pattern escalation). Compared by
    // wire name because `toolNameForStep` yields a String (it may be a raw model tool name).
    private static let clickToolNames: Set<String> = ["click", "right_click", "double_click"]

    /// `driverToolForStep`: the driver tool each step dispatches as. A decoded `tool_call`
    /// carries its validated tool verbatim; the legacy six kinds map to their driver tool so
    /// the rule resolver + gate key on the same vocabulary.
    static func driverToolForStep(_ step: Contracts.ActionStep) -> Contracts.DriverTool {
        switch step {
        case let .toolCall(_, _, tool, _): return tool
        case .clickElement: return .click
        case .typeText: return .typeText
        case .setValue: return .setValue
        case .launchApp: return .launchApp
        // inspect_window_state / capture_screenshot are read-only perception.
        case .inspectWindowState, .captureScreenshot: return .getWindowState
        }
    }

    /// `toolNameForStep`: the raw tool name a step calls (the verbatim tool for a `tool_call`,
    /// the mapped driver tool's wire name for a legacy kind).
    static func toolNameForStep(_ step: Contracts.ActionStep) -> String {
        if case let .toolCall(_, _, tool, _) = step { return tool.rawValue }
        return driverToolForStep(step).rawValue
    }

    /// `elementIndexForStep`: the element index a step targets, from its typed target (legacy
    /// kinds) or its raw driver args (`element_index`, full-surface tool_call).
    static func elementIndexForStep(_ step: Contracts.ActionStep) -> Int? {
        if case let .toolCall(_, _, _, args) = step {
            if case let .number(value) = args["element_index"] { return Int(value) }
            return nil
        }
        return step.actionTarget?.elementIndex
    }

    /// `toolCallTargetForStep`: the risk-relevant target for a click-ish step, looked up by
    /// index in the latest snapshot's perceived AX elements so `riskForToolCall` can escalate
    /// a *commit* click (Send/Delete/…) to mutating. Only clicks get a target; absent element
    /// metadata leaves the gate to its safe default (gate an unidentifiable click).
    static func toolCallTargetForStep(_ step: Contracts.ActionStep,
                                      _ observation: Contracts.GoalLoopObservation?) -> Contracts.ToolCallTarget? {
        guard clickToolNames.contains(toolNameForStep(step)) else { return nil }
        guard let index = elementIndexForStep(step) else { return nil }
        guard let element = observation?.state?.elements.first(where: { $0.index == index }) else { return nil }
        return Contracts.ToolCallTarget(
            element: .init(role: element.role,
                           title: element.label,
                           label: element.label,
                           value: element.value),
            key: nil, keys: nil, pageAction: nil)
    }

    /// `driverCallForStep`: map any step to the (tool, args) the generic driver passthrough
    /// executes. A `tool_call` passes its flat args straight through (the driver's snake_case
    /// shape); the legacy kinds translate to flat args from their target's surface pid/windowId.
    static func driverCallForStep(_ step: Contracts.ActionStep) -> (tool: String, args: [String: Contracts.JSONValue]) {
        switch step {
        case let .toolCall(_, _, tool, args):
            return (tool.rawValue, args)
        case let .launchApp(_, _, appName, bundleId):
            var args: [String: Contracts.JSONValue] = ["app_name": .string(appName)]
            if let bundleId { args["bundle_id"] = .string(bundleId) }
            return ("launch_app", args)
        case let .clickElement(_, _, target):
            return ("click", baseArgs(target))
        case let .typeText(_, _, target, text):
            var args = baseArgs(target)
            args["text"] = .string(text)
            return ("type_text", args)
        case let .setValue(_, _, target, value):
            var args = baseArgs(target)
            args["value"] = .string(value)
            return ("set_value", args)
        // inspect_window_state / capture_screenshot → a read-only window probe.
        case let .inspectWindowState(_, _, target), let .captureScreenshot(_, _, target):
            return ("get_window_state", baseArgs(target))
        }
    }

    private static func baseArgs(_ target: Contracts.ActionTarget) -> [String: Contracts.JSONValue] {
        var base: [String: Contracts.JSONValue] = [:]
        if let pid = target.surface.pid { base["pid"] = .number(Double(pid)) }
        if let windowId = target.surface.windowId { base["window_id"] = .number(Double(windowId)) }
        if let index = target.elementIndex { base["element_index"] = .number(Double(index)) }
        return base
    }

    /// `maxRisk`: the higher-ranked of two risk levels (delegates to the single policy fold).
    static func maxRisk(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        RiskLevel.max(lhs, rhs)
    }

    /// `planToolRisk`: the effective risk of a whole one-action-per-tick plan — the MAX over
    /// each step's tool-derived risk (a commit click escalates to mutating) AND the plan's
    /// declared `risk_level`. The max means the gate can ESCALATE but the model can never
    /// DOWNGRADE below what its own tool risk implies (KD3 anti-bypass). `riskForToolName`
    /// (not `riskForToolCall`) so any raw tool name is gated as mutating rather than throwing.
    static func planToolRisk(_ plan: Contracts.ActionPlan,
                             _ observation: Contracts.GoalLoopObservation?) -> RiskLevel {
        plan.actionPlan.reduce(plan.riskLevel) { acc, step in
            let risk = Contracts.ToolRisk.riskForToolName(
                toolNameForStep(step), target: toolCallTargetForStep(step, observation))
            return RiskLevel.max(acc, risk)
        }
    }

    /// `withEffectiveRisk`: stamp the gate's effective (possibly escalated) risk onto the ready
    /// intent so the displayed plan + the approval surface agree with the loop's pause.
    /// Immutable — returns a new intent (the same value when the risk is unchanged).
    static func withEffectiveRisk(_ intent: Contracts.ResolvedIntent.Ready,
                                  risk: RiskLevel) -> Contracts.ResolvedIntent.Ready {
        if risk == intent.riskLevel { return intent }
        let requires = risk.requiresApproval
        let plan = intent.actionPlan.withRisk(risk, requiresApproval: requires)
        return intent.withRisk(risk, requiresApproval: requires, actionPlan: plan)
    }

    /// `firstBlockedStep`: run every step through the per-call gate; return the first blocked
    /// result if any step needs an approval it doesn't have, else nil. The gate is derived from
    /// the tool + target, never the model's claim, so a commit step blocks when unapproved.
    static func firstBlockedStep(_ steps: [Contracts.ActionStep],
                                 _ observation: Contracts.GoalLoopObservation?,
                                 approved: Bool) -> Contracts.CuaActionResult? {
        for step in steps {
            let tool = driverToolForStep(step)
            let target = toolCallTargetForStep(step, observation)
            if let blocked = ToolCallGate.gate(tool: tool, target: target, approved: approved).blockedResult {
                return blocked
            }
        }
        return nil
    }
}

// MARK: - Construction helpers for the decode-only contract types

// The full-shape contract types (ActionPlan, ResolvedIntent.Ready) are decode-only (custom
// `init(from:)`, no memberwise init) so they faithfully reject malformed JSON. `withEffectiveRisk`
// must rebuild them with a re-derived risk + gate, so these extensions add the memberwise inits
// and immutable copy helpers the dispatch layer needs — kept here (not in the contract files) so
// the contract types stay pure decoders.

extension Contracts.ActionStep {
    /// The surface a legacy kind addresses; nil for `launch_app` (no surface) and `tool_call`
    /// (raw flat args, no typed target).
    var actionTarget: Contracts.ActionTarget? {
        switch self {
        case let .inspectWindowState(_, _, target),
             let .clickElement(_, _, target),
             let .captureScreenshot(_, _, target):
            return target
        case let .typeText(_, _, target, _), let .setValue(_, _, target, _):
            return target
        case .launchApp, .toolCall:
            return nil
        }
    }
}

extension Contracts.ActionPlan {
    init(id: String, summary: String, riskLevel: RiskLevel, requiresApproval: Bool,
         targetAgent: Contracts.TargetAgent, actionPlan: [Contracts.ActionStep]) {
        self.id = id
        self.summary = summary
        self.riskLevel = riskLevel
        self.requiresApproval = requiresApproval
        self.targetAgent = targetAgent
        self.actionPlan = actionPlan
    }

    /// A copy with a re-derived risk + gate (every other field unchanged).
    func withRisk(_ riskLevel: RiskLevel, requiresApproval: Bool) -> Self {
        Self(id: id, summary: summary, riskLevel: riskLevel, requiresApproval: requiresApproval,
             targetAgent: targetAgent, actionPlan: actionPlan)
    }
}

extension Contracts.ResolvedIntent.Ready {
    init(id: String, input: Contracts.IntentInput, intentType: Contracts.IntentType,
         referent: Contracts.SelectedReferent?, constraints: [String], riskLevel: RiskLevel,
         requiresApproval: Bool, targetAgent: Contracts.TargetAgent,
         actionPlan: Contracts.ActionPlan, createdAt: String) {
        self.id = id
        self.input = input
        self.intentType = intentType
        self.referent = referent
        self.constraints = constraints
        self.riskLevel = riskLevel
        self.requiresApproval = requiresApproval
        self.targetAgent = targetAgent
        self.actionPlan = actionPlan
        self.createdAt = createdAt
    }

    /// A copy with a re-derived risk + gate and the matching re-gated plan.
    func withRisk(_ riskLevel: RiskLevel, requiresApproval: Bool,
                  actionPlan: Contracts.ActionPlan) -> Self {
        Self(id: id, input: input, intentType: intentType, referent: referent,
             constraints: constraints, riskLevel: riskLevel, requiresApproval: requiresApproval,
             targetAgent: targetAgent, actionPlan: actionPlan, createdAt: createdAt)
    }
}
