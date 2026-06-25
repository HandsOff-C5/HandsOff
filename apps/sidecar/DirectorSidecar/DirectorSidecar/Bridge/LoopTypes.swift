//
//  LoopTypes.swift
//  DirectorSidecar
//
//  G2 loop wire types for the `transcript` / `referents` / `intent` topics — mirrors
//  @handsoff/contracts transcript.ts, surface.ts, referent.ts, intent.ts + action-plan.ts.
//  The HUD renders these read-only (G2a). `ResolvedIntentLite` is a deliberate lite mirror
//  (plan steps + mutation diff live in the Inspector, G4) per director-bridge-contract.md §5.
//  Drift-guarded by decode tests; an unknown enum/shape fails the frame (dropped, not fatal).
//

import Foundation

/// `transcript` topic — @handsoff/contracts `TranscriptEvent` (partial | final).
struct TranscriptEvent: Codable, Sendable, Equatable {
    let kind: String        // "partial" | "final"
    let text: String
    let confidence: Double  // 0...1
    let latencyMs: Double
    let receivedAt: Double  // epoch ms

    var isPartial: Bool { kind == "partial" }
    var isLowConfidence: Bool { confidence < 0.5 }
}

/// One resolvable surface — @handsoff/contracts `SurfaceSnapshot` (the referent chips).
struct SurfaceSnapshot: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let app: String
    let pid: Int?
    let windowId: Int?
    let availability: String?
    let accessStatus: String?
}

/// The persisted pointing result — @handsoff/contracts `SelectedReferent`.
struct SelectedReferent: Codable, Sendable, Equatable {
    let id: String
    let source: String
    let confidence: Double
}

/// `referents` topic payload: the candidate surfaces + the selected referent (when resolved).
/// Envelope shape is co-owned (not yet published — BLOCKER-1); confirm with the contracts owner.
struct ReferentsPayload: Codable, Sendable, Equatable {
    let surfaces: [SurfaceSnapshot]
    let selected: SelectedReferent?
}

/// READ/WRITE/EXEC tag inferred from an ActionStep.kind (G4 Inspector — confirm with the
/// contracts owner). Read = inspect/screenshot; Write = click/type/set; Exec = launch.
enum CapabilityTag: String, Sendable {
    case read = "READ"
    case write = "WRITE"
    case exec = "EXEC"

    static func from(kind: String) -> CapabilityTag {
        switch kind {
        case "inspect_window_state", "capture_screenshot": return .read
        case "click_element", "type_text", "set_value": return .write
        case "launch_app": return .exec
        default: return .read
        }
    }
}

/// A lite plan step for the Inspector — @handsoff/contracts `ActionStep` (action-plan.ts). Carries
/// the proposed `text`/`value` (the "after"); the prior value is not in the contract, so the
/// mutation preview shows proposed-only (see G4 #1 data-plane blocker).
struct ActionStepLite: Identifiable, Decodable, Sendable, Equatable {
    let id: String
    let label: String
    let kind: String
    let targetTitle: String?
    let proposed: String?   // text (type_text) or value (set_value)

    var tag: CapabilityTag { .from(kind: kind) }

    private enum Key: String, CodingKey { case id, label, kind, target, text, value }
    private struct Target: Decodable {
        let surface: Surface?
        struct Surface: Decodable { let title: String? }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(String.self, forKey: .kind)
        targetTitle = try c.decodeIfPresent(Target.self, forKey: .target)?.surface?.title
        let text = try c.decodeIfPresent(String.self, forKey: .text)
        let value = try c.decodeIfPresent(String.self, forKey: .value)
        proposed = text ?? value
    }

    init(id: String, label: String, kind: String, targetTitle: String?, proposed: String?) {
        self.id = id
        self.label = label
        self.kind = kind
        self.targetTitle = targetTitle
        self.proposed = proposed
    }
}

/// `intent` topic — a lite mirror of `ResolvedIntent` (discriminated on `status`). The HUD reads
/// status/risk/summary; the Inspector (G4) also reads the plan `steps`.
struct ResolvedIntentLite: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable {
        case ready
        case clarificationRequired = "clarification_required"
        case blocked
    }

    let id: String?       // intent id — used as the ApprovalDecision.actionId on greenlight/reject
    let status: Status
    let intentType: String?
    let riskLevel: RiskLevel?
    let requiresApproval: Bool
    let summary: String?         // action_plan.summary (ready)
    let reason: String?          // clarification_required / blocked
    let steps: [ActionStepLite]  // action_plan.action_plan (Inspector plan rows)

    private enum Key: String, CodingKey {
        case id, status, intent_type, risk_level, requires_approval, reason, action_plan
    }
    private struct PlanLite: Decodable {
        let summary: String?
        let action_plan: [ActionStepLite]?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        status = try c.decode(Status.self, forKey: .status)
        intentType = try c.decodeIfPresent(String.self, forKey: .intent_type)
        riskLevel = try c.decodeIfPresent(RiskLevel.self, forKey: .risk_level)
        requiresApproval = try c.decodeIfPresent(Bool.self, forKey: .requires_approval) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        let plan = try c.decodeIfPresent(PlanLite.self, forKey: .action_plan)
        summary = plan?.summary
        steps = plan?.action_plan ?? []
    }

    /// Direct construction (mocks / tests / the HUD reducer).
    init(id: String? = nil, status: Status, intentType: String?, riskLevel: RiskLevel?,
         requiresApproval: Bool, summary: String?, reason: String?, steps: [ActionStepLite] = []) {
        self.id = id
        self.status = status
        self.intentType = intentType
        self.riskLevel = riskLevel
        self.requiresApproval = requiresApproval
        self.summary = summary
        self.reason = reason
        self.steps = steps
    }
}
