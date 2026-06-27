//
//  RiskGate.swift
//  DirectorSidecar
//
//  Phase 4a — the "raise-never-lower" risk policy (engine INVARIANT I9 / THREAT_MODEL INV-15;
//  ported from App/Sources/LoopSessions/RiskGate.swift). FILES ONLY — not yet wired into the loop.
//
//  INVARIANT — risk is TOOL-DERIVED; the model can never downgrade it. The blast-radius floor is
//  consequence-agnostic: it classifies by what a verb CAN do, not by what the model CLAIMS it will
//  do. A proposal may attach a claimed risk, but the gate only lets it RAISE the tier (e.g. the
//  model knows a button is "Delete" → destructive), NEVER lower it. So a model that mislabels a
//  destructive verb as `read_only` to slip past the greenlight is still gated.
//
//  Loop policy (stricter than a per-turn human gate, because the loop has no human watching each
//  turn): auto-run ONLY read_only / reversible verbs; everything mutating, destructive, UNKNOWN, or
//  carrying a tainted arg requires a human greenlight. An UNKNOWN verb is floored at the HIGHEST
//  tier (`.destructiveExternal`) so it can never auto-run on the model's word.
//
//  Vocabulary REUSE: the tier is the Director's own `RiskLevel` (Theme/StateColors.swift) — its four
//  wire values (read_only/reversible/mutating/destructive) ARE the gate's tier algebra. Only the
//  POLICY (the blast-radius classifier + the raise-never-lower max) is added here. The source engine
//  carries an extra `destructive_external` tier; the Director's wire enum collapses it to
//  `.destructiveExternal`, so this port classifies irreversible-external verbs directly as `.destructiveExternal`.

import Foundation

/// One tool call the autonomous loop wants to run, as seen by the gate.
struct ToolCall: Equatable, Sendable {
    /// The verb/tool the agent proposes (e.g. `launch_app`, `set_value`, `delete_file`).
    let verb: String
    /// The call's args — each carries taint (a tainted arg escalates regardless of verb).
    let args: [ActionArg]
    /// What the model/binder CLAIMED the risk is (untrusted — may only raise the tier, never lower).
    let modelClaimedRisk: RiskLevel?

    init(verb: String, args: [ActionArg] = [], modelClaimedRisk: RiskLevel? = nil) {
        self.verb = verb
        self.args = args
        self.modelClaimedRisk = modelClaimedRisk
    }
}

/// The gate's verdict for one tool call.
enum GateDecision: String, Equatable, Sendable {
    /// read_only / reversible, untainted, known verb — the loop may run it without a human.
    case autoRun
    /// mutating / destructive / unknown / tainted — needs an explicit human greenlight.
    case requiresApproval
}

/// The gate's result — the decision plus the effective (tool-derived, possibly model-RAISED) risk.
struct GateResult: Equatable, Sendable {
    let decision: GateDecision
    let effectiveRisk: RiskLevel
    init(decision: GateDecision, effectiveRisk: RiskLevel) {
        self.decision = decision
        self.effectiveRisk = effectiveRisk
    }
}

struct RiskGate {
    init() {}

    /// The TOOL-DERIVED risk floor for a verb — consequence-agnostic, from the verb alone. The model
    /// can never lower this. UNKNOWN verbs floor at the HIGHEST tier (`.destructiveExternal`) so they can
    /// never auto-run on the model's word.
    func planToolRisk(verb: String) -> RiskLevel {
        let v = verb.lowercased()

        // Destructive / irreversible-external — delete, send, trash, format, purge, … (greenlight).
        if Self.destructiveTokens.contains(where: v.contains) { return .destructiveExternal }
        // Observe-only — re-read AX / screenshot / focus / raise. No state change.
        if Self.readOnlyVerbs.contains(v) { return .readOnly }
        // Reversible — launch / move / scroll / type / open-tab (trivially undone).
        if Self.reversibleVerbs.contains(v) { return .reversible }
        // Known state-changers — click / set_value / submit / key presses.
        if Self.mutatingVerbs.contains(v) { return .mutating }
        // Unknown verb — floored at the highest tier so it cannot auto-run on the model's word.
        return .destructiveExternal
    }

    /// Gate one tool call: effective tier = MAX(tool-derived floor, model-claimed) — the model can
    /// only RAISE. A tainted arg escalates to approval regardless of tier.
    func gateToolCall(_ call: ToolCall) -> GateResult {
        let floor = planToolRisk(verb: call.verb)
        let modelTier = call.modelClaimedRisk ?? floor
        let effective = Self.higher(floor, modelTier)   // model may raise, never lower

        let tainted = call.args.contains { $0.taint == .attacker_influenceable }
        let safeTier = effective == .readOnly || effective == .reversible
        let decision: GateDecision = (safeTier && !tainted) ? .autoRun : .requiresApproval

        return GateResult(decision: decision, effectiveRisk: effective)
    }

    // MARK: - Verb tables (the scoped allow-list dimension of the loop policy)

    private static let readOnlyVerbs: Set<String> = [
        "get_window_state", "getwindowstate", "inspect_window_state", "snapshot",
        "screenshot", "capture_screenshot", "focus", "raise",
    ]
    private static let reversibleVerbs: Set<String> = [
        "launch", "launch_app", "launchapp", "move", "open_tab", "opentab",
        "type", "type_text", "typetext", "scroll",
    ]
    private static let mutatingVerbs: Set<String> = [
        "click", "click_element", "clickelement", "click_point",
        "set_value", "setvalue", "submit", "press_key", "presskey", "hotkey",
    ]
    /// Substrings that mark an irreversible-external action — risk floor `.destructiveExternal`.
    /// (Over-matching only ever gates MORE, the safe direction; `rm` is omitted because the loop
    /// gates AX verbs and it substring-collides with innocuous words like "perform"/"format".)
    private static let destructiveTokens: [String] = [
        "delete", "trash", "remove", "send", "purge", "erase", "format", "destroy", "wipe",
    ]

    // MARK: - Tier algebra (over the Director's RiskLevel)

    /// The higher of two tiers by severity rank (used to let the model RAISE but not lower).
    private static func higher(_ a: RiskLevel, _ b: RiskLevel) -> RiskLevel {
        rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ tier: RiskLevel) -> Int {
        switch tier {
        case .readOnly: return 0
        case .reversible: return 1
        case .mutating: return 2
        case .destructiveExternal: return 3
        }
    }
}
