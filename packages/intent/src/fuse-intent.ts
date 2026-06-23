import type {
  ActionPlan,
  ActionStep,
  ActionTarget,
  IntentInput,
  PointingEvidence,
  ResolvedIntent,
} from "@handsoff/contracts";

import { requiresApproval, riskForIntent } from "./risk";
import { parseVoiceCommand } from "./voice-command-parser";

export type FuseIntentOptions = {
  intentId?: string;
  planId?: string;
  createdAt?: string;
  minConfidence?: number;
};

export function fuseIntent(input: IntentInput, options: FuseIntentOptions = {}): ResolvedIntent {
  const createdAt = options.createdAt ?? new Date().toISOString();
  const id = options.intentId ?? "intent-1";
  const evidence = bestEvidence(input.pointingEvidence);
  const surface = evidence?.surface ?? input.surfaceCandidates[0];

  if (input.surfaceCandidates.length === 0) {
    return blockedIntent(
      "clarification_required",
      input,
      id,
      createdAt,
      "No attention-region candidates were available",
    );
  }
  if (!evidence || evidence.confidence < (options.minConfidence ?? 0.5)) {
    return blockedIntent(
      "clarification_required",
      input,
      id,
      createdAt,
      "Pointing confidence is too low",
    );
  }
  if (!surface || surface.availability !== "available" || surface.accessStatus !== "accessible") {
    return blockedIntent(
      "clarification_required",
      input,
      id,
      createdAt,
      "No accessible target was found",
    );
  }

  const parsed = parseVoiceCommand(input.speech.finalTranscript.text);
  if (parsed.status === "unsupported") {
    return blockedIntent("blocked", input, id, createdAt, parsed.reason);
  }

  const risk_level = riskForIntent(parsed.intent_type);
  const requires_approval = requiresApproval(risk_level);
  const target: ActionTarget = { surface, elementIndex: 0 };
  const action_plan = planFor({
    planId: options.planId ?? "plan-1",
    intentType: parsed.intent_type,
    target,
    text: parsed.text,
    value: parsed.value,
    risk_level,
    requires_approval,
  });

  return {
    status: "ready",
    id,
    input,
    intent_type: parsed.intent_type,
    referent: { id: surface.id, source: "fusion", confidence: evidence.confidence },
    constraints: [],
    risk_level,
    requires_approval,
    target_agent: action_plan.target_agent,
    action_plan,
    createdAt,
  };
}

function bestEvidence(evidence: readonly PointingEvidence[]): PointingEvidence | undefined {
  return [...evidence].sort((a, b) => b.confidence - a.confidence)[0];
}

export function blockedIntent(
  status: "blocked" | "clarification_required",
  input: IntentInput,
  id: string,
  createdAt: string,
  reason: string,
): ResolvedIntent {
  return {
    status,
    id,
    input,
    constraints: [],
    requires_approval: false,
    target_agent: "none",
    reason,
    createdAt,
  };
}

function planFor(args: {
  planId: string;
  intentType: ResolvedIntent["intent_type"];
  target: ActionTarget;
  text?: string;
  value?: string;
  risk_level: ActionPlan["risk_level"];
  requires_approval: boolean;
}): ActionPlan {
  const steps: ActionStep[] =
    args.intentType === "inspect"
      ? [
          {
            id: "step-1",
            kind: "inspect_window_state",
            label: "Inspect selected window",
            target: args.target,
          },
        ]
      : args.intentType === "click"
        ? [
            {
              id: "step-1",
              kind: "click_element",
              label: "Click selected target",
              target: args.target,
            },
          ]
        : args.intentType === "type_text"
          ? [
              {
                id: "step-1",
                kind: "type_text",
                label: "Type dictated text",
                target: args.target,
                text: args.text ?? "",
              },
            ]
          : args.intentType === "set_value"
            ? [
                {
                  id: "step-1",
                  kind: "set_value",
                  label: "Set selected value",
                  target: args.target,
                  value: args.value ?? "",
                },
              ]
            : [];

  return {
    id: args.planId,
    summary: summaryFor(args.intentType),
    risk_level: args.risk_level,
    requires_approval: args.requires_approval,
    target_agent: steps.length > 0 ? "cua-driver" : "none",
    action_plan: steps,
  };
}

function summaryFor(intentType: ResolvedIntent["intent_type"]): string {
  return intentType === "inspect"
    ? "Inspect the selected window"
    : intentType === "click"
      ? "Click the selected target"
      : intentType === "type_text"
        ? "Type dictated text into the selected target"
        : intentType === "set_value"
          ? "Set the selected value"
          : "Control the current run";
}
