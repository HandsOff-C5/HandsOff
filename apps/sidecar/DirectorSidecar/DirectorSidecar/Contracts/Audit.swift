//
//  Audit.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts audit.ts — `supervisionAuditEventSchema` (the Intention Log
//  entry, discriminated on `kind`) and `surfaceSelectionRecordSchema`. Faithful to all six
//  audit kinds, including the autonomous-loop per-call `tool_call` record (U3) that carries
//  transcript + bound referent + derived risk + approval provenance.
//
//  Faithful refinements (mirror the zod `.refine`s, enforced as throwing decodes):
//   - every event requires `sessionId` + `actionId` (a kind with no action link fails).
//   - `approval_decided`: the embedded approval's `actionId` must equal the event's `actionId`.
//   - `tool_call`: an unknown driver tool name fails (DriverTool enum decode).
//

import Foundation

extension Contracts {
    /// `surfaceSelectionRecordSchema`: the "select context" audit step — the user pointed
    /// (referent) at a surface (snapshot), which an action later consumed. `actionId` is
    /// optional (selection precedes planning); `sessionId` is always present.
    struct SurfaceSelectionRecord: Codable, Sendable, Equatable {
        let referent: SelectedReferent
        let surface: SurfaceSnapshot
        let sessionId: String
        let actionId: String?
        let selectedAt: String
    }

    /// `supervisionAuditEventSchema`. The shared base (`sessionId`/`actionId`/`recordedAt`)
    /// is carried on every case.
    enum SupervisionAuditEvent: Decodable, Sendable, Equatable {
        case intentCreated(Base, intent: ResolvedIntent)
        case approvalDecided(Base, approval: ApprovalDecision)
        case cuaStateCaptured(Base, phase: CapturePhase, stepId: String, state: CuaWindowState)
        case cuaCall(Base, stepId: String, request: CuaActionRequest, result: CuaActionResult)
        case toolCall(Base, ToolCall)
        case executionFinished(Base, status: ExecutionStatus, result: CuaActionResult?)

        /// The shared audit base every event carries.
        struct Base: Sendable, Equatable {
            let sessionId: String
            let actionId: String
            let recordedAt: String
        }

        enum CapturePhase: String, Decodable, Sendable { case pre, post }

        /// How a per-call action was gated: `auto` (under threshold), or a human decision.
        enum ToolCallApproval: String, Decodable, Sendable { case auto, approved, rejected }

        /// The `tool_call` payload — the full provenance the Intention Log replays.
        struct ToolCall: Sendable, Equatable {
            let transcript: String
            let referent: SelectedReferent?    // null for referent-less calls (get_window_state)
            let tool: DriverTool
            let target: ToolCallTarget?
            let risk: RiskLevel
            let approval: ToolCallApproval
            let result: CuaActionResult
        }

        private enum Key: String, CodingKey {
            case kind, sessionId, actionId, recordedAt
            case intent, approval, phase, stepId, state, request, result, status
            case transcript, referent, tool, target, risk
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let base = Base(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                actionId: try c.decode(String.self, forKey: .actionId),
                recordedAt: try c.decode(String.self, forKey: .recordedAt))

            switch try c.decode(String.self, forKey: .kind) {
            case "intent_created":
                self = .intentCreated(base,
                                      intent: try c.decode(ResolvedIntent.self, forKey: .intent))
            case "approval_decided":
                let approval = try c.decode(ApprovalDecision.self, forKey: .approval)
                guard approval.actionId == base.actionId else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .approval, in: c,
                        debugDescription: "approval actionId must match audit actionId")
                }
                self = .approvalDecided(base, approval: approval)
            case "cua_state_captured":
                self = .cuaStateCaptured(
                    base,
                    phase: try c.decode(CapturePhase.self, forKey: .phase),
                    stepId: try c.decode(String.self, forKey: .stepId),
                    state: try c.decode(CuaWindowState.self, forKey: .state))
            case "cua_call":
                self = .cuaCall(
                    base,
                    stepId: try c.decode(String.self, forKey: .stepId),
                    request: try c.decode(CuaActionRequest.self, forKey: .request),
                    result: try c.decode(CuaActionResult.self, forKey: .result))
            case "tool_call":
                self = .toolCall(base, ToolCall(
                    transcript: try c.decode(String.self, forKey: .transcript),
                    referent: try c.decodeIfPresent(SelectedReferent.self, forKey: .referent),
                    tool: try c.decode(DriverTool.self, forKey: .tool),
                    target: try c.decodeIfPresent(ToolCallTarget.self, forKey: .target),
                    risk: try c.decode(RiskLevel.self, forKey: .risk),
                    approval: try c.decode(ToolCallApproval.self, forKey: .approval),
                    result: try c.decode(CuaActionResult.self, forKey: .result)))
            case "execution_finished":
                self = .executionFinished(
                    base,
                    status: try c.decode(ExecutionStatus.self, forKey: .status),
                    result: try c.decodeIfPresent(CuaActionResult.self, forKey: .result))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c,
                    debugDescription: "Unknown audit event kind: \(other)")
            }
        }
    }
}
