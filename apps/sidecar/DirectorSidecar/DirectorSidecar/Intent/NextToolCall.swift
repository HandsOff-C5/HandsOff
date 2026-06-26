//
//  NextToolCall.swift
//  DirectorSidecar
//
//  Port of @handsoff/intent src/llm/next-tool-call.ts — the autonomous loop's "head" (U3b).
//  Instead of a whole 6-kind ActionPlan, the model returns the NEXT driver tool call toward
//  the goal given the live perception snapshot, or signals the goal is done / needs
//  clarification / is blocked. The structured-output contract (`nextToolCallSchema`) is the
//  exact shape the CF Worker speaks (workers/llm-intent), so the Swift Worker client
//  (IntentWorkerClient.swift) is a drop-in for the injected OpenAI client in the TS.
//
//  Risk + approval are DERIVED from the tool name here (Contracts.ToolRisk), NEVER trusted
//  from the model — the loop stays authoritative and re-derives against the live snapshot,
//  escalating only a proven commit click.
//

import Foundation

/// `nextToolCallSchema` (the Worker's structured-output `response_format`): the model's
/// single next-action decision. `act` = call a tool; `done` = goal satisfied; `clarify`
/// = ambiguous; `blocked` = impossible/unsafe.
struct NextToolCall: Codable, Sendable, Equatable {
    let status: Status
    /// The driver tool to call when status is `act`. Validated against the real driver
    /// surface downstream — a hallucinated name is blocked.
    let tool: String?
    /// The tool's raw flat args as a JSON object STRING (the driver's snake_case shape).
    /// A string, not an open object, because OpenAI strict structured outputs reject open
    /// objects; parsed back into a record downstream by `parseToolArgs`.
    let args: String?
    /// One-line reasoning for the chosen action (audited; shown in the preview).
    let rationale: String
    /// Filled when status is `done`: what was accomplished.
    let summary: String?
    /// Filled when status is `clarify`/`blocked`: why the loop can't act.
    let reason: String?

    enum Status: String, Codable, Sendable, Equatable {
        case act
        case done
        case clarify
        case blocked
    }
}

/// The next-tool-call resolver + the pure mapping from a `NextToolCall` onto the
/// `Contracts.ResolvedIntent` the controller/UI already speak.
enum NextToolCallResolver {
    static let defaultModel = "gpt-4o-mini"

    /// `resolveNextToolCall`. Sends the goal + live state to the Worker (via `client`), then
    /// maps the model's decision onto a `ResolvedIntent`. Every failure mode the TS handles —
    /// no choice, truncation (`length`), refusal, no parsed result, a thrown transport error —
    /// degrades to a typed blocked/clarification intent, never a Swift `throw` to the loop.
    static func resolveNextToolCall(
        _ input: Contracts.IntentInput,
        client: NextToolCallClient,
        tools: [DriverToolDefinition] = [],
        model: String = defaultModel,
        intentId: String = "intent-llm",
        createdAt: String? = nil
    ) async -> Contracts.ResolvedIntent {
        let stamp = createdAt ?? isoNow()
        let id = intentId

        do {
            let completion = try await client.completeNextToolCall(
                model: model,
                messages: NextToolCallPrompt.buildMessages(input, tools: tools)
            )
            guard let choice = completion.choices.first else {
                return .blockedIntent(status: .blocked, input: input, id: id, createdAt: stamp,
                                      reason: "The intent resolver returned no choice")
            }
            if choice.finishReason == "length" {
                return .blockedIntent(status: .clarificationRequired, input: input, id: id, createdAt: stamp,
                                      reason: "The intent resolver response was truncated")
            }
            if let refusal = choice.message.refusal {
                return .blockedIntent(status: .clarificationRequired, input: input, id: id, createdAt: stamp,
                                      reason: refusal)
            }
            guard let parsed = choice.message.parsed else {
                return .blockedIntent(status: .blocked, input: input, id: id, createdAt: stamp,
                                      reason: "The intent resolver returned no parsed result")
            }
            return nextToolCallToIntent(parsed, input: input, id: id, createdAt: stamp)
        } catch {
            return .blockedIntent(status: .blocked, input: input, id: id, createdAt: stamp,
                                  reason: "Intent resolver failed: \(message(for: error))")
        }
    }

    /// `nextToolCallToIntent`. An `act` becomes a ready intent carrying a single generic
    /// `tool_call` step; risk + approval are derived from the tool name (never the model).
    static func nextToolCallToIntent(
        _ next: NextToolCall,
        input: Contracts.IntentInput,
        id: String,
        createdAt: String
    ) -> Contracts.ResolvedIntent {
        switch next.status {
        case .done:
            let summary = trimmedOrNil(next.summary) ?? "Goal satisfied"
            return .satisfied(.init(id: id, input: input, summary: summary, createdAt: createdAt))
        case .clarify:
            return .blockedIntent(
                status: .clarificationRequired, input: input, id: id, createdAt: createdAt,
                reason: trimmedOrNil(next.reason) ?? "The intent resolver needs clarification")
        case .blocked:
            return .blockedIntent(
                status: .blocked, input: input, id: id, createdAt: createdAt,
                reason: trimmedOrNil(next.reason) ?? "The intent resolver blocked the goal")
        case .act:
            return actToIntent(next, input: input, id: id, createdAt: createdAt)
        }
    }

    private static func actToIntent(
        _ next: NextToolCall,
        input: Contracts.IntentInput,
        id: String,
        createdAt: String
    ) -> Contracts.ResolvedIntent {
        // Validate the tool name against the real driver surface (a hallucinated name is blocked).
        guard let toolName = next.tool, let tool = Contracts.DriverTool.parse(toolName) else {
            return .blockedIntent(
                status: .blocked, input: input, id: id, createdAt: createdAt,
                reason: "The intent resolver chose an unknown tool: \(next.tool ?? "nil")")
        }

        let args = parseToolArgs(next.args)
        // Provisional risk for the DISPLAY intent. The loop is authoritative — it re-derives
        // risk against the live snapshot (escalating a commit click to mutating). Here we use
        // the tool's UN-escalated base by passing an EMPTY-but-PRESENT element, so a click
        // resolves to its navigation base (reversible) rather than the no-context "gate
        // everything" default. Approval is still derived from risk, never the model.
        let risk = Contracts.ToolRisk.riskForToolName(tool.rawValue, target: Self.emptyElementTarget)
        let label = trimmedOrNil(next.rationale) ?? "Call \(tool.rawValue)"
        let plan = Contracts.ActionPlan(
            id: "\(id)-plan",
            summary: label,
            riskLevel: risk,
            requiresApproval: risk.requiresApproval,
            targetAgent: .cuaDriver,
            actionPlan: [.toolCall(id: "\(id)-step", label: label, tool: tool, args: args)]
        )
        return .ready(.init(
            id: id,
            input: input,
            intentType: .inspect,
            referent: nil,
            constraints: [],
            riskLevel: risk,
            requiresApproval: risk.requiresApproval,
            targetAgent: .cuaDriver,
            actionPlan: plan,
            createdAt: createdAt
        ))
    }

    /// `parseToolArgs`. The model hands `args` back as a JSON object string; the loop wants a
    /// real record. Parse defensively — null/empty/malformed JSON, or anything that isn't a
    /// plain object (array, string, number, null), collapses to `[:]` so a bad payload degrades
    /// to "call with no args" rather than failing the resolver.
    static func parseToolArgs(_ raw: String?) -> [String: Contracts.JSONValue] {
        guard let raw, !raw.isEmpty else { return [:] }
        guard let value = try? JSONDecoder().decode(Contracts.JSONValue.self, from: Data(raw.utf8)),
              case let .object(fields) = value
        else { return [:] }
        return fields
    }

    // MARK: - Helpers

    /// The empty-but-present element target used for the provisional display-intent risk: a
    /// click with a present element whose fields are all nil resolves to its reversible
    /// navigation base (mirrors the TS `{ element: {} }`).
    private static let emptyElementTarget = Contracts.ToolCallTarget(
        element: .init(role: nil, title: nil, label: nil, value: nil),
        key: nil, keys: nil, pageAction: nil
    )

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func message(for error: Error) -> String {
        if let described = error as? CustomStringConvertible { return described.description }
        return String(describing: error)
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
