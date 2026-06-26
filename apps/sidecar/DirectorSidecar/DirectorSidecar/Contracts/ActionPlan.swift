//
//  ActionPlan.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts action-plan.ts `actionPlanSchema`, `approvalDecisionSchema`,
//  and `targetAgentSchema`. `ExecutionStatus` is the top-level shared enum (SessionTypes.swift)
//  and is reused, not redefined.
//
//  Faithful refinement: `requires_approval` MUST equal `riskLevelRequiresApproval(risk_level)`
//  — a plan that claims a different gate than its risk implies fails the decode (mirrors the
//  zod `.refine`). This is part of "never trust a model-supplied gate; derive from risk".
//

import Foundation

extension Contracts {
    /// `targetAgentSchema`: which executor a plan/intent dispatches to.
    enum TargetAgent: String, Codable, Sendable, CaseIterable {
        case cuaDriver = "cua-driver"
        case none
    }

    /// `approvalDecisionSchema`: a human decision on a gated action.
    struct ApprovalDecision: Codable, Sendable, Equatable {
        let actionId: String
        let decision: Decision
        let decidedAt: String

        enum Decision: String, Codable, Sendable {
            case approved
            case rejected
        }
    }

    /// `actionPlanSchema`: the proposed plan with its derived risk + gate and the ordered
    /// steps. `risk_level`/`requires_approval` use the contract wire keys.
    struct ActionPlan: Decodable, Sendable, Equatable {
        let id: String
        let summary: String
        let riskLevel: RiskLevel
        let requiresApproval: Bool
        let targetAgent: TargetAgent
        let actionPlan: [ActionStep]

        private enum Key: String, CodingKey {
            case id, summary
            case riskLevel = "risk_level"
            case requiresApproval = "requires_approval"
            case targetAgent = "target_agent"
            case actionPlan = "action_plan"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = try c.decode(String.self, forKey: .id)
            summary = try c.decode(String.self, forKey: .summary)
            riskLevel = try c.decode(RiskLevel.self, forKey: .riskLevel)
            requiresApproval = try c.decode(Bool.self, forKey: .requiresApproval)
            targetAgent = try c.decode(TargetAgent.self, forKey: .targetAgent)
            actionPlan = try c.decode([ActionStep].self, forKey: .actionPlan)

            guard requiresApproval == riskLevel.requiresApproval else {
                throw DecodingError.dataCorruptedError(
                    forKey: .requiresApproval, in: c,
                    debugDescription: "requires_approval must match risk_level")
            }
        }
    }
}
