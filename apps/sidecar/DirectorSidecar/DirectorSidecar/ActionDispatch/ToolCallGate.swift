//
//  ToolCallGate.swift
//  DirectorSidecar
//
//  Port of @handsoff/actions gate-tool-call.ts — the per-call gate for the agentic loop.
//  Keyed on a single tool call: the gate is DERIVED from the tool's risk
//  (`Contracts.ToolRisk.riskForToolCall`) and NEVER from a model-supplied claim, so a model
//  that labels a `click` on "Send" as read_only cannot bypass approval.
//
//  `allowed` is true when the call may run now: either its risk auto-runs
//  (read_only/reversible) or a matching approval has been granted. When blocked, `result`
//  carries a typed `blocked` Contracts.CuaActionResult so the loop can audit it identically
//  to any other dispatched call.
//
//  This is the actions-layer execution helper (Track B). It composes with the live driver
//  in the loop (PORTING.md § Porting Order 3) — this unit is the pure gate only.
//

import Foundation

/// `ToolCallGateResult`: a discriminated result mirroring the TS union. `blocked` carries the
/// typed `blocked` action result the loop records.
enum ToolCallGateResult: Equatable {
    case allowed(risk: RiskLevel)
    case blocked(risk: RiskLevel, result: Contracts.CuaActionResult)

    /// True when the call may run now.
    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    /// The derived per-call risk, regardless of outcome.
    var risk: RiskLevel {
        switch self {
        case let .allowed(risk), let .blocked(risk, _): return risk
        }
    }

    /// The typed blocked result, or nil when allowed.
    var blockedResult: Contracts.CuaActionResult? {
        if case let .blocked(_, result) = self { return result }
        return nil
    }
}

/// `gateToolCall`. Caseless namespace for the single pure gate function.
enum ToolCallGate {
    static func gate(tool: Contracts.DriverTool,
                     target: Contracts.ToolCallTarget? = nil,
                     approved: Bool = false) -> ToolCallGateResult {
        let risk = Contracts.ToolRisk.riskForToolCall(tool, target: target)
        if !risk.requiresApproval { return .allowed(risk: risk) }
        if approved { return .allowed(risk: risk) }
        return .blocked(
            risk: risk,
            result: .blocked(
                reason: "Approval required before executing \(riskLabel(risk)) tool \(tool.rawValue)",
                state: nil))
    }

    private static func riskLabel(_ risk: RiskLevel) -> String {
        risk == .destructiveExternal ? "destructive/external" : risk.rawValue
    }
}
