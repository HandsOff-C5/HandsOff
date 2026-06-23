import type {
  ActionPlan,
  ActionStep,
  ActionTarget,
  ClarificationReason,
  ClarificationRequest,
  IntentInput,
  PointingEvidence,
  ResolvedIntent,
} from "@handsoff/contracts";

import {
  decideClarification,
  DEFAULT_CLARIFICATION_POLICY,
  type ClarificationCandidate,
} from "./clarification/decide";
import { requiresApproval, riskForIntent } from "./risk";
import { parseVoiceCommand } from "./voice-command-parser";

// Reason → user-facing string. low_confidence keeps the original wording so the
// existing contract/tests are unchanged; the structured prompt carries the rest
// for the dashboard (#36).
const CLARIFICATION_REASON_TEXT: Record<ClarificationReason, string> = {
  low_confidence: "Pointing confidence is too low",
  ambiguous: "Multiple targets matched — choose one",
  no_target: "No target was found where you pointed",
};

export type FuseIntentOptions = {
  intentId?: string;
  planId?: string;
  createdAt?: string;
  minConfidence?: number;
};

export function fuseIntent(input: IntentInput, options: FuseIntentOptions = {}): ResolvedIntent {
  const createdAt = options.createdAt ?? new Date().toISOString();
  const id = options.intentId ?? "intent-1";

  // The clarification policy (#36) decides whether the referent is bound well
  // enough to act, or whether to ask. It runs on the calibrated-confidence (#100)
  // candidates; the 0.5 floor is preserved as its minConfidence.
  const candidates = clarificationCandidates(input);
  const decision = decideClarification(candidates, {
    minConfidence: options.minConfidence ?? 0.5,
    ambiguityMargin: DEFAULT_CLARIFICATION_POLICY.ambiguityMargin,
  });
  if (decision.kind === "clarify") {
    return clarificationRequired(input, id, createdAt, decision.request);
  }

  const surface =
    candidates.find((c) => c.targetId === decision.targetId)?.surface ?? input.surfaceCandidates[0];
  const confidence = candidates.find((c) => c.targetId === decision.targetId)?.confidence ?? 0;
  if (!surface || surface.availability !== "available" || surface.accessStatus !== "accessible") {
    return blocked(
      "clarification_required",
      input,
      id,
      createdAt,
      "No accessible target was found",
    );
  }

  const parsed = parseVoiceCommand(input.speech.finalTranscript.text);
  if (parsed.status === "unsupported") {
    return blocked("blocked", input, id, createdAt, parsed.reason);
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
    referent: { id: surface.id, source: "fusion", confidence },
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

// Map the pointing evidence to clarification candidates: prefer per-surface
// evidence (the real multi-candidate case that surfaces ambiguity); if no
// evidence carried a surface, pair the best confidence with the top surface
// candidate so a single weak bind still reads as low_confidence (not no_target).
function clarificationCandidates(input: IntentInput): ClarificationCandidate[] {
  const withSurface = input.pointingEvidence.flatMap((e) =>
    e.surface
      ? [
          {
            targetId: e.surface.id,
            label: `${e.surface.app} — ${e.surface.title}`,
            confidence: e.confidence,
            surface: e.surface,
          },
        ]
      : [],
  );
  if (withSurface.length > 0) return withSurface;

  const best = bestEvidence(input.pointingEvidence);
  const surface = input.surfaceCandidates[0];
  if (best && surface) {
    return [
      {
        targetId: surface.id,
        label: `${surface.app} — ${surface.title}`,
        confidence: best.confidence,
        surface,
      },
    ];
  }
  return [];
}

function clarificationRequired(
  input: IntentInput,
  id: string,
  createdAt: string,
  request: ClarificationRequest,
): ResolvedIntent {
  return {
    status: "clarification_required",
    id,
    input,
    constraints: [],
    requires_approval: false,
    target_agent: "none",
    reason: CLARIFICATION_REASON_TEXT[request.reason],
    clarification: request,
    createdAt,
  };
}

function blocked(
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
