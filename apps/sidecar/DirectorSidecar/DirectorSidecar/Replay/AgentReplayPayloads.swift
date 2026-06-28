//
//  AgentReplayPayloads.swift
//  DirectorSidecar
//

import Foundation

enum AgentReplayPayloads {
    static func transcript(_ transcript: Contracts.FinalTranscript) -> Contracts.JSONValue {
        var fields: [String: Contracts.JSONValue] = [
            "text": .string(transcript.text),
            "confidence": .number(transcript.confidence),
            "latencyMs": .number(transcript.latencyMs),
            "receivedAt": .number(transcript.receivedAt),
        ]
        if let words = transcript.words {
            fields["words"] = .array(words.map { word in
                .object([
                    "text": .string(word.text),
                    "startMs": .number(word.startMs),
                    "endMs": .number(word.endMs),
                    "confidence": .number(word.confidence),
                ])
            })
        }
        return .object(fields)
    }

    static func intent(
        _ intent: Contracts.ResolvedIntent,
        tick: Int,
        durationMs: Double
    ) -> Contracts.JSONValue {
        var fields: [String: Contracts.JSONValue] = [
            "intentId": .string(intent.id),
            "status": .string(intentStatus(intent)),
            "tick": .number(Double(tick)),
            "durationMs": .number(durationMs),
        ]
        switch intent {
        case let .ready(ready):
            fields["risk"] = .string(ready.riskLevel.rawValue)
            fields["requiresApproval"] = .bool(ready.requiresApproval)
            fields["actionPlanId"] = .string(ready.actionPlan.id)
            fields["summary"] = .string(ready.actionPlan.summary)
            fields["toolCalls"] = .array(ready.actionPlan.actionPlan.map(actionStep(_:)))
        case let .needsClarification(pending), let .blocked(pending):
            fields["reason"] = .string(pending.reason)
            fields["requiresApproval"] = .bool(pending.requiresApproval)
        case let .satisfied(satisfied):
            fields["summary"] = .string(satisfied.summary)
        }
        return .object(fields)
    }

    static func approval(decision: String, risk: String, actionCount: Int) -> Contracts.JSONValue {
        .object([
            "decision": .string(decision),
            "risk": .string(risk),
            "actionCount": .number(Double(actionCount)),
        ])
    }

    static func toolCallStarted(tool: String, args: [String: Contracts.JSONValue]) -> Contracts.JSONValue {
        .object([
            "tool": .string(tool),
            "args": .object(replayArgs(tool: tool, args: args)),
        ])
    }

    static func toolCallFinished(
        tool: String,
        args: [String: Contracts.JSONValue],
        result: Contracts.CuaActionResult,
        status: String
    ) -> Contracts.JSONValue {
        .object([
            "tool": .string(tool),
            "args": .object(replayArgs(tool: tool, args: args)),
            "status": .string(status),
            "result": actionResult(result),
        ])
    }

    static func loopTerminal(
        status: String,
        errorClass: String?,
        finalResponse: String?,
        reason: String?
    ) -> Contracts.JSONValue {
        var fields: [String: Contracts.JSONValue] = [
            "status": .string(status),
        ]
        if let errorClass { fields["errorClass"] = .string(errorClass) }
        if let finalResponse { fields["finalResponse"] = .string(finalResponse) }
        if let reason { fields["reason"] = .string(reason) }
        return .object(fields)
    }

    static func actionResultStatus(_ result: Contracts.CuaActionResult) -> String {
        switch result {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .blocked: return "blocked"
        }
    }

    static func actionResultMessage(_ result: Contracts.CuaActionResult) -> String {
        switch result {
        case let .succeeded(summary, _): return summary
        case let .failed(error, _): return error
        case let .blocked(reason, _): return reason
        }
    }

    static func intentStatus(_ intent: Contracts.ResolvedIntent) -> String {
        switch intent {
        case .ready: return "ready"
        case .needsClarification: return "clarification_required"
        case .blocked: return "blocked"
        case .satisfied: return "satisfied"
        }
    }

    static func intentErrorClass(_ intent: Contracts.ResolvedIntent) -> String {
        switch intent {
        case .needsClarification: return "ClarificationRequired"
        case .blocked: return "ResolverBlocked"
        case .ready, .satisfied: return "LoopTerminal"
        }
    }

    static func intentReason(_ intent: Contracts.ResolvedIntent) -> String? {
        switch intent {
        case let .needsClarification(pending), let .blocked(pending): return pending.reason
        case .ready, .satisfied: return nil
        }
    }

    static func satisfiedSummary(_ intent: Contracts.ResolvedIntent) -> String? {
        if case let .satisfied(satisfied) = intent { return satisfied.summary }
        return nil
    }

    private static func actionStep(_ step: Contracts.ActionStep) -> Contracts.JSONValue {
        let (tool, args) = StepDispatch.driverCallForStep(step)
        return .object([
            "stepId": .string(step.id),
            "label": .string(step.label),
            "tool": .string(tool),
            "args": .object(replayArgs(tool: tool, args: args)),
        ])
    }

    private static func actionResult(_ result: Contracts.CuaActionResult) -> Contracts.JSONValue {
        switch result {
        case let .succeeded(summary, state):
            return .object([
                "status": .string("succeeded"),
                "summary": .string(summary),
                "state": windowState(state),
            ])
        case let .failed(error, state):
            return .object([
                "status": .string("failed"),
                "error": .string(error),
                "state": windowState(state),
            ])
        case let .blocked(reason, state):
            return .object([
                "status": .string("blocked"),
                "reason": .string(reason),
                "state": windowState(state),
            ])
        }
    }

    private static func windowState(_ state: Contracts.CuaWindowState?) -> Contracts.JSONValue {
        guard let state else { return .null }
        return .object([
            "surface": surface(state.surface),
            "capturedAt": .string(state.capturedAt),
            "elementCount": .number(Double(state.elementCount)),
            "elements": .array(state.elements.map(elementPayload(_:))),
        ])
    }

    private static func elementPayload(_ element: Contracts.CuaElement) -> Contracts.JSONValue {
        var fields: [String: Contracts.JSONValue] = [
            "id": .string(element.id),
            "index": element.index.map { .number(Double($0)) } ?? .null,
            "role": element.role.map(Contracts.JSONValue.string) ?? .null,
            "label": element.label.map(Contracts.JSONValue.string) ?? .null,
        ]
        if let value = element.value {
            fields["valueLength"] = .number(Double(value.count))
        }
        return .object(fields)
    }

    private static func surface(_ surface: Contracts.SurfaceSnapshot) -> Contracts.JSONValue {
        .object([
            "id": .string(surface.id),
            "title": .string(surface.title),
            "app": .string(surface.app),
            "pid": surface.pid.map { .number(Double($0)) } ?? .null,
            "windowId": surface.windowId.map { .number(Double($0)) } ?? .null,
            "availability": .string(surface.availability.rawValue),
            "accessStatus": .string(surface.accessStatus.rawValue),
        ])
    }

    private static func replayArgs(
        tool: String,
        args: [String: Contracts.JSONValue]
    ) -> [String: Contracts.JSONValue] {
        var fields = args
        switch tool {
        case "type_text":
            redactInputArg("text", in: &fields)
        case "set_value":
            redactInputArg("value", in: &fields)
        default:
            break
        }
        return fields
    }

    private static func redactInputArg(_ key: String, in fields: inout [String: Contracts.JSONValue]) {
        guard let value = fields.removeValue(forKey: key) else { return }
        if case let .string(input) = value {
            fields["inputLength"] = .number(Double(input.count))
        }
    }
}
