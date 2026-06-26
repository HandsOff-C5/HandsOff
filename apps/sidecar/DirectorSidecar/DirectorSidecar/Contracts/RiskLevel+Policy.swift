//
//  RiskLevel+Policy.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts action-plan.ts risk vocabulary + approval policy
//  (`RISK_LEVELS`, `riskLevelRequiresApproval`) and tool-risk.ts risk ranking (`RISK_RANK`,
//  `effectiveToolCallRisk`'s max-fold). The `RiskLevel` enum itself stays top-level in
//  Theme/StateColors.swift (the UI binds it); this extension is the canonical policy.
//
//  CONTRACT (do not drift — ADR 0005 § CUA and LLM loop implications): the four tiers are
//  read_only | reversible | mutating | destructive_external, and approval is required for
//  `mutating` and `destructive_external`. The stale Swift `.destructive` case + "allow
//  mutating commits" policy is FIXED — see PORTING.md Migration Notes. Risk is derived
//  locally, never trusted from the model.
//

import Foundation

extension RiskLevel {
    /// `RISK_LEVELS` — the four tiers in ascending order of severity.
    static let levels: [RiskLevel] = [.readOnly, .reversible, .mutating, .destructiveExternal]

    /// `riskLevelRequiresApproval`: mutating and destructive_external gate; read_only and
    /// reversible auto-run.
    var requiresApproval: Bool {
        switch self {
        case .readOnly, .reversible: return false
        case .mutating, .destructiveExternal: return true
        }
    }

    /// `RISK_RANK` — total order used to fold a set of per-call risks to their max
    /// (`effectiveToolCallRisk`): a goal that reads + sends gates as a "send".
    var rank: Int {
        switch self {
        case .readOnly: return 0
        case .reversible: return 1
        case .mutating: return 2
        case .destructiveExternal: return 3
        }
    }

    /// The higher-severity of two risks.
    static func max(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        lhs.rank >= rhs.rank ? lhs : rhs
    }

    /// Effective risk of a set of intended calls — the max over their per-call risks.
    /// Empty set is `read_only` (nothing to gate), matching `effectiveToolCallRisk`.
    static func effective(of risks: [RiskLevel]) -> RiskLevel {
        risks.reduce(.readOnly) { max($0, $1) }
    }
}
