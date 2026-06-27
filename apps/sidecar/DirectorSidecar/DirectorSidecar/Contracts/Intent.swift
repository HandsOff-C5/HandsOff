//
//  Intent.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts intent.ts — `resolvedIntentSchema` and its input closure
//  (`intentInputSchema`, `pointingEvidenceSchema`, `goalSessionInputSchema`,
//  `goalLoopObservationSchema`, `intentTypeSchema`). Pulled into the contracts-first port
//  because the audit `intent_created` event embeds a full `ResolvedIntent`; the LLM-loop
//  resolver/schema (PORTING.md § Porting Order 3) builds ON these, it does not redefine them.
//
//  Distinct from the decode-only `ResolvedIntentLite` (Bridge/LoopTypes.swift), which keeps
//  only status/risk/summary/steps for the HUD + Inspector.
//

import Foundation

extension Contracts {
    /// `intentTypeSchema`.
    enum IntentType: String, Codable, Sendable, CaseIterable {
        case inspect
        case click
        case typeText = "type_text"
        case setValue = "set_value"
        case launch
        case pause
        case stop
    }

    /// `pointingEvidenceSchema`: one perception cue grounding the deixis.
    struct PointingEvidence: Codable, Sendable, Equatable {
        let source: Source
        let confidence: Double
        let strategy: String
        let surface: SurfaceSnapshot?
        let cursor: Cursor?

        enum Source: String, Codable, Sendable, CaseIterable {
            case gesture, gaze, head, face, cursor
            case activeWindow = "active_window"
            case fusion
        }

        struct Cursor: Codable, Sendable, Equatable {
            let x: Double
            let y: Double
        }
    }

    /// `goalLoopObservationSchema`: one tick of the autonomous loop's desktop observation.
    struct GoalLoopObservation: Decodable, Sendable, Equatable {
        let tick: Int
        let capturedAt: String
        let windows: [SurfaceSnapshot]
        let state: CuaWindowState?
        let previousAction: PreviousAction?

        struct PreviousAction: Decodable, Sendable, Equatable {
            let actionId: String
            let result: CuaActionResult
        }
    }

    /// `goalSessionInputSchema`: the running goal + its observation history.
    struct GoalSessionInput: Decodable, Sendable, Equatable {
        let goal: String
        let tick: Int
        let observations: [GoalLoopObservation]
    }

    /// `intentInputSchema`: everything the resolver saw — speech, ≥1 pointing cue,
    /// candidate surfaces, and the optional autonomous-goal session.
    struct IntentInput: Decodable, Sendable, Equatable {
        let sessionId: String
        let finalTranscript: FinalTranscript
        let pointingEvidence: [PointingEvidence]
        let surfaceCandidates: [SurfaceSnapshot]
        let goalSession: GoalSessionInput?
        /// U9: the on-screen text the user pointed at, read from the TemporalBinder-resolved
        /// surface (AX focused-element selection, change-count-gated clipboard). The fusion stays
        /// authoritative for *which* surface; this carries *the text within it* so a compose/act
        /// goal ("summarize this") grounds on the pointed content instead of a guess. Optional —
        /// absent when nothing was selected or the AX grant is missing.
        let selectionText: String?

        private enum Key: String, CodingKey {
            case sessionId, speech, pointingEvidence, surfaceCandidates, goalSession, selectionText
        }
        private enum SpeechKey: String, CodingKey { case finalTranscript }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            let speech = try c.nestedContainer(keyedBy: SpeechKey.self, forKey: .speech)
            finalTranscript = try speech.decode(FinalTranscript.self, forKey: .finalTranscript)
            pointingEvidence = try c.decode([PointingEvidence].self, forKey: .pointingEvidence)
            surfaceCandidates = try c.decode([SurfaceSnapshot].self, forKey: .surfaceCandidates)
            goalSession = try c.decodeIfPresent(GoalSessionInput.self, forKey: .goalSession)
            selectionText = try c.decodeIfPresent(String.self, forKey: .selectionText)
        }
    }

    /// `resolvedIntentSchema`: discriminated on `status`. `ready` carries the gated plan;
    /// `clarificationRequired`/`blocked` carry a reason (+ optional structured clarification);
    /// `satisfied` is a terminal no-op with a summary.
    enum ResolvedIntent: Decodable, Sendable, Equatable {
        case ready(Ready)
        case needsClarification(Pending)   // status: clarification_required
        case blocked(Pending)
        case satisfied(Satisfied)

        struct Ready: Decodable, Sendable, Equatable {
            let id: String
            let input: IntentInput
            let intentType: IntentType
            let referent: SelectedReferent?   // null for referent-less actions (launch by name)
            let constraints: [String]
            let riskLevel: RiskLevel
            let requiresApproval: Bool
            let targetAgent: TargetAgent
            let actionPlan: ActionPlan
            let createdAt: String

            private enum Key: String, CodingKey {
                case id, input, referent, constraints, createdAt
                case intentType = "intent_type"
                case riskLevel = "risk_level"
                case requiresApproval = "requires_approval"
                case targetAgent = "target_agent"
                case actionPlan = "action_plan"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                id = try c.decode(String.self, forKey: .id)
                input = try c.decode(IntentInput.self, forKey: .input)
                intentType = try c.decode(IntentType.self, forKey: .intentType)
                referent = try c.decodeIfPresent(SelectedReferent.self, forKey: .referent)
                constraints = try c.decode([String].self, forKey: .constraints)
                riskLevel = try c.decode(RiskLevel.self, forKey: .riskLevel)
                requiresApproval = try c.decode(Bool.self, forKey: .requiresApproval)
                targetAgent = try c.decode(TargetAgent.self, forKey: .targetAgent)
                actionPlan = try c.decode(ActionPlan.self, forKey: .actionPlan)
                createdAt = try c.decode(String.self, forKey: .createdAt)
            }
        }

        struct Pending: Decodable, Sendable, Equatable {
            let id: String
            let input: IntentInput
            let intentType: IntentType?
            let constraints: [String]
            let riskLevel: RiskLevel?
            let requiresApproval: Bool
            let targetAgent: TargetAgent
            let reason: String
            let clarification: ClarificationRequest?
            let createdAt: String

            private enum Key: String, CodingKey {
                case id, input, constraints, reason, clarification, createdAt
                case intentType = "intent_type"
                case riskLevel = "risk_level"
                case requiresApproval = "requires_approval"
                case targetAgent = "target_agent"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                id = try c.decode(String.self, forKey: .id)
                input = try c.decode(IntentInput.self, forKey: .input)
                intentType = try c.decodeIfPresent(IntentType.self, forKey: .intentType)
                constraints = try c.decodeIfPresent([String].self, forKey: .constraints) ?? []
                riskLevel = try c.decodeIfPresent(RiskLevel.self, forKey: .riskLevel)
                requiresApproval = try c.decode(Bool.self, forKey: .requiresApproval)
                targetAgent = try c.decode(TargetAgent.self, forKey: .targetAgent)
                reason = try c.decode(String.self, forKey: .reason)
                clarification = try c.decodeIfPresent(ClarificationRequest.self, forKey: .clarification)
                createdAt = try c.decode(String.self, forKey: .createdAt)
            }
        }

        struct Satisfied: Decodable, Sendable, Equatable {
            let id: String
            let input: IntentInput
            let summary: String
            let createdAt: String
            // requires_approval is the literal false and target_agent the literal "none"
            // TS-side; decoded + asserted to keep the contract faithful.

            private enum Key: String, CodingKey {
                case id, input, summary, createdAt
                case requiresApproval = "requires_approval"
                case targetAgent = "target_agent"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                id = try c.decode(String.self, forKey: .id)
                input = try c.decode(IntentInput.self, forKey: .input)
                summary = try c.decode(String.self, forKey: .summary)
                createdAt = try c.decode(String.self, forKey: .createdAt)
                let requiresApproval = try c.decode(Bool.self, forKey: .requiresApproval)
                let targetAgent = try c.decode(TargetAgent.self, forKey: .targetAgent)
                guard requiresApproval == false, targetAgent == .none else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .requiresApproval, in: c,
                        debugDescription: "satisfied intent must have requires_approval=false, target_agent=none")
                }
            }
        }

        private enum StatusKey: String, CodingKey { case status }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: StatusKey.self)
            switch try c.decode(String.self, forKey: .status) {
            case "ready": self = .ready(try Ready(from: decoder))
            case "clarification_required": self = .needsClarification(try Pending(from: decoder))
            case "blocked": self = .blocked(try Pending(from: decoder))
            case "satisfied": self = .satisfied(try Satisfied(from: decoder))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .status, in: c,
                    debugDescription: "Unknown resolved intent status: \(other)")
            }
        }
    }
}
