//
//  ResolvedIntentFactory.swift
//  DirectorSidecar
//
//  Construction seam for the LLM resolver (Track C). The contract result types
//  (`Contracts.ResolvedIntent.{Ready,Pending,Satisfied}`, `Contracts.ActionPlan`) are
//  Decodable-ONLY by design — they exist to decode real TS-shaped JSON in the audit /
//  golden path (PORTING.md note 4). The resolver, by contrast, PRODUCES them in memory
//  (the TS `nextToolCallToIntent` builds the object directly), so this file adds the
//  memberwise initializers + the `blockedIntent` factory that mirrors `fuse-intent.ts`.
//
//  Kept in a SEPARATE file (not edited into the contract files) so the contracts port and
//  this resolver port stay independently owned. The initializers reproduce the decoders'
//  invariants by construction: a `satisfied`/`blocked`/`clarification_required` intent always
//  carries `requires_approval = false` + `target_agent = .none`.
//
//  The `Contracts.ActionPlan` and `Contracts.ResolvedIntent.Ready` memberwise inits this
//  resolver also needs are provided by the dispatch track (ActionDispatch/StepDispatch.swift),
//  which builds the same types when it re-derives effective risk — reused here, not duplicated.
//  This file owns only the `Pending`/`Satisfied` inits and the `blockedIntent` factory, which
//  the dispatch layer does not construct.
//

import Foundation

extension Contracts.ResolvedIntent.Pending {
    init(
        id: String,
        input: Contracts.IntentInput,
        intentType: Contracts.IntentType?,
        constraints: [String],
        riskLevel: RiskLevel?,
        requiresApproval: Bool,
        targetAgent: Contracts.TargetAgent,
        reason: String,
        clarification: Contracts.ClarificationRequest?,
        createdAt: String
    ) {
        self.id = id
        self.input = input
        self.intentType = intentType
        self.constraints = constraints
        self.riskLevel = riskLevel
        self.requiresApproval = requiresApproval
        self.targetAgent = targetAgent
        self.reason = reason
        self.clarification = clarification
        self.createdAt = createdAt
    }
}

extension Contracts.ResolvedIntent.Satisfied {
    init(id: String, input: Contracts.IntentInput, summary: String, createdAt: String) {
        self.id = id
        self.input = input
        self.summary = summary
        self.createdAt = createdAt
    }
}

extension Contracts.ResolvedIntent {
    /// `blockedIntent` (fuse-intent.ts): the terminal non-ready intent. `status` is
    /// `blocked` or `clarification_required`; both carry no gate and no agent.
    static func blockedIntent(
        status: BlockedStatus,
        input: Contracts.IntentInput,
        id: String,
        createdAt: String,
        reason: String
    ) -> Contracts.ResolvedIntent {
        let pending = Pending(
            id: id,
            input: input,
            intentType: nil,
            constraints: [],
            riskLevel: nil,
            requiresApproval: false,
            targetAgent: .none,
            reason: reason,
            clarification: nil,
            createdAt: createdAt
        )
        switch status {
        case .blocked: return .blocked(pending)
        case .clarificationRequired: return .needsClarification(pending)
        }
    }

    /// The two non-ready terminal statuses `blockedIntent` can produce.
    enum BlockedStatus {
        case blocked
        case clarificationRequired
    }
}
