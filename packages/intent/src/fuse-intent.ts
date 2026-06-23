import type {
  ActionPlan,
  ActionStep,
  ActionTarget,
  ClarificationReason,
  ClarificationRequest,
  IntentInput,
  PointingEvidence,
  ResolvedIntent,
  SurfaceSnapshot,
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

  const parsed = parseVoiceCommand(input.speech.finalTranscript.text);
  if (parsed.status === "unsupported") {
    return blockedIntent("blocked", input, id, createdAt, parsed.reason);
  }

  // When the voice names an app ("open Cursor", "open TextEdit and type …") that
  // surface IS the target — pointing only needs to agree, not disambiguate. With no
  // named app, the clarification policy (#36) decides whether the gesture/head
  // pointing bound a referent well enough to act, or whether to ask. It runs on the
  // calibrated-confidence (#100) candidates; the 0.5 floor is its minConfidence.
  const voiceTargetSurface = parsed.appName ? surfaceForApp(parsed.appName) : undefined;

  let surface: SurfaceSnapshot | undefined;
  let confidence: number;
  if (voiceTargetSurface) {
    surface = voiceTargetSurface;
    confidence = 1;
  } else {
    const candidates = clarificationCandidates(input);
    const decision = decideClarification(candidates, {
      minConfidence: options.minConfidence ?? 0.5,
      ambiguityMargin: DEFAULT_CLARIFICATION_POLICY.ambiguityMargin,
    });
    if (decision.kind === "clarify") {
      return clarificationRequired(input, id, createdAt, decision.request);
    }
    const chosen = candidates.find((c) => c.targetId === decision.targetId);
    surface = chosen?.surface ?? input.surfaceCandidates[0];
    confidence = chosen?.confidence ?? 0;
  }

  if (
    !surface ||
    (!voiceTargetSurface &&
      (surface.availability !== "available" || surface.accessStatus !== "accessible"))
  ) {
    return blockedIntent(
      "clarification_required",
      input,
      id,
      createdAt,
      "No accessible target was found",
    );
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
    appName: parsed.appName,
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

function surfaceForApp(appName: string): SurfaceSnapshot {
  return {
    id: `app:${appName.toLowerCase()}`,
    title: appName,
    app: appName,
    availability: "unknown",
    accessStatus: "unknown",
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
  const withSurface: ClarificationCandidate[] = [];
  for (const e of input.pointingEvidence) {
    if (!e.surface) continue;
    withSurface.push({
      targetId: e.surface.id,
      label: `${e.surface.app} — ${e.surface.title}`,
      confidence: e.confidence,
      surface: e.surface,
    });
  }
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

interface PlanArgs {
  planId: string;
  intentType: ResolvedIntent["intent_type"];
  target: ActionTarget;
  text?: string;
  value?: string;
  risk_level: ActionPlan["risk_level"];
  requires_approval: boolean;
  appName?: string;
}

type IntentType = NonNullable<ResolvedIntent["intent_type"]>;

// The single step each actionable intent type expands to. Types absent here
// (e.g. control intents) produce no steps and route to "none". stepId differs
// when an app launch precedes the action (then the action becomes step-2).
const STEP_BUILDERS: Partial<Record<IntentType, (args: PlanArgs, stepId: string) => ActionStep>> = {
  inspect: (a, stepId) => ({
    id: stepId,
    kind: "inspect_window_state",
    label: "Inspect selected window",
    target: a.target,
  }),
  click: (a, stepId) => ({
    id: stepId,
    kind: "click_element",
    label: "Click selected target",
    target: a.target,
  }),
  type_text: (a, stepId) => ({
    id: stepId,
    kind: "type_text",
    label: "Type dictated text",
    target: a.target,
    text: a.text ?? "",
  }),
  set_value: (a, stepId) => ({
    id: stepId,
    kind: "set_value",
    label: "Set selected value",
    target: a.target,
    value: a.value ?? "",
  }),
};

const SUMMARIES: Partial<Record<IntentType, string>> = {
  inspect: "Inspect the selected window",
  click: "Click the selected target",
  type_text: "Type dictated text into the selected target",
  set_value: "Set the selected value",
};

function planFor(args: PlanArgs): ActionPlan {
  // A voice-named app launches first; the action then targets it as the next step.
  const launchSteps: ActionStep[] = args.appName
    ? [
        {
          id: "step-1",
          kind: "launch_app",
          label: `Open ${args.appName}`,
          appName: args.appName,
        },
      ]
    : [];
  const actionStepId = args.appName ? "step-2" : "step-1";
  const build = args.intentType ? STEP_BUILDERS[args.intentType] : undefined;
  const steps: ActionStep[] = build ? [build(args, actionStepId)] : [];

  return {
    id: args.planId,
    summary: summaryFor(args.intentType),
    risk_level: args.risk_level,
    requires_approval: args.requires_approval,
    target_agent: launchSteps.length + steps.length > 0 ? "cua-driver" : "none",
    action_plan: [...launchSteps, ...steps],
  };
}

function summaryFor(intentType: ResolvedIntent["intent_type"]): string {
  return (intentType ? SUMMARIES[intentType] : undefined) ?? "Control the current run";
}
